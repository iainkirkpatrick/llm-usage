import Foundation

/// Shared across fetcher instances; a failed account cannot be hammered by the UI refresh timer.
actor ClaudeQuotaBackoff {
    static let shared = ClaudeQuotaBackoff()
    private var deadlines: [String: Date] = [:]
    private var failures: [String: Int] = [:]

    func check(_ keys: [String], now: Date) throws {
        if keys.contains(where: { (deadlines[$0] ?? .distantPast) > now }) {
            throw ClaudeBackendError.backoff
        }
    }

    func fail(_ keys: [String], now: Date, minimum: TimeInterval) {
        for key in keys {
            let count = min(6, (failures[key] ?? 0) + 1)
            failures[key] = count
            let delay = min(3600, max(minimum, 30 * pow(2, Double(count))))
            deadlines[key] = now.addingTimeInterval(delay)
        }
    }

    func success(_ keys: [String]) {
        for key in keys { deadlines.removeValue(forKey: key); failures.removeValue(forKey: key) }
    }
}

final class ClaudeNoRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct ClaudeUsageFetcher: Sendable {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    private let transport: Transport
    private let credentials: ClaudeCredentials.Reader
    private let backoff: ClaudeQuotaBackoff
    private let now: @Sendable () -> Date

    init(transport: @escaping Transport = ClaudeUsageFetcher.liveTransport,
         credentialReader: @escaping ClaudeCredentials.Reader = { profile, prompt in
             try ClaudeCredentials.read(profile: profile, allowKeychainPrompt: prompt)
         }, backoff: ClaudeQuotaBackoff = .shared,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.transport = transport
        self.credentials = credentialReader
        self.backoff = backoff
        self.now = now
    }

    static func sessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        return configuration
    }

    static func liveTransport(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let session = URLSession(configuration: sessionConfiguration(), delegate: ClaudeNoRedirectDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw ClaudeBackendError.invalidResponse }
        return (data, response)
    }

    func fetch(profile: ClaudeAccountProfile, allowKeychainPrompt: Bool = false) async throws -> ClaudeQuotaSnapshot {
        var keys = ["profile:" + ClaudeCredentials.serviceName(for: profile)]
        if let account = profile.accountID { keys.append("account:" + account) }
        try await backoff.check(keys, now: now())
        try Task.checkCancellation()
        let credential: ClaudeCredential
        do { credential = try credentials(profile, allowKeychainPrompt) }
        catch let error as ClaudeBackendError { throw error }
        catch { throw ClaudeBackendError.credentialsInvalid }
        guard credential.expiresAt > now() else { throw ClaudeBackendError.credentialsExpired }
        if let scopes = credential.scopes, !scopes.contains("user:profile") { throw ClaudeBackendError.scopeMissing }
        let identity = try Self.identity(try await request("profile", credential: credential, keys: keys))
        if let expected = profile.accountID, expected != identity.id { throw ClaudeBackendError.identityMismatch }
        let accountKey = "account:" + identity.id
        if !keys.contains(accountKey) { keys.append(accountKey) }
        try await backoff.check(keys, now: now())
        let usage = try await request("usage", credential: credential, keys: keys)
        try Task.checkCancellation()
        // Re-read silently: never prompt again from a background completion check.
        let current: ClaudeCredential
        do { current = try credentials(profile, false) }
        catch { throw ClaudeBackendError.credentialChanged }
        guard current.accessToken == credential.accessToken, current.expiresAt > now() else {
            throw ClaudeBackendError.credentialChanged
        }
        let result = try Self.snapshot(usage: usage, accountID: identity.id, email: identity.email,
                                       credential: credential, now: now())
        await backoff.success(keys)
        return result
    }

    private func request(_ endpoint: String, credential: ClaudeCredential, keys: [String]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/" + endpoint)!)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("Bearer " + credential.accessToken, forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data
        let response: HTTPURLResponse
        do { (data, response) = try await transport(request) }
        catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            await backoff.fail(keys, now: now(), minimum: 60)
            throw ClaudeBackendError.network
        }
        try Task.checkCancellation()
        guard response.statusCode == 200 else {
            let error: ClaudeBackendError
            switch response.statusCode {
            case 401: error = .unauthorized
            case 403: error = .forbidden
            case 429: error = .rateLimited
            default: error = .invalidResponse
            }
            let minimum = response.statusCode == 401 || response.statusCode == 403 ? 300.0 : 60.0
            await backoff.fail(keys, now: now(), minimum: max(minimum, Self.retryAfter(response, now: now()) ?? 0))
            throw error
        }
        guard data.count <= 2 * 1_048_576,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            await backoff.fail(keys, now: now(), minimum: 60)
            throw ClaudeBackendError.invalidResponse
        }
        return json
    }

    static func retryAfter(_ response: HTTPURLResponse, now: Date) -> TimeInterval? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After") else { return nil }
        if let seconds = Double(value), seconds.isFinite { return max(0, min(3600, seconds)) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
        return formatter.date(from: value).map { max(0, min(3600, $0.timeIntervalSince(now))) }
    }

    static func identity(_ json: [String: Any]) throws -> (id: String, email: String?) {
        let account = json["account"] as? [String: Any]
        let organization = json["organization"] as? [String: Any]
        guard let accountID = (account?["uuid"] ?? json["account_uuid"]) as? String,
              let organizationID = (organization?["uuid"] ?? json["organization_uuid"]) as? String,
              UUID(uuidString: accountID) != nil, UUID(uuidString: organizationID) != nil else {
            throw ClaudeBackendError.identityMissing
        }
        return (accountID.lowercased() + ":" + organizationID.lowercased(), account?["email_address"] as? String)
    }

    static func date(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }

    static func window(_ value: Any?, percentKey: String = "utilization") -> RateWindow? {
        guard let dictionary = value as? [String: Any],
              let percent = ClaudeJSON.number(dictionary[percentKey]), (0...100).contains(percent) else { return nil }
        return RateWindow(usedPercent: percent, resetAt: date(dictionary["resets_at"]))
    }

    static func snapshot(usage: [String: Any], accountID: String, email: String?,
                         credential: ClaudeCredential, now: Date) throws -> ClaudeQuotaSnapshot {
        var fiveHour = window(usage["five_hour"])
        var weekly = window(usage["seven_day"]) ?? window(usage["seven_day_oauth_apps"])
        var modelWindows: [ClaudeNamedRateWindow] = []
        for key in usage.keys.sorted() where key.hasPrefix("seven_day_") && key != "seven_day_oauth_apps" {
            if let window = window(usage[key]) {
                let title = key.dropFirst("seven_day_".count).replacingOccurrences(of: "_", with: " ").capitalized
                modelWindows.append(ClaudeNamedRateWindow(title: title, window: window))
            }
        }
        if let limits = usage["limits"] as? [Any] {
            for value in limits {
                guard let limit = value as? [String: Any], let kind = limit["kind"] as? String,
                      let window = window(limit, percentKey: "percent") else { continue }
                switch kind {
                case "session": fiveHour = fiveHour ?? window
                case "weekly_all": weekly = weekly ?? window
                case "weekly_scoped":
                    guard let scope = limit["scope"] as? [String: Any], let model = scope["model"] as? [String: Any],
                          let name = model["display_name"] as? String, !name.isEmpty else { continue }
                    if !modelWindows.contains(where: { $0.title.caseInsensitiveCompare(name) == .orderedSame }) {
                        modelWindows.append(ClaudeNamedRateWindow(title: name, window: window))
                    }
                default: continue
                }
            }
        }
        var extra: ClaudeExtraUsage?
        if let value = usage["extra_usage"] as? [String: Any],
           let enabled = value["is_enabled"] as? NSNumber,
           CFGetTypeID(enabled) == CFBooleanGetTypeID(), enabled.boolValue {
            func dollars(_ key: String) -> Double? {
                guard let number = ClaudeJSON.number(value[key]), number >= 0 else { return nil }
                return number / 100
            }
            let used = dollars("used_credits")
            let limit = dollars("monthly_limit")
            if used != nil || limit != nil { extra = ClaudeExtraUsage(usedUSD: used, limitUSD: limit) }
        }
        guard fiveHour != nil || weekly != nil || !modelWindows.isEmpty || extra != nil else {
            throw ClaudeBackendError.quotaMissing
        }
        return ClaudeQuotaSnapshot(accountID: accountID, email: email,
                                   planType: credential.subscriptionType ?? credential.rateLimitTier,
                                   fiveHour: fiveHour, weekly: weekly, modelWindows: modelWindows,
                                   extraUsage: extra, updatedAt: now)
    }
}

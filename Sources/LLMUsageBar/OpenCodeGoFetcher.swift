import Foundation
import JavaScriptCore

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum OpenCodeGoError: LocalizedError {
    case missingCookie
    case authenticationRequired
    case workspaceNotFound
    case malformedResponse(String)
    case apiError(String)

    var errorDescription: String? {
        switch self {
        case .missingCookie:
            "Cookie missing (import from Chromium or set manually)."
        case .authenticationRequired:
            "Authentication required (refresh OpenCode cookie)."
        case .workspaceNotFound:
            "No workspace found for this account."
        case let .malformedResponse(message):
            "Parse failed: \(message)"
        case let .apiError(message):
            "API error: \(message)"
        }
    }
}

struct OpenCodeGoFetcher {
    private let workspaceListID = "def39973159c7f0483d8793a822b8dbb10d067e12c65455fcb4608459ba0234f"
    private let subscriptionID = "f6fef39ee2c7c233a226d062b50a92eef4a30ebec5d3ec95b8092081d13ddc75"
    private let usageHistoryID = "329c8c3a3db6af6ea9c1936376af2e8afc75fa2330999ddfaab1cacd6f2c1157"

    private let baseURL = URL(string: "https://opencode.ai")!

    func fetch(cookieHeader: String?, workspaceID: String?) async throws -> OpenCodeSnapshot {
        let resolvedCookieHeader: String
        if let manual = Self.normalizeCookie(cookieHeader) {
            resolvedCookieHeader = manual
        } else if let imported = OpenCodeCookieAutoImporter.tryImportCookieHeader(),
                  let normalizedImported = Self.normalizeCookie(imported)
        {
            resolvedCookieHeader = normalizedImported
        } else {
            throw OpenCodeGoError.missingCookie
        }

        let resolvedWorkspaceID = try await self.resolveWorkspaceID(cookieHeader: resolvedCookieHeader, configured: workspaceID)
        let limitsAny = try? await self.callServerFunction(
            id: self.subscriptionID,
            args: [resolvedWorkspaceID],
            cookieHeader: resolvedCookieHeader,
            refererPath: "/workspace/\(resolvedWorkspaceID)/billing"
        )
        let limits = limitsAny.flatMap { Self.parseLimits(from: $0) }

        let rows = try await self.fetchUsageRows(
            workspaceID: resolvedWorkspaceID,
            cookieHeader: resolvedCookieHeader
        )

        return OpenCodeSnapshot(
            workspaceID: resolvedWorkspaceID,
            limits: limits,
            rows: rows,
            updatedAt: Date()
        )
    }

    private func resolveWorkspaceID(cookieHeader: String, configured: String?) async throws -> String {
        if let configured = Self.normalizeWorkspaceID(configured) {
            return configured
        }

        let any = try await self.callServerFunction(
            id: self.workspaceListID,
            args: [],
            cookieHeader: cookieHeader,
            refererPath: "/"
        )
        let ids = Self.extractWorkspaceIDs(from: any)
        if let first = ids.first {
            return first
        }

        if let fallback = try await self.fetchWorkspaceIDFromRawScript(cookieHeader: cookieHeader) {
            return fallback
        }

        throw OpenCodeGoError.workspaceNotFound
    }

    private func fetchWorkspaceIDFromRawScript(cookieHeader: String) async throws -> String? {
        var components = URLComponents(url: self.baseURL.appendingPathComponent("_server"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "id", value: self.workspaceListID)]

        guard let url = components?.url else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue(self.workspaceListID, forHTTPHeaderField: "X-Server-Id")
        request.setValue("server-fn:llm-usage-bar-\(UUID().uuidString)", forHTTPHeaderField: "X-Server-Instance")
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue("https://opencode.ai", forHTTPHeaderField: "Origin")
        request.setValue("https://opencode.ai/", forHTTPHeaderField: "Referer")
        request.setValue("text/javascript, application/json;q=0.9, */*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { return nil }

        if http.statusCode == 401 || http.statusCode == 403 {
            throw OpenCodeGoError.authenticationRequired
        }

        guard let text = String(data: data, encoding: .utf8) else { return nil }

        if text.contains("/auth/authorize") && text.contains("status:302") {
            throw OpenCodeGoError.authenticationRequired
        }

        if let range = text.range(of: #"wrk_[A-Za-z0-9]+"#, options: .regularExpression) {
            return String(text[range])
        }

        return nil
    }

    private func fetchUsageRows(workspaceID: String, cookieHeader: String) async throws -> [OpenCodeUsageRow] {
        let pageSize = 50
        let maxPages = 6
        var allRows: [OpenCodeUsageRow] = []

        for page in 0..<maxPages {
            let any = try await self.callServerFunction(
                id: self.usageHistoryID,
                args: [workspaceID, page],
                cookieHeader: cookieHeader,
                refererPath: "/workspace/\(workspaceID)"
            )
            let rows = Self.extractUsageRows(from: any)
            allRows.append(contentsOf: rows)
            if rows.count < pageSize { break }
        }

        return allRows.sorted(by: { $0.timeCreated > $1.timeCreated })
    }

    private func callServerFunction(
        id: String,
        args: [Any],
        cookieHeader: String,
        refererPath: String
    ) async throws -> Any {
        var components = URLComponents(url: self.baseURL.appendingPathComponent("_server"), resolvingAgainstBaseURL: false)
        var queryItems: [URLQueryItem] = [URLQueryItem(name: "id", value: id)]
        if !args.isEmpty {
            let data = try JSONSerialization.data(withJSONObject: args, options: [])
            let encoded = String(decoding: data, as: UTF8.self)
            queryItems.append(URLQueryItem(name: "args", value: encoded))
        }
        components?.queryItems = queryItems

        guard let url = components?.url else {
            throw OpenCodeGoError.apiError("Failed to build OpenCode URL.")
        }

        let instanceID = "server-fn:llm-usage-bar-\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue(id, forHTTPHeaderField: "X-Server-Id")
        request.setValue(instanceID, forHTTPHeaderField: "X-Server-Instance")
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue("https://opencode.ai", forHTTPHeaderField: "Origin")
        request.setValue("https://opencode.ai\(refererPath)", forHTTPHeaderField: "Referer")
        request.setValue("text/javascript, application/json;q=0.9, */*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OpenCodeGoError.apiError("Invalid HTTP response.")
        }

        if http.statusCode == 401 || http.statusCode == 403 {
            throw OpenCodeGoError.authenticationRequired
        }

        if let location = http.value(forHTTPHeaderField: "Location"),
           location.contains("/auth/authorize")
        {
            throw OpenCodeGoError.authenticationRequired
        }

        if http.value(forHTTPHeaderField: "X-Error") == "true" || http.value(forHTTPHeaderField: "x-error") == "true" {
            if let location = http.value(forHTTPHeaderField: "Location"), location.contains("/auth/authorize") {
                throw OpenCodeGoError.authenticationRequired
            }
        }

        let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        if contentType.contains("application/json") {
            return try JSONSerialization.jsonObject(with: data, options: [])
        }

        guard let text = String(data: data, encoding: .utf8) else {
            throw OpenCodeGoError.malformedResponse("Response was not UTF-8.")
        }

        if text.contains("/auth/authorize") && text.contains("status:302") {
            throw OpenCodeGoError.authenticationRequired
        }

        if let decoded = Self.decodeServerFunctionScript(text, instanceID: instanceID) {
            return decoded
        }

        throw OpenCodeGoError.malformedResponse("Could not decode server function payload.")
    }

    private static func decodeServerFunctionScript(_ script: String, instanceID: String) -> Any? {
        let context = JSContext()
        context?.exceptionHandler = { _, _ in }

        _ = context?.evaluateScript(
            "var self = {}; " +
                "function Headers(init){ this.init = init; } " +
                "function Response(body, init){ this.body = body; this.init = init || {}; this.status = this.init.status; this.statusText = this.init.statusText; this.headers = this.init.headers; }"
        )
        _ = context?.evaluateScript(script)

        guard let map = context?.objectForKeyedSubscript("self")?.forProperty("$R") else {
            return nil
        }

        var bucket = map.forProperty(instanceID)
        if bucket == nil || bucket?.isUndefined == true {
            if let dict = map.toDictionary() as? [String: Any], let key = dict.keys.first {
                bucket = map.forProperty(key)
            }
        }

        guard let bucket else { return nil }

        let length = Int(bucket.forProperty("length")?.toInt32() ?? -1)
        if length == 0 {
            return NSNull()
        }

        guard let first = bucket.atIndex(0), !first.isUndefined else {
            return nil
        }

        return first.toObject() ?? NSNull()
    }

    private static func parseLimits(from any: Any) -> OpenCodeGoLimits? {
        if let dict = any as? [String: Any] {
            if let limits = self.parseLimitsDict(dict) {
                return limits
            }
            for value in dict.values {
                if let limits = self.parseLimits(from: value) {
                    return limits
                }
            }
        }

        if let array = any as? [Any] {
            for value in array {
                if let limits = self.parseLimits(from: value) {
                    return limits
                }
            }
        }

        return nil
    }

    private static func parseLimitsDict(_ dict: [String: Any]) -> OpenCodeGoLimits? {
        let now = Date()

        let rolling = self.parseWindow(dict["rollingUsage"] as? [String: Any], now: now)
        let weekly = self.parseWindow(dict["weeklyUsage"] as? [String: Any], now: now)
        let monthly = self.parseWindow(dict["monthlyUsage"] as? [String: Any], now: now)

        if rolling != nil || weekly != nil || monthly != nil {
            return OpenCodeGoLimits(
                fiveHour: rolling,
                weekly: weekly,
                monthly: monthly,
                updatedAt: now
            )
        }

        return nil
    }

    private static func parseWindow(_ dict: [String: Any]?, now: Date) -> RateWindow? {
        guard let dict else { return nil }

        let rawPercent = self.double(dict["usagePercent"]) ?? self.double(dict["usedPercent"]) ?? self.double(dict["percentUsed"])
        guard let percent = rawPercent else { return nil }

        let usedPercent: Double = if percent <= 1.0 { percent * 100 } else { percent }
        let resetInSec = self.int(dict["resetInSec"]) ?? self.int(dict["resetSeconds"]) ?? self.int(dict["resetsInSec"])
        let resetAt: Date? = resetInSec.map { now.addingTimeInterval(TimeInterval($0)) }

        return RateWindow(usedPercent: usedPercent, resetAt: resetAt)
    }

    private static func extractWorkspaceIDs(from any: Any) -> [String] {
        var ids: [String] = []
        self.collectWorkspaceIDs(any, into: &ids)
        return ids
    }

    private static func collectWorkspaceIDs(_ any: Any, into ids: inout [String]) {
        if let value = any as? String,
           value.hasPrefix("wrk_"),
           !ids.contains(value)
        {
            ids.append(value)
            return
        }

        if let dict = any as? [String: Any] {
            for value in dict.values {
                self.collectWorkspaceIDs(value, into: &ids)
            }
            return
        }

        if let array = any as? [Any] {
            for value in array {
                self.collectWorkspaceIDs(value, into: &ids)
            }
        }
    }

    private static func extractUsageRows(from any: Any) -> [OpenCodeUsageRow] {
        var rows: [OpenCodeUsageRow] = []
        self.collectRows(any, into: &rows)
        return rows
    }

    private static func collectRows(_ any: Any, into rows: inout [OpenCodeUsageRow]) {
        if let dict = any as? [String: Any] {
            if let row = self.row(from: dict) {
                rows.append(row)
            }
            for value in dict.values {
                self.collectRows(value, into: &rows)
            }
            return
        }

        if let array = any as? [Any] {
            for value in array {
                self.collectRows(value, into: &rows)
            }
        }
    }

    private static func row(from dict: [String: Any]) -> OpenCodeUsageRow? {
        guard let model = dict["model"] as? String,
              let time = self.parseDate(dict["timeCreated"]),
              let input = self.int(dict["inputTokens"]),
              let output = self.int(dict["outputTokens"]),
              let costRaw = self.double(dict["cost"])
        else {
            return nil
        }

        let enrichment = dict["enrichment"] as? [String: Any]
        let plan = enrichment?["plan"] as? String

        return OpenCodeUsageRow(
            timeCreated: time,
            model: model,
            inputTokens: input,
            outputTokens: output,
            reasoningTokens: self.int(dict["reasoningTokens"]) ?? 0,
            cacheReadTokens: self.int(dict["cacheReadTokens"]) ?? 0,
            cacheWrite5mTokens: self.int(dict["cacheWrite5mTokens"]) ?? 0,
            cacheWrite1hTokens: self.int(dict["cacheWrite1hTokens"]) ?? 0,
            costUSD: costRaw / 100_000_000,
            plan: plan
        )
    }

    private static func parseDate(_ value: Any?) -> Date? {
        switch value {
        case let number as NSNumber:
            let raw = number.doubleValue
            if raw > 1_000_000_000_000 {
                return Date(timeIntervalSince1970: raw / 1000)
            }
            if raw > 1_000_000_000 {
                return Date(timeIntervalSince1970: raw)
            }
            return nil
        case let string as String:
            if let raw = Double(string) {
                return self.parseDate(raw as NSNumber)
            }
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = iso.date(from: string) { return date }
            iso.formatOptions = [.withInternetDateTime]
            return iso.date(from: string)
        default:
            return nil
        }
    }

    private static func double(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber:
            number.doubleValue
        case let string as String:
            Double(string.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            nil
        }
    }

    private static func int(_ value: Any?) -> Int? {
        switch value {
        case let number as NSNumber:
            number.intValue
        case let string as String:
            Int(string.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            nil
        }
    }

    private static func normalizeWorkspaceID(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        if raw.hasPrefix("wrk_") { return raw }
        if let match = raw.range(of: #"wrk_[A-Za-z0-9]+"#, options: .regularExpression) {
            return String(raw[match])
        }
        return nil
    }

    private static func normalizeCookie(_ raw: String?) -> String? {
        guard var cookie = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !cookie.isEmpty else {
            return nil
        }
        if cookie.lowercased().hasPrefix("cookie:") {
            cookie = String(cookie.dropFirst("cookie:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return cookie.isEmpty ? nil : cookie
    }
}

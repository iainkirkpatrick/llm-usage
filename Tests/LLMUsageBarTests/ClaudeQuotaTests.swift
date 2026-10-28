import CryptoKit
import XCTest
@testable import LLMUsageBar

private final class ClaudeFixtureState: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var recorded: [URLRequest] = []
    func next(_ request: URLRequest? = nil) -> Int {
        lock.lock(); defer { lock.unlock() }
        count += 1
        if let request { recorded.append(request) }
        return count
    }
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return recorded }
}

final class ClaudeQuotaTests: XCTestCase {
    private static let account = "11111111-1111-1111-1111-111111111111"
    private static let organization = "22222222-2222-2222-2222-222222222222"
    private static let identity = account + ":" + organization
    private static let profileJSON = "{\"account\":{\"uuid\":\"\(account)\",\"email_address\":\"fixture@example.test\"},\"organization\":{\"uuid\":\"\(organization)\"}}"
    private static let credentialData = Data(#"{"claudeAiOauth":{"accessToken":"fixture-token","expiresAt":4102444800000,"scopes":["user:profile"],"subscriptionType":"max"}}"#.utf8)
    private static func credential() throws -> ClaudeCredential { try ClaudeCredential.parse(credentialData) }
    private static func response(_ request: URLRequest, _ body: String, status: Int = 200,
                                 headers: [String: String]? = nil) -> (Data, HTTPURLResponse) {
        (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!)
    }
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    func testServiceNamesUseNFCStandardizedAbsolutePathAndDistinguishDefault() {
        let implicit = ClaudeAccountProfile(label: "Default")
        let explicit = ClaudeAccountProfile(label: "Explicit", configDirectory: "~/.claude")
        XCTAssertEqual(ClaudeCredentials.serviceName(for: implicit), "Claude Code-credentials")
        let hash = SHA256.hash(data: Data(explicit.directoryURL.path.precomposedStringWithCanonicalMapping.utf8))
            .map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(ClaudeCredentials.serviceName(for: explicit), "Claude Code-credentials-" + hash.prefix(8))
        XCTAssertNotEqual(ClaudeCredentials.serviceName(for: implicit), ClaudeCredentials.serviceName(for: explicit))
        XCTAssertEqual(ClaudeCredentials.serviceName(for: .init(label: "A", configDirectory: "/tmp/e\u{301}/../e\u{301}")),
                       ClaudeCredentials.serviceName(for: .init(label: "B", configDirectory: "/tmp/é")))
    }

    func testCredentialValidation() throws {
        XCTAssertEqual(try Self.credential().subscriptionType, "max")
        for (json, expected) in [
            (#"{"claudeAiOauth":{"accessToken":"fixture","expiresAt":1}}"#, ClaudeBackendError.credentialsExpired),
            (#"{"claudeAiOauth":{"accessToken":"fixture","expiresAt":4102444800000,"scopes":[]}}"#, .scopeMissing),
            (#"{"claudeAiOauth":{"accessToken":"fixture","expiresAt":true}}"#, .credentialsInvalid),
            (#"{"claudeAiOauth":{"accessToken":"fixture\nheader","expiresAt":4102444800000}}"#, .credentialsInvalid),
            (#"{"claudeAiOauth":{"accessToken":"fixture","expiresAt":4102444800000,"scopes":"user:profile"}}"#, .credentialsInvalid),
        ] {
            XCTAssertThrowsError(try ClaudeCredential.parse(Data(json.utf8))) { XCTAssertEqual($0 as? ClaudeBackendError, expected) }
        }
    }

    func testFileFallbackAndCustomKeychainIsolation() throws {
        let directory = try temporaryDirectory()
        let file = directory.appendingPathComponent(".credentials.json")
        let profile = ClaudeAccountProfile(label: "Fixture", configDirectory: directory.path)
        try Self.credentialData.write(to: file)
        let credential = try ClaudeCredentials.read(profile: profile, allowKeychainPrompt: false) { service, prompt in
            XCTAssertEqual(service, ClaudeCredentials.serviceName(for: profile))
            XCTAssertFalse(prompt)
            return nil
        }
        XCTAssertEqual(credential.accessToken, "fixture-token")
        try Data("malformed".utf8).write(to: file)
        _ = try ClaudeCredentials.read(profile: profile, allowKeychainPrompt: true) { service, interactive in
            XCTAssertEqual(service, ClaudeCredentials.serviceName(for: profile))
            XCTAssertTrue(interactive)
            XCTAssertNotEqual(service, "Claude Code-credentials")
            return Self.credentialData
        }
        try FileManager.default.removeItem(at: file)
        XCTAssertThrowsError(try ClaudeCredentials.read(profile: profile, allowKeychainPrompt: false) { _, prompt in
            XCTAssertFalse(prompt); return nil
        }) { XCTAssertEqual($0 as? ClaudeBackendError, .credentialsMissing) }
    }

    func testConflictingStoresAndDeniedKeychainNeverSilentlyUseOldFile() throws {
        let directory = try temporaryDirectory()
        let profile = ClaudeAccountProfile(label: "Fixture", configDirectory: directory.path)
        try Self.credentialData.write(to: directory.appendingPathComponent(".credentials.json"))
        let other = Data(String(decoding: Self.credentialData, as: UTF8.self).replacingOccurrences(of: "fixture-token", with: "other-account-token").utf8)
        XCTAssertThrowsError(try ClaudeCredentials.read(profile: profile, allowKeychainPrompt: false) { _, _ in other }) {
            XCTAssertEqual($0 as? ClaudeBackendError, .credentialStoresConflict)
        }
        XCTAssertThrowsError(try ClaudeCredentials.read(profile: profile, allowKeychainPrompt: false) { _, _ in
            throw ClaudeBackendError.keychainUnavailable
        }) { XCTAssertEqual($0 as? ClaudeBackendError, .keychainUnavailable) }
        XCTAssertEqual(try ClaudeCredentials.read(profile: profile, allowKeychainPrompt: false) { _, _ in Self.credentialData }.accessToken, "fixture-token")
    }

    func testSymlinkAndOversizedCredentialFilesFailClosed() throws {
        let directory = try temporaryDirectory()
        let target = directory.appendingPathComponent("fixture.json")
        let file = directory.appendingPathComponent(".credentials.json")
        let profile = ClaudeAccountProfile(label: "Fixture", configDirectory: directory.path)
        try Self.credentialData.write(to: target)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        XCTAssertThrowsError(try ClaudeCredentials.read(profile: profile, allowKeychainPrompt: false) { _, _ in
            XCTFail("Unsafe files must fail closed"); return nil
        }) { XCTAssertEqual($0 as? ClaudeBackendError, .unsafeCredentialFile) }
        try FileManager.default.removeItem(at: file)
        try Data(repeating: 0, count: ClaudeCredentials.maximumFileSize + 1).write(to: file)
        XCTAssertThrowsError(try ClaudeCredentials.read(profile: profile, allowKeychainPrompt: false) { _, _ in nil }) {
            XCTAssertEqual($0 as? ClaudeBackendError, .unsafeCredentialFile)
        }
    }

    func testOptionalMalformedWindowsAndSpendUnits() throws {
        let usage = try JSONSerialization.jsonObject(with: Data(#"{"five_hour":{"utilization":true},"seven_day":{"utilization":"20"},"seven_day_oauth_apps":{"utilization":45,"resets_at":"2026-08-01T00:00:00.123Z"},"seven_day_sonnet":{"utilization":101},"seven_day_opus":{"utilization":0},"extra_usage":{"is_enabled":true,"used_credits":1234,"monthly_limit":5000}}"#.utf8)) as! [String: Any]
        let snapshot = try ClaudeUsageFetcher.snapshot(usage: usage, accountID: Self.identity, email: nil, credential: Self.credential(), now: Date())
        XCTAssertNil(snapshot.fiveHour)
        XCTAssertEqual(snapshot.weekly?.usedPercent, 45)
        XCTAssertNotNil(snapshot.weekly?.resetAt)
        XCTAssertEqual(snapshot.modelWindows.map(\.title), ["Opus"])
        XCTAssertEqual(snapshot.extraUsage?.usedUSD, 12.34)
        XCTAssertEqual(snapshot.extraUsage?.limitUSD, 50)
        XCTAssertNotNil(ClaudeUsageFetcher.date("2026-08-01T00:00:00Z"))
        XCTAssertNil(ClaudeUsageFetcher.window(["utilization": Double.infinity]))
        XCTAssertNil(ClaudeUsageFetcher.window(["utilization": -1]))
    }

    func testMissingQuotaIsNotZeroAndSpendOnlyIsValid() throws {
        XCTAssertThrowsError(try ClaudeUsageFetcher.snapshot(usage: [:], accountID: Self.identity, email: nil,
                                                            credential: Self.credential(), now: Date())) {
            XCTAssertEqual($0 as? ClaudeBackendError, .quotaMissing)
        }
        let result = try ClaudeUsageFetcher.snapshot(usage: ["extra_usage": ["is_enabled": true, "used_credits": 100]],
                                                    accountID: Self.identity, email: nil, credential: Self.credential(), now: Date())
        XCTAssertNil(result.fiveHour)
        XCTAssertNil(result.weekly)
        XCTAssertEqual(result.extraUsage?.usedUSD, 1)
        XCTAssertNil(result.extraUsage?.limitUSD)
    }

    func testLimitsList() throws {
        let usage: [String: Any] = ["limits": [
            ["kind": "session", "percent": 12],
            ["kind": "weekly_all", "percent": 34],
            ["kind": "weekly_scoped", "percent": 56, "scope": ["model": ["display_name": "Sonnet"]]],
            ["kind": "session", "percent": "bad"],
        ]]
        let result = try ClaudeUsageFetcher.snapshot(usage: usage, accountID: Self.identity, email: nil,
                                                    credential: Self.credential(), now: Date())
        XCTAssertEqual(result.fiveHour?.usedPercent, 12)
        XCTAssertEqual(result.weekly?.usedPercent, 34)
        XCTAssertEqual(result.modelWindows.first?.title, "Sonnet")
    }

    func testFetchUsesSameTokenAndSilentCompletionRead() async throws {
        let reads = ClaudeFixtureState()
        let requests = ClaudeFixtureState()
        let fetcher = ClaudeUsageFetcher(transport: { request in
            let count = requests.next(request)
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-beta"), "oauth-2025-04-20")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            return Self.response(request, count == 1 ? Self.profileJSON : #"{"five_hour":{"utilization":20}}"#)
        }, credentialReader: { _, prompt in
            XCTAssertEqual(prompt, reads.next() == 1)
            return try Self.credential()
        }, backoff: ClaudeQuotaBackoff())
        let result = try await fetcher.fetch(profile: .init(label: "Fixture", accountID: Self.identity), allowKeychainPrompt: true)
        XCTAssertEqual(result.accountID, Self.identity)
        XCTAssertEqual(result.email, "fixture@example.test")
        XCTAssertEqual(requests.requests.map { $0.url!.lastPathComponent }, ["profile", "usage"])
    }

    func testIdentityMismatchAndMissingOrganizationFailBeforeUsage() async throws {
        for body in [Self.profileJSON, "{\"account_uuid\":\"\(Self.account)\"}"] {
            let requests = ClaudeFixtureState()
            let fetcher = ClaudeUsageFetcher(transport: { request in
                _ = requests.next(request)
                return Self.response(request, body)
            }, credentialReader: { _, _ in try Self.credential() }, backoff: ClaudeQuotaBackoff())
            do {
                _ = try await fetcher.fetch(profile: .init(label: "Fixture", accountID: "other"))
                XCTFail("Must reject identity")
            } catch {
                XCTAssertEqual(error as? ClaudeBackendError, body == Self.profileJSON ? .identityMismatch : .identityMissing)
            }
            XCTAssertEqual(requests.requests.count, 1)
        }
    }

    func testLoginSwitchFailsClosed() async throws {
        let reads = ClaudeFixtureState()
        let fetcher = ClaudeUsageFetcher(transport: { request in
            Self.response(request, request.url!.lastPathComponent == "profile" ? Self.profileJSON : #"{"five_hour":{"utilization":20}}"#)
        }, credentialReader: { _, _ in
            if reads.next() == 1 { return try Self.credential() }
            return ClaudeCredential(accessToken: "different-fixture", expiresAt: .distantFuture, scopes: nil,
                                    subscriptionType: nil, rateLimitTier: nil)
        }, backoff: ClaudeQuotaBackoff())
        do { _ = try await fetcher.fetch(profile: .init(label: "Fixture")); XCTFail("Must reject login switch") }
        catch { XCTAssertEqual(error as? ClaudeBackendError, .credentialChanged) }
    }

    func testHTTPFailuresAreSanitizedAndBackoffSharedByProfile() async throws {
        for (status, expected) in [(401, ClaudeBackendError.unauthorized), (403, .forbidden), (429, .rateLimited), (302, .invalidResponse)] {
            let requests = ClaudeFixtureState()
            let backoff = ClaudeQuotaBackoff()
            let fetcher = ClaudeUsageFetcher(transport: { request in
                _ = requests.next(request)
                return Self.response(request, "SECRET SERVER BODY", status: status, headers: ["Retry-After": "120"])
            }, credentialReader: { _, _ in try Self.credential() }, backoff: backoff)
            let profile = ClaudeAccountProfile(label: "Fixture", configDirectory: "/fixture/\(status)")
            do { _ = try await fetcher.fetch(profile: profile); XCTFail("Must fail") }
            catch { XCTAssertEqual(error as? ClaudeBackendError, expected); XCTAssertFalse(error.localizedDescription.contains("SECRET")) }
            do { _ = try await fetcher.fetch(profile: profile); XCTFail("Must back off") }
            catch { XCTAssertEqual(error as? ClaudeBackendError, .backoff) }
            XCTAssertEqual(requests.requests.count, 1)
        }
    }

    func testBackoffHonorsRetryAfterAndAccountIsolation() async throws {
        let backoff = ClaudeQuotaBackoff()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let response = HTTPURLResponse(url: URL(string: "https://example.invalid")!, statusCode: 429,
                                       httpVersion: nil, headerFields: ["Retry-After": "120"])!
        let retry = try XCTUnwrap(ClaudeUsageFetcher.retryAfter(response, now: now))
        XCTAssertEqual(retry, 120)
        await backoff.fail(["profile:a", "account:a"], now: now, minimum: retry)
        try await backoff.check(["profile:b", "account:b"], now: now)
        do {
            try await backoff.check(["profile:other", "account:a"], now: now.addingTimeInterval(119))
            XCTFail("Same account must be paused across profiles")
        } catch { XCTAssertEqual(error as? ClaudeBackendError, .backoff) }
        try await backoff.check(["profile:a"], now: now.addingTimeInterval(121))
        await backoff.success(["profile:a", "account:a"])
        try await backoff.check(["account:a"], now: now)
    }

    func testTopLevelIdentityRequiresBothUUIDs() throws {
        let identity = try ClaudeUsageFetcher.identity(["account_uuid": Self.account, "organization_uuid": Self.organization])
        XCTAssertEqual(identity.id, Self.identity)
        XCTAssertThrowsError(try ClaudeUsageFetcher.identity(["account_uuid": Self.account, "organization_uuid": "invalid"]))
    }

    func testTransportErrorsAreSanitizedAndCancellationPropagates() async throws {
        let network = ClaudeUsageFetcher(transport: { _ in
            throw NSError(domain: "SECRET_TOKEN", code: 1, userInfo: [NSLocalizedDescriptionKey: "SECRET_TOKEN"])
        }, credentialReader: { _, _ in try Self.credential() }, backoff: ClaudeQuotaBackoff())
        do { _ = try await network.fetch(profile: .init(label: "Fixture")); XCTFail("Must fail") }
        catch {
            XCTAssertEqual(error as? ClaudeBackendError, .network)
            XCTAssertFalse(error.localizedDescription.contains("SECRET_TOKEN"))
        }
        let cancelled = ClaudeUsageFetcher(transport: { _ in throw CancellationError() },
                                           credentialReader: { _, _ in try Self.credential() }, backoff: ClaudeQuotaBackoff())
        do { _ = try await cancelled.fetch(profile: .init(label: "Fixture")); XCTFail("Must cancel") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testSecurityConfigurationAndRedirectDelegate() {
        let configuration = ClaudeUsageFetcher.sessionConfiguration()
        XCTAssertNil(configuration.urlCache)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertLessThanOrEqual(configuration.timeoutIntervalForResource, 30)
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let request = URLRequest(url: URL(string: "https://example.invalid")!)
        let task = session.dataTask(with: request)
        let response = HTTPURLResponse(url: request.url!, statusCode: 307, httpVersion: nil, headerFields: nil)!
        ClaudeNoRedirectDelegate().urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: request) {
            XCTAssertNil($0)
        }
        task.cancel()
    }
}

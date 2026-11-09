import Foundation
import XCTest
@testable import LLMUsageBar

final class ClaudeCLIUsageAdapterTests: XCTestCase {
    private let profile: ClaudeAccountProfile = .init(label: "Fixture")

    private enum Fixtures {
        static let org = "123e4567-e89b-42d3-a456-426614174000"
        static let identity = ClaudeOwnerAuthObservation(email: "User@example.invalid", organizationID: Fixtures.org, authMethod: "claude.ai", apiProvider: "firstParty")
        static let capturedAt = Date(timeIntervalSince1970: 1_700_000_000)
        static let resetAt = Date(timeIntervalSince1970: 1_700_003_600)
        static func usage(_ at: Date? = nil) -> ClaudeCodeStructuredUsage {
            .init(session: .init(usedPercent: 25, resetAt: Fixtures.resetAt), weekly: .init(usedPercent: 40, resetAt: nil), capturedAt: at ?? Fixtures.capturedAt)
        }
    }
    private func json(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    actor Calls {
        var identities: [ClaudeOwnerAuthObservation] = []
        var profiles: [ClaudeAccountProfile] = []
        var budgets: [TimeInterval] = []
        var usageCalls = 0
        func identity(_ value: ClaudeOwnerAuthObservation, profile: ClaudeAccountProfile, timeout: TimeInterval) -> ClaudeOwnerAuthObservation {
            identities.append(value); profiles.append(profile); budgets.append(timeout); return value
        }
        func countUsage() { usageCalls += 1 }
        func counts() -> (Int, Int) { (identities.count, usageCalls) }
        func seenProfiles() -> [ClaudeAccountProfile] { profiles }
        func seenBudgets() -> [TimeInterval] { budgets }
    }
    final class SyncCalls: @unchecked Sendable {
        private let lock = NSLock()
        private var identityCount = 0
        func increment() { lock.lock(); identityCount += 1; lock.unlock() }
        func count() -> Int { lock.lock(); defer { lock.unlock() }; return identityCount }
    }
    final class Clock: @unchecked Sendable {
        private let lock = NSLock(); private var value: TimeInterval
        init(_ value: TimeInterval) { self.value = value }
        func now() -> TimeInterval { lock.lock(); defer { lock.unlock() }; return value }
        func advance(_ by: TimeInterval) { lock.lock(); value += by; lock.unlock() }
    }

    func testReportedFingerprintIsProfileSpecificIncludingExplicitDefaultDirectory() throws {
        let defaultProfile = ClaudeAccountProfile(label: "Default")
        let explicit = ClaudeAccountProfile(label: "Custom", configDirectory: "~/.claude")
        XCTAssertNotEqual(try ClaudeCLIUsageAdapter.reportedFingerprint(profile: defaultProfile, identity: Fixtures.identity),
                          try ClaudeCLIUsageAdapter.reportedFingerprint(profile: explicit, identity: Fixtures.identity))
    }

    func testReportedFingerprintStableAcrossEmailAndOrganizationCasing() throws {
        let upper = ClaudeOwnerAuthObservation(email: "USER@EXAMPLE.INVALID", organizationID: Fixtures.org.uppercased(), authMethod: "claude.ai", apiProvider: "firstParty")
        XCTAssertEqual(try ClaudeCLIUsageAdapter.reportedFingerprint(profile: profile, identity: Fixtures.identity),
                       try ClaudeCLIUsageAdapter.reportedFingerprint(profile: profile, identity: upper))
    }

    func testReportedFingerprintRejectsInvalidProviderAndOrganization() {
        let invalids = [ClaudeOwnerAuthObservation(email: Fixtures.identity.email, organizationID: Fixtures.org, authMethod: "claude.ai", apiProvider: "other"),
                        ClaudeOwnerAuthObservation(email: Fixtures.identity.email, organizationID: "not-a-uuid", authMethod: "claude.ai", apiProvider: "firstParty")]
        for invalid in invalids {
            XCTAssertThrowsError(try ClaudeCLIUsageAdapter.reportedFingerprint(profile: profile, identity: invalid))
        }
    }

    func testIdentityDataClaudeCodeUsesOwnerIdentityNotNativeReader() async throws {
        let calls = Calls(); let native = SyncCalls()
        let adapter = ClaudeCLIUsageAdapter(identityReader: { p, timeout in await calls.identity(Fixtures.identity, profile: p, timeout: timeout) },
            usageReader: { _, _ in Fixtures.usage() }, nativeIdentity: { _ in native.increment(); return "native" },
            nativeUsage: { _, _ in throw ClaudeBackendError.credentialChanged })
        let result = try json(await adapter.identityData(profile: profile, source: .claudeCode))
        XCTAssertEqual(result["fingerprint"] as? String, try ClaudeCLIUsageAdapter.reportedFingerprint(profile: profile, identity: Fixtures.identity))
        XCTAssertEqual(native.count(), 0)
        let counts = await calls.counts(); XCTAssertEqual(counts.0, 1)
    }

    func testUsageDataUsesLegacyClaudeWindowPayloadAndCaptureTimestamp() async throws {
        let calls = Calls()
        let adapter = ClaudeCLIUsageAdapter(identityReader: { p, timeout in await calls.identity(Fixtures.identity, profile: p, timeout: timeout) },
            usageReader: { _, _ in await calls.countUsage(); return Fixtures.usage() }, uptime: { 10 })
        let data = try await adapter.usageData(profile: profile, source: .claudeCode, expectedFingerprint: nil)
        let body = try XCTUnwrap(try json(data)["claude"] as? [String: Any])
        XCTAssertEqual(body["updatedAt"] as? String, ISO8601DateFormatter().string(from: Fixtures.capturedAt))
        XCTAssertEqual(body["capturedAt"] as? String, body["updatedAt"] as? String)
        XCTAssertEqual(body["freshnessVerified"] as? Bool, false)
        XCTAssertEqual(body["identityVerifiedForTrackedAccount"] as? Bool, false)
        let session = try XCTUnwrap(body["session"] as? [String: Any])
        XCTAssertEqual(session["usedPercent"] as? Double, 25)
        XCTAssertEqual(session["remainingPercent"] as? Double, 75)
        XCTAssertEqual(session["resetAt"] as? String, ISO8601DateFormatter().string(from: Fixtures.resetAt))
        XCTAssertEqual((body["weekly"] as? [String: Any])?["usedPercent"] as? Double, 40)
    }

    func testUsageDataPreservesFreshCaptureTimestamp() async throws {
        let fresh = Date(timeIntervalSince1970: 1_800_000_000)
        let adapter = ClaudeCLIUsageAdapter(identityReader: { _, _ in Fixtures.identity }, usageReader: { _, _ in Fixtures.usage(fresh) }, uptime: { 10 })
        let data = try await adapter.usageData(profile: profile, source: .claudeCode, expectedFingerprint: nil)
        let body = try XCTUnwrap(try json(data)["claude"] as? [String: Any])
        XCTAssertEqual(body["capturedAt"] as? String, ISO8601DateFormatter().string(from: fresh))
        XCTAssertEqual(body["updatedAt"] as? String, ISO8601DateFormatter().string(from: fresh))
    }

    func testSelectedProfilePassedExactlyToIdentityAndUsageReaders() async throws {
        let calls = Calls(); let selected = ClaudeAccountProfile(label: "Selected", configDirectory: "/tmp/custom-claude", accountID: "tracked")
        let adapter = ClaudeCLIUsageAdapter(identityReader: { p, timeout in await calls.identity(Fixtures.identity, profile: p, timeout: timeout) },
            usageReader: { p, _ in await calls.countUsage(); _ = await calls.identity(Fixtures.identity, profile: p, timeout: 0); return Fixtures.usage() }, uptime: { 10 })
        _ = try await adapter.usageData(profile: selected, source: .claudeCode, expectedFingerprint: nil)
        let seen = await calls.seenProfiles()
        XCTAssertEqual(seen.count, 3)
        XCTAssertTrue(seen.allSatisfy { $0 == selected })
    }

    func testExpectedFingerprintMismatchRejectsBeforeUsageFetch() async {
        let calls = Calls()
        let adapter = ClaudeCLIUsageAdapter(identityReader: { p, timeout in await calls.identity(Fixtures.identity, profile: p, timeout: timeout) },
            usageReader: { _, _ in await calls.countUsage(); return Fixtures.usage() }, uptime: { 10 })
        do { _ = try await adapter.usageData(profile: profile, source: .claudeCode, expectedFingerprint: "wrong"); XCTFail("expected mismatch") }
        catch { XCTAssertEqual(error as? ClaudeBackendError, .credentialChanged) }
        let counts = await calls.counts(); XCTAssertEqual(counts.1, 0)
    }

    func testPostFetchIdentityChangeRejectsAndDoesNotReturnPayload() async {
        let calls = Calls(); let changed = ClaudeOwnerAuthObservation(email: "other@example.invalid", organizationID: Fixtures.org, authMethod: "claude.ai", apiProvider: "firstParty")
        let adapter = ClaudeCLIUsageAdapter(identityReader: { p, timeout in
            let result = await calls.identity(Fixtures.identity, profile: p, timeout: timeout)
            let count = await calls.counts().0
            return count == 2 ? result : changed
        }, usageReader: { _, _ in await calls.countUsage(); return Fixtures.usage() }, uptime: { 10 })
        do { _ = try await adapter.usageData(profile: profile, source: .claudeCode, expectedFingerprint: nil); XCTFail("identity changed") }
        catch { XCTAssertEqual(error as? ClaudeOwnerUsageProbeError, .identityChanged) }
        let counts = await calls.counts(); XCTAssertEqual(counts.1, 1)
    }

    func testSignOutBeforeOrAfterUsageRejects() async {
        for signOutOnCall in [1, 2] {
            let calls = Calls()
            let adapter = ClaudeCLIUsageAdapter(identityReader: { p, timeout in
                let count = await calls.counts().0
                if count + 1 == signOutOnCall { throw ClaudeOwnerUsageProbeError.signInRequired }
                return await calls.identity(Fixtures.identity, profile: p, timeout: timeout)
            }, usageReader: { _, _ in await calls.countUsage(); return Fixtures.usage() }, uptime: { 10 })
            do { _ = try await adapter.usageData(profile: profile, source: .claudeCode, expectedFingerprint: nil); XCTFail("signout must reject") }
            catch { XCTAssertEqual(error as? ClaudeOwnerUsageProbeError, .signInRequired) }
            let counts = await calls.counts(); XCTAssertEqual(counts.1, signOutOnCall == 1 ? 0 : 1)
        }
    }

    func testShortBudgetsFailBeforeUsageFetch() async {
        let calls = Calls(); let clock = Clock(10)
        let adapter = ClaudeCLIUsageAdapter(identityReader: { p, timeout in await calls.identity(Fixtures.identity, profile: p, timeout: timeout) },
            usageReader: { _, _ in await calls.countUsage(); return Fixtures.usage() }, uptime: { clock.now() })
        do { _ = try await adapter.usageData(profile: profile, source: .claudeCode, expectedFingerprint: nil, timeout: 2); XCTFail("budget reserve") }
        catch { XCTAssertEqual(error as? ClaudeCodeStructuredUsageReaderError, .timedOut) }
        let counts = await calls.counts(); XCTAssertEqual(counts.1, 0)
    }

    func testOAuthUsesOnlyInjectedNativeReadersAndPassesExpectedFingerprint() async throws {
        let calls = Calls(); let nativeIdentity = SyncCalls(); let expected = "expected"
        let quota = ClaudeQuotaSnapshot(accountID: "account", email: nil, planType: nil, fiveHour: .init(usedPercent: 10, resetAt: nil), weekly: nil, modelWindows: [], extraUsage: nil, updatedAt: Fixtures.capturedAt)
        let adapter = ClaudeCLIUsageAdapter(identityReader: { p, timeout in await calls.identity(Fixtures.identity, profile: p, timeout: timeout) },
            usageReader: { _, _ in await calls.countUsage(); return Fixtures.usage() },
            nativeIdentity: { _ in nativeIdentity.increment(); return "native" },
            nativeUsage: { _, actual in XCTAssertEqual(actual, expected); return quota }, uptime: { 10 })
        let data = try await adapter.usageData(profile: profile, source: .oauth, expectedFingerprint: expected)
        let body = try XCTUnwrap(try json(data)["claude"] as? [String: Any])
        XCTAssertEqual(body["source"] as? String, "Claude OAuth API")
        XCTAssertEqual(nativeIdentity.count(), 0)
        let counts = await calls.counts(); XCTAssertEqual(counts.0, 0); XCTAssertEqual(counts.1, 0)
    }

    func testStructuredEnvironmentSanitizesAuthAndCloudButPreservesRestrictionAndPrivacyFlags() {
        let profile = ClaudeAccountProfile(label: "Custom", configDirectory: "~/claude-profiles/work/../custom")
        let sensitive = ["ANTHROPIC_API_KEY": "secret", "ANTHROPIC_AUTH_TOKEN": "secret", "AWS_SECRET_ACCESS_KEY": "secret",
                         "GOOGLE_APPLICATION_CREDENTIALS": "secret", "CLAUDE_CONFIG_DIR": "/wrong", "NODE_OPTIONS": "secret", "HTTPS_PROXY": "secret"]
        for restriction in ["1", "0", "false"] {
            var inherited = sensitive; inherited["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] = restriction
            let env = ClaudeCLIUsageAdapter.structuredEnvironment(profile: profile, inherited: inherited)
            XCTAssertEqual(env["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"], restriction)
            XCTAssertEqual(env["CLAUDE_CONFIG_DIR"], profile.directoryURL.path)
            for key in sensitive.keys where key != "CLAUDE_CONFIG_DIR" { XCTAssertNil(env[key], "should strip \(key)") }
            XCTAssertEqual(env["DISABLE_AUTOUPDATER"], "1")
            XCTAssertEqual(env["DISABLE_TELEMETRY"], "1")
            XCTAssertEqual(env["DISABLE_ERROR_REPORTING"], "1")
        }
    }

    func testStructuredEnvironmentDistinguishesUnsetDefaultFromExplicitNormalizedProfile() {
        let inherited: [String: String] = ["CLAUDE_CONFIG_DIR": "", "DISABLE_TELEMETRY": "0"]
        let defaultEnv = ClaudeCLIUsageAdapter.structuredEnvironment(profile: ClaudeCLIUsageAdapter.profile(environment: inherited), inherited: inherited)
        XCTAssertNil(defaultEnv["CLAUDE_CONFIG_DIR"])
        XCTAssertNil(defaultEnv["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"])
        XCTAssertEqual(defaultEnv["DISABLE_TELEMETRY"], "1", "narrow privacy controls must remain disabled")
        let explicit = ClaudeAccountProfile(label: "Explicit", configDirectory: "~/claude/../.claude")
        let explicitEnv = ClaudeCLIUsageAdapter.structuredEnvironment(profile: explicit, inherited: [:])
        XCTAssertEqual(explicitEnv["CLAUDE_CONFIG_DIR"], explicit.directoryURL.path)
        XCTAssertNotEqual(defaultEnv["CLAUDE_CONFIG_DIR"], explicitEnv["CLAUDE_CONFIG_DIR"])
    }
}

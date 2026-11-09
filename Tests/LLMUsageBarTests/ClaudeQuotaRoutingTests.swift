import Foundation
import XCTest
@testable import LLMUsageBar

private enum RoutingFixtureError: Error { case expired }

private final class ClaudeRoutingFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var reads: [(String, Bool)] = []
    private var recoveries: [String] = []
    private var profileRequests = 0
    private var usageRequests = 0
    private var defaultIdentity: String
    private var defaultFails = false
    private var defaultFailure: ClaudeBackendError = .credentialsExpired
    private var tokenFlipOnUsage = false
    private var tokenChanged = false
    private var defaultCredentialReads = 0
    private var defaultWasRecovered = false
    private var profileEmail: String?
    private var switchOnOtherRead: String?

    init(defaultIdentity: String, defaultFails: Bool = false, profileEmail: String? = nil) {
        self.defaultIdentity = defaultIdentity
        self.defaultFails = defaultFails
        self.profileEmail = profileEmail
    }

    private func synchronized<T>(_ body: () throws -> T) rethrows -> T { try lock.withLock(body) }
    var readLog: [(String, Bool)] { synchronized { reads } }
    var recoveryLog: [String] { synchronized { recoveries } }
    var apiCounts: (Int, Int) { synchronized { (profileRequests, usageRequests) } }
    func setDefaultIdentity(_ value: String) { synchronized { defaultIdentity = value } }
    func switchDefaultOnOtherRead(to value: String) { synchronized { switchOnOtherRead = value } }
    func changeTokenDuringUsage() { synchronized { tokenFlipOnUsage = true } }

    func credential(_ profile: ClaudeAccountProfile, _ prompt: Bool) throws -> ClaudeCredential {
        try synchronized {
        let key = profile.configDirectory == nil ? "default" : (profile.label == "Target" ? "target" : profile.label)
        reads.append((key, prompt))
        if key == "default", defaultFails, !defaultWasRecovered { throw defaultFailure }
        if key == "Other" {
            if let switched = switchOnOtherRead { defaultIdentity = switched; switchOnOtherRead = nil }
            throw ClaudeBackendError.credentialsExpired
        }
        if key == "default" { defaultCredentialReads += 1 }
        let token = key == "default" ? (tokenFlipOnUsage && defaultCredentialReads > 1 ? "changed-token" : "default-token") : "token-\(key)"
        return ClaudeCredential(accessToken: token, expiresAt: Date(timeIntervalSince1970: 4_102_444_800),
                                scopes: ["user:profile"], subscriptionType: nil, rateLimitTier: nil)
        }
    }

    func transport(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (currentIdentity, email) = synchronized { () -> (String, String?) in
            let isDefault = request.value(forHTTPHeaderField: "Authorization") == "Bearer default-token" ||
                request.value(forHTTPHeaderField: "Authorization") == "Bearer changed-token"
            if request.url?.lastPathComponent == "profile", isDefault { profileRequests += 1 }
            else if request.url?.lastPathComponent == "usage", isDefault { usageRequests += 1 }
            if request.url?.lastPathComponent == "usage", tokenFlipOnUsage { tokenChanged = true }
            return (defaultIdentity, profileEmail)
        }
        let token = request.value(forHTTPHeaderField: "Authorization") ?? ""
        let identity: String
        if token == "Bearer default-token" || token == "Bearer changed-token" { identity = currentIdentity }
        else if token == "Bearer token-Second" { identity = "33333333-3333-3333-3333-333333333333:22222222-2222-2222-2222-222222222222" }
        else { identity = "11111111-1111-1111-1111-111111111111:22222222-2222-2222-2222-222222222222" }
        let body: String
        if request.url?.lastPathComponent == "profile" {
            let parts = identity.split(separator: ":")
            body = "{\"account\":{\"uuid\":\"\(parts[0])\",\"email_address\":\(email.map { "\\\"\($0)\\\"" } ?? "null")},\"organization\":{\"uuid\":\"\(parts[1])\"}}"
        } else {
            body = #"{"five_hour":{"utilization":37}}"#
        }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }

    func recover(_ profile: ClaudeAccountProfile) async throws {
        synchronized {
            let key = profile.configDirectory == nil ? "default" : (profile.label == "Target" ? "target" : profile.label)
            recoveries.append(key)
            if key == "default" { defaultWasRecovered = true; defaultFails = false }
        }
    }

    func setDefaultFailed(_ error: ClaudeBackendError = .credentialsExpired) { synchronized { defaultFailure = error; defaultFails = true; defaultWasRecovered = false } }
}

final class ClaudeQuotaRoutingTests: XCTestCase {
    private let a = "11111111-1111-1111-1111-111111111111"
    private let b = "33333333-3333-3333-3333-333333333333"
    private let org = "22222222-2222-2222-2222-222222222222"
    private var identity: String { "\(a):\(org)" }
    private var otherIdentity: String { "\(b):\(org)" }

    private func profile(_ label: String = "Target", identity: String? = nil, directory: String? = "/tmp/claude-route") -> ClaudeAccountProfile {
        ClaudeAccountProfile(label: label, configDirectory: directory, accountID: identity)
    }

    private func quota(_ identity: String) -> ClaudeQuotaSnapshot {
        ClaudeQuotaSnapshot(accountID: identity, email: nil, planType: nil, fiveHour: nil, weekly: nil,
                            modelWindows: [], extraUsage: nil, updatedAt: Date())
    }

    private func observation(_ identity: String? = nil, error: Error? = nil, hint: String? = nil) -> ClaudeDefaultQuotaObservation {
        ClaudeDefaultQuotaObservation(quota: identity.map(quota), error: error, identityHint: hint)
    }

    func testPureRoutingRequiresUniqueExactIdentityAndFailsClosed() {
        let target = profile(identity: identity)
        let isolated = profile("Other", identity: otherIdentity, directory: "/tmp/other")
        if case .defaultClaudeCode = ClaudeQuotaRouting.source(for: target, profiles: [target, isolated], observation: observation(identity)) {} else { XCTFail("Exact live identity should route to default") }
        if case .configuredProfile = ClaudeQuotaRouting.source(for: isolated, profiles: [target, isolated], observation: observation(identity)) {} else { XCTFail("Different account must remain isolated") }
        if case .configuredProfile = ClaudeQuotaRouting.source(for: target, profiles: [target], observation: observation(otherIdentity)) {} else { XCTFail("Different account must not substitute") }
        if case .configuredProfile = ClaudeQuotaRouting.source(for: target, profiles: [target], observation: observation("\(a):\(b)")) {} else { XCTFail("Different org must not substitute") }
        if case .configuredProfile(let recovery) = ClaudeQuotaRouting.source(for: profile(identity: nil), profiles: [profile(identity: nil)], observation: observation(identity)) { XCTAssertTrue(recovery) } else { XCTFail("Missing pin must not adopt default") }
        let duplicate = profile("Duplicate", identity: identity, directory: "/tmp/duplicate")
        if case .unavailable = ClaudeQuotaRouting.source(for: target, profiles: [target, duplicate], observation: observation(identity)) {} else { XCTFail("Duplicate identities must be ambiguous") }
    }

    func testPureRoutingHintOnlyGatesRepairAndDefaultLossNeverUsesStaleCopy() {
        let target = profile(identity: identity)
        if case .defaultClaudeCode = ClaudeQuotaRouting.source(for: target, profiles: [target], observation: observation(error: ClaudeBackendError.credentialsExpired, hint: identity)) {} else { XCTFail("Matching hint should prevent stale-copy fallback") }
        if case .configuredProfile(let recovery) = ClaudeQuotaRouting.source(for: target, profiles: [target], observation: observation(error: ClaudeBackendError.credentialsExpired, hint: otherIdentity)) { XCTAssertFalse(recovery) } else { XCTFail("An unverified unrelated hint cannot authorize competing refresh") }
        if case .configuredProfile(let recovery) = ClaudeQuotaRouting.source(for: target, profiles: [target], observation: observation(error: ClaudeBackendError.credentialsMissing)) { XCTAssertTrue(recovery) } else { XCTFail("Signed-out default permits isolated recovery") }
        if case .defaultClaudeCode = ClaudeQuotaRouting.source(for: profile("Default", identity: nil, directory: nil), profiles: [target], observation: observation(error: ClaudeBackendError.credentialsExpired)) {} else { XCTFail("Explicit default profile remains default") }
    }

    @MainActor
    private func makeState(_ fixture: ClaudeRoutingFixture, profiles: [ClaudeAccountProfile], autoRefresh: Bool = true,
                           hint: String? = nil) throws -> (AppState, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        var config = AppConfig.default
        config.claudeUsageSource = .oauth
        config.codexEnabled = false; config.openCodeEnabled = false; config.piEnabled = false
        config.claudeAutoRefreshEnabled = autoRefresh
        config.claudeAccounts = profiles
        let fetcher = ClaudeUsageFetcher(transport: fixture.transport, credentialReader: fixture.credential,
                                         backoff: ClaudeQuotaBackoff())
        let recovery = ClaudeCredentialRecovery(reader: fixture.credential, runner: { profile, _ in try await fixture.recover(profile) })
        let handoff = PiCodexCredentialHandoff(managedHomeStore: ManagedCodexHomeStore(root: root.appendingPathComponent("homes")),
                                               piAuthStore: PiAuthStore(authURL: root.appendingPathComponent("pi-auth.json")), journalRoot: root)
        let state = AppState(config: config, claudeFetcher: fetcher, claudeRecovery: recovery,
                             claudeDefaultIdentityHint: { hint }, piCodexHandoff: handoff,
                             pendingCodexResetURL: root.appendingPathComponent("pending.json"),
                             logInfo: { _ in }, logError: { _ in })
        return (state, root)
    }

    @MainActor
    func testOneDefaultObservationRoutesOnlyMatchingTrackedAccountWithoutChangingProfiles() async throws {
        let target = profile(identity: identity)
        let other = profile("Other", identity: otherIdentity, directory: "/tmp/other-route")
        let fixture = ClaudeRoutingFixture(defaultIdentity: identity)
        let (state, _) = try makeState(fixture, profiles: [target, other])
        await state.refresh(onStart: {})
        XCTAssertEqual(fixture.apiCounts.0, 2, "One normal default observation plus revalidation before isolated recovery")
        XCTAssertEqual(state.snapshot.claudeAccounts.first(where: { $0.id == target.id })?.quota?.accountID, identity)
        XCTAssertEqual(state.snapshot.claudeAccounts.first(where: { $0.id == target.id })?.quotaSource, .defaultClaudeCode)
        XCTAssertNil(state.snapshot.claudeAccounts.first(where: { $0.id == other.id })?.quota)
        XCTAssertEqual(fixture.recoveryLog, ["Other"])
        XCTAssertFalse(fixture.readLog.contains { $0.0 == "target" })
        XCTAssertEqual(state.claudeAccounts, [target, other])
    }

    @MainActor
    func testDefaultSwitchAfterBatchObservationPreventsCompetingIsolatedRefresh() async throws {
        let target = profile(identity: identity)
        let other = profile("Other", identity: otherIdentity, directory: "/tmp/other-route")
        let fixture = ClaudeRoutingFixture(defaultIdentity: identity)
        fixture.switchDefaultOnOtherRead(to: otherIdentity)
        let (state, _) = try makeState(fixture, profiles: [target, other])
        await state.refresh(onStart: {})
        XCTAssertTrue(fixture.recoveryLog.isEmpty, "Do not refresh a stale copy after default switched to it")
        XCTAssertEqual(state.snapshot.claudeAccounts.first(where: { $0.id == other.id })?.quota?.accountID, otherIdentity)
        XCTAssertEqual(state.snapshot.claudeAccounts.first(where: { $0.id == other.id })?.quotaSource, .defaultClaudeCode)
    }

    @MainActor
    func testMalformedDefaultIsNotProofOfAbsence() async throws {
        let other = profile("Other", identity: otherIdentity, directory: "/tmp/other-route")
        let fixture = ClaudeRoutingFixture(defaultIdentity: identity)
        fixture.setDefaultFailed(.credentialsInvalid)
        let (state, _) = try makeState(fixture, profiles: [other])
        await state.refresh(onStart: {})
        XCTAssertTrue(fixture.recoveryLog.isEmpty)
        XCTAssertNil(state.snapshot.claudeAccounts.first?.quota)
        XCTAssertTrue(state.snapshot.claudeAccounts.first?.quotaError?.contains("default Claude login could not be verified") == true)
    }

    @MainActor
    func testManualRefreshCannotRepairAnUnrelatedDefaultWhenAutoRefreshIsOff() async throws {
        let target = profile(identity: identity)
        let other = profile("Second", identity: otherIdentity, directory: "/tmp/other-route")
        let fixture = ClaudeRoutingFixture(defaultIdentity: identity, defaultFails: true)
        let (state, _) = try makeState(fixture, profiles: [target, other], autoRefresh: false, hint: identity)
        await state.refreshClaudeAccount(id: other.id, allowKeychainPrompt: true)
        XCTAssertTrue(fixture.recoveryLog.isEmpty)
        XCTAssertFalse(fixture.readLog.contains { $0.0 == "default" && $0.1 })
    }

    @MainActor
    func testSetupUsesQuotaSourceWithoutChangingConfiguredProfile() async throws {
        let target = profile(identity: identity)
        let fixture = ClaudeRoutingFixture(defaultIdentity: identity)
        let (state, _) = try makeState(fixture, profiles: [target])
        await state.refresh(onStart: {})
        let setup = try XCTUnwrap(state.claudeQuotaSetupProfile(id: target.id))
        XCTAssertNil(setup.configDirectory)
        XCTAssertEqual(setup.id, target.id)
        XCTAssertEqual(setup.accountID, target.accountID)
        XCTAssertEqual(state.claudeAccounts, [target])
    }

    @MainActor
    func testDefaultIdentityCanMoveBetweenTrackedLabelsOnSubsequentPoll() async throws {
        let first = profile("First", identity: identity, directory: "/tmp/first-route")
        let second = profile("Second", identity: otherIdentity, directory: "/tmp/second-route")
        let fixture = ClaudeRoutingFixture(defaultIdentity: identity)
        let (state, _) = try makeState(fixture, profiles: [first, second])
        await state.refresh(onStart: {})
        fixture.setDefaultIdentity(otherIdentity)
        await state.refresh(onStart: {})
        XCTAssertEqual(state.snapshot.claudeAccounts.first(where: { $0.id == first.id })?.quotaSource, .configuredProfile)
        XCTAssertEqual(state.snapshot.claudeAccounts.first(where: { $0.id == second.id })?.quotaSource, .defaultClaudeCode)
        XCTAssertEqual(state.claudeAccounts.map(\.accountID), [identity, otherIdentity])
        XCTAssertEqual(fixture.apiCounts.0, 2)
    }

    @MainActor
    func testMatchingDefaultHintRepairsDefaultOnlyAndVerifiesIdentity() async throws {
        let target = profile(identity: identity)
        let fixture = ClaudeRoutingFixture(defaultIdentity: identity, defaultFails: true)
        let (state, _) = try makeState(fixture, profiles: [target], hint: identity)
        await state.refresh(onStart: {})
        XCTAssertEqual(fixture.recoveryLog, ["default"])
        XCTAssertFalse(fixture.recoveryLog.contains("Target"))
        XCTAssertEqual(state.snapshot.claudeAccounts.first?.quota?.accountID, identity)
        XCTAssertEqual(state.snapshot.claudeAccounts.first?.quotaSource, .defaultClaudeCode)
    }

    @MainActor
    func testMismatchingRecoveredDefaultCannotPublishWrongQuota() async throws {
        let target = profile(identity: identity)
        let fixture = ClaudeRoutingFixture(defaultIdentity: otherIdentity, defaultFails: true)
        let (state, _) = try makeState(fixture, profiles: [target], hint: identity)
        await state.refresh(onStart: {})
        XCTAssertEqual(fixture.recoveryLog, ["default"])
        XCTAssertNil(state.snapshot.claudeAccounts.first?.quota)
        XCTAssertNotNil(state.snapshot.claudeAccounts.first?.quotaError)
    }

    @MainActor
    func testUnknownDefaultIdentityDisablesExpiryRepairButValidConfiguredQuotaRemainsUsable() async throws {
        let target = profile(identity: identity)
        let fixture = ClaudeRoutingFixture(defaultIdentity: otherIdentity)
        fixture.setDefaultFailed()
        let (state, _) = try makeState(fixture, profiles: [target], hint: nil)
        await state.refresh(onStart: {})
        XCTAssertTrue(fixture.recoveryLog.isEmpty)
        XCTAssertEqual(state.snapshot.claudeAccounts.first?.quota?.accountID, identity)
        XCTAssertEqual(fixture.readLog.filter { $0.0 == "target" }.count, 2)
    }

    @MainActor
    func testManualRefreshPromptsDefaultOnlyForMatchingProfile() async throws {
        let matching = profile(identity: identity)
        let fixture = ClaudeRoutingFixture(defaultIdentity: identity)
        let (state, _) = try makeState(fixture, profiles: [matching], hint: identity)
        await state.refreshClaudeAccount(id: matching.id, allowKeychainPrompt: true)
        XCTAssertTrue(fixture.readLog.first(where: { $0.0 == "default" })?.1 == true)
        XCTAssertFalse(fixture.readLog.contains { $0.0 == "target" })

        let unrelated = profile(identity: otherIdentity)
        let secondFixture = ClaudeRoutingFixture(defaultIdentity: identity)
        let (secondState, _) = try makeState(secondFixture, profiles: [unrelated], hint: identity)
        await secondState.refreshClaudeAccount(id: unrelated.id, allowKeychainPrompt: true)
        XCTAssertTrue(secondFixture.readLog.first(where: { $0.0 == "default" })?.1 == false)
        XCTAssertTrue(secondFixture.readLog.contains { $0.0 == "target" })
    }

    @MainActor
    func testSignedOutOrClearedDefaultNeverTriggersAutomaticRepair() async throws {
        let target = profile(identity: identity)
        for error in [ClaudeBackendError.credentialsMissing, .credentialsCleared] {
            let fixture = ClaudeRoutingFixture(defaultIdentity: identity)
            fixture.setDefaultFailed(error)
            let (state, _) = try makeState(fixture, profiles: [target], hint: identity)
            await state.refresh(onStart: {})
            XCTAssertTrue(fixture.recoveryLog.isEmpty, "Unexpected recovery after \\(error)")
        }
    }

    @MainActor
    func testCredentialFlipDuringDefaultRequestIsRejectedByCompletionRead() async throws {
        let target = profile(identity: identity)
        let fixture = ClaudeRoutingFixture(defaultIdentity: identity)
        fixture.changeTokenDuringUsage()
        let (state, _) = try makeState(fixture, profiles: [target], hint: identity)
        await state.refresh(onStart: {})
        XCTAssertNil(state.snapshot.claudeAccounts.first?.quota, "reads=\(fixture.readLog.map { $0.0 })")
        XCTAssertTrue(state.snapshot.claudeAccounts.first?.quotaError?.contains("changed") == true, "reads=\(fixture.readLog.map { $0.0 })")
    }
}

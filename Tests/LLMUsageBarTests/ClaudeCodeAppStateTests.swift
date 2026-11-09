import Foundation
import XCTest
@testable import LLMUsageBar

private actor CodeRefreshGate {
    private var entered = false
    private var released = false
    private var observers: [CheckedContinuation<Void, Never>] = []
    private var blocked: CheckedContinuation<Void, Never>?

    func pause() async {
        entered = true
        observers.forEach { $0.resume() }
        observers.removeAll()
        if !released { await withCheckedContinuation { blocked = $0 } }
    }

    func waitUntilEntered() async {
        if !entered { await withCheckedContinuation { observers.append($0) } }
    }

    func release() {
        released = true
        blocked?.resume()
        blocked = nil
    }
}

private actor CodeAppStateFetcher: ClaudeCodeUsageFetching {
    struct Call: Sendable {
        let profile: ClaudeAccountProfile
        let force: Bool
    }
    private var observation: Result<ClaudeOwnerAuthObservation, ClaudeOwnerUsageProbeError>
    private var reading: Result<ClaudeCodeUsageSnapshot, ClaudeOwnerUsageProbeError>
    private var identityCalls: [ClaudeAccountProfile] = []
    private var fetchCalls: [Call] = []
    private let gate: CodeRefreshGate?

    init(identity: ClaudeOwnerAuthObservation, reading: ClaudeCodeUsageSnapshot, gate: CodeRefreshGate? = nil) {
        observation = .success(identity)
        self.reading = .success(reading)
        self.gate = gate
    }

    func identity(profile: ClaudeAccountProfile) async throws -> ClaudeOwnerAuthObservation {
        identityCalls.append(profile)
        return try observation.get()
    }

    func fetch(profile: ClaudeAccountProfile, force: Bool) async throws -> ClaudeCodeUsageSnapshot {
        fetchCalls.append(Call(profile: profile, force: force))
        let result = reading
        if let gate { await gate.pause() }
        return try result.get()
    }

    func setIdentity(_ value: Result<ClaudeOwnerAuthObservation, ClaudeOwnerUsageProbeError>) { observation = value }
    func setReading(_ value: Result<ClaudeCodeUsageSnapshot, ClaudeOwnerUsageProbeError>) { reading = value }
    func calls() -> ([ClaudeAccountProfile], [Call]) { (identityCalls, fetchCalls) }
}

private final class CodeNativeAccessSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var calls: Int { lock.withLock { count } }
    func credential(_ profile: ClaudeAccountProfile, _ prompt: Bool) throws -> ClaudeCredential {
        lock.withLock { count += 1 }
        throw ClaudeBackendError.credentialsMissing
    }
}

@MainActor
private final class CodeConfigSaves {
    var values: [AppConfig] = []
    func save(_ config: AppConfig) -> Bool { values.append(config); return true }
}

final class ClaudeCodeAppStateTests: XCTestCase {
    private static let org = "22222222-2222-2222-2222-222222222222"
    private static let otherOrg = "33333333-3333-3333-3333-333333333333"
    private static let account = "11111111-1111-1111-1111-111111111111:22222222-2222-2222-2222-222222222222"
    private static let capturedAt = Date(timeIntervalSince1970: 1_700_000_000)

    private static func identity(email: String = "owner@example.test", org: String = org) -> ClaudeOwnerAuthObservation {
        ClaudeOwnerAuthObservation(email: email, organizationID: org, authMethod: "claude.ai", apiProvider: "firstParty")
    }

    private static func reading(_ identity: ClaudeOwnerAuthObservation = identity()) -> ClaudeCodeUsageSnapshot {
        ClaudeCodeUsageSnapshot(identity: identity,
            usage: ClaudeCLIUsageReading(fiveHour: ClaudeCLIUsageWindow(usedPercent: 37, resetDescription: "in 2 hours"),
                weekly: ClaudeCLIUsageWindow(usedPercent: 61, resetDescription: "Friday"), modelWindows: []),
            capturedAt: capturedAt)
    }

    private static func fetcher(gate: CodeRefreshGate? = nil) -> CodeAppStateFetcher {
        CodeAppStateFetcher(identity: identity(), reading: reading(), gate: gate)
    }

    @MainActor
    private func makeState(_ fetcher: any ClaudeCodeUsageFetching, count: Int = 1, pinned: Bool = true,
                           autoRefresh: Bool = true) throws -> (AppState, CodeNativeAccessSpy, CodeConfigSaves) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ClaudeCodeAppStateTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        var config = AppConfig.default
        config.codexEnabled = false
        config.openCodeEnabled = false
        config.piEnabled = false
        config.claudeEnabled = true
        config.claudeUsageSource = .claudeCode
        config.claudeAutoRefreshEnabled = autoRefresh
        config.claudeAccounts = (0..<count).map {
            ClaudeAccountProfile(label: "Fixture \($0)", configDirectory: root.appendingPathComponent("profile-\($0)").path,
                accountID: pinned ? Self.account : nil, email: pinned ? "owner@example.test" : nil)
        }
        let spy = CodeNativeAccessSpy()
        let saves = CodeConfigSaves()
        let native = ClaudeUsageFetcher(transport: { _ in throw ClaudeBackendError.network },
            credentialReader: spy.credential, backoff: ClaudeQuotaBackoff())
        let recovery = ClaudeCredentialRecovery(reader: spy.credential, runner: { _, _ in throw ClaudeBackendError.credentialsMissing })
        let handoff = PiCodexCredentialHandoff(managedHomeStore: ManagedCodexHomeStore(root: root.appendingPathComponent("homes")),
            piAuthStore: PiAuthStore(authURL: root.appendingPathComponent("pi-auth.json")), journalRoot: root)
        let state = AppState(config: config, claudeFetcher: native, claudeCodeFetcher: fetcher,
            configSaver: { saves.save($0) },
            claudeSessionsReader: { _ in ClaudeLocalUsage(rows: [], fileCount: 0, unreadableFileCount: 0, updatedAt: Self.capturedAt) },
            claudeRecovery: recovery, claudeDefaultIdentityHint: { nil },
            piCodexHandoff: handoff, pendingCodexResetURL: root.appendingPathComponent("pending.json"),
            logInfo: { _ in }, logError: { _ in })
        return (state, spy, saves)
    }

    @MainActor
    func testBackgroundRefreshPublishesReportedUsageNotOAuthQuota() async throws {
        let fixture = Self.fetcher()
        let (state, spy, _) = try makeState(fixture)
        await state.refresh(onStart: {})
        let snapshot = try XCTUnwrap(state.snapshot.claudeAccounts.first)
        let usage = try XCTUnwrap(snapshot.codeUsage)
        XCTAssertNil(snapshot.quota)
        XCTAssertNil(snapshot.quotaError)
        XCTAssertEqual(usage.identity, Self.identity())
        XCTAssertEqual(usage.usage.fiveHour?.usedPercent, 37)
        XCTAssertEqual(usage.usage.weekly?.usedPercent, 61)
        XCTAssertEqual(usage.capturedAt, Self.capturedAt)
        XCTAssertEqual(spy.calls, 0)
        let calls = await fixture.calls()
        XCTAssertEqual(calls.0.count, 1)
        XCTAssertNil(calls.0.first?.configDirectory)
        XCTAssertEqual(calls.1.count, 1)
        XCTAssertTrue(try XCTUnwrap(calls.1.first).force, "Default observations must not reuse a previous login's cached quota")
    }

    @MainActor
    func testUniqueMatchingDefaultUsesUnsetDirectoryWithoutChangingSavedProfile() async throws {
        let fixture = Self.fetcher()
        let (state, _, _) = try makeState(fixture)
        let original = state.claudeAccounts[0]
        await state.refresh(onStart: {})
        let calls = await fixture.calls()
        XCTAssertNil(try XCTUnwrap(calls.1.first).profile.configDirectory)
        XCTAssertEqual(calls.1.first?.profile.id, original.id)
        XCTAssertEqual(state.snapshot.claudeAccounts.first?.quotaSource, .defaultClaudeCode)
        XCTAssertEqual(state.claudeAccounts[0].configDirectory, original.configDirectory)
    }

    @MainActor
    func testNonmatchingDefaultRemainsConfigured() async throws {
        let fixture = Self.fetcher()
        await fixture.setIdentity(.success(Self.identity(email: "foreign@example.test")))
        let (state, _, _) = try makeState(fixture)
        await state.refresh(onStart: {})
        let calls = await fixture.calls()
        XCTAssertEqual(calls.1.first?.profile.configDirectory, state.claudeAccounts[0].configDirectory)
        XCTAssertEqual(state.snapshot.claudeAccounts.first?.quotaSource, .configuredProfile)
        XCTAssertNotNil(state.snapshot.claudeAccounts.first?.codeUsage)
    }

    @MainActor
    func testUnknownUnpinnedProfileDoesNotAdoptAmbientDefault() async throws {
        let fixture = Self.fetcher()
        let (state, _, _) = try makeState(fixture, pinned: false)
        await state.refresh(onStart: {})
        let calls = await fixture.calls()
        XCTAssertNotNil(try XCTUnwrap(calls.1.first).profile.configDirectory)
        XCTAssertEqual(state.snapshot.claudeAccounts.first?.quotaSource, .configuredProfile)
    }

    @MainActor
    func testAmbiguousDefaultDoesNotSubstituteEitherProfile() async throws {
        let fixture = Self.fetcher()
        let (state, _, _) = try makeState(fixture, count: 2)
        await state.refresh(onStart: {})
        let calls = await fixture.calls()
        XCTAssertEqual(calls.1.count, 2)
        XCTAssertTrue(calls.1.allSatisfy { $0.profile.configDirectory != nil })
        XCTAssertTrue(state.snapshot.claudeAccounts.allSatisfy { $0.quotaSource == .configuredProfile && $0.codeUsage != nil })
    }

    @MainActor
    func testInaccessibleDefaultDoesNotBlockConfiguredProfile() async throws {
        let fixture = Self.fetcher()
        await fixture.setIdentity(.failure(.authUnavailable))
        let (state, spy, _) = try makeState(fixture)
        await state.refresh(onStart: {})
        XCTAssertNotNil(state.snapshot.claudeAccounts.first?.codeUsage)
        XCTAssertEqual(state.snapshot.claudeAccounts.first?.quotaSource, .configuredProfile)
        XCTAssertEqual(spy.calls, 0)
    }

    @MainActor
    func testForeignOrganizationAndEmailRejectReadingAndClearOldUsage() async throws {
        for foreign in [Self.identity(org: Self.otherOrg), Self.identity(email: "foreign@example.test")] {
            let fixture = Self.fetcher()
            let (state, _, _) = try makeState(fixture)
            await state.refresh(onStart: {})
            XCTAssertNotNil(state.snapshot.claudeAccounts.first?.codeUsage)
            await fixture.setReading(.success(Self.reading(foreign)))
            await state.refresh(onStart: {})
            XCTAssertNil(state.snapshot.claudeAccounts.first?.codeUsage)
            XCTAssertNotNil(state.snapshot.claudeAccounts.first?.quotaError)
        }
    }

    @MainActor
    func testSignoutAndIdentityChangeNeverRetainOldUsage() async throws {
        for error in [ClaudeOwnerUsageProbeError.signInRequired, .identityChanged, .authUnavailable] {
            let fixture = Self.fetcher()
            let (state, _, _) = try makeState(fixture)
            await state.refresh(onStart: {})
            await fixture.setReading(.failure(error))
            await state.refresh(onStart: {})
            XCTAssertNil(state.snapshot.claudeAccounts.first?.codeUsage)
            XCTAssertEqual(state.snapshot.claudeAccounts.first?.quotaError, ClaudeCodeUsageRouting.diagnostic(error))
        }
    }

    @MainActor
    func testTransientFailureRetainsOriginalCaptureTimeOnlyForSameOrigin() async throws {
        let fixture = Self.fetcher()
        let (state, _, _) = try makeState(fixture)
        await state.refresh(onStart: {})
        await fixture.setReading(.failure(.timedOut))
        await state.refresh(onStart: {})
        XCTAssertEqual(state.snapshot.claudeAccounts.first?.codeUsage?.capturedAt, Self.capturedAt)
        XCTAssertNotNil(state.snapshot.claudeAccounts.first?.quotaError)
        await fixture.setIdentity(.failure(.authUnavailable))
        await state.refresh(onStart: {})
        XCTAssertEqual(state.snapshot.claudeAccounts.first?.quotaSource, .configuredProfile)
        XCTAssertNil(state.snapshot.claudeAccounts.first?.codeUsage)
    }

    @MainActor
    func testAutoRefreshOffRunsNeitherIdentityNorFetch() async throws {
        let fixture = Self.fetcher()
        let (state, spy, _) = try makeState(fixture, autoRefresh: false)
        await state.refresh(onStart: {})
        let calls = await fixture.calls()
        XCTAssertTrue(calls.0.isEmpty)
        XCTAssertTrue(calls.1.isEmpty)
        XCTAssertNil(state.snapshot.claudeAccounts.first?.codeUsage)
        XCTAssertEqual(spy.calls, 0)
    }

    @MainActor
    func testExplicitProfileRefreshForcesFetchWithAutoRefreshOff() async throws {
        let fixture = Self.fetcher()
        let (state, spy, _) = try makeState(fixture, autoRefresh: false)
        await state.refreshClaudeAccount(id: state.claudeAccounts[0].id, allowKeychainPrompt: true)
        let calls = await fixture.calls()
        XCTAssertEqual(calls.0.count, 1)
        XCTAssertEqual(calls.1.count, 1)
        XCTAssertTrue(try XCTUnwrap(calls.1.first).force)
        XCTAssertNotNil(state.snapshot.claudeAccounts.first?.codeUsage)
        XCTAssertEqual(spy.calls, 0)
    }

    @MainActor
    func testPersistingSourceChangeClearsIncompatibleReading() async throws {
        let fixture = Self.fetcher()
        let (state, _, saves) = try makeState(fixture)
        await state.refresh(onStart: {})
        XCTAssertNotNil(state.snapshot.claudeAccounts.first?.codeUsage)
        var next = state.currentConfig
        next.claudeUsageSource = .oauth
        XCTAssertTrue(state.persistConfig(next))
        XCTAssertNil(state.snapshot.claudeAccounts.first?.codeUsage)
        XCTAssertNil(state.snapshot.claudeAccounts.first?.quota)
        XCTAssertEqual(saves.values.last?.claudeUsageSource, .oauth)
    }

    @MainActor
    func testSourceAndProfileMutationWhileAwaitingDiscardCompletion() async throws {
        for changeSource in [true, false] {
            let gate = CodeRefreshGate()
            let fixture = Self.fetcher(gate: gate)
            let (state, _, saves) = try makeState(fixture)
            let id = state.claudeAccounts[0].id
            let refresh = Task { await state.refreshClaudeAccount(id: id, allowKeychainPrompt: true) }
            await gate.waitUntilEntered()
            var next = state.currentConfig
            if changeSource { next.claudeUsageSource = .oauth }
            else { next.claudeAccounts[0].configDirectory = next.claudeAccounts[0].configDirectory! + "-changed" }
            XCTAssertTrue(state.persistConfig(next))
            await gate.release()
            await refresh.value
            XCTAssertNil(state.snapshot.claudeAccounts.first?.codeUsage)
            XCTAssertNil(state.claudeAccounts[0].codeEmail)
            XCTAssertEqual(saves.values.count, 1, "A stale completion must not persist association pins")
            XCTAssertEqual(state.currentConfig, next)
        }
    }

    @MainActor
    func testReportedPinsPersistSeparatelyAndPreserveOAuthIdentity() async throws {
        for pinned in [true, false] {
            let fixture = Self.fetcher()
            let (state, _, saves) = try makeState(fixture, pinned: pinned)
            let original = state.claudeAccounts[0]
            await state.refresh(onStart: {})
            let saved = try XCTUnwrap(saves.values.last?.claudeAccounts.first)
            XCTAssertEqual(saved.codeEmail, "owner@example.test")
            XCTAssertEqual(saved.codeOrganizationID, Self.org)
            XCTAssertEqual(saved.accountID, original.accountID)
            XCTAssertEqual(saved.email, original.email)
            XCTAssertEqual(saved.configDirectory, original.configDirectory)
            XCTAssertEqual(state.claudeAccounts[0], saved)
        }
    }

    @MainActor
    func testTopLevelExplicitRefreshWorksWithAutomaticRefreshOff() async throws {
        let fixture = Self.fetcher()
        let (state, _, _) = try makeState(fixture, autoRefresh: false)
        await state.refresh(forceClaude: true, onStart: {})
        let calls = await fixture.calls()
        XCTAssertEqual(calls.1.count, 1)
        XCTAssertTrue(try XCTUnwrap(calls.1.first).force)
        XCTAssertNotNil(state.snapshot.claudeAccounts.first?.codeUsage)
    }

    @MainActor
    func testOrganizationWithoutEmailCannotAdoptAmbientLogin() async throws {
        let fixture = Self.fetcher()
        let (state, _, _) = try makeState(fixture)
        var config = state.currentConfig
        config.claudeAccounts[0].email = nil
        XCTAssertTrue(state.persistConfig(config))
        await state.refresh(onStart: {})
        let calls = await fixture.calls()
        XCTAssertNotNil(try XCTUnwrap(calls.1.first).profile.configDirectory)
        XCTAssertEqual(state.snapshot.claudeAccounts.first?.quotaSource, .configuredProfile)
    }

    @MainActor
    func testHistoricalConfiguredEmailBootstrapRequiresWholeSavedUUIDPair() async throws {
        for pairMatches in [true, false] {
            let fixture = Self.fetcher()
            let (state, _, _) = try makeState(fixture)
            var config = state.currentConfig
            config.claudeAccounts[0].email = nil
            XCTAssertTrue(state.persistConfig(config))
            let profile = state.claudeAccounts[0]
            try FileManager.default.createDirectory(at: profile.directoryURL, withIntermediateDirectories: true)
            let metadata: [String: Any] = ["oauthAccount": [
                "accountUuid": pairMatches ? "11111111-1111-1111-1111-111111111111" : "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
                "organizationUuid": Self.org, "emailAddress": "owner@example.test"]]
            try JSONSerialization.data(withJSONObject: metadata).write(to: profile.directoryURL.appendingPathComponent(".claude.json"))
            await state.refresh(onStart: {})
            let calls = await fixture.calls()
            XCTAssertEqual(calls.1.first?.profile.configDirectory == nil, pairMatches)
            XCTAssertNil(state.claudeAccounts[0].email, "Historical metadata must not become verified OAuth email")
            XCTAssertEqual(state.claudeAccounts[0].accountID, Self.account)
        }
    }

    @MainActor
    func testObservedDefaultLogoutCannotBeOverruledByRealActorSuccessCache() async throws {
        let fixture = Self.fetcher()
        let cache = ClaudeCodeUsageFetcher(identityRunner: { try await fixture.identity(profile: $0) },
            usageRunner: { try await fixture.fetch(profile: $0, force: false) }, cacheInterval: 600)
        let (state, _, _) = try makeState(cache)
        var config = state.currentConfig
        config.claudeAccounts[0].configDirectory = nil
        XCTAssertTrue(state.persistConfig(config))
        await state.refresh(onStart: {})
        XCTAssertNotNil(state.snapshot.claudeAccounts.first?.codeUsage)
        await fixture.setIdentity(.failure(.signInRequired))
        await state.refresh(onStart: {})
        XCTAssertNil(state.snapshot.claudeAccounts.first?.codeUsage)
        XCTAssertEqual(state.snapshot.claudeAccounts.first?.quotaError, ClaudeOwnerUsageProbeError.signInRequired.localizedDescription)
        let calls = await fixture.calls()
        XCTAssertEqual(calls.1.count, 1, "Observed logout must not call through to the cached reading")
    }

    @MainActor
    func testObservedDefaultChangeFollowedByTimeoutDoesNotRetainOldAccount() async throws {
        let fixture = Self.fetcher()
        let (state, _, _) = try makeState(fixture)
        var config = state.currentConfig
        config.claudeAccounts[0].configDirectory = nil
        XCTAssertTrue(state.persistConfig(config))
        await state.refresh(onStart: {})
        await fixture.setIdentity(.success(Self.identity(email: "other@example.test")))
        await fixture.setReading(.failure(.timedOut))
        await state.refresh(onStart: {})
        XCTAssertNil(state.snapshot.claudeAccounts.first?.codeUsage)
        let calls = await fixture.calls()
        XCTAssertEqual(calls.1.count, 1, "A known foreign default must be rejected before usage fetching")
    }

    func testRoutingPolicyValidationRetentionAndSafeDiagnostics() throws {
        let profile = ClaudeAccountProfile(label: "Policy", configDirectory: "/unused-fixture", accountID: Self.account,
            email: "OWNER@example.test", codeEmail: "owner@example.test", codeOrganizationID: Self.org.uppercased())
        XCTAssertNoThrow(try ClaudeCodeUsageRouting.validate(Self.identity(), for: profile))
        XCTAssertThrowsError(try ClaudeCodeUsageRouting.validate(Self.identity(org: Self.otherOrg), for: profile))
        XCTAssertThrowsError(try ClaudeCodeUsageRouting.validate(Self.identity(email: "foreign@example.test"), for: profile))
        XCTAssertEqual(ClaudeCodeUsageRouting.source(for: profile, profiles: [profile], defaultIdentity: Self.identity()), .defaultClaudeCode)
        XCTAssertEqual(ClaudeCodeUsageRouting.source(for: profile, profiles: [profile], defaultIdentity: nil), .configuredProfile)
        XCTAssertTrue(ClaudeCodeUsageRouting.canRetainLastKnown(after: ClaudeOwnerUsageProbeError.timedOut))
        XCTAssertTrue(ClaudeCodeUsageRouting.canRetainLastKnown(after: ClaudeBackendError.network))
        XCTAssertFalse(ClaudeCodeUsageRouting.canRetainLastKnown(after: ClaudeBackendError.identityMismatch))
        XCTAssertFalse(ClaudeCodeUsageRouting.canRetainLastKnown(after: CancellationError()))
        XCTAssertEqual(ClaudeCodeUsageRouting.diagnostic(ClaudeOwnerUsageProbeError.signInRequired), ClaudeOwnerUsageProbeError.signInRequired.localizedDescription)
        XCTAssertFalse(ClaudeCodeUsageRouting.diagnostic(NSError(domain: "/private/secret", code: 1)).contains("secret"))
    }
}

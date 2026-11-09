import Foundation
import XCTest
@testable import LLMUsageBar

private final class RecoveryFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var freshKeys = Set<String>()
    private var calls: [String] = []
    private var clock = Date(timeIntervalSince1970: 2_000_000_000)
    var date: Date { lock.lock(); defer { lock.unlock() }; return clock }
    var attempts: [String] { lock.lock(); defer { lock.unlock() }; return calls }
    func advance() { lock.lock(); clock = clock.addingTimeInterval(301); lock.unlock() }
    func record(_ profile: ClaudeAccountProfile, fresh: Bool = true) {
        lock.lock(); defer { lock.unlock() }
        let key = ClaudeCredentials.serviceName(for: profile)
        calls.append(key)
        if fresh { freshKeys.insert(key) }
    }
    func read(_ profile: ClaudeAccountProfile, _ prompt: Bool) throws -> ClaudeCredential {
        XCTAssertFalse(prompt, "Recovery polling must never prompt")
        lock.lock(); defer { lock.unlock() }
        guard freshKeys.contains(ClaudeCredentials.serviceName(for: profile)) else { throw ClaudeBackendError.credentialsExpired }
        return ClaudeCredential(accessToken: "fixture", expiresAt: clock.addingTimeInterval(3600), scopes: ["user:profile"], subscriptionType: nil, rateLimitTier: nil)
    }
}

final class ClaudeCredentialRecoveryTests: XCTestCase {
    func testCoalescesSameProfileAndKeepsDifferentProfilesIndependent() async throws {
        let fixture = RecoveryFixture()
        let recovery = ClaudeCredentialRecovery(reader: fixture.read, runner: { profile, ready in
            try await Task.sleep(nanoseconds: 30_000_000)
            fixture.record(profile)
            XCTAssertTrue(ready())
        }, now: { fixture.date })
        let first = ClaudeAccountProfile(label: "First", configDirectory: "/tmp/recovery-first")
        let second = ClaudeAccountProfile(label: "Second", configDirectory: "/tmp/recovery-second")
        async let a: Void = recovery.recover(profile: first)
        async let b: Void = recovery.recover(profile: first)
        async let c: Void = recovery.recover(profile: second)
        _ = try await (a, b, c)
        XCTAssertEqual(fixture.attempts.count, 2)
        XCTAssertEqual(Set(fixture.attempts).count, 2)
    }

    func testFailedRefreshIsCooledDownPerProfileAndCanRetryLater() async throws {
        let fixture = RecoveryFixture()
        let recovery = ClaudeCredentialRecovery(reader: fixture.read, runner: { profile, _ in
            fixture.record(profile, fresh: false)
            throw ClaudeAuthRefreshCLIError.timedOut
        }, now: { fixture.date })
        let profile = ClaudeAccountProfile(label: "Fixture")
        for expected in ["timed out", "cooling down"] {
            do { try await recovery.recover(profile: profile); XCTFail() }
            catch { XCTAssertTrue(error.localizedDescription.contains(expected)) }
        }
        XCTAssertEqual(fixture.attempts.count, 1)
        fixture.advance()
        do { try await recovery.recover(profile: profile); XCTFail() } catch {}
        XCTAssertEqual(fixture.attempts.count, 2)
    }

    func testChangedCredentialStoreBeforeRecoveryFailsClosed() async throws {
        for error in [ClaudeBackendError.keychainUnavailable, .credentialStoresConflict, .credentialsMissing, .credentialsInvalid] {
            let fixture = RecoveryFixture()
            let recovery = ClaudeCredentialRecovery(reader: { _, _ in throw error }, runner: { profile, _ in fixture.record(profile) })
            do { try await recovery.recover(profile: .init(label: "Fixture")); XCTFail() }
            catch let actual as ClaudeBackendError { XCTAssertEqual(actual, error) }
            XCTAssertTrue(fixture.attempts.isEmpty)
        }
    }

    func testCancellingInitiatorCancelsSharedRecoveryAndPreservesCooldown() async throws {
        let fixture = RecoveryFixture()
        let profile = ClaudeAccountProfile(label: "Fixture")
        let recovery = ClaudeCredentialRecovery(reader: fixture.read, runner: { profile, _ in
            fixture.record(profile, fresh: false)
            try await Task.sleep(nanoseconds: 10_000_000_000)
        }, now: { fixture.date })
        let first = Task { try await recovery.recover(profile: profile) }
        while fixture.attempts.isEmpty { await Task.yield() }
        let second = Task { try await recovery.recover(profile: profile) }
        try await Task.sleep(nanoseconds: 20_000_000)
        first.cancel()
        for task in [first, second] {
            do { try await task.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
        }
        XCTAssertEqual(fixture.attempts.count, 1)
        do { try await recovery.recover(profile: profile); XCTFail() }
        catch { XCTAssertTrue(error is ClaudeCredentialRecoveryError) }
    }

    func testRejectedLoginClearedDuringSetupIsReportedAsSignInRequired() async throws {
        let fixture = RecoveryFixture()
        let recovery = ClaudeCredentialRecovery(reader: { _, _ in
            if fixture.attempts.isEmpty { throw ClaudeBackendError.credentialsExpired }
            throw ClaudeBackendError.credentialsCleared
        }, runner: { profile, _ in
            fixture.record(profile, fresh: false)
            throw ClaudeAuthRefreshCLIError.setupRequired
        })
        do { try await recovery.recover(profile: .init(label: "Fixture")); XCTFail() }
        catch { XCTAssertEqual(error as? ClaudeBackendError, .credentialsCleared) }
        XCTAssertEqual(fixture.attempts.count, 1)
    }

    func testSuccessfulRunnerIsNotEnoughWithoutFreshCredentials() async throws {
        let fixture = RecoveryFixture()
        let recovery = ClaudeCredentialRecovery(reader: fixture.read, runner: { profile, _ in
            fixture.record(profile, fresh: false)
        }, now: { fixture.date })
        do { try await recovery.recover(profile: .init(label: "Fixture")); XCTFail() }
        catch { XCTAssertTrue(error is ClaudeCredentialRecoveryError) }
    }

    func testAlreadyRefreshedCredentialsSkipCLIAndDefaultRemainsDistinct() async throws {
        let fixture = RecoveryFixture()
        let implicit = ClaudeAccountProfile(label: "Default")
        fixture.record(implicit)
        let recovery = ClaudeCredentialRecovery(reader: fixture.read, runner: { profile, _ in fixture.record(profile) }, now: { fixture.date })
        try await recovery.recover(profile: implicit)
        XCTAssertEqual(fixture.attempts.count, 1)
        try await recovery.recover(profile: .init(label: "Explicit", configDirectory: "~/.claude"))
        XCTAssertEqual(Set(fixture.attempts).count, 2)
    }
}

@MainActor
final class AppStateClaudeRecoveryTests: XCTestCase {
    private static let identity = "11111111-1111-1111-1111-111111111111:22222222-2222-2222-2222-222222222222"

    private func makeState(enabled: Bool, failure: ClaudeBackendError = .credentialsExpired,
                           mismatch: Bool = false) throws -> (AppState, RecoveryFixture, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let fixture = RecoveryFixture()
        let profile = ClaudeAccountProfile(label: "Fixture", configDirectory: root.path,
                                           accountID: mismatch ? "different-account" : Self.identity)
        let recovery = ClaudeCredentialRecovery(reader: fixture.read, runner: { profile, _ in fixture.record(profile) }, now: { fixture.date })
        let fetcher = ClaudeUsageFetcher(transport: { request in
            let body = request.url!.lastPathComponent == "profile"
                ? #"{"account":{"uuid":"11111111-1111-1111-1111-111111111111"},"organization":{"uuid":"22222222-2222-2222-2222-222222222222"}}"#
                : #"{"five_hour":{"utilization":25}}"#
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, credentialReader: { profile, _ in
            if profile.configDirectory == nil { throw ClaudeBackendError.credentialsMissing }
            do { return try fixture.read(profile, false) }
            catch { throw failure }
        }, backoff: ClaudeQuotaBackoff(), now: { fixture.date })
        var config = AppConfig.default
        config.codexEnabled = false; config.openCodeEnabled = false; config.piEnabled = false
        config.claudeAutoRefreshEnabled = enabled
        config.claudeUsageSource = .oauth
        config.claudeAccounts = [profile]
        let handoff = PiCodexCredentialHandoff(managedHomeStore: ManagedCodexHomeStore(root: root.appendingPathComponent("homes")),
                                              piAuthStore: PiAuthStore(authURL: root.appendingPathComponent("pi-auth.json")), journalRoot: root)
        let state = AppState(config: config, claudeFetcher: fetcher, claudeRecovery: recovery,
                             claudeDefaultIdentityHint: { nil }, piCodexHandoff: handoff,
                             pendingCodexResetURL: root.appendingPathComponent("pending.json"), logInfo: { _ in }, logError: { _ in })
        return (state, fixture, root)
    }

    func testBackgroundRecoveryCanBeDisabled() async throws {
        let (state, fixture, _) = try makeState(enabled: false)
        await state.refresh(onStart: {})
        XCTAssertEqual(fixture.attempts.count, 0)
        XCTAssertNil(state.snapshot.claudeAccounts.first?.quota)
        XCTAssertNotNil(state.snapshot.claudeAccounts.first?.quotaError)
    }

    func testEnabledBackgroundRecoveryRetriesQuotaAndPublishesOnlyVerifiedIdentity() async throws {
        let (state, fixture, _) = try makeState(enabled: true)
        await state.refresh(onStart: {})
        XCTAssertEqual(fixture.attempts.count, 1)
        XCTAssertEqual(state.snapshot.claudeAccounts.first?.quota?.accountID, Self.identity)
        XCTAssertNil(state.snapshot.claudeAccounts.first?.quotaError)
    }

    func testExplicitProfileRefreshMayRecoverWithBackgroundOptionOff() async throws {
        let (state, fixture, _) = try makeState(enabled: false)
        await state.refreshClaudeAccount(id: state.claudeAccounts[0].id, allowKeychainPrompt: true)
        XCTAssertEqual(fixture.attempts.count, 1)
        XCTAssertNotNil(state.snapshot.claudeAccounts.first?.quota)
    }

    func testRecoveryCannotAdoptAnotherAccount() async throws {
        let (state, fixture, _) = try makeState(enabled: true, mismatch: true)
        await state.refresh(onStart: {})
        XCTAssertEqual(fixture.attempts.count, 1)
        XCTAssertNil(state.snapshot.claudeAccounts.first?.quota)
        XCTAssertTrue(state.snapshot.claudeAccounts.first?.quotaError?.contains("another Claude account") == true)
        XCTAssertEqual(state.claudeAccounts[0].accountID, "different-account")
    }

    func testNonExpiryErrorsNeverLaunchRecovery() async throws {
        for failure in [ClaudeBackendError.keychainUnavailable, .credentialsMissing, .credentialsInvalid, .credentialsCleared,
                        .credentialStoresConflict, .identityMismatch, .scopeMissing, .unauthorized, .network] {
            let (state, fixture, _) = try makeState(enabled: true, failure: failure)
            await state.refresh(onStart: {})
            XCTAssertTrue(fixture.attempts.isEmpty, "Unexpected recovery for \(failure)")
        }
    }
}

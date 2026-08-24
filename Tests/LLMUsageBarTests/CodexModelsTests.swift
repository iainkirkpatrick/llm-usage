import CryptoKit
import XCTest
@testable import LLMUsageBar

private final class TestConfigBox: @unchecked Sendable {
    var value: AppConfig
    init(_ value: AppConfig) { self.value = value }
}

private final class TestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var value = 0

    func increment() {
        self.lock.lock()
        self.value += 1
        self.lock.unlock()
    }
}

final class CodexModelsTests: XCTestCase {
    func testNodeDateDecodingSupportsFractionalAndStandardISO8601() {
        XCTAssertNotNil(CodexNodeBridge.iso8601Date(from: "2026-07-19T22:08:28.000Z"))
        XCTAssertNotNil(CodexNodeBridge.iso8601Date(from: "2026-07-19T22:08:28Z"))
        XCTAssertNil(CodexNodeBridge.iso8601Date(from: "not-a-date"))
    }

    func testOldConfigDecodesWithoutManagedAccounts() throws {
        let data = Data(#"{"codexEnabled":true,"piEnabled":true}"#.utf8)
        let config = try JSONDecoder().decode(AppConfig.self, from: data)
        XCTAssertTrue(config.codexManagedAccounts.isEmpty)
        XCTAssertNil(config.codexPrimaryAccountID)
    }

    func testManagedProfileSerializationContainsMetadataOnly() throws {
        let profile = CodexManagedAccountProfile(
            id: UUID(),
            label: "Work",
            email: "work@example.com",
            planType: "pro")
        let data = try JSONEncoder().encode(profile)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(json.contains("work@example.com"))
        XCTAssertFalse(json.contains("auth.json"))
        XCTAssertFalse(json.contains("access_token"))
        XCTAssertFalse(json.contains("CODEX_HOME"))
    }

    func testManagedHomeStoreKeepsHomesAndAuthPrivate() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("llm-usage-managed-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = ManagedCodexHomeStore(root: root)
        let accountID = UUID()
        let home = try store.prepareAccountHome(for: accountID)
        XCTAssertEqual(try self.permissions(at: root), 0o700)
        XCTAssertEqual(try self.permissions(at: home), 0o700)

        let auth = home.appendingPathComponent("auth.json")
        try Data("credentials stay isolated".utf8).write(to: auth)
        try store.secureAuthFile(for: accountID, requireExisting: true)
        XCTAssertEqual(try self.permissions(at: auth), 0o600)
    }

    func testStagedLoginReplacesOnlyValidatedAuthAndKeepsOldAuthOnValidationFailure() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("llm-usage-login-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = ManagedCodexHomeStore(root: root)
        let accountID = UUID()
        let home = try store.prepareAccountHome(for: accountID)
        let authURL = home.appendingPathComponent("auth.json")
        try Data(Self.validNativeAuth("old").utf8).write(to: authURL)
        try store.secureAuthFile(for: accountID, requireExisting: true)

        let staging = try store.prepareLoginStagingHome(for: accountID)
        try Data(Self.validNativeAuth("new").utf8)
            .write(to: staging.appendingPathComponent("auth.json"))
        try store.commitStagedAuth(for: accountID, stagingHome: staging)
        XCTAssertEqual(String(decoding: try Data(contentsOf: authURL), as: UTF8.self).contains("new"), true)
        try store.removeLoginStagingHome(staging, accountID: accountID)

        let invalidStaging = try store.prepareLoginStagingHome(for: accountID)
        try Data(#"{"OPENAI_API_KEY":"sk-test"}"#.utf8)
            .write(to: invalidStaging.appendingPathComponent("auth.json"))
        XCTAssertThrowsError(try store.commitStagedAuth(for: accountID, stagingHome: invalidStaging))
        XCTAssertEqual(String(decoding: try Data(contentsOf: authURL), as: UTF8.self).contains("new"), true)
        try store.removeLoginStagingHome(invalidStaging, accountID: accountID)
    }

    func testManagedHomeRejectsSymlinkedRoot() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("llm-usage-symlink-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        let realRoot = parent.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: realRoot, withIntermediateDirectories: false)
        let linkedRoot = parent.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: realRoot)

        let store = ManagedCodexHomeStore(root: linkedRoot)
        XCTAssertThrowsError(try store.prepareAccountHome(for: UUID()))
    }

    func testLoginURLExtractionOnlyAcceptsSafeOpenAIHTTPSURLs() {
        XCTAssertEqual(
            CodexLoginRunner.safeOAuthURL(from: "Open https://auth.openai.com/oauth/authorize?state=abc now")?.host,
            "auth.openai.com")
        XCTAssertNil(CodexLoginRunner.safeOAuthURL(from: "https://example.com/oauth"))
        XCTAssertNil(CodexLoginRunner.safeOAuthURL(from: "https://auth.openai.com/oauth?access_token=secret"))
    }

    func testManagedRemovalRestoresQuarantineWhenMetadataSaveFails() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("llm-usage-removal-save-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = ManagedCodexHomeStore(root: root)
        let accountID = UUID()
        _ = try store.prepareAccountHome(for: accountID)
        let original = Self.config(with: accountID)
        var next = original
        next.codexManagedAccounts = []
        next.codexPrimaryAccountID = nil
        guard let removal = try store.stageAccountHomeRemoval(for: accountID) else {
            XCTFail("Expected a managed home to be staged")
            return
        }

        var saveResponses = [false, true]
        var saved: [AppConfig] = []
        XCTAssertThrowsError(try ManagedCodexAccountRemovalTransaction.commit(
            original: original,
            next: next,
            removal: removal,
            save: { config in
                saved.append(config)
                return saveResponses.removeFirst()
            },
            finalize: { _ in
                XCTFail("Finalization must not run after a metadata failure")
            },
            restore: { removal in
                try store.restoreAccountHome(removal)
            })) { error in
                guard case .metadataSaveFailed = error as? ManagedCodexAccountRemovalTransactionError else {
                    return XCTFail("Unexpected transaction error: \(error)")
                }
            }

        XCTAssertEqual(saved.count, 2)
        XCTAssertTrue(saved[0].codexManagedAccounts.isEmpty)
        XCTAssertEqual(saved[1].codexManagedAccounts.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.homeURL(for: accountID).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: removal.quarantineURL.path))
    }

    func testManagedRemovalRollsBackMetadataAndHomeWhenFinalizationFails() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("llm-usage-removal-finalize-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = ManagedCodexHomeStore(root: root)
        let accountID = UUID()
        _ = try store.prepareAccountHome(for: accountID)
        let original = Self.config(with: accountID)
        var next = original
        next.codexManagedAccounts = []
        next.codexPrimaryAccountID = nil
        guard let removal = try store.stageAccountHomeRemoval(for: accountID) else {
            XCTFail("Expected a managed home to be staged")
            return
        }

        var saveCount = 0
        XCTAssertThrowsError(try ManagedCodexAccountRemovalTransaction.commit(
            original: original,
            next: next,
            removal: removal,
            save: { _ in
                saveCount += 1
                return true
            },
            finalize: { _ in
                throw InjectedRemovalFailure.finalization
            },
            restore: { removal in
                try store.restoreAccountHome(removal)
            })) { error in
                guard case .credentialFinalizationFailed = error as? ManagedCodexAccountRemovalTransactionError else {
                    return XCTFail("Unexpected transaction error: \(error)")
                }
            }

        XCTAssertEqual(saveCount, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.homeURL(for: accountID).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: removal.quarantineURL.path))
    }

    func testManagedPiHandoffMovesTheLiveCredentialAndPreservesOtherPiProviders() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("llm-usage-pi-handoff-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let managedRoot = root.appendingPathComponent("managed", isDirectory: true)
        let piAuth = root.appendingPathComponent("pi/agent/auth.json")
        let journalRoot = root.appendingPathComponent("journal", isDirectory: true)
        let store = ManagedCodexHomeStore(root: managedRoot)
        let piStore = PiAuthStore(authURL: piAuth)
        let handoff = PiCodexCredentialHandoff(
            managedHomeStore: store,
            piAuthStore: piStore,
            journalRoot: journalRoot)

        let firstID = UUID()
        let secondID = UUID()
        let first = CodexManagedAccountProfile(id: firstID, label: "Personal")
        let second = CodexManagedAccountProfile(id: secondID, label: "Work")
        var config = AppConfig.default
        config.codexManagedAccounts = [first, second]
        config.codexPrimaryAccountID = firstID

        let firstHome = try store.prepareAccountHome(for: firstID)
        let secondHome = try store.prepareAccountHome(for: secondID)
        try Data(Self.validNativeAuth("first", accountID: "chatgpt-first").utf8)
            .write(to: firstHome.appendingPathComponent("auth.json"))
        try Data(Self.validNativeAuth("second", accountID: "chatgpt-second").utf8)
            .write(to: secondHome.appendingPathComponent("auth.json"))
        try store.secureAuthFile(for: firstID, requireExisting: true)
        try store.secureAuthFile(for: secondID, requireExisting: true)

        // Seed an unrelated Pi provider. The handoff must preserve it byte-for-byte semantically.
        _ = try piStore.readRawDocument()
        let unrelated: [String: Any] = ["type": "api_key", "key": "env:OTHER_KEY"]
        let initialPi: [String: Any] = ["other-provider": unrelated]
        try JSONSerialization.data(withJSONObject: initialPi, options: [.prettyPrinted, .sortedKeys])
            .write(to: piAuth)
        try AppOwnedPathSafety.hardenRegularFile(at: piAuth, permissions: 0o600)

        let savedConfig = TestConfigBox(config)
        let activatedFirst = try handoff.activate(
            accountID: firstID,
            config: config,
            saveConfig: { savedConfig.value = $0; return true })
        config = activatedFirst.config
        XCTAssertEqual(config.codexPiHandoffAccountID, firstID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstHome.appendingPathComponent("auth.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondHome.appendingPathComponent("auth.json").path))

        var piObject = try JSONSerialization.jsonObject(with: piStore.readRawDocument()) as! [String: Any]
        let firstPi = piObject["openai-codex"] as! [String: Any]
        XCTAssertEqual(firstPi["accountId"] as? String, "chatgpt-first")
        XCTAssertEqual((piObject["other-provider"] as? [String: Any])?["key"] as? String, "env:OTHER_KEY")

        // Simulate a Pi refresh. Switching away must persist these latest values before target
        // activation, rather than restoring the stale native login snapshot.
        piObject["openai-codex"] = [
            "type": "oauth",
            "access": "first-refreshed",
            "refresh": "first-refresh-rotated",
            "expires": 4_000_000_000,
            "accountId": "chatgpt-first",
        ]
        try JSONSerialization.data(withJSONObject: piObject, options: [.prettyPrinted, .sortedKeys])
            .write(to: piAuth)
        try AppOwnedPathSafety.hardenRegularFile(at: piAuth, permissions: 0o600)

        let activatedSecond = try handoff.activate(
            accountID: secondID,
            config: config,
            saveConfig: { savedConfig.value = $0; return true })
        config = activatedSecond.config
        XCTAssertEqual(config.codexPiHandoffAccountID, secondID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondHome.appendingPathComponent("auth.json").path))

        let persistedFirst = try JSONSerialization.jsonObject(
            with: Data(contentsOf: firstHome.appendingPathComponent("auth.json"))) as! [String: Any]
        let persistedFirstTokens = persistedFirst["tokens"] as! [String: Any]
        XCTAssertEqual(persistedFirstTokens["access_token"] as? String, "first-refreshed")
        XCTAssertEqual(persistedFirstTokens["refresh_token"] as? String, "first-refresh-rotated")

        let activeSecondPi = try JSONSerialization.jsonObject(with: piStore.readRawDocument()) as! [String: Any]
        XCTAssertEqual((activeSecondPi["openai-codex"] as? [String: Any])?["accountId"] as? String, "chatgpt-second")
        XCTAssertEqual((activeSecondPi["other-provider"] as? [String: Any])?["key"] as? String, "env:OTHER_KEY")

        _ = try handoff.deactivate(
            accountID: secondID,
            config: config,
            saveConfig: { savedConfig.value = $0; return true })
        XCTAssertNil(savedConfig.value.codexPiHandoffAccountID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondHome.appendingPathComponent("auth.json").path))
        let releasedPi = try JSONSerialization.jsonObject(with: piStore.readRawDocument()) as! [String: Any]
        XCTAssertNil(releasedPi["openai-codex"])
        XCTAssertNotNil(releasedPi["other-provider"])
        XCTAssertEqual(try self.permissions(at: piAuth), 0o600)
    }

    func testManagedPiHandoffRejectsADifferentPiIdentityWithoutChangingCredentials() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("llm-usage-pi-mismatch-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = ManagedCodexHomeStore(root: root.appendingPathComponent("managed", isDirectory: true))
        let piAuth = root.appendingPathComponent("pi/agent/auth.json")
        let piStore = PiAuthStore(authURL: piAuth)
        let accountID = UUID()
        let profile = CodexManagedAccountProfile(id: accountID, label: "Work")
        let home = try store.prepareAccountHome(for: accountID)
        try Data(Self.validNativeAuth("managed", accountID: "chatgpt-managed").utf8)
            .write(to: home.appendingPathComponent("auth.json"))
        try store.secureAuthFile(for: accountID, requireExisting: true)
        _ = try piStore.readRawDocument()
        let originalPi: [String: Any] = [
            "openai-codex": [
                "type": "oauth",
                "access": "other-access",
                "refresh": "other-refresh",
                "expires": 4_000_000_000,
                "accountId": "chatgpt-other",
            ],
            "other-provider": ["type": "api_key", "key": "env:OTHER_KEY"],
        ]
        let originalData = try JSONSerialization.data(withJSONObject: originalPi, options: [.prettyPrinted, .sortedKeys])
        try originalData.write(to: piAuth)
        try AppOwnedPathSafety.hardenRegularFile(at: piAuth, permissions: 0o600)

        var config = AppConfig.default
        config.codexManagedAccounts = [profile]
        let handoff = PiCodexCredentialHandoff(
            managedHomeStore: store,
            piAuthStore: piStore,
            journalRoot: root.appendingPathComponent("journal", isDirectory: true))
        XCTAssertThrowsError(try handoff.activate(
            accountID: accountID,
            config: config,
            saveConfig: { _ in true })) { error in
            guard case let PiCodexCredentialHandoffError.piCredentialIdentityMismatch(expected, actual) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(expected, "chatgpt-managed")
            XCTAssertEqual(actual, "chatgpt-other")
        }
        XCTAssertEqual(try Data(contentsOf: piAuth), originalData)
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent("auth.json").path))
    }

    func testManagedPiHandoffRollsBackWhenConfigurationCommitFails() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("llm-usage-pi-rollback-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let accountID = UUID()
        let store = ManagedCodexHomeStore(root: root.appendingPathComponent("managed", isDirectory: true))
        let home = try store.prepareAccountHome(for: accountID)
        let auth = home.appendingPathComponent("auth.json")
        try Data(Self.validNativeAuth("managed", accountID: "chatgpt-managed").utf8).write(to: auth)
        try store.secureAuthFile(for: accountID, requireExisting: true)

        var config = AppConfig.default
        config.codexManagedAccounts = [CodexManagedAccountProfile(id: accountID, label: "Work")]
        let piStore = PiAuthStore(authURL: root.appendingPathComponent("pi/agent/auth.json"))
        let handoff = PiCodexCredentialHandoff(
            managedHomeStore: store,
            piAuthStore: piStore,
            journalRoot: root.appendingPathComponent("journal", isDirectory: true))

        XCTAssertThrowsError(try handoff.activate(
            accountID: accountID,
            config: config,
            saveConfig: { _ in false })) { error in
            guard case .configSaveFailed = error as? PiCodexCredentialHandoffError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: auth.path))
        let restoredPi = try JSONSerialization.jsonObject(with: piStore.readRawDocument()) as! [String: Any]
        XCTAssertNil(restoredPi["openai-codex"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("journal/codex-pi-handoff.json").path))
    }

    func testConfigStoreSerializesCompetingWritersAndRejectsAStaleHandoff() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("llm-usage-config-lock-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var base = AppConfig.default
        base.refreshIntervalSeconds = 300
        let baseConfig = base
        XCTAssertTrue(ConfigStore.saveForTesting(baseConfig, at: root))
        let expected = ConfigStore.diskSnapshotForTesting(at: root)

        let successes = TestCounter()
        DispatchQueue.concurrentPerform(iterations: 16) { index in
            var candidate = baseConfig
            candidate.refreshIntervalSeconds = 30 + index
            if ConfigStore.saveForTesting(candidate, at: root) {
                successes.increment()
            }
        }
        XCTAssertEqual(successes.value, 16)

        var competing = base
        competing.codexEnabled = false
        let competingConfig = competing
        var handoff = base
        handoff.codexPiHandoffAccountID = UUID()
        let handoffConfig = handoff
        for _ in 0..<32 {
            XCTAssertTrue(ConfigStore.saveForTesting(baseConfig, at: root))
            let raceExpected = ConfigStore.diskSnapshotForTesting(at: root)
            let competitorWins = TestCounter()
            let handoffWins = TestCounter()
            DispatchQueue.concurrentPerform(iterations: 2) { index in
                if index == 0 {
                    if ConfigStore.saveForTesting(handoffConfig, at: root, expected: raceExpected) {
                        handoffWins.increment()
                    }
                } else if ConfigStore.saveForTesting(competingConfig, at: root) {
                    competitorWins.increment()
                }
            }
            XCTAssertEqual(competitorWins.value, 1)
            XCTAssertLessThanOrEqual(handoffWins.value, 1)
            let raceResult = try JSONDecoder().decode(
                AppConfig.self,
                from: Data(contentsOf: root.appendingPathComponent("config.json")))
            // Whichever writer acquires the lock first, the ordinary writer either follows the
            // handoff or invalidates its expected snapshot; it must never be overwritten by a
            // stale handoff comparison.
            XCTAssertEqual(raceResult, competingConfig)
        }

        XCTAssertTrue(ConfigStore.saveForTesting(competingConfig, at: root))
        XCTAssertFalse(ConfigStore.saveForTesting(handoffConfig, at: root, expected: expected))
        let persisted = try JSONDecoder().decode(
            AppConfig.self,
            from: Data(contentsOf: root.appendingPathComponent("config.json")))
        XCTAssertEqual(persisted, competingConfig)
    }

    func testPiLockReportsOwnershipLossAfterInodeReplacement() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("llm-usage-pi-lock-loss-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)

        let lockURL = root.appendingPathComponent("auth.json.lock", isDirectory: true)
        let lock = HandoffDirectoryLock(url: lockURL)
        try lock.acquire()
        try FileManager.default.removeItem(at: lockURL)
        try FileManager.default.createDirectory(at: lockURL, withIntermediateDirectories: false)
        try AppOwnedPathSafety.ensureDirectory(at: lockURL, permissions: 0o700)

        for _ in 0..<40 where !lock.isCompromised {
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertTrue(lock.isCompromised)
        XCTAssertThrowsError(try lock.checkOwnership()) { error in
            guard case .lockOwnershipLost = error as? PiCodexCredentialHandoffError else {
                return XCTFail("Unexpected ownership error: \(error)")
            }
        }
        lock.release()
        XCTAssertTrue(FileManager.default.fileExists(atPath: lockURL.path))
    }

    func testPiHandoffAbortsAndLeavesRecoveryJournalWhenPiOwnershipIsLost() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("llm-usage-pi-transaction-lock-loss-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let accountID = UUID()
        let store = ManagedCodexHomeStore(root: root.appendingPathComponent("managed", isDirectory: true))
        let home = try store.prepareAccountHome(for: accountID)
        let authURL = home.appendingPathComponent("auth.json")
        try Data(Self.validNativeAuth("managed", accountID: "chatgpt-managed").utf8).write(to: authURL)
        try store.secureAuthFile(for: accountID, requireExisting: true)
        let piStore = PiAuthStore(authURL: root.appendingPathComponent("pi/agent/auth.json"))
        _ = try piStore.readRawDocument()
        let journalRoot = root.appendingPathComponent("journal", isDirectory: true)
        let handoff = PiCodexCredentialHandoff(
            managedHomeStore: store,
            piAuthStore: piStore,
            journalRoot: journalRoot)
        var config = AppConfig.default
        config.codexManagedAccounts = [CodexManagedAccountProfile(id: accountID, label: "Work")]

        XCTAssertThrowsError(try handoff.activate(
            accountID: accountID,
            config: config,
            saveConfig: { _ in
                guard (try? FileManager.default.removeItem(at: piStore.lockURL)) != nil,
                      (try? FileManager.default.createDirectory(at: piStore.lockURL, withIntermediateDirectories: false)) != nil,
                      (try? AppOwnedPathSafety.ensureDirectory(at: piStore.lockURL, permissions: 0o700)) != nil
                else { return false }
                return true
            })) { error in
            guard case .lockOwnershipLost = error as? PiCodexCredentialHandoffError else {
                return XCTFail("Unexpected ownership error: \(error)")
            }
        }
        // The durable config callback returned success, so the journal is now the recovery
        // authority; do not attempt a conflicting rollback after Pi ownership was lost.
        XCTAssertFalse(FileManager.default.fileExists(atPath: authURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: handoff.journalURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: piStore.lockURL.path))
    }

    func testPiLockNeverDeletesAnExistingLock() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("llm-usage-pi-lock-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let authURL = root.appendingPathComponent("pi/agent/auth.json")
        let store = PiAuthStore(authURL: authURL)
        _ = try store.readRawDocument()
        try FileManager.default.createDirectory(at: store.lockURL, withIntermediateDirectories: false, attributes: nil)
        try AppOwnedPathSafety.ensureDirectory(at: store.lockURL, permissions: 0o700)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 0)], ofItemAtPath: store.lockURL.path)

        XCTAssertThrowsError(try store.readRawDocument()) { error in
            guard case .piAuthBusy = error as? PiCodexCredentialHandoffError else {
                return XCTFail("Unexpected lock error: \(error)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.lockURL.path))
    }

    func testCommittedActivationRecoveryUsesChatGPTIdentityNotProfileUUID() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("llm-usage-pi-recovery-activation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let profileID = UUID()
        let chatGPTAccountID = "chatgpt-target"
        let store = ManagedCodexHomeStore(root: root.appendingPathComponent("managed", isDirectory: true))
        let piStore = PiAuthStore(authURL: root.appendingPathComponent("pi/agent/auth.json"))
        let journalRoot = root.appendingPathComponent("journal", isDirectory: true)
        let handoff = PiCodexCredentialHandoff(managedHomeStore: store, piAuthStore: piStore, journalRoot: journalRoot)
        let home = try store.prepareAccountHome(for: profileID)
        let nativeData = Data(Self.validNativeAuth("target", accountID: chatGPTAccountID).utf8)
        let staging = home.appendingPathComponent(".pi-handoff-auth-fault", isDirectory: false)
        try nativeData.write(to: staging)
        try AppOwnedPathSafety.hardenRegularFile(at: staging, permissions: 0o600)

        _ = try piStore.readRawDocument()
        let preData = Data(#"{"other-provider":{"key":"env:OTHER_KEY"}}"#.utf8)
        let postObject: [String: Any] = [
            "openai-codex": [
                "type": "oauth", "access": "target", "refresh": "refresh",
                "expires": 4_000_000_000, "accountId": chatGPTAccountID,
            ],
            "other-provider": ["key": "env:OTHER_KEY"],
        ]
        let postData = try JSONSerialization.data(withJSONObject: postObject, options: [.prettyPrinted, .sortedKeys])
        try preData.write(to: piStore.authURL)
        try AppOwnedPathSafety.hardenRegularFile(at: piStore.authURL, permissions: 0o600)
        try Self.writeProtected(preData, at: journalRoot.appendingPathComponent("pi.bak"))
        try Self.writeProtected(postData, at: journalRoot.appendingPathComponent("post.bak"))

        var config = AppConfig.default
        config.codexManagedAccounts = [CodexManagedAccountProfile(
            id: profileID, label: "Target", accountID: chatGPTAccountID)]
        config.codexPiHandoffAccountID = profileID
        let journal: [String: Any] = [
            "operation": "activate", "phase": "committed",
            "targetProfileID": profileID.uuidString, "committedProfileID": profileID.uuidString,
            "targetChatGPTAccountID": chatGPTAccountID,
            "targetCredentialHash": Self.sha256(nativeData), "piPreimageHash": Self.sha256(preData),
            "stagingPath": staging.path,
            "piBackupPath": journalRoot.appendingPathComponent("pi.bak").path,
            "postPiPath": journalRoot.appendingPathComponent("post.bak").path,
            "postPiHash": Self.sha256(postData), "piExisted": true,
        ]
        try Self.writeJournal(journal, at: handoff.journalURL)
        try postData.write(to: piStore.authURL)
        try AppOwnedPathSafety.hardenRegularFile(at: piStore.authURL, permissions: 0o600)

        try handoff.recoverIfNeeded(config: config)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: handoff.journalURL.path))
    }

    func testRollbackRecoveryLeavesJournalWhenPiBackupIsMissing() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("llm-usage-pi-recovery-missing-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let profileID = UUID()
        let accountID = "chatgpt-target"
        let store = ManagedCodexHomeStore(root: root.appendingPathComponent("managed", isDirectory: true))
        let home = try store.prepareAccountHome(for: profileID)
        let nativeData = Data(Self.validNativeAuth("target", accountID: accountID).utf8)
        let staging = home.appendingPathComponent(".pi-handoff-auth-fault", isDirectory: false)
        try nativeData.write(to: staging)
        try AppOwnedPathSafety.hardenRegularFile(at: staging, permissions: 0o600)
        let piStore = PiAuthStore(authURL: root.appendingPathComponent("pi/agent/auth.json"))
        _ = try piStore.readRawDocument()
        let journalRoot = root.appendingPathComponent("journal", isDirectory: true)
        let handoff = PiCodexCredentialHandoff(
            managedHomeStore: store,
            piAuthStore: piStore,
            journalRoot: journalRoot)
        let preData = try piStore.readRawDocument()
        let missingBackup = journalRoot.appendingPathComponent("missing-pi.bak")
        var config = AppConfig.default
        config.codexManagedAccounts = [CodexManagedAccountProfile(id: profileID, label: "Target", accountID: accountID)]
        let journal: [String: Any] = [
            "operation": "activate", "phase": "target-staged",
            "targetProfileID": profileID.uuidString, "committedProfileID": profileID.uuidString,
            "targetChatGPTAccountID": accountID,
            "targetCredentialHash": Self.sha256(nativeData), "piPreimageHash": Self.sha256(preData),
            "stagingPath": staging.path, "piBackupPath": missingBackup.path,
            "piExisted": true,
        ]
        try Self.writeJournal(journal, at: handoff.journalURL)

        XCTAssertThrowsError(try handoff.recoverIfNeeded(config: config)) { error in
            guard case .recoveryRequired = error as? PiCodexCredentialHandoffError else {
                return XCTFail("Unexpected recovery error: \(error)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: handoff.journalURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: staging.path))
    }

    func testJournalIsRemovedBeforeNonessentialBackupCleanup() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("llm-usage-pi-cleanup-order-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let profileID = UUID()
        let accountID = "chatgpt-cleanup"
        let store = ManagedCodexHomeStore(root: root.appendingPathComponent("managed", isDirectory: true))
        let home = try store.prepareAccountHome(for: profileID)
        let piStore = PiAuthStore(authURL: root.appendingPathComponent("pi/agent/auth.json"))
        _ = try piStore.readRawDocument()
        let journalRoot = root.appendingPathComponent("journal", isDirectory: true)
        try FileManager.default.createDirectory(at: journalRoot, withIntermediateDirectories: true)

        let postObject: [String: Any] = [
            "openai-codex": [
                "type": "oauth", "access": "cleanup-access", "refresh": "cleanup-refresh",
                "expires": 4_000_000_000, "accountId": accountID,
            ],
        ]
        let postData = try JSONSerialization.data(withJSONObject: postObject, options: [.prettyPrinted, .sortedKeys])
        try postData.write(to: piStore.authURL)
        try AppOwnedPathSafety.hardenRegularFile(at: piStore.authURL, permissions: 0o600)
        let postBackup = journalRoot.appendingPathComponent("post.bak")
        try Self.writeProtected(postData, at: postBackup)
        let badPiBackup = journalRoot.appendingPathComponent("pi.bak", isDirectory: true)
        try FileManager.default.createDirectory(at: badPiBackup, withIntermediateDirectories: false)
        try AppOwnedPathSafety.ensureDirectory(at: badPiBackup, permissions: 0o700)

        let preData = Data(#"{"other-provider":{"key":"env:OTHER_KEY"}}"#.utf8)
        let nativeData = Self.nativeData(access: "cleanup-access", refresh: "cleanup-refresh", accountID: accountID)
        var config = AppConfig.default
        config.codexManagedAccounts = [CodexManagedAccountProfile(
            id: profileID, label: "Cleanup", accountID: accountID)]
        config.codexPiHandoffAccountID = profileID
        let handoff = PiCodexCredentialHandoff(
            managedHomeStore: store,
            piAuthStore: piStore,
            journalRoot: journalRoot)
        let staging = home.appendingPathComponent(".pi-handoff-auth-cleanup")
        let journal: [String: Any] = [
            "operation": "activate", "phase": "committed",
            "targetProfileID": profileID.uuidString, "committedProfileID": profileID.uuidString,
            "targetChatGPTAccountID": accountID,
            "targetCredentialHash": Self.sha256(nativeData), "piPreimageHash": Self.sha256(preData),
            "stagingPath": staging.path, "piBackupPath": badPiBackup.path,
            "postPiPath": postBackup.path, "postPiHash": Self.sha256(postData), "piExisted": true,
        ]
        try Self.writeJournal(journal, at: handoff.journalURL)

        XCTAssertThrowsError(try handoff.recoverIfNeeded(config: config)) { error in
            guard case .cleanupFailed = error as? PiCodexCredentialHandoffError else {
                return XCTFail("Unexpected cleanup error: \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: handoff.journalURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: postBackup.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: badPiBackup.path))
    }

    func testCommittedDeactivationDoesNotDeleteNewPiLogin() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("llm-usage-pi-recovery-deactivation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let profileID = UUID()
        let accountID = "chatgpt-active"
        let store = ManagedCodexHomeStore(root: root.appendingPathComponent("managed", isDirectory: true))
        let home = try store.prepareAccountHome(for: profileID)
        let authURL = home.appendingPathComponent("auth.json")
        let nativeData = Self.nativeData(access: "active", refresh: "refresh", accountID: accountID)
        try nativeData.write(to: authURL)
        try store.secureAuthFile(for: profileID, requireExisting: true)
        let piStore = PiAuthStore(authURL: root.appendingPathComponent("pi/agent/auth.json"))
        _ = try piStore.readRawDocument()
        let preObject: [String: Any] = [
            "openai-codex": [
                "type": "oauth", "access": "active", "refresh": "refresh",
                "expires": 4_000_000_000, "accountId": accountID,
            ],
        ]
        let preData = try JSONSerialization.data(withJSONObject: preObject, options: [.prettyPrinted, .sortedKeys])
        let postData = Data(#"{"other-provider":{"key":"env:OTHER_KEY"}}"#.utf8)
        try preData.write(to: piStore.authURL)
        try AppOwnedPathSafety.hardenRegularFile(at: piStore.authURL, permissions: 0o600)
        let journalRoot = root.appendingPathComponent("journal", isDirectory: true)
        let handoff = PiCodexCredentialHandoff(
            managedHomeStore: store,
            piAuthStore: piStore,
            journalRoot: journalRoot)
        try Self.writeProtected(preData, at: journalRoot.appendingPathComponent("pi.bak"))
        try Self.writeProtected(postData, at: journalRoot.appendingPathComponent("post.bak"))
        try Self.writeProtected(nativeData, at: journalRoot.appendingPathComponent("old.bak"))

        var config = AppConfig.default
        config.codexManagedAccounts = [CodexManagedAccountProfile(id: profileID, label: "Active", accountID: accountID)]
        let journal: [String: Any] = [
            "operation": "deactivate", "phase": "committed",
            "targetProfileID": profileID.uuidString, "previousProfileID": profileID.uuidString,
            "targetChatGPTAccountID": accountID, "previousChatGPTAccountID": accountID,
            "targetCredentialHash": Self.sha256(nativeData), "previousCredentialHash": Self.sha256(nativeData),
            "oldAuthPath": authURL.path, "oldAuthBackupPath": journalRoot.appendingPathComponent("old.bak").path,
            "piBackupPath": journalRoot.appendingPathComponent("pi.bak").path,
            "piPreimageHash": Self.sha256(preData), "postPiPath": journalRoot.appendingPathComponent("post.bak").path,
            "postPiHash": Self.sha256(postData), "piExisted": true,
        ]
        try Self.writeJournal(journal, at: handoff.journalURL)

        let newPiObject: [String: Any] = [
            "openai-codex": [
                "type": "oauth", "access": "new-login", "refresh": "new-refresh",
                "expires": 4_000_000_000, "accountId": accountID,
            ],
        ]
        let newPiData = try JSONSerialization.data(withJSONObject: newPiObject, options: [.prettyPrinted, .sortedKeys])
        try newPiData.write(to: piStore.authURL)
        try AppOwnedPathSafety.hardenRegularFile(at: piStore.authURL, permissions: 0o600)

        XCTAssertThrowsError(try handoff.recoverIfNeeded(config: config)) { error in
            guard case .recoveryRequired = error as? PiCodexCredentialHandoffError else {
                return XCTFail("Unexpected recovery error: \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: piStore.authURL), newPiData)
        XCTAssertTrue(FileManager.default.fileExists(atPath: handoff.journalURL.path))
    }

    func testProcessDescendantTraversalIsDeterministicAndDeepestFirst() {
        let graph: [pid_t: [pid_t]] = [
            100: [103, 102, 100, -1],
            102: [104],
            103: [105, 104],
            104: [106],
            105: [106],
            106: [100],
        ]
        let ordered = ProcessTreeTermination.orderedDescendants(of: 100) { graph[$0] ?? [] }
        XCTAssertEqual(ordered, [106, 104, 105, 102, 103])
        XCTAssertEqual(
            ProcessTreeTermination.descendants(of: 100) { graph[$0] ?? [] },
            Set([102, 103, 104, 105, 106]))
    }

    private enum InjectedRemovalFailure: Error {
        case finalization
    }

    private static func config(with accountID: UUID) -> AppConfig {
        var config = AppConfig.default
        config.codexManagedAccounts = [CodexManagedAccountProfile(id: accountID, label: "Work")]
        config.codexPrimaryAccountID = accountID
        return config
    }

    private static func validNativeAuth(_ token: String, accountID: String = "account") -> String {
        "{\"OPENAI_API_KEY\":null,\"tokens\":{\"access_token\":\"\(token)\",\"refresh_token\":\"refresh\",\"account_id\":\"\(accountID)\"}}"
    }

    private static func nativeData(access: String, refresh: String, accountID: String) -> Data {
        let object: [String: Any] = [
            "OPENAI_API_KEY": NSNull(),
            "tokens": ["access_token": access, "refresh_token": refresh, "account_id": accountID],
        ]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func writeProtected(_ data: Data, at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil)
        try data.write(to: url)
        try AppOwnedPathSafety.hardenRegularFile(at: url, permissions: 0o600)
    }

    private static func writeJournal(_ object: [String: Any], at url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try self.writeProtected(data, at: url)
    }

    private func permissions(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }
}

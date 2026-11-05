import Foundation
import XCTest
@testable import LLMUsageBar

final class PiCodexCredentialHandoffTests: XCTestCase {
    func testAdoptsMatchingUnmanagedPiCredentialWithoutChangingCredentialBytes() throws {
        let fixture = try Fixture(piAccountID: "chatgpt-account", profileAccountID: "chatgpt-account")
        defer { fixture.cleanUp() }
        let originalPi = try Data(contentsOf: fixture.piAuth)
        let saved = SavedConfigBox()

        let result = try fixture.handoff.activate(
            accountID: fixture.profile.id,
            config: fixture.config,
            saveConfig: { saved.value = $0; return true })

        XCTAssertEqual(result.config.codexPiHandoffAccountID, fixture.profile.id)
        XCTAssertEqual(result.config.codexPrimaryAccountID, fixture.profile.id)
        XCTAssertEqual(result.config.codexManagedAccounts.first?.accountID, "chatgpt-account")
        XCTAssertEqual(saved.value, result.config)
        XCTAssertEqual(try Data(contentsOf: fixture.piAuth), originalPi)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.nativeAuth.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.handoff.journalURL.path))
    }

    func testAdoptionSaveFailureLeavesPiAndNativeCredentialsUntouched() throws {
        let fixture = try Fixture(piAccountID: "chatgpt-account", profileAccountID: "chatgpt-account")
        defer { fixture.cleanUp() }
        let originalPi = try Data(contentsOf: fixture.piAuth)

        XCTAssertThrowsError(try fixture.handoff.activate(
            accountID: fixture.profile.id,
            config: fixture.config,
            saveConfig: { _ in false })) { error in
                XCTAssertEqual(error as? PiCodexCredentialHandoffError, .configSaveFailed)
            }
        XCTAssertEqual(try Data(contentsOf: fixture.piAuth), originalPi)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.nativeAuth.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.handoff.journalURL.path))
    }

    func testRejectsMismatchedOrUnidentifiedPiCredentialAndMissingProfileIdentity() throws {
        for (piID, profileID) in [("another-account", "expected-account"), ("chatgpt-account", nil)] {
            let fixture = try Fixture(piAccountID: piID, profileAccountID: profileID)
            defer { fixture.cleanUp() }
            let originalPi = try Data(contentsOf: fixture.piAuth)
            XCTAssertThrowsError(try fixture.handoff.activate(
                accountID: fixture.profile.id,
                config: fixture.config,
                saveConfig: { _ in XCTFail("Must not save rejected adoption"); return true }))
            XCTAssertEqual(try Data(contentsOf: fixture.piAuth), originalPi)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.nativeAuth.path))
        }
    }

    func testRejectsPiOAuthWithoutAccountIdentity() throws {
        let fixture = try Fixture(piAccountID: "chatgpt-account", profileAccountID: "chatgpt-account")
        defer { fixture.cleanUp() }
        let piDocument: [String: Any] = ["openai-codex": [
            "type": "oauth", "access": "access-token", "refresh": "refresh-token", "expires": 4_000_000_000,
        ]]
        let bytes = try JSONSerialization.data(withJSONObject: piDocument, options: [.sortedKeys])
        try bytes.write(to: fixture.piAuth)
        try AppOwnedPathSafety.hardenRegularFile(at: fixture.piAuth, permissions: 0o600)

        XCTAssertThrowsError(try fixture.handoff.activate(
            accountID: fixture.profile.id,
            config: fixture.config,
            saveConfig: { _ in XCTFail("Must not save unidentified adoption"); return true })) { error in
                guard case .invalidPiCredential = error as? PiCodexCredentialHandoffError else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
        XCTAssertEqual(try Data(contentsOf: fixture.piAuth), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.nativeAuth.path))
    }

    func testRejectsMalformedPiAuthWithoutChangingIt() throws {
        let fixture = try Fixture(piAccountID: "chatgpt-account", profileAccountID: "chatgpt-account")
        defer { fixture.cleanUp() }
        let malformed = Data("not-json".utf8)
        try malformed.write(to: fixture.piAuth)
        try AppOwnedPathSafety.hardenRegularFile(at: fixture.piAuth, permissions: 0o600)

        XCTAssertThrowsError(try fixture.handoff.activate(
            accountID: fixture.profile.id,
            config: fixture.config,
            saveConfig: { _ in XCTFail("Must not save malformed adoption"); return true }))
        XCTAssertEqual(try Data(contentsOf: fixture.piAuth), malformed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.nativeAuth.path))
    }

    func testRejectsMissingPiCredentialWithoutCreatingAuthFile() throws {
        let fixture = try Fixture(piAccountID: nil, profileAccountID: "chatgpt-account")
        defer { fixture.cleanUp() }

        XCTAssertThrowsError(try fixture.handoff.activate(
            accountID: fixture.profile.id,
            config: fixture.config,
            saveConfig: { _ in XCTFail("Must not save without Pi OAuth"); return true })) { error in
                XCTAssertEqual(error as? PiCodexCredentialHandoffError, .piCredentialMissing)
            }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.piAuth.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.nativeAuth.path))
    }

    func testPreviousHandoffCannotSwitchToTargetWithMissingNativeCredential() throws {
        let fixture = try Fixture(piAccountID: "chatgpt-old", profileAccountID: "chatgpt-target")
        defer { fixture.cleanUp() }
        let oldID = UUID()
        var config = fixture.config
        config.codexManagedAccounts.append(CodexManagedAccountProfile(
            id: oldID, label: "Old", accountID: "chatgpt-old"))
        config.codexPiHandoffAccountID = oldID
        let originalPi = try Data(contentsOf: fixture.piAuth)

        XCTAssertThrowsError(try fixture.handoff.activate(
            accountID: fixture.profile.id,
            config: config,
            saveConfig: { _ in XCTFail("Must not save an invalid switch"); return true })) { error in
                guard case .managedCredentialMissing = error as? PiCodexCredentialHandoffError else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
        XCTAssertEqual(try Data(contentsOf: fixture.piAuth), originalPi)
    }

    private final class SavedConfigBox: @unchecked Sendable {
        var value: AppConfig?
    }

    private struct Fixture {
        let root: URL
        let profile: CodexManagedAccountProfile
        let config: AppConfig
        let piAuth: URL
        let nativeAuth: URL
        let handoff: PiCodexCredentialHandoff

        init(piAccountID: String?, profileAccountID: String?) throws {
            self.root = FileManager.default.temporaryDirectory
                .appendingPathComponent("pi-codex-adoption-\(UUID().uuidString)", isDirectory: true)
            let accountID = UUID()
            self.profile = CodexManagedAccountProfile(id: accountID, label: "Work", accountID: profileAccountID)
            var config = AppConfig.default
            config.codexManagedAccounts = [self.profile]
            self.config = config
            let homes = ManagedCodexHomeStore(root: self.root.appendingPathComponent("managed", isDirectory: true))
            self.nativeAuth = homes.homeURL(for: accountID).appendingPathComponent("auth.json")
            _ = try homes.prepareAccountHome(for: accountID)
            self.piAuth = self.root.appendingPathComponent("pi/agent/auth.json")
            let piStore = PiAuthStore(authURL: self.piAuth)
            if let piAccountID {
                let document: [String: Any] = ["openai-codex": [
                    "type": "oauth",
                    "access": "access-token",
                    "refresh": "refresh-token",
                    "expires": 4_000_000_000,
                    "accountId": piAccountID,
                ]]
                let bytes = try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
                try FileManager.default.createDirectory(at: self.piAuth.deletingLastPathComponent(), withIntermediateDirectories: true)
                try bytes.write(to: self.piAuth)
                try AppOwnedPathSafety.hardenRegularFile(at: self.piAuth, permissions: 0o600)
            }
            self.handoff = PiCodexCredentialHandoff(
                managedHomeStore: homes,
                piAuthStore: piStore,
                journalRoot: self.root.appendingPathComponent("journal", isDirectory: true))
        }

        func cleanUp() { try? FileManager.default.removeItem(at: self.root) }
    }
}

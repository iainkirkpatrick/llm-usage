import Foundation
import XCTest
@testable import LLMUsageBar

final class CodexUsageRoutingTests: XCTestCase {
    private let a = CodexManagedAccountProfile(label: "A", accountID: "account-a")
    private let b = CodexManagedAccountProfile(label: "B", accountID: "account-b")

    func testExternalSwitchRoutesKnownAccountWithoutChangingOwnershipOrPrimary() {
        let observed = PiCodexUsageObservation(accountID: "account-b", error: nil)
        let profiles = [a, b]
        XCTAssertEqual(observed.matchingProfile(in: profiles), b.id)
        XCTAssertEqual(observed.source(for: b, profiles: profiles, recordedHandoff: a.id), .pi)
        if case .unavailable = observed.source(for: a, profiles: profiles, recordedHandoff: a.id) {} else { XCTFail("Displaced account must require recovery") }
        XCTAssertTrue(observed.handoffIsOutOfSync(profiles: profiles, recordedHandoff: a.id))
    }

    func testExecutionTimeObservationNeverPermitsUnownedPiResetSpending() {
        let profiles = [a, b]
        // This is the fresh observation at execution, even if preflight saw a native B.
        let switched = PiCodexUsageObservation(accountID: "account-b", error: nil)
        XCTAssertEqual(switched.source(for: b, profiles: profiles, recordedHandoff: nil), .pi)
        if case .unavailable = switched.spendingSource(for: b, profiles: profiles, recordedHandoff: nil) {} else { XCTFail("Read-only discovery must not authorize spending") }
        for profile in profiles {
            if case .unavailable = switched.spendingSource(for: profile, profiles: profiles, recordedHandoff: a.id) {} else { XCTFail("Drift must block spending") }
        }
        XCTAssertEqual(switched.spendingSource(for: b, profiles: profiles, recordedHandoff: b.id), .pi)
        XCTAssertEqual(switched.spendingSource(for: a, profiles: profiles, recordedHandoff: b.id), .native)
    }

    func testUnknownMissingAndInvalidPiIdentityFailClosedWithoutHidingIndependentNativeHomes() {
        let profiles = [a, b]
        for identity in [nil, "unknown-account"] as [String?] {
            let observed = PiCodexUsageObservation(accountID: identity, error: nil)
            XCTAssertNil(observed.matchingProfile(in: profiles))
            XCTAssertEqual(observed.source(for: b, profiles: profiles, recordedHandoff: a.id), .native)
            if case .unavailable = observed.source(for: a, profiles: profiles, recordedHandoff: a.id) {} else { XCTFail() }
        }
        let failed = PiCodexUsageObservation(accountID: nil, error: "invalid auth")
        for profile in profiles {
            if case .unavailable = failed.source(for: profile, profiles: profiles, recordedHandoff: a.id) {} else { XCTFail("Cannot rule out native duplicate") }
        }
    }

    func testDuplicateIdentityIsNotAttributedToEitherProfile() {
        let duplicate = CodexManagedAccountProfile(label: "Duplicate", accountID: b.accountID)
        let profiles = [a, b, duplicate]
        let observed = PiCodexUsageObservation(accountID: b.accountID, error: nil)
        XCTAssertNil(observed.matchingProfile(in: profiles))
        for profile in [b, duplicate] {
            if case .unavailable = observed.source(for: profile, profiles: profiles, recordedHandoff: nil) {} else { XCTFail() }
        }
    }

    func testClearStaleAssociationChangesOnlyMetadataAndPreservesCredentials() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let piBefore = try fixture.writePi(account: "account-b")
        let native = fixture.root.appendingPathComponent("native-sentinel")
        try Data("untouched native bytes".utf8).write(to: native)
        var config = AppConfig.default
        config.codexManagedAccounts = [a, b]
        config.codexPrimaryAccountID = a.id
        config.codexPiHandoffAccountID = a.id
        let result = try fixture.handoff.forgetStaleHandoff(config: config, saveConfig: { $0.codexPiHandoffAccountID == nil })
        XCTAssertNil(result.codexPiHandoffAccountID)
        XCTAssertEqual(result.codexPrimaryAccountID, a.id)
        XCTAssertEqual(result.codexManagedAccounts, config.codexManagedAccounts)
        XCTAssertEqual(try Data(contentsOf: fixture.piURL), piBefore)
        XCTAssertEqual(try Data(contentsOf: native), Data("untouched native bytes".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.handoff.journalURL.path))
    }

    func testClearStaleAssociationRejectsHealthyHandoffPendingJournalAndSaveFailure() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var config = AppConfig.default
        config.codexManagedAccounts = [a, b]
        config.codexPiHandoffAccountID = a.id
        let healthy = try fixture.writePi(account: "account-a")
        XCTAssertThrowsError(try fixture.handoff.forgetStaleHandoff(config: config, saveConfig: { _ in true }))
        XCTAssertEqual(try Data(contentsOf: fixture.piURL), healthy)
        let switched = try fixture.writePi(account: "account-b")
        XCTAssertThrowsError(try fixture.handoff.forgetStaleHandoff(config: config, saveConfig: { _ in false }))
        XCTAssertEqual(try Data(contentsOf: fixture.piURL), switched)
        try Data("journal sentinel".utf8).write(to: fixture.handoff.journalURL)
        XCTAssertThrowsError(try fixture.handoff.forgetStaleHandoff(config: config, saveConfig: { _ in true }))
        XCTAssertEqual(try Data(contentsOf: fixture.handoff.journalURL), Data("journal sentinel".utf8))
    }

    func testAbsentPiInspectionAndMetadataRecoveryDoNotCreateAuthFile() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        XCTAssertNil(try PiAuthStore(authURL: fixture.piURL).currentOAuthAccountID())
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.piURL.deletingLastPathComponent().path))
        var config = AppConfig.default
        config.codexManagedAccounts = [a]
        config.codexPiHandoffAccountID = a.id
        let result = try fixture.handoff.forgetStaleHandoff(config: config, saveConfig: { _ in true })
        XCTAssertNil(result.codexPiHandoffAccountID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.piURL.path))
    }

    private struct Fixture {
        let root: URL
        let piURL: URL
        let handoff: PiCodexCredentialHandoff
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            piURL = root.appendingPathComponent("pi/auth.json")
            handoff = PiCodexCredentialHandoff(managedHomeStore: ManagedCodexHomeStore(root: root.appendingPathComponent("homes")), piAuthStore: PiAuthStore(authURL: piURL), journalRoot: root)
        }
        func writePi(account: String) throws -> Data {
            let data = try JSONSerialization.data(withJSONObject: ["openai-codex": ["type": "oauth", "access": "fixture-access", "refresh": "fixture-refresh", "expires": Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000, "accountId": account], "unrelated": ["type": "api_key", "key": "fixture"]])
            try FileManager.default.createDirectory(at: piURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: piURL)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: piURL.path)
            return data
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}

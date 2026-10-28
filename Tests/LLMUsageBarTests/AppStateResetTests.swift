import Foundation
import XCTest
@testable import LLMUsageBar

@MainActor
final class AppStateResetTests: XCTestCase {
    func testExternalPiLoginAfterPreflightDoesNotCreatePendingReset() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let fetcher = StubCodexFetcher(onNativeFetch: { count in
            // The initial refresh sees a native account. Pi changes while the execution-time
            // usage request is awaiting a response, after the menu enabled the reset action.
            if count == 2 { try fixture.writePi() }
        })
        let state = fixture.state(fetcher: fetcher)
        await state.refresh(onStart: {})
        XCTAssertTrue(state.canRedeemCodexReset(accountID: fixture.accountKey, creditID: "reset-1"))

        do {
            _ = try await state.consumeCodexResetCredit(accountID: fixture.accountKey, creditID: "reset-1")
            XCTFail("An observed but unowned Pi login cannot spend resets")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Manage this active Pi account"))
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.pendingURL.path))
        let calls = await fetcher.consumptions
        XCTAssertTrue(calls.isEmpty)

        // Recovery must not leave an in-memory pending attempt blocking a different credit.
        try FileManager.default.removeItem(at: fixture.piURL)
        await state.refresh(onStart: {})
        XCTAssertTrue(state.canRedeemCodexReset(accountID: fixture.accountKey, creditID: "reset-2"))
    }

    func testLocalOwnershipRejectionPreservesAnExistingUnknownAttempt() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let pending = try fixture.writePending(key: "original-key")
        let fetcher = StubCodexFetcher(onNativeFetch: { count in
            if count == 2 { try fixture.writePi() }
        })
        let state = fixture.state(fetcher: fetcher)
        await state.refresh(onStart: {})

        do {
            _ = try await state.consumeCodexResetCredit(accountID: fixture.accountKey, creditID: "reset-1")
            XCTFail("Must reject unowned Pi spending")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Manage this active Pi account"))
        }

        XCTAssertEqual(try Data(contentsOf: fixture.pendingURL), pending)
        let calls = await fetcher.consumptions
        XCTAssertTrue(calls.isEmpty)
        try FileManager.default.removeItem(at: fixture.piURL)
        await state.refresh(onStart: {})
        XCTAssertTrue(state.canRedeemCodexReset(accountID: fixture.accountKey, creditID: "reset-1"))
        XCTAssertFalse(state.canRedeemCodexReset(accountID: fixture.accountKey, creditID: "reset-2"))
    }

    func testDispatchedFailureRemainsDurableAndRetryReusesKeyAfterRestart() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let fetcher = StubCodexFetcher(failFirstConsumption: true, onConsume: { key in
            let pending = try fixture.pendingDocument()
            XCTAssertEqual(pending["accountID"], fixture.accountKey)
            XCTAssertEqual(pending["creditID"], "reset-1")
            XCTAssertEqual(pending["idempotencyKey"], key, "Persist before dispatch")
        })
        let state = fixture.state(fetcher: fetcher)
        await state.refresh(onStart: {})
        do {
            _ = try await state.consumeCodexResetCredit(accountID: fixture.accountKey, creditID: "reset-1")
            XCTFail("Injected timeout should retain the unknown result")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("timed out"))
        }
        let pending = try fixture.pendingDocument()
        let key = try XCTUnwrap(pending["idempotencyKey"])
        XCTAssertFalse(state.canRedeemCodexReset(accountID: fixture.accountKey, creditID: "reset-2"))

        let restarted = fixture.state(fetcher: fetcher)
        await restarted.refresh(onStart: {})
        XCTAssertFalse(restarted.canRedeemCodexReset(accountID: fixture.accountKey, creditID: "reset-2"))
        let result = try await restarted.consumeCodexResetCredit(accountID: fixture.accountKey, creditID: "reset-1")
        XCTAssertEqual(result.outcome, "consumed")
        XCTAssertNil(result.refreshError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.pendingURL.path))
        let calls = await fetcher.consumptions
        XCTAssertEqual(calls.map(\.key), [key, key])
        XCTAssertTrue(calls.allSatisfy { $0.expectedAccountID == "account-fixture" && $0.home == fixture.homeURL })
        XCTAssertTrue(restarted.canRedeemCodexReset(accountID: fixture.accountKey, creditID: "reset-2"))
    }

    func testLostSuccessfulResponseCanRetryWhenCreditIsNoLongerAvailable() async throws {
        for stateAfterLoss in StubCodexFetcher.CreditState.allCases {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let fetcher = StubCodexFetcher(failFirstConsumption: true, stateAfterLoss: stateAfterLoss)
            let state = fixture.state(fetcher: fetcher)
            await state.refresh(onStart: {})
            do {
                _ = try await state.consumeCodexResetCredit(accountID: fixture.accountKey, creditID: "reset-1")
                XCTFail("Injected response loss must remain pending")
            } catch {}
            let key = try XCTUnwrap(fixture.pendingDocument()["idempotencyKey"])

            let restarted = fixture.state(fetcher: fetcher)
            await restarted.refresh(onStart: {})
            XCTAssertEqual(restarted.pendingCodexResetCreditID(for: fixture.accountKey), "reset-1")
            XCTAssertTrue(restarted.canRedeemCodexReset(accountID: fixture.accountKey, creditID: "reset-1"))
            do {
                _ = try await restarted.consumeCodexResetCredit(accountID: fixture.accountKey, creditID: "reset-2")
                XCTFail("A different request must not replace the pending key")
            } catch {}
            _ = try await restarted.consumeCodexResetCredit(accountID: fixture.accountKey, creditID: "reset-1")
            let calls = await fetcher.consumptions
            XCTAssertEqual(calls.map(\.key), [key, key], "\(stateAfterLoss)")
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.pendingURL.path))
            XCTAssertNil(restarted.pendingCodexResetCreditID(for: fixture.accountKey))
        }
    }

    func testOwnedPiResetUsesPiAndClearsConfirmedAttempt() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.writePi()
        try FileManager.default.removeItem(at: fixture.homeURL.appendingPathComponent("auth.json"))
        let fetcher = StubCodexFetcher(onNativeFetch: { _ in XCTFail("Owned Pi credentials must not use a native copy") })
        let state = fixture.state(fetcher: fetcher, ownedByPi: true)
        await state.refresh(onStart: {})
        _ = try await state.consumeCodexResetCredit(accountID: fixture.accountKey, creditID: "reset-1")
        let calls = await fetcher.consumptions
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.expectedAccountID, "account-fixture")
        XCTAssertNil(calls.first?.home)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.pendingURL.path))
    }

    func testPersistenceFailureNeverDispatchesReset() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.pendingURL, withIntermediateDirectories: false)
        let fetcher = StubCodexFetcher()
        let state = fixture.state(fetcher: fetcher)
        await state.refresh(onStart: {})
        do {
            _ = try await state.consumeCodexResetCredit(accountID: fixture.accountKey, creditID: "reset-1")
            XCTFail("Unsafe pending path must prevent dispatch")
        } catch {}
        let calls = await fetcher.consumptions
        XCTAssertTrue(calls.isEmpty)
    }

    private struct Fixture: Sendable {
        let root: URL
        let piURL: URL
        let pendingURL: URL
        let profile: CodexManagedAccountProfile
        let handoff: PiCodexCredentialHandoff
        var accountKey: String { profile.id.uuidString }
        var homeURL: URL { handoff.managedHomeStore.homeURL(for: profile.id) }

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            piURL = root.appendingPathComponent("pi/auth.json")
            pendingURL = root.appendingPathComponent("pending-codex-reset.json")
            profile = CodexManagedAccountProfile(label: "Fixture", accountID: "account-fixture")
            let homes = ManagedCodexHomeStore(root: root.appendingPathComponent("homes"))
            handoff = PiCodexCredentialHandoff(managedHomeStore: homes, piAuthStore: PiAuthStore(authURL: piURL), journalRoot: root)
            let home = try homes.prepareAccountHome(for: profile.id)
            try Data(#"{"tokens":{"access_token":"fixture-access","refresh_token":"fixture-refresh","account_id":"account-fixture"}}"#.utf8)
                .write(to: home.appendingPathComponent("auth.json"))
            try homes.secureAuthFile(for: profile.id, requireExisting: true)
        }

        @MainActor
        func state(fetcher: StubCodexFetcher, ownedByPi: Bool = false) -> AppState {
            var config = AppConfig.default
            config.codexManagedAccounts = [profile]
            config.codexPrimaryAccountID = profile.id
            config.codexPiHandoffAccountID = ownedByPi ? profile.id : nil
            config.claudeEnabled = false
            config.openCodeEnabled = false
            config.piEnabled = false
            return AppState(config: config, codexFetcher: fetcher, piCodexHandoff: handoff,
                            pendingCodexResetURL: pendingURL, logInfo: { _ in }, logError: { _ in })
        }

        func writePi() throws {
            try FileManager.default.createDirectory(at: piURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: ["openai-codex": [
                "type": "oauth", "access": "fixture-access", "refresh": "fixture-refresh",
                "expires": Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000,
                "accountId": "account-fixture"
            ]])
            try data.write(to: piURL)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: piURL.path)
        }

        func writePending(key: String) throws -> Data {
            let data = try JSONSerialization.data(withJSONObject: ["accountID": accountKey, "creditID": "reset-1", "idempotencyKey": key])
            try data.write(to: pendingURL)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pendingURL.path)
            return data
        }

        func pendingDocument() throws -> [String: String] {
            try JSONDecoder().decode([String: String].self, from: Data(contentsOf: pendingURL))
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}

private actor StubCodexFetcher: CodexUsageFetching {
    enum CreditState: CaseIterable {
        case redeemed, expired, empty, missingDetails, removedWithOtherCredits
    }

    struct Consumption {
        let key: String
        let expectedAccountID: String
        let home: URL?
    }
    private let onNativeFetch: @Sendable (Int) throws -> Void
    private let onConsume: @Sendable (String) throws -> Void
    private let failFirstConsumption: Bool
    private let stateAfterLoss: CreditState?
    private var nativeFetchCount = 0
    private(set) var consumptions: [Consumption] = []

    init(
        failFirstConsumption: Bool = false,
        stateAfterLoss: CreditState? = nil,
        onNativeFetch: @escaping @Sendable (Int) throws -> Void = { _ in },
        onConsume: @escaping @Sendable (String) throws -> Void = { _ in })
    {
        self.failFirstConsumption = failFirstConsumption
        self.stateAfterLoss = stateAfterLoss
        self.onNativeFetch = onNativeFetch
        self.onConsume = onConsume
    }

    func fetchPiAuth(expectedAccountID: String) async throws -> CodexSnapshot {
        self.usage()
    }

    func fetchManaged(codexHome: URL) async throws -> CodexSnapshot {
        nativeFetchCount += 1
        try onNativeFetch(nativeFetchCount)
        return self.usage()
    }

    func consumeResetCredit(creditID: String, idempotencyKey: String, expectedChatGPTAccountID: String, codexHome: URL?) async throws -> String {
        try onConsume(idempotencyKey)
        consumptions.append(Consumption(key: idempotencyKey, expectedAccountID: expectedChatGPTAccountID, home: codexHome))
        if failFirstConsumption && consumptions.count == 1 { throw CodexNodeBridge.BridgeError.timedOut }
        return "consumed"
    }

    private func usage() -> CodexSnapshot {
        let state = consumptions.isEmpty ? nil : stateAfterLoss
        let ids: [String]
        switch state {
        case .empty, .missingDetails: ids = []
        case .removedWithOtherCredits: ids = ["reset-2"]
        default: ids = ["reset-1", "reset-2"]
        }
        let credits = ids.map { id in
            let status = id == "reset-1" && state == .redeemed ? "redeemed"
                : id == "reset-1" && state == .expired ? "expired" : "available"
            return CodexResetCredit(id: id, resetType: nil, status: status, grantedAt: nil, expiresAt: nil, title: nil, description: nil)
        }
        return CodexSnapshot(session: RateWindow(usedPercent: 90, resetAt: nil), weekly: nil, creditsRemaining: nil,
                             resetCredits: state == .missingDetails ? nil : CodexResetCredits(
                                availableCount: credits.filter { $0.status == "available" }.count, credits: credits),
                             sourceLabel: "Fixture", updatedAt: Date())
    }
}

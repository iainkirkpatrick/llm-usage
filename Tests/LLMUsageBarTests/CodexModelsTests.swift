import XCTest
@testable import LLMUsageBar

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

    private static func validNativeAuth(_ token: String) -> String {
        "{\"OPENAI_API_KEY\":null,\"tokens\":{\"access_token\":\"\(token)\",\"refresh_token\":\"refresh\",\"account_id\":\"account\"}}"
    }

    private func permissions(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }
}

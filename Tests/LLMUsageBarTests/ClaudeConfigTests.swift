import XCTest
@testable import LLMUsageBar

final class ClaudeConfigTests: XCTestCase {
    func testDefaultsEnableClaudeWithoutRegisteringDefaultProfile() {
        XCTAssertTrue(AppConfig.default.claudeEnabled)
        XCTAssertTrue(AppConfig.default.claudeAccounts.isEmpty)
    }

    func testOlderConfigDecodesClaudeDefaults() throws {
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(#"{"codexEnabled":true,"piEnabled":true}"#.utf8))
        XCTAssertTrue(config.claudeEnabled)
        XCTAssertTrue(config.claudeAccounts.isEmpty)
    }

    func testClaudeProfilesPersistMetadataOnly() throws {
        let profile = ClaudeAccountProfile(label: "Work", configDirectory: "/Users/example/.claude-work", email: "work@example.com")
        let data = try JSONEncoder().encode(AppConfig.default.withClaudeAccounts([profile]))
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(json.contains("work@example.com"))
        XCTAssertTrue(json.contains(".claude-work"))
        XCTAssertFalse(json.localizedCaseInsensitiveContains("token"))
        XCTAssertFalse(json.localizedCaseInsensitiveContains("credential"))
        XCTAssertFalse(json.localizedCaseInsensitiveContains("secret"))
    }
}

private extension AppConfig {
    func withClaudeAccounts(_ accounts: [ClaudeAccountProfile]) -> AppConfig {
        var copy = self
        copy.claudeAccounts = accounts
        return copy
    }
}

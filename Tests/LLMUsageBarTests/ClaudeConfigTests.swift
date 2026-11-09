import XCTest
@testable import LLMUsageBar

final class ClaudeConfigTests: XCTestCase {
    func testDefaultsEnableClaudeWithoutRegisteringDefaultProfile() {
        XCTAssertTrue(AppConfig.default.claudeEnabled)
        XCTAssertTrue(AppConfig.default.claudeAccounts.isEmpty)
        XCTAssertEqual(AppConfig.default.claudeUsageSource, .claudeCode)
        XCTAssertTrue(AppConfig.default.claudeAutoRefreshEnabled)
    }

    func testOlderConfigDecodesClaudeDefaults() throws {
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(#"{"codexEnabled":true,"piEnabled":true}"#.utf8))
        XCTAssertTrue(config.claudeEnabled)
        XCTAssertTrue(config.claudeAccounts.isEmpty)
        XCTAssertEqual(config.claudeUsageSource, .oauth)
        XCTAssertTrue(config.claudeAutoRefreshEnabled)
    }

    func testBackgroundRefreshSettingRoundTripsBothValues() throws {
        for enabled in [true, false] {
            var config = AppConfig.default
            config.claudeAutoRefreshEnabled = enabled
            XCTAssertEqual(try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(config)), config)
        }
    }

    func testUsageSourceRoundTripsAndPreservesBackgroundRefreshOptOut() throws {
        for source in ClaudeUsageSource.allCases {
            var config = AppConfig.default
            config.claudeUsageSource = source
            config.claudeAutoRefreshEnabled = false
            let decoded = try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(config))
            XCTAssertEqual(decoded.claudeUsageSource, source)
            XCTAssertFalse(decoded.claudeAutoRefreshEnabled)
        }
    }

    func testExplicitBackgroundRefreshOptOutIsPreserved() throws {
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(#"{"claudeAutoRefreshEnabled":false}"#.utf8))
        XCTAssertFalse(config.claudeAutoRefreshEnabled)
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

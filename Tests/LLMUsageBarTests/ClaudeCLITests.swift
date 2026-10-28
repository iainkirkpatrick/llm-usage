import XCTest
@testable import LLMUsageBar

final class ClaudeCLITests: XCTestCase {
    private func fixture(_ script: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("claude-fixture")
        try Data(("#!/bin/sh\n" + script + "\n").utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return executable
    }

    func testEnvironmentIsolationAndDefaultUnset() {
        let inherited = ["PATH": "/usr/bin:/bin", "HOME": "/fixture/home", "CLAUDE_CONFIG_DIR": "/wrong",
                         "ANTHROPIC_API_KEY": "fixture-secret", "ANTHROPIC_AUTH_TOKEN": "fixture-secret",
                         "CLAUDE_CODE_OAUTH_TOKEN": "fixture-secret", "CLAUDE_CODE_USE_BEDROCK": "1",
                         "AWS_PROFILE": "fixture", "GOOGLE_APPLICATION_CREDENTIALS": "/fixture/credentials",
                         "AZURE_API_KEY": "fixture-secret", "HTTPS_PROXY": "https://proxy.invalid", "NODE_OPTIONS": "--require fixture"]
        let result = ClaudeCLI.loginEnvironment(profile: .init(label: "Default"), inherited: inherited)
        XCTAssertEqual(result, ["PATH": "/usr/bin:/bin", "HOME": "/fixture/home"])
        let explicit = ClaudeCLI.loginEnvironment(profile: .init(label: "Custom", configDirectory: "/fixture/a/../b"), inherited: inherited)
        XCTAssertEqual(explicit["CLAUDE_CONFIG_DIR"], "/fixture/b")
    }

    func testExecutableOverrideMustBeAbsoluteAndExecutable() throws {
        let executable = try fixture("exit 0")
        XCTAssertEqual(ClaudeCLI.resolveExecutable(environment: ["LLM_BAR_CLAUDE_PATH": executable.path]), executable)
        XCTAssertNil(ClaudeCLI.resolveExecutable(environment: ["LLM_BAR_CLAUDE_PATH": "relative/claude"]))
        XCTAssertNil(ClaudeCLI.resolveExecutable(environment: ["LLM_BAR_CLAUDE_PATH": executable.deletingLastPathComponent().path]))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: executable.path)
        XCTAssertNil(ClaudeCLI.resolveExecutable(environment: ["LLM_BAR_CLAUDE_PATH": executable.path]))
    }

    func testNativeLoginArgumentsAndIsolatedEnvironment() async throws {
        let executable = try fixture(#"""
        [ "$#" = 3 ] || exit 1
        [ "$1" = auth ] || exit 2
        [ "$2" = login ] || exit 3
        [ "$3" = --claudeai ] || exit 4
        [ "$CLAUDE_CONFIG_DIR" = /fixture/isolated ] || exit 5
        [ -z "$ANTHROPIC_API_KEY" ] || exit 6
        [ -z "$CLAUDE_CODE_OAUTH_TOKEN" ] || exit 7
        exit 0
        """#)
        try await ClaudeCLI.login(profile: .init(label: "Fixture", configDirectory: "/fixture/isolated"), executable: executable,
                                  environment: ["PATH": "/usr/bin:/bin", "ANTHROPIC_API_KEY": "fixture", "CLAUDE_CODE_OAUTH_TOKEN": "fixture"], timeout: 5)
        let defaultExecutable = try fixture("[ -z \"${CLAUDE_CONFIG_DIR+x}\" ] || exit 1\nexit 0")
        try await ClaudeCLI.login(profile: .init(label: "Fixture"), executable: defaultExecutable,
                                  environment: ["CLAUDE_CONFIG_DIR": "/wrong"], timeout: 5)
    }

    func testFailureNeverIncludesCLIOutput() async throws {
        let executable = try fixture("printf 'SECRET_TOKEN AUTH_CODE https://example.invalid?code=secret' >&2\nexit 1")
        do {
            try await ClaudeCLI.login(profile: .init(label: "Fixture"), executable: executable, environment: [:], timeout: 5)
            XCTFail("Must fail")
        } catch {
            XCTAssertEqual(error as? ClaudeBackendError, .cliFailed)
            XCTAssertFalse(error.localizedDescription.contains("SECRET"))
            XCTAssertFalse(error.localizedDescription.contains("AUTH_CODE"))
        }
    }

    func testTimeoutTerminatesOwnedFixture() async throws {
        let executable = try fixture("/bin/sleep 30")
        let start = Date()
        do {
            try await ClaudeCLI.login(profile: .init(label: "Fixture"), executable: executable, environment: [:], timeout: 0.1)
            XCTFail("Must time out")
        } catch { XCTAssertEqual(error as? ClaudeBackendError, .loginTimedOut) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    func testCancellationTerminatesOwnedFixture() async throws {
        let executable = try fixture("/bin/sleep 30")
        let task = Task {
            try await ClaudeCLI.login(profile: .init(label: "Fixture"), executable: executable, environment: [:], timeout: 30)
        }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        do { try await task.value; XCTFail("Must cancel") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}

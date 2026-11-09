import Darwin
import XCTest
@testable import LLMUsageBar

final class ClaudeAuthRefreshCLITests: XCTestCase {
    private func fixture(_ script: String) throws -> (directory: URL, executable: URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("claude-fixture")
        try Data(("#!/bin/sh\n" + script + "\n").utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return (directory, executable)
    }

    private func waitForFile(_ url: URL) async throws {
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: url.path) { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Fixture did not start")
    }

    private func assertProcessGone(_ file: URL, file sourceFile: StaticString = #filePath, line: UInt = #line) throws {
        let text = try String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = try XCTUnwrap(Int32(text), file: sourceFile, line: line)
        for _ in 0..<100 {
            if kill(pid, 0) == -1 && errno == ESRCH { return }
            usleep(10_000)
        }
        XCTFail("Fixture process still exists", file: sourceFile, line: line)
    }

    func testPTYArgumentsEnvironmentIsolationAndPromptSuccess() async throws {
        let fixture = try fixture(#"""
        [ -t 0 ] && [ -t 1 ] && [ -t 2 ] || exit 1
        [ "$#" = 9 ] || exit 2
        [ "$1" = --allowed-tools ] && [ -z "$2" ] || exit 3
        [ "$3" = --tools ] && [ -z "$4" ] || exit 4
        [ "$5" = --strict-mcp-config ] && [ "$6" = --settings ] || exit 5
        [ "$7" = '{"disableAllHooks":true,"remoteControlAtStartup":false}' ] || exit 6
        [ "$8" = --no-chrome ] && [ "$9" = /status ] || exit 7
        [ "$CLAUDE_CONFIG_DIR" = /fixture/profile ] || exit 8
        [ -z "${ANTHROPIC_API_KEY+x}${CLAUDE_CODE_OAUTH_TOKEN+x}${AWS_PROFILE+x}${NODE_OPTIONS+x}${BASH_ENV+x}${ENV+x}${HTTPS_PROXY+x}" ] || exit 9
        case "$PWD" in */llm-usage-claude-refresh-*) ;; *) exit 10 ;; esac
        [ "$(/usr/bin/stat -f %Lp "$PWD")" = 700 ] || exit 11
        printf '%s' "$PWD" > "$FIXTURE_CWD"
        printf '%s' "$$" > "$FIXTURE_PID"
        : > "$FIXTURE_MARKER"
        while :; do /bin/sleep 1; done
        """#)
        let marker = fixture.directory.appendingPathComponent("refreshed")
        let cwd = fixture.directory.appendingPathComponent("cwd")
        let pid = fixture.directory.appendingPathComponent("pid")
        let start = Date()
        try await ClaudeAuthRefreshCLI.refresh(
            profile: .init(label: "Fixture", configDirectory: "/fixture/a/../profile"),
            executable: fixture.executable,
            environment: ["PATH": "/usr/bin:/bin", "CLAUDE_CONFIG_DIR": "/wrong",
                          "ANTHROPIC_API_KEY": "secret", "CLAUDE_CODE_OAUTH_TOKEN": "secret",
                          "AWS_PROFILE": "secret", "NODE_OPTIONS": "secret", "BASH_ENV": "/nonexistent",
                          "ENV": "/nonexistent", "HTTPS_PROXY": "secret", "FIXTURE_CWD": cwd.path,
                          "FIXTURE_PID": pid.path, "FIXTURE_MARKER": marker.path], timeout: 5,
            isRefreshed: { FileManager.default.fileExists(atPath: marker.path) })
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        try assertProcessGone(pid)
        let workspace = try String(contentsOf: cwd, encoding: .utf8)
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace))
    }

    func testDefaultProfileLeavesConfigUnsetAndZeroExitRequiresCredential() async throws {
        let fixture = try fixture(#"""
        [ -z "${CLAUDE_CONFIG_DIR+x}" ] || exit 1
        : > "$FIXTURE_MARKER"
        exit 0
        """#)
        let marker = fixture.directory.appendingPathComponent("refreshed")
        try await ClaudeAuthRefreshCLI.refresh(profile: .init(label: "Default"), executable: fixture.executable,
            environment: ["CLAUDE_CONFIG_DIR": "/wrong", "FIXTURE_MARKER": marker.path], timeout: 2,
            isRefreshed: { FileManager.default.fileExists(atPath: marker.path) })

        let empty = try self.fixture("exit 0")
        do {
            try await ClaudeAuthRefreshCLI.refresh(profile: .init(label: "Default"), executable: empty.executable,
                environment: [:], timeout: 2, isRefreshed: { false })
            XCTFail("Exit zero alone is not success")
        } catch { XCTAssertEqual(error as? ClaudeAuthRefreshCLIError, .failed) }
    }

    func testFailureRedactsTerminalOutput() async throws {
        let fixture = try fixture("printf 'SECRET_TOKEN https://secret.invalid?code=AUTH_CODE' >&2\nexit 42")
        do {
            try await ClaudeAuthRefreshCLI.refresh(profile: .init(label: "Fixture"), executable: fixture.executable,
                environment: [:], timeout: 2, isRefreshed: { false })
            XCTFail("Must fail")
        } catch {
            XCTAssertEqual(error as? ClaudeAuthRefreshCLIError, .failed)
            XCTAssertEqual(error.localizedDescription, "Claude Code did not refresh credentials.")
        }
    }

    func testContinuousOutputCannotStarveTimeout() async throws {
        let fixture = try fixture("while :; do printf 'SECRET noisy terminal output 0123456789\\r\\n'; done")
        let start = Date()
        do {
            try await ClaudeAuthRefreshCLI.refresh(profile: .init(label: "Fixture"), executable: fixture.executable,
                environment: [:], timeout: 0.15, isRefreshed: { false })
            XCTFail("Must time out")
        } catch { XCTAssertEqual(error as? ClaudeAuthRefreshCLIError, .timedOut) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }

    func testTrustBarrierKillsDescendantAndIsNeverAccepted() async throws {
        let fixture = try fixture(#"""
        /bin/sleep 30 &
        printf '%s' "$!" > "$FIXTURE_CHILD"
        printf '%s' "$$" > "$FIXTURE_PID"
        printf 'Do you trust the files in this folder? Press Enter to confirm'
        read answer
        : > "$FIXTURE_ACCEPTED"
        wait
        """#)
        let child = fixture.directory.appendingPathComponent("child")
        let pid = fixture.directory.appendingPathComponent("pid")
        let accepted = fixture.directory.appendingPathComponent("accepted")
        do {
            try await ClaudeAuthRefreshCLI.refresh(profile: .init(label: "Fixture"), executable: fixture.executable,
                environment: ["FIXTURE_CHILD": child.path, "FIXTURE_PID": pid.path, "FIXTURE_ACCEPTED": accepted.path],
                // Allow fixture startup under full-suite load; this test checks
                // the trust barrier and cleanup, not the short-timeout behavior.
                timeout: 2, isRefreshed: { false })
            XCTFail("Must stop at the trust barrier")
        } catch { XCTAssertEqual(error as? ClaudeAuthRefreshCLIError, .setupRequired) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: accepted.path))
        try assertProcessGone(child)
        try assertProcessGone(pid)
    }

    func testFirstRunSetupProducesActionableErrorWithoutAnsweringPrompts() async throws {
        let fixture = try fixture("printf '\\033[32mChoose the text style that looks best with your terminal\\033[0m'\nread answer")
        do {
            try await ClaudeAuthRefreshCLI.refresh(profile: .init(label: "Fixture"), executable: fixture.executable,
                environment: [:], timeout: 2, isRefreshed: { false })
            XCTFail("Must require interactive setup")
        } catch {
            XCTAssertEqual(error as? ClaudeAuthRefreshCLIError, .setupRequired)
            XCTAssertTrue(error.localizedDescription.contains("Copy refresh setup command"))
        }
    }

    func testCancellationKillsDescendant() async throws {
        let fixture = try fixture(#"""
        /bin/sleep 30 &
        printf '%s' "$!" > "$FIXTURE_CHILD"
        printf '%s' "$$" > "$FIXTURE_PID"
        wait
        """#)
        let child = fixture.directory.appendingPathComponent("child")
        let pid = fixture.directory.appendingPathComponent("pid")
        let task = Task {
            try await ClaudeAuthRefreshCLI.refresh(profile: .init(label: "Fixture"), executable: fixture.executable,
                environment: ["FIXTURE_CHILD": child.path, "FIXTURE_PID": pid.path], timeout: 30,
                isRefreshed: { false })
        }
        try await waitForFile(pid)
        task.cancel()
        do { try await task.value; XCTFail("Must cancel") }
        catch { XCTAssertTrue(error is CancellationError) }
        try assertProcessGone(child)
        try assertProcessGone(pid)
    }

    func testExitedWrapperDoesNotLeaveItsBackgroundChildRunning() async throws {
        let fixture = try fixture("/bin/sleep 30 &\nprintf '%s' \"$!\" > \"$FIXTURE_CHILD\"\nexit 0")
        let child = fixture.directory.appendingPathComponent("child")
        do {
            try await ClaudeAuthRefreshCLI.refresh(profile: .init(label: "Fixture"), executable: fixture.executable,
                environment: ["FIXTURE_CHILD": child.path], timeout: 2, isRefreshed: { false })
            XCTFail("A wrapper exit is not refresh success")
        } catch { XCTAssertEqual(error as? ClaudeAuthRefreshCLIError, .failed) }
        try assertProcessGone(child)
    }

    func testLaunchFailureIsSanitized() async throws {
        do {
            try await ClaudeAuthRefreshCLI.refresh(profile: .init(label: "Fixture"),
                executable: URL(fileURLWithPath: "/nonexistent/SECRET"), environment: [:], timeout: 1,
                isRefreshed: { false })
            XCTFail("Must fail to launch")
        } catch {
            XCTAssertEqual(error as? ClaudeAuthRefreshCLIError, .launchFailed)
            XCTAssertFalse(error.localizedDescription.contains("SECRET"))
        }
    }
}

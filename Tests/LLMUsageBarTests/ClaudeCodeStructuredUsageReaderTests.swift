import Foundation
import XCTest
@testable import LLMUsageBar

final class ClaudeCodeStructuredUsageReaderTests: XCTestCase {
    private let body = #"{"rate_limits_available":true,"rate_limits":{"five_hour":{"utilization":12.5,"resets_at":"2020-01-02T03:04:05Z"},"seven_day":{"utilization":88,"resets_at":null}}}"#

    private func parse(_ json: String) throws -> ClaudeCodeStructuredUsage {
        try ClaudeCodeStructuredUsageReader.parse(Data(json.utf8), capturedAt: Date(timeIntervalSince1970: 42))
    }

    func testLegacyBodyPreservesCaptureAndExpiredReset() throws {
        let value = try parse(body)
        XCTAssertEqual(value.session?.usedPercent, 12.5)
        XCTAssertEqual(value.weekly?.usedPercent, 88)
        XCTAssertNil(value.weekly?.resetAt)
        XCTAssertEqual(value.session?.resetAt, ClaudeUsageFetcher.date("2020-01-02T03:04:05Z"))
        XCTAssertEqual(value.capturedAt, Date(timeIntervalSince1970: 42))
    }

    func testModernFallbackAndLegacyPrecedence() throws {
        let value = try parse(#"{"rate_limits_available":true,"rate_limits":{"five_hour":{"utilization":0,"resets_at":null},"limits":[{"kind":"session","percent":45},{"kind":"weekly_all","percent":100,"resets_at":"2020-01-02T03:04:05.123Z"},{"kind":"weekly_scoped","percent":11}]}}"#)
        XCTAssertEqual(value.session?.usedPercent, 0)
        XCTAssertEqual(value.weekly?.usedPercent, 100)
        XCTAssertNotNil(value.weekly?.resetAt)
        let oauth = try parse(#"{"rate_limits_available":true,"rate_limits":{"seven_day_oauth_apps":{"utilization":24}}}"#)
        XCTAssertEqual(oauth.weekly?.usedPercent, 24)
        XCTAssertNil(oauth.session)
        let modern = try parse(#"{"rate_limits_available":true,"rate_limits":{"limits":[{"kind":"session","percent":33}]}}"#)
        XCTAssertEqual(modern.session?.usedPercent, 33)
    }

    func testStrictSchemaRejectsBooleansRangesMalformedAndMissingUsage() throws {
        for json in ["[]", "not json", "{}",
                     body.replacingOccurrences(of: "true", with: "1"),
                     body.replacingOccurrences(of: "12.5", with: "true"),
                     body.replacingOccurrences(of: "12.5", with: "-1"),
                     body.replacingOccurrences(of: "12.5", with: "100.01"),
                     body.replacingOccurrences(of: "12.5", with: "\"12.5\""),
                     body.replacingOccurrences(of: "12.5", with: "1e999"),
                     body.replacingOccurrences(of: "2020-01-02T03:04:05Z", with: "secret-path"),
                     #"{"rate_limits_available":true,"rate_limits":{}}"#,
                     #"{"rate_limits_available":true,"rate_limits":{"five_hour":{"resets_at":null}}}"#,
                     #"{"rate_limits_available":true,"rate_limits":{"limits":{}}}"#,
                     #"{"response":{"rate_limits_available":true,"rate_limits":{}}}"#] {
            XCTAssertThrowsError(try parse(json), json)
        }
    }

    func testUnavailableIsSanitized() {
        XCTAssertThrowsError(try parse(#"{"rate_limits_available":false,"error":"SECRET /private/token"}"#)) {
            XCTAssertEqual($0 as? ClaudeCodeStructuredUsageReaderError, .unsupported)
            XCTAssertFalse($0.localizedDescription.contains("SECRET"))
            XCTAssertFalse($0.localizedDescription.contains("/private"))
        }
    }

    private func fixture(_ script: String) throws -> (URL, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("fixture")
        try Data(("#!/bin/sh\n" + script + "\n").utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return (executable, directory)
    }

    private func fetch(_ fixture: (URL, URL), timeout: TimeInterval = 3,
                       environment: [String: String] = [:]) async throws -> ClaudeCodeStructuredUsage {
        try await ClaudeCodeStructuredUsageReader.fetch(profile: .init(label: "Fixture", configDirectory: "/not-read"),
            executable: fixture.0, environment: environment, workingDirectory: fixture.1, timeout: timeout)
    }

    private var initialize: String {
        #"""
        IFS= read -r init || exit 10
        printf '%s' "$init" > init.json
        id=$(printf '%s' "$init" | /usr/bin/sed 's/.*"request_id":"\([^"]*\)".*/\1/')
        printf '{"type":"system","subtype":"status","status":"starting"}\n'
        printf '{"type":"control_response","response":{"subtype":"success","request_id":"%s","response":{}}}\n' "$id"
        IFS= read -r usage || exit 11
        printf '%s' "$usage" > usage.json
        id=$(printf '%s' "$usage" | /usr/bin/sed 's/.*"request_id":"\([^"]*\)".*/\1/')
        """#
    }

    private func success(_ body: String) -> String {
        """
        printf '{"type":"control_response","response":{"subtype":"success","request_id":"%s","response":%s}}\\n' "$id" '\(body)'
        """
    }

    func testExactArgumentsEnvironmentAndOnlyTwoControlFrames() async throws {
        let f = try fixture("""
        printf '%s\\n' "$@" > args
        /usr/bin/env > env
        \(initialize)
        \(success(body))
        if IFS= read -r extra; then printf '%s' "$extra" > extra; fi
        """)
        let value = try await fetch(f, environment: ["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
            "ANTHROPIC_API_KEY": "fixture-not-a-credential", "CLAUDE_CONFIG_DIR": "/fixture/as-given",
            "HOME": f.1.path, "DISABLE_TELEMETRY": "fixture-value"])
        XCTAssertEqual(value.session?.usedPercent, 12.5)
        let args = try String(contentsOf: f.1.appendingPathComponent("args"), encoding: .utf8)
        XCTAssertEqual(args.components(separatedBy: "\n"), ["--print", "--input-format", "stream-json", "--output-format",
            "stream-json", "--verbose", "--tools", "", "--allowed-tools", "", "--strict-mcp-config", "--safe-mode",
            "--no-chrome", "--no-session-persistence", "--settings",
            "{\"disableAllHooks\":true,\"remoteControlAtStartup\":false}", ""])
        let env = try String(contentsOf: f.1.appendingPathComponent("env"), encoding: .utf8)
        for entry in ["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1", "ANTHROPIC_API_KEY=fixture-not-a-credential",
                      "CLAUDE_CONFIG_DIR=/fixture/as-given", "DISABLE_TELEMETRY=fixture-value"] {
            XCTAssertTrue(env.components(separatedBy: "\n").contains(entry))
        }
        XCTAssertFalse(env.contains("DISABLE_AUTOUPDATER="))
        func frame(_ name: String) throws -> [String: Any] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: f.1.appendingPathComponent(name))) as? [String: Any])
        }
        let first = try frame("init.json"), second = try frame("usage.json")
        XCTAssertEqual(first["type"] as? String, "control_request")
        XCTAssertEqual(second["type"] as? String, "control_request")
        XCTAssertNotEqual(first["request_id"] as? String, second["request_id"] as? String)
        let request = try XCTUnwrap(first["request"] as? [String: Any])
        XCTAssertEqual(Set(request.keys), Set(["subtype", "hooks", "sdkMcpServers", "promptSuggestions", "agentProgressSummaries"]))
        XCTAssertEqual(request["subtype"] as? String, "initialize")
        XCTAssertEqual((request["hooks"] as? [String: Any])?.count, 0)
        XCTAssertEqual(request["sdkMcpServers"] as? [String], [])
        XCTAssertEqual(request["promptSuggestions"] as? Bool, false)
        XCTAssertEqual(request["agentProgressSummaries"] as? Bool, false)
        let usage = try XCTUnwrap(second["request"] as? [String: Any])
        XCTAssertEqual(Set(usage.keys), Set(["subtype", "skip_behaviors"]))
        XCTAssertEqual(usage["subtype"] as? String, "get_usage")
        XCTAssertEqual(usage["skip_behaviors"] as? Bool, true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.1.appendingPathComponent("extra").path))
    }

    func testChunkedJSONAndInterleavedNotifications() async throws {
        let f = try fixture(initialize + "\n" + """
        printf 'fixture diagnostic' >&2
        printf '{"type":"system","subtype":"init"}\\n'
        printf '{"type":"control_res'
        /bin/sleep 0.03
        printf 'ponse","response":{"subtype":"success","request_id":"%s","response":%s}}' "$id" '\(body)'
        """)
        let value = try await fetch(f)
        XCTAssertEqual(value.weekly?.usedPercent, 88)
    }

    func testProtocolFailuresAndErrorsNeverExposeRawText() async throws {
        let scripts: [(String, ClaudeCodeStructuredUsageReaderError)] = [
            ("printf 'not-json SECRET /private/token\\n'", .invalidOutput),
            (#"printf '%s\n' '{"type":"control_request","request_id":"secret","request":{"subtype":"can_use_tool"}}'"#, .interactiveRequest),
            (#"printf '%s\n' '{"type":"control_response","response":{"subtype":"success","request_id":"wrong","response":{}}}'"#, .invalidOutput),
            (initialize + "\n" + #"printf '{"type":"control_response","response":{"subtype":"error","request_id":"%s","error":"SECRET /private/token"}}\n' "$id""#, .requestFailed),
            (initialize + "\n" + success(#"{"rate_limits_available":false}"#), .unsupported),
            (initialize + "\n" + success(body) + "\nprintf 'trailing-malformed SECRET\\n'", .invalidOutput),
            (initialize + "\n" + success(body) + "\n" + success(body), .invalidOutput),
            (#"printf '%s\n' '{"type":"assistant","message":"SECRET"}'"#, .invalidOutput)
        ]
        for (script, expected) in scripts {
            let f = try fixture(script)
            do { _ = try await fetch(f); XCTFail("Expected \(expected)") }
            catch {
                XCTAssertEqual(error as? ClaudeCodeStructuredUsageReaderError, expected)
                XCTAssertFalse(error.localizedDescription.contains("SECRET"))
                XCTAssertFalse(error.localizedDescription.contains("/private"))
            }
        }
    }

    func testTimeoutAndBoundedOutput() async throws {
        for (script, timeout, expected) in [
            ("/bin/sleep 30", 0.1, ClaudeCodeStructuredUsageReaderError.timedOut),
            ("/usr/bin/head -c 1100000 /dev/zero >&2", 3.0, .outputLimit),
            ("/usr/bin/head -c 270000 /dev/zero", 3.0, .outputLimit)
        ] {
            let f = try fixture(script)
            do { _ = try await fetch(f, timeout: timeout); XCTFail("Expected failure") }
            catch { XCTAssertEqual(error as? ClaudeCodeStructuredUsageReaderError, expected) }
        }
    }

    func testLaunchFailureAndNonzeroExitAreSanitized() async throws {
        let f = try fixture("printf 'SECRET /private/token' >&2; exit 23")
        do { _ = try await fetch(f); XCTFail("Expected nonzero exit failure") }
        catch { XCTAssertEqual(error as? ClaudeCodeStructuredUsageReaderError, .requestFailed) }
        do {
            _ = try await ClaudeCodeStructuredUsageReader.fetch(profile: .init(label: "Fixture"),
                executable: f.1.appendingPathComponent("nonexistent"), environment: [:], workingDirectory: f.1, timeout: 1)
            XCTFail("Expected launch failure")
        } catch {
            XCTAssertEqual(error as? ClaudeCodeStructuredUsageReaderError, .launchFailed)
            XCTAssertFalse(error.localizedDescription.contains(f.1.path))
        }
    }

    func testNotificationCountAndCombinedOutputAreBounded() async throws {
        for script in [
            #"i=0; while [ "$i" -lt 129 ]; do printf '%s\n' '{"type":"system","subtype":"status"}'; i=$((i+1)); done"#,
            #"/usr/bin/head -c 800000 /dev/zero >&2; /usr/bin/head -c 250000 /dev/zero"#
        ] {
            let f = try fixture(script)
            do { _ = try await fetch(f); XCTFail("Expected output limit") }
            catch { XCTAssertEqual(error as? ClaudeCodeStructuredUsageReaderError, .outputLimit) }
        }
    }

    func testCancellationAndDescendantCleanup() async throws {
        let f = try fixture("/bin/sleep 30 &\necho $! > child\nwait")
        let executable = f.0, directory = f.1
        let task = Task {
            try await ClaudeCodeStructuredUsageReader.fetch(profile: .init(label: "Fixture"), executable: executable,
                environment: [:], workingDirectory: directory, timeout: 20)
        }
        for _ in 0..<200 {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("child").path) { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        let pid = try XCTUnwrap(Int32(String(contentsOf: directory.appendingPathComponent("child"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        // A killed child may briefly be a zombie until launchd reaps it. ps state
        // distinguishes that from an executing orphan without touching user PIDs.
        let ps = Process(), pipe = Pipe()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-o", "stat=", "-p", String(pid)]
        ps.standardOutput = pipe
        try ps.run(); ps.waitUntilExit()
        let state = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(state.isEmpty || state.hasPrefix("Z"), "Fixture descendant is still running")
    }
}

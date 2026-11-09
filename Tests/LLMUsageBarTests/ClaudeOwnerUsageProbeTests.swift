import Darwin
import Foundation
import XCTest
@testable import LLMUsageBar

final class ClaudeOwnerUsageProbeTests: XCTestCase {
    private let org = "123e4567-e89b-42d3-a456-426614174000"

    private func fixture(_ body: String) throws -> (URL, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("owner-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("claude-fixture")
        try Data(("#!/bin/sh\n" + body + "\n").utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        return (script, dir)
    }

    private func auth(_ email: String = "test@example.invalid", _ org: String? = nil) -> String {
        let id = org ?? self.org
        return "printf '%s' '{\"loggedIn\":true,\"authMethod\":\"claude.ai\",\"apiProvider\":\"firstParty\",\"email\":\"\(email)\",\"orgId\":\"\(id)\"}'"
    }

    private func start(_ authCommand: String? = nil) -> String {
        """
        if [ "$1" = auth ]; then
          [ "$2" = status ] && [ "$3" = --json ] || exit 41
          \(authCommand ?? auth())
          exit 0
        fi
        [ "$1" = --allowed-tools ] && [ "$2" = "" ] || exit 42
        [ "$3" = --tools ] && [ "$4" = "" ] || exit 43
        [ "$5" = --strict-mcp-config ] && [ "$6" = --settings ] || exit 44
        [ "$7" = '{"disableAllHooks":true,"remoteControlAtStartup":false}' ] || exit 45
        [ "$8" = --no-chrome ] && [ "$9" = --safe-mode ] && [ "${10}" = /usage ] || exit 46
        """ + "\n"
    }

    private func usage(_ ending: String = "") -> String {
        "printf '\\nCurrent session\\n42%% used\\nCurrent week\\n31%% used\\n'; \(ending)"
    }

    private func probe(_ fixture: (URL, URL), profile: ClaudeAccountProfile = .init(label: "Fixture"),
                       environment: [String: String] = [:], timeout: TimeInterval = 5) async throws -> ClaudeOwnerUsageProbeResult {
        try await ClaudeOwnerUsageProbe.run(profile: profile, executable: fixture.0, environment: environment,
                                            workingDirectory: fixture.1, timeout: timeout)
    }

    func testStableAuthAndUsageResultIsNeverVerifiedIdentity() async throws {
        let f = try fixture(start() + usage("/bin/sleep 2"))
        let result = try await probe(f)
        XCTAssertEqual(result.ownerReportedIdentity.email, "test@example.invalid")
        XCTAssertEqual(result.ownerReportedIdentity.organizationID, org)
        XCTAssertEqual(result.usage.fiveHour?.usedPercent, 42)
        XCTAssertEqual(result.usage.weekly?.usedPercent, 31)
        XCTAssertFalse(result.identityVerifiedForTrackedAccount)
        XCTAssertEqual(result.jsonObject()["identityVerifiedForTrackedAccount"] as? Bool, false)
        XCTAssertFalse(result.freshnessVerified)
        XCTAssertEqual(result.jsonObject()["freshnessVerified"] as? Bool, false)
        XCTAssertNotNil(result.jsonObject()["capturedAt"])
        XCTAssertNil(result.jsonObject()["updatedAt"], "A capture must not masquerade as a fresh measurement")
        XCTAssertNil((result.jsonObject()["ownerReportedIdentity"] as? [String: Any])?["accountID"])
    }

    func testChangedEmailOrOrganizationFails() async throws {
        for change in [auth("other@example.invalid"), auth("test@example.invalid", "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")] {
            let counter = "n=$(/bin/cat \"$COUNT_FILE\" 2>/dev/null || echo 0); n=$((n+1)); echo $n > \"$COUNT_FILE\"; if [ $n -eq 1 ]; then \(auth()); else \(change); fi"
            let f = try fixture(start(counter) + usage())
            do { _ = try await probe(f, environment: ["COUNT_FILE": f.1.appendingPathComponent("count").path]); XCTFail("identity change must fail") }
            catch { XCTAssertEqual(error as? ClaudeOwnerUsageProbeError, .identityChanged) }
        }
    }

    func testLoggedOutAndUnsupportedAuthNeverStartUsage() async throws {
        let auths = ["printf '%s' '{\"loggedIn\":false}'",
                     "printf '%s' '{\"loggedIn\":true,\"authMethod\":\"other\",\"apiProvider\":\"firstParty\",\"email\":\"test@example.invalid\",\"orgId\":\"\(org)\"}'",
                     "printf '%s' '{\"loggedIn\":true,\"authMethod\":\"claude.ai\",\"apiProvider\":\"firstParty\",\"email\":\"test@example.invalid\"}'"]
        for command in auths {
            let f = try fixture(start(command) + "/usr/bin/touch \"$USAGE_MARKER\"; exit 0")
            do { _ = try await probe(f, environment: ["USAGE_MARKER": f.1.appendingPathComponent("usage").path]); XCTFail("auth should reject") }
            catch {
                let expected: ClaudeOwnerUsageProbeError = command.contains("false") ? .signInRequired : .authUnavailable
                XCTAssertEqual(error as? ClaudeOwnerUsageProbeError, expected)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.1.appendingPathComponent("usage").path))
        }
    }

    func testSetupBarrierAndExplicitUsageErrorAreRejectedWithoutRawOutputOrInput() async throws {
        for (text, expected) in [("Do you trust the files in this folder?", ClaudeOwnerUsageProbeError.setupRequired),
                                 ("Error: Failed to load usage data", .usageUnavailable)] {
            let marker = "\(text.hashValue)"
            let f = try fixture(start() + "printf '\\n%s\\n' '\(text)'; if read answer; then /usr/bin/touch \"$INPUT_MARKER\"; fi")
            do { _ = try await probe(f, environment: ["INPUT_MARKER": f.1.appendingPathComponent(marker).path]); XCTFail("expected rejection") }
            catch { XCTAssertEqual(error as? ClaudeOwnerUsageProbeError, expected); XCTAssertFalse(error.localizedDescription.contains(text)) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.1.appendingPathComponent(marker).path))
        }
    }

    func testSanitizedOutputAndConfigEnvironmentIsolation() async throws {
        let f = try fixture(start() + "printf '\\nSECRET_RAW_OUTPUT\\n'")
        do { _ = try await probe(f, environment: ["CLAUDE_CONFIG_DIR": "/wrong", "ANTHROPIC_API_KEY": "secret", "NODE_OPTIONS": "secret"]); XCTFail() }
        catch { XCTAssertFalse(error.localizedDescription.contains("SECRET_RAW_OUTPUT")) }
        let isolated = ClaudeCLI.loginEnvironment(profile: .init(label: "Default"), inherited: ["CLAUDE_CONFIG_DIR": "/wrong", "ANTHROPIC_API_KEY": "secret", "NODE_OPTIONS": "secret"])
        XCTAssertNil(isolated["CLAUDE_CONFIG_DIR"])
        XCTAssertNil(isolated["ANTHROPIC_API_KEY"])
        XCTAssertNil(isolated["NODE_OPTIONS"])
        XCTAssertEqual(ClaudeCLI.loginEnvironment(profile: .init(label: "Custom", configDirectory: "/fixture/a/../b"), inherited: [:])["CLAUDE_CONFIG_DIR"], "/fixture/b")
    }

    func testStructuredStatusPreservesInheritedTrafficRestrictionWithoutAuthOverrides() async throws {
        for restriction in ["1", "0", "false"] {
            let f = try fixture("""
            [ "$1" = auth ] && [ "$2" = status ] && [ "$3" = --json ] || exit 71
            [ "$CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC" = "\(restriction)" ] || exit 72
            [ "$CLAUDE_CONFIG_DIR" = /fixture/b ] || exit 73
            [ "$DISABLE_TELEMETRY" = 1 ] && [ "$DISABLE_ERROR_REPORTING" = 1 ] || exit 74
            [ -z "${ANTHROPIC_API_KEY+x}${NODE_OPTIONS+x}" ] || exit 75
            \(auth())
            """)
            let identity = try await ClaudeOwnerUsageProbe.observeIdentity(
                profile: .init(label: "Fixture", configDirectory: "/fixture/a/../b"), executable: f.0,
                environment: ["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": restriction,
                              "CLAUDE_CONFIG_DIR": "/wrong", "ANTHROPIC_API_KEY": "fixture", "NODE_OPTIONS": "fixture"],
                workingDirectory: f.1, timeout: 3, allowRestrictedTraffic: true)
            XCTAssertEqual(identity.organizationID, org)
        }
    }

    func testTimeoutAndCancellationAfterUsageProcessStarts() async throws {
        let f = try fixture(start() + "while :; do printf x; done")
        do { _ = try await probe(f, timeout: 0.2); XCTFail() }
        catch { XCTAssertEqual(error as? ClaudeOwnerUsageProbeError, .timedOut) }
        let c = try fixture(start() + "/usr/bin/touch \"$STARTED\"; /bin/sleep 30")
        let task = Task.detached {
            try await ClaudeOwnerUsageProbe.run(profile: .init(label: "Fixture"), executable: c.0,
                                                environment: ["STARTED": c.1.appendingPathComponent("started").path], workingDirectory: c.1, timeout: 20)
        }
        let marker = c.1.appendingPathComponent("started")
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: marker.path), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "usage subprocess should have started before cancellation")
        task.cancel()
        do { _ = try await task.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
    }

    func testUsageChildEnvironmentFlagsAndPTY() async throws {
        for profile in [ClaudeAccountProfile(label: "Default"),
                        ClaudeAccountProfile(label: "Custom", configDirectory: "/fixture/a/../b")] {
            let marker = "child-\(profile.label)"
            let checks = """
            [ \"${CLAUDE_CONFIG_DIR-unset}\" = \"\(profile.configDirectory == nil ? "unset" : "/fixture/b")\" ] || exit 51
            [ \"${DISABLE_AUTOUPDATER-unset}\" = 1 ] || exit 52
            [ -z \"${CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC+x}\" ] || exit 53
            [ \"${DISABLE_TELEMETRY-unset}\" = 1 ] && [ \"${DISABLE_ERROR_REPORTING-unset}\" = 1 ] || exit 56
            [ \"${CLAUDE_CODE_DISABLE_OFFICIAL_MARKETPLACE_AUTOINSTALL-unset}\" = 1 ] || exit 57
            [ -z \"${ANTHROPIC_API_KEY+x}${ANTHROPIC_AUTH_TOKEN+x}${AWS_SECRET_ACCESS_KEY+x}${GOOGLE_APPLICATION_CREDENTIALS+x}${NODE_OPTIONS+x}${HTTP_PROXY+x}${HTTPS_PROXY+x}${ALL_PROXY+x}${NO_PROXY+x}\" ] || exit 54
            [ -t 0 ] && [ -t 1 ] && [ -t 2 ] || exit 55
            /usr/bin/touch \"$CHILD_MARKER\"
            """
            let f = try fixture(start() + checks + "\n" + usage("/bin/sleep 2"))
            let hostile = ["ANTHROPIC_API_KEY": "secret", "ANTHROPIC_AUTH_TOKEN": "secret",
                           "AWS_SECRET_ACCESS_KEY": "secret", "GOOGLE_APPLICATION_CREDENTIALS": "secret",
                           "NODE_OPTIONS": "secret", "HTTP_PROXY": "secret", "HTTPS_PROXY": "secret",
                           "ALL_PROXY": "secret", "NO_PROXY": "secret", "CLAUDE_CONFIG_DIR": "/wrong",
                           "CHILD_MARKER": f.1.appendingPathComponent(marker).path]
            do { _ = try await probe(f, profile: profile, environment: hostile) }
            catch { XCTFail("child environment/PTY assertions failed: \(error)") }
            XCTAssertTrue(FileManager.default.fileExists(atPath: f.1.appendingPathComponent(marker).path))
        }
    }

    func testExplicitTrafficRestrictionIsNotSilentlyOverridden() async throws {
        for value in ["1", "0", "false"] {
            let f = try fixture("/usr/bin/touch \"$LAUNCH_MARKER\"; exit 42")
            let marker = f.1.appendingPathComponent("launched")
            do {
                _ = try await probe(f, environment: ["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": value,
                                                    "LAUNCH_MARKER": marker.path])
                XCTFail("Explicit privacy restriction must be respected")
            } catch { XCTAssertEqual(error as? ClaudeOwnerUsageProbeError, .trafficRestricted) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        }
    }

    func testAuthOutputLimitIncludesStderrAndNeverStartsUsage() async throws {
        let command = "while :; do printf 'SECRET_AUTH_STDOUT'; printf 'SECRET_AUTH_STDERR' >&2; done"
        let f = try fixture(start(command) + "/usr/bin/touch \"$USAGE_MARKER\"")
        let marker = f.1.appendingPathComponent("usage")
        do {
            _ = try await probe(f, environment: ["USAGE_MARKER": marker.path])
            XCTFail("Auth flooding must be bounded")
        } catch {
            XCTAssertEqual(error as? ClaudeOwnerUsageProbeError, .outputLimit)
            XCTAssertFalse(error.localizedDescription.contains("SECRET"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testNumericLoggedInAndMalformedJSONAreNotAuthentication() {
        for json in ["{\"loggedIn\":1}", "{\"loggedIn\":\"true\"}", "not JSON"] {
            XCTAssertThrowsError(try ClaudeOwnerAuthObservation.parse(Data(json.utf8))) {
                XCTAssertEqual($0 as? ClaudeOwnerUsageProbeError, .authUnavailable)
            }
        }
    }

    func testClearedQuotaCannotBeReturnedAfterLaterError() async throws {
        let f = try fixture(start() + usage("printf '\\033[?25l\\033[2J\\033[HError: Failed to load usage data'; /bin/sleep 2"))
        do { _ = try await probe(f); XCTFail("Old panel must not survive an error redraw") }
        catch { XCTAssertEqual(error as? ClaudeOwnerUsageProbeError, .usageUnavailable) }
    }

    func testFinalErrorAndNonzeroExitCannotReturnEarlierUsage() async throws {
        for ending in ["printf '\\033[2J\\033[HError: Failed to load usage data'; exit 0", "exit 42"] {
            let f = try fixture(start() + usage("/bin/sleep 0.1; \(ending)"))
            do { _ = try await probe(f); XCTFail("Final failure must invalidate the earlier candidate") }
            catch { XCTAssertTrue([.usageUnavailable, .invalidOutput].contains(error as? ClaudeOwnerUsageProbeError)) }
        }
    }

    func testUsageOutputHasAHardByteLimit() async throws {
        let f = try fixture(start() + "/usr/bin/head -c 1100000 /dev/zero; /bin/sleep 2")
        do { _ = try await probe(f, timeout: 15); XCTFail("Usage output must be bounded") }
        catch { XCTAssertEqual(error as? ClaudeOwnerUsageProbeError, .outputLimit) }
    }

    func testUsageDescendantAndExitedWrapperAreCleanedUp() async throws {
        for exits in [false, true] {
            let pidFile = "\(exits).pid"
            let body = start() + "/bin/sleep 30 & echo $! > \"$PID_FILE\"; " + usage(exits ? "exit 0" : "/bin/sleep 2")
            let f = try fixture(body)
            do { _ = try await probe(f, environment: ["PID_FILE": f.1.appendingPathComponent(pidFile).path]) }
            catch { XCTFail("usage fixture should be recognized: \(error)") }
            let pidText = try String(contentsOf: f.1.appendingPathComponent(pidFile), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            if let pid = Int32(pidText) {
                let deadline = Date().addingTimeInterval(2)
                while kill(pid, 0) == 0 && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
                XCTAssertNotEqual(kill(pid, 0), 0, "descendant pid \(pid) should be gone")
            } else { XCTFail("missing descendant PID") }
        }
    }
}

import Foundation
import XCTest
@testable import LLMUsageBar

final class PiSessionsFetcherTests: XCTestCase {
    func testIncludesOnlySubagentProviderCallsWithoutDoubleCountingMainCalls() throws {
        let fixture = try self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        try self.writeJSONLines([
            [
                "type": "provider_call", "timestamp": "2026-09-07T11:00:00Z",
                "message_completion_at": "2026-09-07T11:01:00Z", "execution_scope": "main",
                "subagent_depth": 0, "provider": "telemetry-main", "model": "main-model",
                "input": 100, "output": 10, "cacheRead": 20, "cacheWrite": 30,
                "totalTokens": 160, "cost": 9.0,
            ],
            [
                "type": "provider_call", "timestamp": "2026-09-07T11:02:00Z",
                "message_completion_at": "2026-09-07T11:03:00Z", "execution_scope": "subagent",
                "subagent_depth": 0, "session_id": "sub-session", "cwd": "/tmp/project",
                "provider": "sub-provider", "model": "sub-model",
                "input": 20, "output": 3, "cacheRead": 4, "cacheWrite": 5,
                "totalTokens": 32, "cost": 0.2,
            ],
            [
                "type": "provider_call", "timestamp": "2026-09-07T11:04:00Z",
                "execution_scope": "main", "subagent_depth": 2,
                "provider": "depth-provider", "model": "depth-model",
                "input": 30, "output": 6, "cacheRead": 7, "cacheWrite": 8,
                "totalTokens": 51, "cost": 0.3,
            ],
            [
                "type": "agent_run", "execution_scope": "subagent", "subagent_depth": 1,
                "input": 999, "output": 999, "totalTokens": 1998, "cost": 99.0,
            ],
            [
                "type": "provider_call", "execution_scope": "subagent", "subagent_depth": 1,
                "input": 1, "output": 1, "cacheRead": 1, "cacheWrite": 1, "totalTokens": 4,
            ],
        ], at: fixture.telemetry)
        let malformed = "not-json\n"
            .appending("{\"type\":\"provider_call\"}\n")
            .appending("{\"type\":\"provider_call\",\"execution_scope\":\"subagent\",\"timestamp\":\"bad\",\"input\":1,\"output\":1,\"cacheRead\":1,\"cacheWrite\":1,\"totalTokens\":4,\"cost\":1}\n")
        let telemetryHandle = try FileHandle(forWritingTo: fixture.telemetry)
        try telemetryHandle.seekToEnd()
        try telemetryHandle.write(contentsOf: Data(malformed.utf8))
        try telemetryHandle.close()

        let snapshot = try PiSessionsFetcher().fetch(
            sessionsDirectory: fixture.sessions.path,
            deduplicateForkHistory: true)

        // One main session message plus the two subagent provider calls. The main telemetry
        // call and the aggregate agent_run must not add rows.
        XCTAssertEqual(snapshot.rows.count, 3)
        XCTAssertNil(snapshot.rows.first(where: { $0.model == "main-model" }))
        XCTAssertNotNil(snapshot.rows.first(where: { $0.model == "depth-model" }))
        let subagent = try XCTUnwrap(snapshot.rows.first { $0.model == "sub-model" })
        XCTAssertEqual(subagent.provider, "sub-provider")
        XCTAssertEqual(subagent.cwd, "/tmp/project")
        XCTAssertEqual(subagent.sessionID, "sub-session")
        XCTAssertEqual(subagent.timeCreated, try self.date("2026-09-07T11:03:00Z"))

        let summary = PiUsageAggregation.summary(
            rows: snapshot.rows,
            window: .lastThirtyDays,
            now: try self.date("2026-09-07T12:00:00Z"),
            calendar: Calendar(identifier: .gregorian))
        XCTAssertEqual(summary.requestCount, 3)
        XCTAssertEqual(summary.totalInputTokens, 60)
        XCTAssertEqual(summary.totalOutputTokens, 14)
        XCTAssertEqual(summary.totalCacheReadTokens, 13)
        XCTAssertEqual(summary.totalCacheWriteTokens, 14)
        XCTAssertEqual(summary.totalCostUSD, 0.6, accuracy: 0.000001)
    }

    func testMalformedOrMissingTelemetryDoesNotDiscardSessionRows() throws {
        let fixture = try self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        try "{\"type\":\"provider_call\",\"execution_scope\":\"subagent\",\"input\":\"bad\"}\n"
            .write(to: fixture.telemetry, atomically: true, encoding: .utf8)
        let snapshot = try PiSessionsFetcher().fetch(
            sessionsDirectory: fixture.sessions.path,
            deduplicateForkHistory: true)
        XCTAssertEqual(snapshot.rows.count, 1)
        XCTAssertEqual(snapshot.rows[0].model, "session-model")

        try FileManager.default.removeItem(at: fixture.telemetry)
        let withoutTelemetry = try PiSessionsFetcher().fetch(
            sessionsDirectory: fixture.sessions.path,
            deduplicateForkHistory: true)
        XCTAssertEqual(withoutTelemetry.rows.count, 1)
    }

    func testTelemetryRefreshParsesOnlyAppendedRowsWithoutDuplicates() throws {
        let fixture = try self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        try self.writeJSONLines([
            self.telemetryRecord(model: "first-model", timestamp: "2026-09-07T11:00:00Z"),
        ], at: fixture.telemetry)
        let fetcher = PiSessionsFetcher()
        let first = try fetcher.fetch(
            sessionsDirectory: fixture.sessions.path,
            deduplicateForkHistory: true)
        XCTAssertEqual(first.rows.filter { $0.sessionFile == fixture.resolvedTelemetryPath }.count, 1)

        try self.appendJSONLines([
            self.telemetryRecord(model: "second-model", timestamp: "2026-09-07T11:01:00Z"),
        ], at: fixture.telemetry)
        let second = try fetcher.fetch(
            sessionsDirectory: fixture.sessions.path,
            deduplicateForkHistory: true)
        let telemetryRows = second.rows.filter { $0.sessionFile == fixture.resolvedTelemetryPath }
        XCTAssertEqual(telemetryRows.count, 2)
        XCTAssertEqual(Set(telemetryRows.compactMap(\.model)), Set(["first-model", "second-model"]))

        let repeated = try fetcher.fetch(
            sessionsDirectory: fixture.sessions.path,
            deduplicateForkHistory: true)
        XCTAssertEqual(repeated.rows.filter { $0.sessionFile == fixture.resolvedTelemetryPath }.count, 2)
    }

    func testTelemetryIncompleteTrailingLineIsParsedAfterItIsCompleted() throws {
        let fixture = try self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let line = try self.jsonLine(
            self.telemetryRecord(model: "partial-model", timestamp: "2026-09-07T11:00:00Z"))
        let splitIndex = line.index(line.startIndex, offsetBy: line.count / 2)
        try String(line[..<splitIndex]).write(to: fixture.telemetry, atomically: true, encoding: .utf8)

        let fetcher = PiSessionsFetcher()
        let beforeCompletion = try fetcher.fetch(
            sessionsDirectory: fixture.sessions.path,
            deduplicateForkHistory: true)
        XCTAssertEqual(beforeCompletion.rows.filter { $0.sessionFile == fixture.resolvedTelemetryPath }.count, 0)

        try self.appendJSONLines([], rawSuffix: String(line[splitIndex...]) + "\n", at: fixture.telemetry)
        let afterCompletion = try fetcher.fetch(
            sessionsDirectory: fixture.sessions.path,
            deduplicateForkHistory: true)
        XCTAssertEqual(afterCompletion.rows.filter { $0.sessionFile == fixture.resolvedTelemetryPath }.count, 1)
    }

    func testTelemetryTruncationAndReplacementResetTheCache() throws {
        let fixture = try self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        try self.writeJSONLines([
            self.telemetryRecord(model: "old-one", timestamp: "2026-09-07T11:00:00Z"),
            self.telemetryRecord(model: "old-two", timestamp: "2026-09-07T11:01:00Z"),
        ], at: fixture.telemetry)
        let fetcher = PiSessionsFetcher()
        _ = try fetcher.fetch(sessionsDirectory: fixture.sessions.path, deduplicateForkHistory: true)

        let truncatedHandle = try FileHandle(forWritingTo: fixture.telemetry)
        try truncatedHandle.truncate(atOffset: 0)
        try truncatedHandle.seekToEnd()
        let truncatedLine = try self.jsonLine(
            self.telemetryRecord(model: "after-truncation", timestamp: "2026-09-07T11:02:00Z"))
        try truncatedHandle.write(contentsOf: Data((truncatedLine + "\n").utf8))
        try truncatedHandle.close()

        let afterTruncation = try fetcher.fetch(
            sessionsDirectory: fixture.sessions.path,
            deduplicateForkHistory: true)
        var telemetryRows = afterTruncation.rows.filter { $0.sessionFile == fixture.resolvedTelemetryPath }
        XCTAssertEqual(telemetryRows.compactMap(\.model), ["after-truncation"])

        try self.writeJSONLines([
            self.telemetryRecord(model: "after-replacement", timestamp: "2026-09-07T11:03:00Z"),
        ], at: fixture.telemetry)
        let afterReplacement = try fetcher.fetch(
            sessionsDirectory: fixture.sessions.path,
            deduplicateForkHistory: true)
        telemetryRows = afterReplacement.rows.filter { $0.sessionFile == fixture.resolvedTelemetryPath }
        XCTAssertEqual(telemetryRows.compactMap(\.model), ["after-replacement"])
    }

    func testTelemetryMissingOptionalUsageFieldsDefaultsInsteadOfDroppingCall() throws {
        let fixture = try self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        try self.writeJSONLines([
            [
                "type": "provider_call", "execution_scope": "subagent",
                "timestamp": "2026-09-07T11:00:00Z", "input": 7, "output": 2,
                "provider": "provider", "model": "optional-usage-model",
            ],
            [
                "type": "provider_call", "execution_scope": "subagent",
                "timestamp": "2026-09-07T11:01:00Z",
            ],
        ], at: fixture.telemetry)

        let snapshot = try PiSessionsFetcher().fetch(
            sessionsDirectory: fixture.sessions.path,
            deduplicateForkHistory: true)
        let row = try XCTUnwrap(snapshot.rows.first { $0.model == "optional-usage-model" })
        XCTAssertEqual(row.inputTokens, 7)
        XCTAssertEqual(row.outputTokens, 2)
        XCTAssertEqual(row.cacheReadTokens, 0)
        XCTAssertEqual(row.cacheWriteTokens, 0)
        XCTAssertEqual(row.totalTokens, 9)
        XCTAssertEqual(row.costUSD, 0)
        XCTAssertEqual(snapshot.rows.filter { $0.sessionFile == fixture.resolvedTelemetryPath }.count, 1)
    }

    private struct Fixture {
        let root: URL
        let sessions: URL
        let telemetry: URL

        var resolvedTelemetryPath: String {
            sessions.standardizedFileURL
                .deletingLastPathComponent()
                .appendingPathComponent("telemetry/events.jsonl")
                .path
        }
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("llm-usage-pi-telemetry-\(UUID().uuidString)", isDirectory: true)
        let sessions = root.appendingPathComponent("pi/agent/sessions", isDirectory: true)
        let telemetry = root.appendingPathComponent("pi/agent/telemetry/events.jsonl", isDirectory: false)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: telemetry.deletingLastPathComponent(), withIntermediateDirectories: true)
        try self.writeJSONLines([
            ["type": "session", "id": "session-id", "cwd": "/tmp/session", "timestamp": "2026-09-07T10:00:00Z"],
            [
                "type": "message", "timestamp": "2026-09-07T10:05:00Z",
                "message": [
                    "role": "assistant", "provider": "session-provider", "model": "session-model",
                    "usage": [
                        "input": 10, "output": 5, "cacheRead": 2, "cacheWrite": 1,
                        "totalTokens": 18, "cost": ["total": 0.1],
                    ],
                ],
            ],
        ], at: sessions.appendingPathComponent("session.jsonl"))
        return Fixture(root: root, sessions: sessions, telemetry: telemetry)
    }

    private func telemetryRecord(model: String, timestamp: String) -> [String: Any] {
        [
            "type": "provider_call", "execution_scope": "subagent", "subagent_depth": 1,
            "timestamp": timestamp, "input": 1, "output": 1, "cacheRead": 0,
            "cacheWrite": 0, "totalTokens": 2, "cost": 0.1, "model": model,
        ]
    }

    private func writeJSONLines(_ objects: [[String: Any]], at url: URL) throws {
        let lines = try objects.map { try self.jsonLine($0) }
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func appendJSONLines(
        _ objects: [[String: Any]],
        rawSuffix: String = "",
        at url: URL
    ) throws {
        let lines = try objects.map { try self.jsonLine($0) }
        let text = lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n") + rawSuffix
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }

    private func jsonLine(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    private func date(_ value: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return try XCTUnwrap(formatter.date(from: value))
    }
}

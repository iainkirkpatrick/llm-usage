import Foundation
import XCTest
@testable import LLMUsageBar

final class PiSessionsFetcherTests: XCTestCase {
    func testAssistantAndCompletedSubagentTotalsUseParentSessionMetadata() throws {
        let fixture = try self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let sessionFile = fixture.sessions.appendingPathComponent("parent.jsonl")
        try self.writeJSONLines([
            self.header(id: "parent-session", cwd: "/tmp/parent", timestamp: "2026-09-07T10:00:00Z"),
            self.assistantMessage(
                id: "assistant-entry",
                timestamp: "2026-09-07T10:05:00Z",
                input: 10,
                output: 5,
                cacheRead: 2,
                cacheWrite: 1,
                cost: 0.1),
            self.subagentMessage(
                id: "subagent-entry",
                toolCallID: "subagent-call",
                timestamp: "2026-09-07T10:10:00Z",
                results: [
                    self.result(
                        model: "sub-model",
                        input: 20,
                        output: 3,
                        cacheRead: 4,
                        cacheWrite: 5,
                        cost: 0.2,
                        contextTokens: 999,
                        turns: 3),
                ])
        ], at: sessionFile)

        let snapshot = try self.fetch(fixture)
        XCTAssertEqual(snapshot.rows.count, 2)

        let subagent = try XCTUnwrap(snapshot.rows.first { $0.model == "sub-model" })
        XCTAssertTrue(subagent.sessionFile.hasSuffix("/parent.jsonl"))
        XCTAssertEqual(subagent.sessionID, "parent-session")
        XCTAssertEqual(subagent.cwd, "/tmp/parent")
        XCTAssertEqual(subagent.timeCreated, try self.date("2026-09-07T10:10:00Z"))
        XCTAssertEqual(subagent.inputTokens, 20)
        XCTAssertEqual(subagent.outputTokens, 3)
        XCTAssertEqual(subagent.cacheReadTokens, 4)
        XCTAssertEqual(subagent.cacheWriteTokens, 5)
        XCTAssertEqual(subagent.totalTokens, 32)
        XCTAssertEqual(subagent.costUSD, 0.2, accuracy: 0.000001)
        XCTAssertEqual(subagent.requestCount, 3)

        let summary = PiUsageAggregation.summary(
            rows: snapshot.rows,
            window: .lastThirtyDays,
            now: try self.date("2026-09-07T12:00:00Z"),
            calendar: self.utcCalendar())
        XCTAssertEqual(summary.requestCount, 4)
        XCTAssertEqual(summary.totalInputTokens, 30)
        XCTAssertEqual(summary.totalOutputTokens, 8)
        XCTAssertEqual(summary.totalCacheReadTokens, 6)
        XCTAssertEqual(summary.totalCacheWriteTokens, 6)
        XCTAssertEqual(summary.totalTokens, 50)
        XCTAssertEqual(summary.totalCostUSD, 0.3, accuracy: 0.000001)
    }

    func testSubagentTurnsContributeRequestsWithNonzeroUsageFallback() throws {
        let fixture = try self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        try self.writeJSONLines([
            self.header(id: "session", cwd: "/tmp/project", timestamp: "2026-09-07T10:00:00Z"),
            self.subagentMessage(
                id: "turns-entry",
                timestamp: "2026-09-07T10:01:00Z",
                results: [
                    self.result(model: "turn-model", input: 1, output: 1, turns: 4),
                    self.result(model: "fallback-model", input: 2, output: 0),
                ])
        ], at: fixture.sessions.appendingPathComponent("turns.jsonl"))

        let snapshot = try self.fetch(fixture)
        XCTAssertEqual(snapshot.rows.count, 2)
        XCTAssertEqual(snapshot.rows.first { $0.model == "turn-model" }?.requestCount, 4)
        XCTAssertEqual(snapshot.rows.first { $0.model == "fallback-model" }?.requestCount, 1)
        XCTAssertEqual(PiUsageAggregation.requestCount(rows: snapshot.rows), 5)

        let groups = PiUsageAggregation.groupByModel(
            rows: snapshot.rows,
            window: .lastThirtyDays,
            now: try self.date("2026-09-07T12:00:00Z"),
            calendar: self.utcCalendar())
        XCTAssertEqual(groups.map(\.requestCount), [4, 1])
    }

    func testParallelAndChainResultsRemainSeparateWithoutRunIDs() throws {
        let fixture = try self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let sameUsage: [[String: Any]] = [
            self.result(model: "same-model", input: 7, output: 2, cost: 0.25),
            self.result(model: "same-model", input: 7, output: 2, cost: 0.25),
        ]
        try self.writeJSONLines([
            self.header(id: "session", cwd: "/tmp/project", timestamp: "2026-09-07T10:00:00Z"),
            self.subagentMessage(
                id: "parallel-entry",
                timestamp: "2026-09-07T10:01:00Z",
                mode: "parallel",
                results: sameUsage),
            self.subagentMessage(
                id: "chain-entry",
                timestamp: "2026-09-07T10:02:00Z",
                mode: "chain",
                results: sameUsage),
        ], at: fixture.sessions.appendingPathComponent("parallel-chain.jsonl"))

        let snapshot = try self.fetch(fixture)
        XCTAssertEqual(snapshot.rows.filter { $0.model == "same-model" }.count, 4)
        let summary = PiUsageAggregation.summary(
            rows: snapshot.rows,
            window: .lastThirtyDays,
            now: try self.date("2026-09-07T12:00:00Z"),
            calendar: self.utcCalendar())
        XCTAssertEqual(summary.requestCount, 4)
        XCTAssertEqual(summary.totalInputTokens, 28)
        XCTAssertEqual(summary.totalOutputTokens, 8)
        XCTAssertEqual(summary.totalCostUSD, 1, accuracy: 0.000001)
    }

    func testRunIDAndPersistedMessageIdentityDedupeCopiedSummaries() throws {
        let fixture = try self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let runID = "run-123"
        let runResult = self.result(
            model: "run-model",
            input: 10,
            output: 2,
            cost: 0.1,
            runID: runID)
        let copiedRunResult = self.result(
            model: "run-model",
            input: 10,
            output: 2,
            cost: 0.1,
            runID: runID)
        let originalPath = fixture.sessions.appendingPathComponent("a-original.jsonl")
        let forkPath = fixture.sessions.appendingPathComponent("b-fork.jsonl")
        try self.writeJSONLines([
            self.header(id: "original", cwd: "/tmp/project", timestamp: "2026-09-07T10:00:00Z"),
            self.subagentMessage(
                id: "run-entry",
                toolCallID: "run-call",
                timestamp: "2026-09-07T10:30:00Z",
                results: [runResult]),
        ], at: originalPath)
        try self.writeJSONLines([
            self.header(
                id: "fork",
                cwd: "/tmp/project",
                timestamp: "2026-09-07T10:20:00Z",
                parentSession: originalPath.path),
            self.subagentMessage(
                id: "run-entry",
                toolCallID: "run-call",
                timestamp: "2026-09-07T10:30:00Z",
                results: [copiedRunResult]),
        ], at: forkPath)

        let fallbackResult = self.result(model: "fallback-model", input: 3, output: 1, cost: 0.05)
        let fallbackOriginal = fixture.sessions.appendingPathComponent("c-fallback-original.jsonl")
        let fallbackCopy = fixture.sessions.appendingPathComponent("d-fallback-copy.jsonl")
        let fallbackMessage = self.subagentMessage(
            id: "fallback-entry",
            toolCallID: "fallback-call",
            timestamp: "2026-09-07T10:40:00Z",
            results: [fallbackResult])
        try self.writeJSONLines([
            self.header(id: "fallback-original", cwd: "/tmp/project", timestamp: "2026-09-07T10:00:00Z"),
            fallbackMessage,
        ], at: fallbackOriginal)
        try self.writeJSONLines([
            self.header(id: "fallback-copy", cwd: "/tmp/project", timestamp: "2026-09-07T10:00:00Z"),
            fallbackMessage,
        ], at: fallbackCopy)

        let snapshot = try self.fetch(fixture)
        XCTAssertEqual(snapshot.rows.filter { $0.model == "run-model" }.count, 1)
        XCTAssertEqual(snapshot.rows.filter { $0.model == "fallback-model" }.count, 1)
        XCTAssertEqual(snapshot.rows.count, 2)
    }

    func testForkHistoryStillDropsCopiedEntriesOlderThanForkHeader() throws {
        let fixture = try self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let originalPath = fixture.sessions.appendingPathComponent("a-original.jsonl")
        let forkPath = fixture.sessions.appendingPathComponent("b-fork.jsonl")
        let oldAssistant = self.assistantMessage(
            id: "old-assistant",
            timestamp: "2026-09-07T10:05:00Z",
            input: 1,
            output: 1,
            cost: 0.01)
        let oldSubagent = self.subagentMessage(
            id: "old-subagent",
            timestamp: "2026-09-07T10:06:00Z",
            results: [self.result(model: "old-subagent-model", input: 2, output: 1, cost: 0.02)])
        try self.writeJSONLines([
            self.header(id: "original", cwd: "/tmp/project", timestamp: "2026-09-07T10:00:00Z"),
            oldAssistant,
            oldSubagent,
        ], at: originalPath)
        try self.writeJSONLines([
            self.header(
                id: "fork",
                cwd: "/tmp/project",
                timestamp: "2026-09-07T11:00:00Z",
                parentSession: originalPath.path),
            oldAssistant,
            oldSubagent,
            self.assistantMessage(
                id: "new-assistant",
                timestamp: "2026-09-07T11:01:00Z",
                input: 3,
                output: 1,
                cost: 0.03),
        ], at: forkPath)

        let snapshot = try self.fetch(fixture)
        XCTAssertEqual(snapshot.forkedSessionCount, 1)
        XCTAssertEqual(snapshot.rows.filter { $0.model == "old-subagent-model" }.count, 1)
        XCTAssertEqual(snapshot.rows.filter { $0.model == "main-model" }.count, 2)
    }

    func testMalformedSummariesAreIgnoredAndValidMissingOptionalFieldsDefaultToZero() throws {
        let fixture = try self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        try self.writeJSONLines([
            self.header(id: "session", cwd: "/tmp/project", timestamp: "2026-09-07T10:00:00Z"),
            self.assistantMessage(
                id: "assistant-entry",
                timestamp: "2026-09-07T10:01:00Z",
                input: 1,
                output: 1,
                cost: 0.01),
            [
                "type": "message", "id": "missing-details", "timestamp": "2026-09-07T10:02:00Z",
                "message": ["role": "toolResult", "toolName": "subagent"],
            ],
            self.subagentMessage(
                id: "not-an-array",
                timestamp: "2026-09-07T10:03:00Z",
                resultsValue: "bad"),
            self.subagentMessage(
                id: "missing-usage",
                timestamp: "2026-09-07T10:04:00Z",
                results: [["model": "missing-usage"]]),
            self.subagentMessage(
                id: "bad-number",
                timestamp: "2026-09-07T10:05:00Z",
                results: [self.result(model: "bad-number", input: "bad", output: 1)]),
            self.subagentMessage(
                id: "negative-number",
                timestamp: "2026-09-07T10:06:00Z",
                results: [self.result(model: "negative-number", input: -1, output: 1)]),
            self.subagentMessage(
                id: "incomplete",
                timestamp: "2026-09-07T10:06:30Z",
                results: [self.result(model: "incomplete", input: 50, output: 5, exitCode: -1)]),
            self.subagentMessage(
                id: "valid-defaults",
                timestamp: "2026-09-07T10:07:00Z",
                results: [[
                    "model": "valid-defaults",
                    "usage": ["input": 4, "output": 2],
                ]]),
        ], at: fixture.sessions.appendingPathComponent("malformed.jsonl"))

        let snapshot = try self.fetch(fixture)
        XCTAssertEqual(snapshot.rows.count, 2)
        let row = try XCTUnwrap(snapshot.rows.first { $0.model == "valid-defaults" })
        XCTAssertEqual(row.inputTokens, 4)
        XCTAssertEqual(row.outputTokens, 2)
        XCTAssertEqual(row.cacheReadTokens, 0)
        XCTAssertEqual(row.cacheWriteTokens, 0)
        XCTAssertEqual(row.totalTokens, 6)
        XCTAssertEqual(row.costUSD, 0)
        XCTAssertEqual(row.requestCount, 1)
        XCTAssertNil(snapshot.rows.first { $0.model == "bad-number" })
        XCTAssertNil(snapshot.rows.first { $0.model == "negative-number" })
        XCTAssertNil(snapshot.rows.first { $0.model == "incomplete" })
    }

    func testExtremeSummaryCountersSaturateWithoutOverflow() throws {
        let fixture = try self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        try self.writeJSONLines([
            self.header(id: "session", cwd: "/tmp/project", timestamp: "2026-09-07T10:00:00Z"),
            self.subagentMessage(
                id: "huge-entry",
                timestamp: "2026-09-07T10:01:00Z",
                results: [[
                    "model": "huge-model",
                    "usage": [
                        "input": Int.max,
                        "output": Int.max,
                        "cacheRead": Int.max,
                        "cacheWrite": Int.max,
                        "cost": 1.0,
                        "turns": Int.max,
                        "contextTokens": Int.max,
                    ],
                ]]),
        ], at: fixture.sessions.appendingPathComponent("huge.jsonl"))

        let snapshot = try self.fetch(fixture)
        let summary = PiUsageAggregation.summary(
            rows: snapshot.rows,
            window: .lastThirtyDays,
            now: try self.date("2026-09-07T12:00:00Z"),
            calendar: self.utcCalendar())
        XCTAssertEqual(summary.totalInputTokens, Int.max)
        XCTAssertEqual(summary.totalOutputTokens, Int.max)
        XCTAssertEqual(summary.totalCacheReadTokens, Int.max)
        XCTAssertEqual(summary.totalCacheWriteTokens, Int.max)
        XCTAssertEqual(summary.totalTokens, Int.max)
        XCTAssertEqual(summary.requestCount, Int.max)
    }

    func testLegacyProviderEventFileIsNotCombinedWithSessionRows() throws {
        let fixture = try self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        try self.writeJSONLines([
            self.header(id: "session", cwd: "/tmp/project", timestamp: "2026-09-07T10:00:00Z"),
            self.assistantMessage(
                id: "assistant-entry",
                timestamp: "2026-09-07T10:01:00Z",
                input: 1,
                output: 1,
                cost: 0.01),
        ], at: fixture.sessions.appendingPathComponent("session.jsonl"))
        let eventsFile = fixture.root.appendingPathComponent("pi/agent/telemetry/events.jsonl")
        try FileManager.default.createDirectory(
            at: eventsFile.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try self.writeJSONLines([[
            "type": "provider_call",
            "execution_scope": "subagent",
            "timestamp": "2026-09-07T10:02:00Z",
            "input": 100,
            "output": 100,
            "cost": 99.0,
            "model": "legacy-model",
        ]], at: eventsFile)

        let snapshot = try self.fetch(fixture)
        XCTAssertEqual(snapshot.rows.count, 1)
        XCTAssertNil(snapshot.rows.first { $0.model == "legacy-model" })
    }

    private struct Fixture {
        let root: URL
        let sessions: URL
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("llm-usage-pi-sessions-\(UUID().uuidString)", isDirectory: true)
        let sessions = root.appendingPathComponent("pi/agent/sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        return Fixture(root: root, sessions: sessions)
    }

    private func fetch(_ fixture: Fixture, deduplicateForkHistory: Bool = true) throws -> PiSnapshot {
        try PiSessionsFetcher().fetch(
            sessionsDirectory: fixture.sessions.path,
            deduplicateForkHistory: deduplicateForkHistory)
    }

    private func header(
        id: String,
        cwd: String,
        timestamp: String,
        parentSession: String? = nil
    ) -> [String: Any] {
        var value: [String: Any] = [
            "type": "session",
            "id": id,
            "cwd": cwd,
            "timestamp": timestamp,
        ]
        if let parentSession {
            value["parentSession"] = parentSession
        }
        return value
    }

    private func assistantMessage(
        id: String,
        timestamp: String,
        input: Any,
        output: Any,
        cacheRead: Any = 0,
        cacheWrite: Any = 0,
        cost: Any
    ) -> [String: Any] {
        [
            "type": "message",
            "id": id,
            "timestamp": timestamp,
            "message": [
                "role": "assistant",
                "provider": "provider",
                "model": "main-model",
                "usage": [
                    "input": input,
                    "output": output,
                    "cacheRead": cacheRead,
                    "cacheWrite": cacheWrite,
                    "totalTokens": 0,
                    "cost": ["total": cost],
                ],
            ],
        ]
    }

    private func subagentMessage(
        id: String,
        toolCallID: String = "call",
        timestamp: String,
        mode: String = "single",
        results: [[String: Any]]? = nil,
        resultsValue: Any? = nil
    ) -> [String: Any] {
        var details: [String: Any] = ["mode": mode]
        if let results {
            details["results"] = results
        } else if let resultsValue {
            details["results"] = resultsValue
        }
        return [
            "type": "message",
            "id": id,
            "timestamp": timestamp,
            "message": [
                "role": "toolResult",
                "toolCallId": toolCallID,
                "toolName": "subagent",
                "details": details,
            ],
        ]
    }

    private func result(
        model: String,
        input: Any,
        output: Any,
        cacheRead: Any = 0,
        cacheWrite: Any = 0,
        cost: Any = 0,
        contextTokens: Any? = nil,
        turns: Any? = nil,
        runID: String? = nil,
        exitCode: Any? = nil
    ) -> [String: Any] {
        var usage: [String: Any] = [
            "input": input,
            "output": output,
            "cacheRead": cacheRead,
            "cacheWrite": cacheWrite,
            "cost": cost,
        ]
        if let contextTokens {
            usage["contextTokens"] = contextTokens
        }
        if let turns {
            usage["turns"] = turns
        }
        var value: [String: Any] = ["model": model, "usage": usage]
        if let runID {
            value["subagentRunId"] = runID
        }
        if let exitCode {
            value["exitCode"] = exitCode
        }
        return value
    }

    private func writeJSONLines(_ objects: [[String: Any]], at url: URL) throws {
        let lines = try objects.map { try self.jsonLine($0) }
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func jsonLine(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    private func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func date(_ value: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return try XCTUnwrap(formatter.date(from: value))
    }
}

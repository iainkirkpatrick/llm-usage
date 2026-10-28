import Foundation
import XCTest
@testable import LLMUsageBar

final class ClaudeSessionsFetcherTests: XCTestCase {
    func testScansProjectsAndSubagentsDeduplicatesStreamingAndCopiedMessages() throws {
        let fixture = try Fixture()
        let stamp = "2025-01-02T03:04:05.123Z"
        let early = Self.entry(timestamp: stamp, request: "req-1", messageID: "msg-1", usage: "\"input_tokens\":10,\"output_tokens\":0")
        let final = Self.entry(timestamp: stamp, request: "req-1", messageID: "msg-1", usage: "\"input_tokens\":10,\"output_tokens\":7,\"cache_read_input_tokens\":2")
        try fixture.write("projects/a/session.jsonl", lines: [early, final])
        try fixture.write("projects/a/subagents/child.jsonl", lines: [Self.entry(timestamp: stamp, request: "other", messageID: "other-msg", usage: "\"input_tokens\":3,\"output_tokens\":4")])
        try fixture.write("sessions/ignored.jsonl", lines: [Self.entry(timestamp: stamp, request: "outside", messageID: "outside", usage: "\"input_tokens\":999")])
        // Copies of the same request/message identity collapse to one logical usage.
        try fixture.write("projects/copy.jsonl", lines: [Self.entry(timestamp: stamp, request: "req-1", messageID: "msg-1", usage: "\"input_tokens\":10,\"output_tokens\":6")])

        let result = try ClaudeSessionsFetcher().fetch(profile: fixture.profile, now: Self.date(stamp))
        XCTAssertEqual(result.fileCount, 3)
        XCTAssertEqual(result.rows.count, 2)
        let main = try XCTUnwrap(result.rows.first { $0.inputTokens == 10 })
        XCTAssertEqual(main.outputTokens, 7)
        XCTAssertEqual(main.cacheReadTokens, 2)
    }

    func testDistinctMessagesInTheSameRequestAreNotMerged() throws {
        let fixture = try Fixture()
        let stamp = "2025-01-02T03:04:05Z"
        try fixture.write("projects/session.jsonl", lines: [
            Self.entry(timestamp: stamp, request: "same-request", messageID: "message-a", usage: "\"input_tokens\":3,\"output_tokens\":2"),
            Self.entry(timestamp: stamp, request: "same-request", messageID: "message-b", usage: "\"input_tokens\":4,\"output_tokens\":5"),
        ])
        let result = try ClaudeSessionsFetcher().fetch(profile: fixture.profile, now: Self.date(stamp))
        XCTAssertEqual(result.rows.count, 2)
        XCTAssertEqual(result.rows.map(\.totalTokens).reduce(0, +), 14)
    }

    func testValidatesCountersCacheFallbackFutureAndIncompleteRows() throws {
        let fixture = try Fixture()
        let rows = [
            Self.entry(timestamp: "2025-01-02T03:04:05Z", request: "nested", messageID: "n", usage: "\"input_tokens\":1,\"output_tokens\":2,\"cache_creation\":{\"ephemeral_5m_input_tokens\":3,\"ephemeral_1h_input_tokens\":4}"),
            Self.entry(timestamp: "2025-01-02T03:04:05Z", request: "aggregate", messageID: "a", usage: "\"input_tokens\":1,\"output_tokens\":2,\"cache_creation_input_tokens\":8,\"cache_creation\":{\"ephemeral_5m_input_tokens\":3,\"ephemeral_1h_input_tokens\":4}"),
            Self.entry(timestamp: "2025-01-02T03:04:05Z", request: "bad", messageID: "b", usage: "\"input_tokens\":4,\"output_tokens\":-3,\"cache_read_input_tokens\":1.5,\"cache_creation_input_tokens\":\"nope\""),
            Self.entry(timestamp: "2030-01-02T03:04:05Z", request: "future", messageID: "f", usage: "\"input_tokens\":5,\"output_tokens\":5"),
            Self.entry(timestamp: "2025-01-02T03:04:05Z", request: "partial", messageID: "p", usage: "\"input_tokens\":5", stopReason: "null"),
        ]
        try fixture.write("projects/session.jsonl", lines: rows)
        let result = try ClaudeSessionsFetcher().fetch(profile: fixture.profile, now: Self.date("2025-01-03T00:00:00Z"))
        XCTAssertEqual(result.rows.count, 3)
        let nested = try XCTUnwrap(result.rows.first { $0.cacheWriteTokens == 7 })
        XCTAssertEqual(nested.inputTokens, 1)
        let aggregate = try XCTUnwrap(result.rows.first { $0.cacheWriteTokens == 8 })
        XCTAssertEqual(aggregate.cacheWriteTokens, 8)
        let bad = try XCTUnwrap(result.rows.first { $0.inputTokens == 4 })
        XCTAssertEqual(bad.outputTokens, 0)
        XCTAssertEqual(bad.cacheReadTokens, 0)
    }

    func testMissingProjectsDirectoryIsEmptyUsageForExistingProfile() throws {
        let fixture = try Fixture(createProjects: false)
        let now = Self.date("2025-01-03T00:00:00Z")
        let result = try ClaudeSessionsFetcher().fetch(profile: fixture.profile, now: now)
        XCTAssertTrue(result.rows.isEmpty)
        XCTAssertEqual(result.fileCount, 0)
        XCTAssertEqual(result.unreadableFileCount, 0)
        XCTAssertEqual(result.updatedAt, now)
    }

    func testSymlinkAndNonDirectoryProjectsRemainFailures() throws {
        let fixture = try Fixture(createProjects: false)
        let other = try Fixture()
        try other.write("projects/private.jsonl", lines: [Self.entry(timestamp: "2025-01-02T03:04:05Z", request: "secret", messageID: "secret", usage: "\"input_tokens\":99")])
        try FileManager.default.createSymbolicLink(at: fixture.root.appendingPathComponent("projects"), withDestinationURL: other.root.appendingPathComponent("projects"))
        XCTAssertThrowsError(try ClaudeSessionsFetcher().fetch(profile: fixture.profile))

        try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("projects"))
        try "not a directory".write(to: fixture.root.appendingPathComponent("projects"), atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try ClaudeSessionsFetcher().fetch(profile: fixture.profile))
    }

    func testUnreadableExistingDirectoriesRemainFailures() throws {
        let fixture = try Fixture()
        let projects = fixture.root.appendingPathComponent("projects")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: projects.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: projects.path) }
        guard !FileManager.default.isReadableFile(atPath: projects.path) else {
            throw XCTSkip("This process can bypass filesystem read permissions")
        }
        XCTAssertThrowsError(try ClaudeSessionsFetcher().fetch(profile: fixture.profile))
    }

    func testMissingOrSymlinkedProfileIsNotEmptyUsage() throws {
        let fixture = try Fixture(createProjects: false)
        let missing = ClaudeAccountProfile(label: "missing", configDirectory: fixture.root.appendingPathComponent("missing").path)
        XCTAssertThrowsError(try ClaudeSessionsFetcher().fetch(profile: missing))
        let link = fixture.root.appendingPathComponent("linked-profile")
        let target = try Fixture(createProjects: false)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target.root)
        XCTAssertThrowsError(try ClaudeSessionsFetcher().fetch(profile: ClaudeAccountProfile(label: "link", configDirectory: link.path)))
    }

    func testMalformedProfilePathRemainsFailure() {
        let malformed = ClaudeAccountProfile(label: "bad", configDirectory: "relative/path")
        XCTAssertThrowsError(try ClaudeSessionsFetcher().fetch(profile: malformed))
    }

    func testUnreadableOrMalformedContentDoesNotInventRows() throws {
        let fixture = try Fixture()
        try fixture.write("projects/session.jsonl", lines: ["{broken", Self.entry(timestamp: "2025-01-02T03:04:05Z", request: "ok", messageID: "ok", usage: "\"input_tokens\":2")])
        let result = try ClaudeSessionsFetcher().fetch(profile: fixture.profile, now: Self.date("2025-01-03T00:00:00Z"))
        XCTAssertEqual(result.fileCount, 1)
        XCTAssertEqual(result.rows.count, 1)
        XCTAssertEqual(result.unreadableFileCount, 0)
    }

    private static func entry(timestamp: String, request: String, messageID: String, usage: String, stopReason: String? = "\"end_turn\"") -> String {
        "{\"type\":\"assistant\",\"timestamp\":\"\(timestamp)\",\"requestId\":\"\(request)\",\"message\":{\"id\":\"\(messageID)\",\"role\":\"assistant\",\"model\":\"test\",\"stop_reason\":\(stopReason ?? "\"end_turn\""),\"usage\":{\(usage)}}}"
    }

    private static func date(_ string: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string) ?? ISO8601DateFormatter().date(from: string)!
    }

    private final class Fixture {
        let root: URL
        let profile: ClaudeAccountProfile

        init(createProjects: Bool = true) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            if createProjects { try FileManager.default.createDirectory(at: root.appendingPathComponent("projects"), withIntermediateDirectories: true) }
            profile = ClaudeAccountProfile(label: "fixture", configDirectory: root.path)
        }

        func write(_ relative: String, lines: [String]) throws {
            let url = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        }

        deinit { try? FileManager.default.removeItem(at: root) }
    }
}

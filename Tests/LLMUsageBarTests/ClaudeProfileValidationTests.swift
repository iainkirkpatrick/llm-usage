import Foundation
import XCTest
@testable import LLMUsageBar

final class ClaudeProfileValidationTests: XCTestCase {
    func testRejectsDuplicateRelativeMissingAndSymlinkDirectories() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = ClaudeAccountProfile(label: "First", configDirectory: root.path)
        XCTAssertNoThrow(try ClaudeProfileValidation.validate(profile, among: []))
        XCTAssertThrowsError(try ClaudeProfileValidation.validate(profile, among: [profile]))
        XCTAssertThrowsError(try ClaudeProfileValidation.validate(.init(label: "Relative", configDirectory: "relative"), among: []))
        XCTAssertThrowsError(try ClaudeProfileValidation.validate(.init(label: "Missing", configDirectory: root.appendingPathComponent("missing").path), among: []))
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        XCTAssertThrowsError(try ClaudeProfileValidation.validate(.init(label: "Link", configDirectory: link.path), among: []))
    }

    func testTokenSummariesIncludeCachesExcludeFutureRowsAndSaturate() {
        let now = Date(timeIntervalSince1970: 1000)
        let rows = [
            ClaudeTokenUsage(timeCreated: now, model: "fixture", inputTokens: Int.max, outputTokens: 2, cacheReadTokens: 3, cacheWriteTokens: 4),
            ClaudeTokenUsage(timeCreated: now.addingTimeInterval(1), model: "future", inputTokens: 99, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0),
            ClaudeTokenUsage(timeCreated: now.addingTimeInterval(-100), model: "old", inputTokens: 99, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0),
        ]
        let summary = ClaudeTokenSummary.aggregate(rows: rows, since: now.addingTimeInterval(-10), now: now)
        XCTAssertEqual(summary.requests, 1)
        XCTAssertEqual(summary.inputTokens, Int.max)
        XCTAssertEqual(summary.outputTokens, 2)
        XCTAssertEqual(summary.cacheReadTokens, 3)
        XCTAssertEqual(summary.cacheWriteTokens, 4)
        XCTAssertEqual(summary.totalTokens, Int.max)
    }
}

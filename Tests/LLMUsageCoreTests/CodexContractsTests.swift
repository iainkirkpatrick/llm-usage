import Foundation
import XCTest
@testable import LLMUsageCore

final class CodexContractsTests: XCTestCase {
    func testJSONContractAndISO8601Dates() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = CodexSnapshot(
            session: RateWindow(usedPercent: 58, resetAt: date), weekly: nil,
            creditsRemaining: nil, resetCredits: CodexResetCredits(availableCount: 3, credits: []),
            sourceLabel: "Pi auth", updatedAt: date)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: CodexCLIOutput(snapshot: snapshot).jsonData()) as? [String: Any])
        let codex = try XCTUnwrap(object["codex"] as? [String: Any])
        XCTAssertEqual(Set(codex.keys), ["session", "resetCredits", "source", "updatedAt"])
        let session = try XCTUnwrap(codex["session"] as? [String: Any])
        XCTAssertEqual(Set(session.keys), ["usedPercent", "remainingPercent", "resetAt"])
        XCTAssertEqual(session["remainingPercent"] as? Double, 42)
        XCTAssertNotNil(ISO8601DateFormatter().date(from: try XCTUnwrap(session["resetAt"] as? String)))
        XCTAssertNil(codex["weekly"])
        XCTAssertNil(codex["creditsRemaining"])
    }

    func testWindowClassification() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(CodexWindowClassifier.kind(durationMinutes: 300, resetAt: nil), .session)
        XCTAssertEqual(CodexWindowClassifier.kind(durationMinutes: 10_080, resetAt: nil), .weekly)
        XCTAssertEqual(CodexWindowClassifier.kind(durationMinutes: nil, resetAt: now.addingTimeInterval(25 * 3600), now: now), .weekly)
        XCTAssertEqual(CodexWindowClassifier.kind(durationMinutes: nil, resetAt: nil, now: now), .session)
    }
}

import XCTest
@testable import LLMUsageBar

final class CodexModelsTests: XCTestCase {
    func testNodeDateDecodingSupportsFractionalAndStandardISO8601() {
        XCTAssertNotNil(CodexNodeBridge.iso8601Date(from: "2026-07-19T22:08:28.000Z"))
        XCTAssertNotNil(CodexNodeBridge.iso8601Date(from: "2026-07-19T22:08:28Z"))
        XCTAssertNil(CodexNodeBridge.iso8601Date(from: "not-a-date"))
    }
}

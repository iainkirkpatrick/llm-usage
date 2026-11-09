import XCTest
@testable import LLMUsageBar

final class ClaudeCodeConfigTests: XCTestCase {
    func testCodeUsageSnapshotRetainsOwnerObservationWithoutCreatingVerifiedQuotaIdentity() {
        let identity = ClaudeOwnerAuthObservation(
            email: "owner@example.com",
            organizationID: "22222222-2222-2222-2222-222222222222",
            authMethod: "claude.ai",
            apiProvider: "firstParty")
        let usage = ClaudeCLIUsageReading(
            fiveHour: nil,
            weekly: nil,
            modelWindows: [])
        let capturedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let result = ClaudeOwnerUsageProbeResult(
            ownerReportedIdentity: identity,
            usage: usage,
            capturedAt: capturedAt)

        let snapshot = ClaudeCodeUsageSnapshot(result: result)

        XCTAssertEqual(snapshot.identity, identity)
        XCTAssertEqual(snapshot.capturedAt, capturedAt)
        XCTAssertFalse(result.identityVerifiedForTrackedAccount)
    }
}

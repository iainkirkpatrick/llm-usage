import Foundation
import XCTest
@testable import LLMUsageBar

final class ClaudeDefaultIdentityHintTests: XCTestCase {
    private let account = "11111111-1111-1111-1111-111111111111"
    private let organization = "22222222-2222-2222-2222-222222222222"

    private func makeHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        return home
    }

    private func json(_ account: Any, _ organization: Any) -> Data {
        let value: [String: Any] = ["oauthAccount": ["accountUuid": account, "organizationUuid": organization]]
        return try! JSONSerialization.data(withJSONObject: value)
    }

    private func put(_ data: Data, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    func testParseCanonicalizesUUIDCase() {
        let result = ClaudeDefaultIdentityHint.parse(json(account.uppercased(), organization.uppercased()))
        XCTAssertEqual(result, "\(account):\(organization)")
    }

    func testReadsBothLocationsAndAcceptsOneValidLocation() throws {
        let home = try makeHome()
        let expected = "\(account):\(organization)"
        try put(json(account, organization), at: home.appendingPathComponent(".claude.json"))
        XCTAssertEqual(ClaudeDefaultIdentityHint.read(home: home), expected)

        let newLocation = home.appendingPathComponent(".claude/.claude.json")
        try put(json(account.uppercased(), organization.uppercased()), at: newLocation)
        XCTAssertEqual(ClaudeDefaultIdentityHint.read(home: home), expected)
    }

    func testConflictingValidFilesFailClosed() throws {
        let home = try makeHome()
        try put(json(account, organization), at: home.appendingPathComponent(".claude.json"))
        try put(json("33333333-3333-3333-3333-333333333333", organization), at: home.appendingPathComponent(".claude/.claude.json"))
        XCTAssertNil(ClaudeDefaultIdentityHint.read(home: home))
    }

    func testInvalidEntriesAreIgnoredAndMalformedOtherFileFallsBack() throws {
        XCTAssertNil(ClaudeDefaultIdentityHint.parse(json("not-a-uuid", organization)))
        XCTAssertNil(ClaudeDefaultIdentityHint.parse(json(account, 42)))
        XCTAssertNil(ClaudeDefaultIdentityHint.parse(json(true, organization)))

        let home = try makeHome()
        try put(Data("{broken".utf8), at: home.appendingPathComponent(".claude.json"))
        try put(json(account, organization), at: home.appendingPathComponent(".claude/.claude.json"))
        XCTAssertEqual(ClaudeDefaultIdentityHint.read(home: home), "\(account):\(organization)")
    }

    func testAbsentOversizedAndSymlinkFilesAreIgnored() throws {
        let home = try makeHome()
        XCTAssertNil(ClaudeDefaultIdentityHint.read(home: home))

        try put(Data(repeating: 0x20, count: 1_048_577), at: home.appendingPathComponent(".claude.json"))
        XCTAssertNil(ClaudeDefaultIdentityHint.read(home: home))
        try FileManager.default.removeItem(at: home.appendingPathComponent(".claude.json"))

        let target = home.appendingPathComponent("target.json")
        try put(json(account, organization), at: target)
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent(".claude.json"), withDestinationURL: target)
        XCTAssertNil(ClaudeDefaultIdentityHint.read(home: home))
    }

    func testCanonicalIdentityRequiresExactlyTwoCanonicalUUIDs() {
        XCTAssertEqual(ClaudeDefaultIdentityHint.canonicalIdentity("\(account.uppercased()):\(organization)"), "\(account):\(organization)")
        XCTAssertNil(ClaudeDefaultIdentityHint.canonicalIdentity("\(account):invalid"))
        XCTAssertNil(ClaudeDefaultIdentityHint.canonicalIdentity("\(account):\(organization):extra"))
        XCTAssertNil(ClaudeDefaultIdentityHint.canonicalIdentity(nil))
    }
}

import Foundation
import XCTest
@testable import LLMUsageBar

final class ClaudeCLIUsageParserTests: XCTestCase {
    func testUsedLeftResetAndModelWindow() throws {
        let parsed = try ClaudeCLIUsageParser.parse(screen: """
        Current session
        25% used
        Resets in 4h 20m
        Current week
        70% left
        Resets Monday
        Current week (Sonnet)
        10% used
        Resets in 2d
        """)
        XCTAssertEqual(parsed.fiveHour?.usedPercent, 25)
        XCTAssertEqual(parsed.fiveHour?.resetDescription, "Resets in 4h 20m")
        XCTAssertEqual(parsed.weekly?.usedPercent, 30)
        XCTAssertEqual(parsed.weekly?.resetDescription, "Resets Monday")
        XCTAssertEqual(parsed.modelWindows, [.init(title: "Sonnet", window: .init(usedPercent: 10, resetDescription: "Resets in 2d"))])
    }

    func testMissingWindowsAndInsightsAreNotInterpretedAsUsage() throws {
        XCTAssertNil(try ClaudeCLIUsageParser.parse(screen: "Current week\n50% used").fiveHour)
        XCTAssertThrowsError(try ClaudeCLIUsageParser.parse(screen: "Current session\nNo quota info"))
        XCTAssertThrowsError(try ClaudeCLIUsageParser.parse(screen: "What’s contributing to your limits usage?\nCurrent session\n99% used"))
        XCTAssertThrowsError(try ClaudeCLIUsageParser.parse(screen: "Current week (Opus)\n20% used"))
    }

    func testRejectsLoadingMalformedOutOfRangeAndConflicts() {
        for input in ["Loading…\nCurrent session\n10% used", "Refreshing\nCurrent week\n10% used",
                      "Current session\nhello 10%", "Current session\n101% used",
                      "Current session\n10% used\n20% used"] {
            XCTAssertThrowsError(try ClaudeCLIUsageParser.parse(screen: input), input)
        }
    }

    func testCurrentWeekAllModelsIsWeekly() throws {
        XCTAssertEqual(try ClaudeCLIUsageParser.parse(screen: "Current week (all models)\n20% used").weekly?.usedPercent, 20)
    }

    func testConflictingDuplicateHeadersAreRejected() {
        XCTAssertThrowsError(try ClaudeCLIUsageParser.parse(screen: "Current session\n10% used\nCurrent session\n20% used"))
    }

    func testInsightsHeadingIgnoresCaseWhitespaceCurlyQuoteAndSuffix() {
        let parsed = try! ClaudeCLIUsageParser.parse(screen: "Current session\n10% used\n WHAT’S   CONTRIBUTING TO YOUR LIMITS USAGE? later\nCurrent session\n90% used")
        XCTAssertEqual(parsed.fiveHour?.usedPercent, 10)
    }

    func testCurrentCLIInsightsHeadingCannotContributeQuota() throws {
        let reading = try ClaudeCLIUsageParser.parse(screen: "Current week (all models)\n19% used\nWhat's contributing to your usage?\nMCP servers % of usage\nCurrent session\n99% used")
        XCTAssertNil(reading.fiveHour)
        XCTAssertEqual(reading.weekly?.usedPercent, 19)
    }

    func testExplicitErrorInvalidatesPriorQuota() {
        XCTAssertThrowsError(try ClaudeCLIUsageParser.parse(screen: "Current session\n10% used\nError: Failed to load usage data"))
    }

    func testLoadingAndExplicitErrorRemainDistinct() {
        XCTAssertThrowsError(try ClaudeCLIUsageParser.parse(screen: "Loading…\nCurrent session\n10% used")) { XCTAssertEqual($0 as? ClaudeCLIUsageParserError, .loading) }
        XCTAssertThrowsError(try ClaudeCLIUsageParser.parse(screen: "Error: Failed to load usage data")) { XCTAssertEqual($0 as? ClaudeCLIUsageParserError, .unavailable) }
    }

    func testParserBoundsInputAndModelTitles() {
        XCTAssertThrowsError(try ClaudeCLIUsageParser.parse(screen: String(repeating: "x", count: 1_000_001)))
        XCTAssertThrowsError(try ClaudeCLIUsageParser.parse(screen: "Current week (\(String(repeating: "x", count: 201)))\n10% used"))
    }

    func testTerminalAutowrapAndScroll() {
        var screen = ClaudeCLITerminalScreen(columns: 4, rows: 2)
        screen.append(Data("abcdefgh".utf8))
        XCTAssertEqual(screen.text, "abcd\nefgh")
        screen.append(Data("\n\rij".utf8))
        XCTAssertEqual(screen.text, "efgh\nij")
    }

    func testTerminalCSIEmptyFieldsUseDefaults() {
        var screen = ClaudeCLITerminalScreen(columns: 12, rows: 4)
        screen.append(Data("abc\u{001B}[;4H!".utf8))
        XCTAssertTrue(screen.text.contains("abc!"))
    }

    func testTerminalHugeCSIParametersDoNotOverflow() {
        var screen = ClaudeCLITerminalScreen(columns: 12, rows: 4)
        screen.append(Data("x\u{001B}[999999999999999999999Cz".utf8))
        XCTAssertTrue(screen.text.contains("z"))
    }

    func testTerminalSupportsColumnRowAndLineMovement() {
        var screen = ClaudeCLITerminalScreen(columns: 12, rows: 5)
        screen.append(Data("\u{001B}[3Gx\u{001B}[3dy\u{001B}[Ez\u{001B}[Fa".utf8))
        XCTAssertTrue(screen.text.contains("x"))
        XCTAssertTrue(screen.text.contains("y"))
        XCTAssertTrue(screen.text.contains("z"))
    }

    func testTerminalSaveRestoreCursor() {
        var screen = ClaudeCLITerminalScreen(columns: 12, rows: 3)
        screen.append(Data("ab\u{001B}7\u{001B}[3;3Hxx\u{001B}8Z".utf8))
        XCTAssertTrue(screen.text.hasPrefix("abZ"))
    }

    func testTerminalUnsupportedCSIInvalidatesOldDisplay() {
        var screen = ClaudeCLITerminalScreen(columns: 12, rows: 3)
        screen.append(Data("old\u{001B}[?1049hnew".utf8))
        XCTAssertFalse(screen.text.contains("old"))
    }

    func testTerminalResetAndMalformedCursorCannotRetainOldQuotaOrCrash() {
        for operation in ["\u{001B}c", "\u{001B}[-1B\u{001B}[2K", "\u{001B}[-999;0H\u{001B}[2K"] {
            var screen = ClaudeCLITerminalScreen()
            screen.append(Data("Current session\r\n42% used".utf8))
            screen.append(Data(operation.utf8))
            XCTAssertThrowsError(try ClaudeCLIUsageParser.parse(screen: screen.text))
        }
    }

    func testCursorVisibilityAndBracketedPasteDoNotEraseUsage() throws {
        var screen = ClaudeCLITerminalScreen()
        screen.append(Data("\u{001B}[?25lCurrent session\r\n42% used\u{001B}[?25h\u{001B}[?2004h\u{001B}[?2026l".utf8))
        XCTAssertEqual(try ClaudeCLIUsageParser.parse(screen: screen.text).fiveHour?.usedPercent, 42)
    }

    func testKeyboardProtocolAndTerminalQueriesDoNotEraseQuotaRows() throws {
        var screen = ClaudeCLITerminalScreen()
        screen.append(Data("Current session\r\n42% used\u{001B}[<u\u{001B}[>5u\u{001B}[>0q\u{001B}[6n\u{001B}[c\u{001B}[2 q".utf8))
        XCTAssertEqual(try ClaudeCLIUsageParser.parse(screen: screen.text).fiveHour?.usedPercent, 42)
    }

    func testWideCharactersAndCombiningMarksRespectCursorColumns() {
        var screen = ClaudeCLITerminalScreen(columns: 20, rows: 2)
        screen.append(Data("界e\u{0301}x\u{001B}[4G!".utf8))
        XCTAssertTrue(screen.text.hasPrefix("界e\u{0301}!"))
        screen.append(Data("\u{001B}[2G\u{001B}[K".utf8))
        XCTAssertFalse(screen.text.contains("界"), "Erasing a wide glyph's continuation clears the whole glyph")
    }

    func testSeededLastKnownUsageCannotBecomeAFreshMeasurement() {
        for notice in ["Showing last-known usage as of yesterday", "Could not refresh usage data"] {
            XCTAssertThrowsError(try ClaudeCLIUsageParser.parse(screen: "Current session\n10% used\n\(notice)")) {
                XCTAssertEqual($0 as? ClaudeCLIUsageParserError, .unavailable)
            }
        }
    }

    func testTerminalUTF8DoesNotDisplaceFollowingASCIILabel() {
        var screen = ClaudeCLITerminalScreen(columns: 30, rows: 3)
        screen.append(Data("éCurrent session".utf8))
        XCTAssertTrue(screen.text.contains("éCurrent session"))
    }

    func testTerminalRedrawEraseAndUTF8Chunks() {
        var screen = ClaudeCLITerminalScreen(columns: 40, rows: 8)
        screen.append(Data("Current session\r\u{001B}[2KCurrent week\n80% ".utf8))
        let bytes = Array("é used".utf8)
        screen.append(Data(bytes.prefix(1)))
        screen.append(Data(bytes.dropFirst()))
        XCTAssertTrue(screen.text.contains("Current week"))
        XCTAssertTrue(screen.text.contains("80% é used"))
        var redraw = ClaudeCLITerminalScreen(columns: 30, rows: 4)
        redraw.append(Data("old\u{001B}[1;1Hnew\u{001B}[K".utf8))
        XCTAssertTrue(redraw.text.hasPrefix("new"))
        XCTAssertFalse(redraw.text.contains("old"))
    }
}

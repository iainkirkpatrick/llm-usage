import Foundation
import XCTest
@testable import LLMUsageBar

final class PiUsageAggregationTests: XCTestCase {
    func testLastNinetyDaysUsesInclusiveLocalCalendarBoundaryAndExcludesFutureRows() throws {
        let calendar = self.calendar(timeZoneSecondsFromGMT: 0)
        let now = try self.date("2026-09-07T12:00:00Z")
        let today = calendar.startOfDay(for: now)
        let firstDay = try XCTUnwrap(calendar.date(byAdding: .day, value: -89, to: today))
        let rows = [
            self.row(at: firstDay.addingTimeInterval(-1)),
            self.row(at: firstDay),
            self.row(at: firstDay.addingTimeInterval(1)),
            self.row(at: now),
            self.row(at: now.addingTimeInterval(1)),
        ]

        let summary = PiUsageAggregation.summary(
            rows: rows,
            window: .lastNinetyDays,
            now: now,
            calendar: calendar)

        XCTAssertEqual(PiUsageWindow.lastNinetyDays.title, "Last 90d")
        XCTAssertEqual(summary.requestCount, 3)
        XCTAssertEqual(summary.totalCostUSD, 3, accuracy: 0.000001)
    }

    func testLastNinetyDaysMatchesChartAcrossDSTCalendarBoundary() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let now = try self.date("2026-11-02T12:00:00-08:00")
        let today = calendar.startOfDay(for: now)
        let firstDay = try XCTUnwrap(calendar.date(byAdding: .day, value: -89, to: today))
        let fixedDurationCutoff = now.addingTimeInterval(-90 * 24 * 60 * 60)
        XCTAssertLessThan(calendar.startOfDay(for: fixedDurationCutoff), firstDay)

        let rows = [
            self.row(at: fixedDurationCutoff, input: 100),
            self.row(at: firstDay, input: 2, output: 3),
            self.row(at: now, input: 4, output: 5),
            self.row(at: now.addingTimeInterval(1), input: 100),
        ]
        let summary = PiUsageAggregation.summary(
            rows: rows,
            window: .lastNinetyDays,
            now: now,
            calendar: calendar)
        let buckets = PiUsageAggregation.dailyTokenUsage(rows: rows, now: now, calendar: calendar)

        XCTAssertEqual(summary.requestCount, 2)
        XCTAssertEqual(summary.totalTokens, 14)
        XCTAssertEqual(summary.totalTokens, buckets.reduce(0) { $0 + $1.totalTokens })
        XCTAssertEqual(buckets.first?.totalTokens, 5)
        XCTAssertEqual(buckets.last?.totalTokens, 9)
    }

    func testSummarySaturatesNegativeAndOverflowingTokenComponents() throws {
        let calendar = self.calendar(timeZoneSecondsFromGMT: 0)
        let now = try self.date("2026-09-07T12:00:00Z")
        let rows = [
            self.row(
                at: now,
                input: Int.max,
                output: Int.max,
                cacheRead: Int.max,
                cacheWrite: Int.max,
                totalTokens: 0),
            self.row(
                at: now,
                input: Int.min,
                output: -1,
                cacheRead: -2,
                cacheWrite: -3,
                totalTokens: 0),
        ]

        let summary = PiUsageAggregation.summary(
            rows: rows,
            window: .today,
            now: now,
            calendar: calendar)

        XCTAssertEqual(summary.totalInputTokens, Int.max)
        XCTAssertEqual(summary.totalOutputTokens, Int.max)
        XCTAssertEqual(summary.totalCacheReadTokens, Int.max)
        XCTAssertEqual(summary.totalCacheWriteTokens, Int.max)
        XCTAssertEqual(summary.totalTokens, Int.max)
        XCTAssertEqual(Formatting.tokens(summary.totalTokens), Formatting.tokens(Int.max))
    }

    func testDailyTokenUsageReturnsNinetyBucketsWithZeroDaysAndAllTokenComponents() throws {
        let calendar = self.calendar(timeZoneSecondsFromGMT: 0)
        let now = try self.date("2026-09-07T12:00:00Z")
        let today = calendar.startOfDay(for: now)
        let firstDay = try XCTUnwrap(calendar.date(byAdding: .day, value: -89, to: today))
        let twoDaysAgo = try XCTUnwrap(calendar.date(byAdding: .day, value: -2, to: today))

        let rows = [
            self.row(at: firstDay, input: 10, output: 20, cacheRead: 30, cacheWrite: 40, totalTokens: 1),
            self.row(at: twoDaysAgo, input: 1, output: 2, cacheRead: 3, cacheWrite: 4, totalTokens: 1),
            self.row(at: now, input: 7, output: 8, cacheRead: 9, cacheWrite: 10, totalTokens: 1),
        ]
        let buckets = PiUsageAggregation.dailyTokenUsage(rows: rows, now: now, calendar: calendar)

        XCTAssertEqual(buckets.count, 90)
        XCTAssertEqual(buckets.first?.day, firstDay)
        XCTAssertEqual(buckets.last?.day, today)
        XCTAssertEqual(buckets.first?.totalTokens, 100)
        XCTAssertEqual(buckets[1].totalTokens, 0)
        XCTAssertEqual(buckets[87].totalTokens, 10)
        XCTAssertEqual(buckets.last?.totalTokens, 34)
    }

    func testDailyTokenUsageUsesLocalCalendarDayBoundaries() throws {
        let calendar = self.calendar(timeZoneSecondsFromGMT: -8 * 60 * 60)
        let now = try self.date("2026-01-15T00:30:00-08:00")
        let beforeMidnight = try self.date("2026-01-14T23:59:59-08:00")
        let atMidnight = try self.date("2026-01-15T00:00:00-08:00")
        let buckets = PiUsageAggregation.dailyTokenUsage(
            rows: [
                self.row(at: beforeMidnight, input: 2, output: 0, totalTokens: 0),
                self.row(at: atMidnight, input: 3, output: 0, totalTokens: 0),
            ],
            now: now,
            calendar: calendar)

        XCTAssertEqual(buckets.count, 90)
        XCTAssertEqual(buckets[88].totalTokens, 2)
        XCTAssertEqual(buckets[89].totalTokens, 3)
        XCTAssertEqual(calendar.component(.day, from: buckets[88].day), 14)
        XCTAssertEqual(calendar.component(.day, from: buckets[89].day), 15)
    }

    func testDailyTokenUsageRepresentsEveryDayWhenThereIsNoUsage() throws {
        let calendar = self.calendar(timeZoneSecondsFromGMT: 0)
        let now = try self.date("2026-09-07T12:00:00Z")
        let buckets = PiUsageAggregation.dailyTokenUsage(rows: [], now: now, calendar: calendar)

        XCTAssertEqual(buckets.count, 90)
        XCTAssertTrue(buckets.allSatisfy { $0.totalTokens == 0 })
    }

    func testDailyTokenUsageExcludesOlderAndFutureRows() throws {
        let calendar = self.calendar(timeZoneSecondsFromGMT: 0)
        let now = try self.date("2026-09-07T12:00:00Z")
        let today = calendar.startOfDay(for: now)
        let firstDay = try XCTUnwrap(calendar.date(byAdding: .day, value: -89, to: today))
        let older = firstDay.addingTimeInterval(-1)
        let futureToday = now.addingTimeInterval(1)
        let futureTomorrow = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: today))

        let buckets = PiUsageAggregation.dailyTokenUsage(
            rows: [
                self.row(at: older, input: 100),
                self.row(at: firstDay, input: 4, output: 0),
                self.row(at: futureToday, input: 200),
                self.row(at: futureTomorrow, input: 300),
            ],
            now: now,
            calendar: calendar)

        XCTAssertEqual(buckets.reduce(0) { $0 + $1.totalTokens }, 4)
        XCTAssertEqual(buckets.first?.totalTokens, 4)
        XCTAssertEqual(buckets.last?.totalTokens, 0)
    }

    private func row(
        at date: Date,
        input: Int = 1,
        output: Int = 1,
        cacheRead: Int = 0,
        cacheWrite: Int = 0,
        totalTokens: Int? = nil
    ) -> PiUsageRow {
        PiUsageRow(
            timeCreated: date,
            sessionFile: "session.jsonl",
            sessionID: "session",
            cwd: "/tmp/project",
            provider: "provider",
            model: "model",
            inputTokens: input,
            outputTokens: output,
            cacheReadTokens: cacheRead,
            cacheWriteTokens: cacheWrite,
            totalTokens: totalTokens ?? input + output + cacheRead + cacheWrite,
            costUSD: 1)
    }

    private func calendar(timeZoneSecondsFromGMT: Int) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: timeZoneSecondsFromGMT)!
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

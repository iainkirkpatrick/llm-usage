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

    func testSummaryAndGroupsUsePerRowRequestContributionsWithSaturation() throws {
        let calendar = self.calendar(timeZoneSecondsFromGMT: 0)
        let now = try self.date("2026-09-07T12:00:00Z")
        let rows = [
            self.row(at: now, input: 1, output: 2, requestCount: 1),
            self.row(at: now, input: 3, output: 4, requestCount: 3),
            self.row(at: now, input: Int.max, output: 0, requestCount: Int.max),
        ]

        let summary = PiUsageAggregation.summary(rows: rows, window: .today, now: now, calendar: calendar)
        let groups = PiUsageAggregation.groupByModel(rows: rows, window: .today, now: now, calendar: calendar)

        XCTAssertEqual(summary.requestCount, Int.max)
        XCTAssertEqual(summary.totalInputTokens, Int.max)
        XCTAssertEqual(summary.totalOutputTokens, 6)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].requestCount, Int.max)
        XCTAssertEqual(groups[0].totalInputTokens, Int.max)
        XCTAssertEqual(groups[0].totalOutputTokens, 6)
        XCTAssertEqual(groups[0].totalTokens, Int.max)
        XCTAssertEqual(PiUsageAggregation.requestCount(rows: rows), Int.max)
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

    func testChartDatasetsUseSelectableRangeBoundariesAndZeroFill() throws {
        let calendar = self.calendar(timeZoneSecondsFromGMT: 0)
        let now = try self.date("2026-09-07T12:00:00Z")
        let today = calendar.startOfDay(for: now)
        let sixMonthStart = try XCTUnwrap(calendar.date(byAdding: .month, value: -6, to: today))
        let oneYearStart = try XCTUnwrap(calendar.date(byAdding: .year, value: -1, to: today))
        let ninetyDayStart = try XCTUnwrap(calendar.date(byAdding: .day, value: -89, to: today))
        let rows = [
            self.row(at: ninetyDayStart, input: 3, output: 0),
            self.row(at: sixMonthStart, input: 5, output: 0),
            self.row(at: oneYearStart, input: 7, output: 0),
            self.row(at: now, input: 11, output: 0),
        ]

        let datasets = PiUsageAggregation.chartDatasets(rows: rows, now: now, calendar: calendar)
        let ninetyDays = try XCTUnwrap(datasets[.ninetyDays])
        let sixMonths = try XCTUnwrap(datasets[.sixMonths])
        let oneYear = try XCTUnwrap(datasets[.oneYear])

        XCTAssertEqual(ninetyDays.rangeKey, "90d")
        XCTAssertEqual(ninetyDays.title, "90d")
        XCTAssertEqual(ninetyDays.unitLabel, "day")
        XCTAssertEqual(ninetyDays.buckets.count, 90)
        XCTAssertEqual(ninetyDays.buckets.first?.startDate, ninetyDayStart)
        XCTAssertEqual(ninetyDays.buckets.last?.endDate, today)
        XCTAssertEqual(ninetyDays.buckets.first?.totalTokens, 3)
        XCTAssertEqual(ninetyDays.buckets[1].totalTokens, 0)
        XCTAssertEqual(ninetyDays.buckets.last?.totalTokens, 11)

        XCTAssertEqual(sixMonths.unitLabel, "day")
        XCTAssertEqual(sixMonths.buckets.first?.startDate, sixMonthStart)
        XCTAssertEqual(sixMonths.buckets.last?.endDate, today)
        XCTAssertEqual(sixMonths.buckets.first?.totalTokens, 5)
        XCTAssertTrue(sixMonths.buckets.dropFirst().dropLast().contains { $0.totalTokens == 0 })

        XCTAssertEqual(oneYear.rangeKey, "1y")
        XCTAssertEqual(oneYear.title, "1y")
        XCTAssertEqual(oneYear.unitLabel, "week")
        XCTAssertEqual(oneYear.buckets.first?.startDate, oneYearStart)
        XCTAssertEqual(oneYear.buckets.last?.endDate, today)
        XCTAssertEqual(oneYear.buckets.first?.totalTokens, 7)
        XCTAssertEqual(oneYear.buckets.last?.totalTokens, 11)
        XCTAssertEqual(oneYear.buckets.count, 53)
        for pair in zip(oneYear.buckets, oneYear.buckets.dropFirst()) {
            let expectedNextStart = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: pair.0.endDate))
            XCTAssertEqual(pair.1.startDate, expectedNextStart)
        }
    }

    func testSixMonthsUsesCalendarMonthBoundaryAtMonthEnd() throws {
        let calendar = self.calendar(timeZoneSecondsFromGMT: 0)
        let now = try self.date("2024-08-31T12:00:00Z")
        let today = calendar.startOfDay(for: now)
        let sixMonthStart = try XCTUnwrap(calendar.date(byAdding: .month, value: -6, to: today))
        let dayBeforeStart = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: sixMonthStart))
        let datasets = PiUsageAggregation.chartDatasets(
            rows: [
                self.row(at: dayBeforeStart, input: 100, output: 0),
                self.row(at: sixMonthStart, input: 2, output: 0),
                self.row(at: now, input: 3, output: 0),
            ],
            now: now,
            calendar: calendar)

        let sixMonths = try XCTUnwrap(datasets[.sixMonths])
        XCTAssertEqual(sixMonthStart, try XCTUnwrap(calendar.date(from: DateComponents(year: 2024, month: 2, day: 29))))
        XCTAssertEqual(sixMonths.buckets.count, 185)
        XCTAssertEqual(sixMonths.buckets.first?.startDate, sixMonthStart)
        XCTAssertEqual(sixMonths.buckets.first?.totalTokens, 2)
        XCTAssertEqual(sixMonths.buckets.last?.endDate, today)
        XCTAssertEqual(sixMonths.buckets.last?.totalTokens, 3)
    }

    func testChartDatasetsExcludeFutureRowsBeforeFindingAllTimeStart() throws {
        let calendar = self.calendar(timeZoneSecondsFromGMT: 0)
        let now = try self.date("2026-09-07T12:00:00Z")
        let today = calendar.startOfDay(for: now)
        let eligibleDay = try XCTUnwrap(calendar.date(byAdding: .day, value: -3, to: today))
        let futureToday = now.addingTimeInterval(1)
        let futureTomorrow = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: today))
        let datasets = PiUsageAggregation.chartDatasets(
            rows: [
                self.row(at: eligibleDay, input: 4, output: 0),
                self.row(at: futureToday, input: 100, output: 0),
                self.row(at: futureTomorrow, input: 200, output: 0),
            ],
            now: now,
            calendar: calendar)

        let all = try XCTUnwrap(datasets[.all])
        XCTAssertEqual(all.buckets.first?.startDate, eligibleDay)
        XCTAssertEqual(all.buckets.last?.endDate, today)
        XCTAssertEqual(all.buckets.reduce(0) { $0 + $1.totalTokens }, 4)
        XCTAssertEqual(all.buckets.first?.totalTokens, 4)

        let empty = PiUsageAggregation.chartDatasets(
            rows: [self.row(at: futureToday, input: 100, output: 0)],
            now: now,
            calendar: calendar)
        XCTAssertTrue(try XCTUnwrap(empty[.all]).buckets.isEmpty)
    }

    func testOneYearAndAllWeeklyBucketsHaveInclusiveSevenDayRangesAndPartialFinalBucket() throws {
        let calendar = self.calendar(timeZoneSecondsFromGMT: 0)
        let now = try self.date("2026-09-07T12:00:00Z")
        let today = calendar.startOfDay(for: now)
        let allStart = try XCTUnwrap(calendar.date(byAdding: .day, value: -20, to: today))
        let datasets = PiUsageAggregation.chartDatasets(
            rows: [self.row(at: allStart, input: 2, output: 0)],
            now: now,
            calendar: calendar)

        let oneYear = try XCTUnwrap(datasets[.oneYear])
        for bucket in oneYear.buckets.dropLast() {
            let expectedEnd = try XCTUnwrap(calendar.date(byAdding: .day, value: 6, to: bucket.startDate))
            XCTAssertEqual(bucket.endDate, expectedEnd)
        }
        XCTAssertEqual(oneYear.buckets.last?.endDate, today)

        let all = try XCTUnwrap(datasets[.all])
        XCTAssertEqual(all.unitLabel, "week")
        XCTAssertEqual(all.buckets.count, 3)
        XCTAssertEqual(all.buckets[0].startDate, allStart)
        XCTAssertEqual(all.buckets[0].endDate, try XCTUnwrap(calendar.date(byAdding: .day, value: -14, to: today)))
        XCTAssertEqual(all.buckets[1].startDate, try XCTUnwrap(calendar.date(byAdding: .day, value: -13, to: today)))
        XCTAssertEqual(all.buckets[1].endDate, try XCTUnwrap(calendar.date(byAdding: .day, value: -7, to: today)))
        XCTAssertEqual(all.buckets[2].startDate, try XCTUnwrap(calendar.date(byAdding: .day, value: -6, to: today)))
        XCTAssertEqual(all.buckets[2].endDate, today)
    }

    func testAllSwitchesFromWeeklyToCalendarMonthsAtDocumentedThreshold() throws {
        let calendar = self.calendar(timeZoneSecondsFromGMT: 0)
        let now = try self.date("2026-09-07T12:00:00Z")
        let today = calendar.startOfDay(for: now)
        let weeklyStart = try XCTUnwrap(calendar.date(
            byAdding: .day,
            value: -(PiUsageAggregation.allWeeklyBucketThreshold * 7 - 1),
            to: today))
        let monthlyStart = try XCTUnwrap(calendar.date(
            byAdding: .day,
            value: -((PiUsageAggregation.allWeeklyBucketThreshold + 1) * 7 - 1),
            to: today))

        let weekly = try XCTUnwrap(PiUsageAggregation.chartDatasets(
            rows: [self.row(at: weeklyStart, input: 1, output: 0)],
            now: now,
            calendar: calendar)[.all])
        XCTAssertEqual(weekly.unitLabel, "week")
        XCTAssertEqual(weekly.buckets.count, PiUsageAggregation.allWeeklyBucketThreshold)
        XCTAssertEqual(weekly.buckets.first?.startDate, weeklyStart)
        XCTAssertEqual(weekly.buckets.last?.endDate, today)

        let monthly = try XCTUnwrap(PiUsageAggregation.chartDatasets(
            rows: [self.row(at: monthlyStart, input: 2, output: 0)],
            now: now,
            calendar: calendar)[.all])
        XCTAssertEqual(monthly.unitLabel, "month")
        XCTAssertLessThan(monthly.buckets.count, PiUsageAggregation.allWeeklyBucketThreshold)
        XCTAssertEqual(monthly.buckets.first?.startDate, monthlyStart)
        XCTAssertEqual(monthly.buckets.last?.endDate, today)
        XCTAssertEqual(monthly.buckets.first?.totalTokens, 2)
        XCTAssertTrue(monthly.buckets.dropFirst().dropLast().contains { $0.totalTokens == 0 })
        for pair in zip(monthly.buckets, monthly.buckets.dropFirst()) {
            let expectedNextStart = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: pair.0.endDate))
            XCTAssertEqual(pair.1.startDate, expectedNextStart)
        }
    }

    func testChartDatasetsFollowLocalCalendarAcrossDST() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let now = try self.date("2026-11-02T12:00:00-08:00")
        let today = calendar.startOfDay(for: now)
        let sixMonthStart = try XCTUnwrap(calendar.date(byAdding: .month, value: -6, to: today))
        let datasets = PiUsageAggregation.chartDatasets(
            rows: [
                self.row(at: sixMonthStart, input: 3, output: 0),
                self.row(at: today, input: 5, output: 0),
            ],
            now: now,
            calendar: calendar)

        let sixMonths = try XCTUnwrap(datasets[.sixMonths])
        XCTAssertEqual(sixMonths.buckets.first?.startDate, sixMonthStart)
        XCTAssertEqual(sixMonths.buckets.count, 185)
        XCTAssertEqual(sixMonths.buckets.last?.startDate, today)
        for pair in zip(sixMonths.buckets, sixMonths.buckets.dropFirst()) {
            let expectedNext = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: pair.0.startDate))
            XCTAssertEqual(pair.1.startDate, expectedNext)
        }

        let oneYear = try XCTUnwrap(datasets[.oneYear])
        for bucket in oneYear.buckets.dropLast() {
            let expectedEnd = try XCTUnwrap(calendar.date(byAdding: .day, value: 6, to: bucket.startDate))
            XCTAssertEqual(bucket.endDate, expectedEnd)
        }
    }

    func testChartBucketSumsSaturateNegativeAndOverflowingTokens() throws {
        let calendar = self.calendar(timeZoneSecondsFromGMT: 0)
        let now = try self.date("2026-09-07T12:00:00Z")
        let datasets = PiUsageAggregation.chartDatasets(
            rows: [
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
            ],
            now: now,
            calendar: calendar)

        let ninetyDays = try XCTUnwrap(datasets[.ninetyDays])
        XCTAssertEqual(ninetyDays.buckets.last?.totalTokens, Int.max)
        XCTAssertEqual(ninetyDays.buckets.reduce(0) { $0 + $1.totalTokens }, Int.max)
        let oneYear = try XCTUnwrap(datasets[.oneYear])
        XCTAssertEqual(oneYear.buckets.last?.totalTokens, Int.max)
    }

    private func row(
        at date: Date,
        input: Int = 1,
        output: Int = 1,
        cacheRead: Int = 0,
        cacheWrite: Int = 0,
        totalTokens: Int? = nil,
        requestCount: Int = 1
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
            costUSD: 1,
            requestCount: requestCount)
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

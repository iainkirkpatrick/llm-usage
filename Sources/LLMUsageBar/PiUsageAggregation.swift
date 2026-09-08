import Foundation

enum PiUsageWindow {
    case today
    case lastSevenDays
    case lastThirtyDays
    case lastNinetyDays

    var title: String {
        switch self {
        case .today: "Today"
        case .lastSevenDays: "Last 7d"
        case .lastThirtyDays: "Last 30d"
        case .lastNinetyDays: "Last 90d"
        }
    }
}

/// Compatibility model for callers that only need the original fixed daily chart.
/// New chart code should use `PiChartBucket` and `PiChartDataset`.
struct PiDailyUsageBucket: Sendable, Equatable {
    let day: Date
    let totalTokens: Int
}

enum PiUsageAggregation {
    /// The fixed summary-card/chart window remains 90 local calendar days.
    static let ninetyDayChartDayCount = 90
    /// Kept for source compatibility with the original daily-chart API.
    static let dailyChartDayCount = Self.ninetyDayChartDayCount

    /// All-time history stays weekly through 104 buckets (roughly two years at
    /// seven days per bucket). Older history switches to calendar-month buckets
    /// so the menu chart does not become a dense strip of unreadable bars.
    static let allWeeklyBucketThreshold = 104

    static func summary(
        rows: [PiUsageRow],
        window: PiUsageWindow,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> PiSummary {
        let filtered = self.filteredRows(rows: rows, window: window, now: now, calendar: calendar)

        return PiSummary(
            requestCount: self.requestSum(filtered),
            totalCostUSD: PiTokenTotals.saturatedNonnegativeCostSum(filtered.map(\.costUSD)),
            totalInputTokens: self.tokenSum(filtered, keyPath: \.inputTokens),
            totalOutputTokens: self.tokenSum(filtered, keyPath: \.outputTokens),
            totalCacheReadTokens: self.tokenSum(filtered, keyPath: \.cacheReadTokens),
            totalCacheWriteTokens: self.tokenSum(filtered, keyPath: \.cacheWriteTokens)
        )
    }

    /// Builds every selectable chart range from one immutable row snapshot.
    /// Dates in the returned buckets are local start-of-day values and their end
    /// dates are inclusive. Future rows are excluded before any bucket is made.
    static func chartDatasets(
        rows: [PiUsageRow],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [PiChartRange: PiChartDataset] {
        let today = calendar.startOfDay(for: now)
        let eligibleRows = rows.filter { $0.timeCreated <= now }
        let totalsByDay = self.tokenTotalsByDay(
            rows: eligibleRows,
            calendar: calendar)

        let ninetyStart = calendar.startOfDay(for: calendar.date(
            byAdding: .day,
            value: -(Self.ninetyDayChartDayCount - 1),
            to: today) ?? today)
        let sixMonthStart = calendar.startOfDay(for: calendar.date(
            byAdding: .month,
            value: -6,
            to: today) ?? today)
        let oneYearStart = calendar.startOfDay(for: calendar.date(
            byAdding: .year,
            value: -1,
            to: today) ?? today)

        var datasets: [PiChartRange: PiChartDataset] = [
            .ninetyDays: PiChartDataset(
                range: .ninetyDays,
                unitLabel: "day",
                buckets: self.dailyBuckets(
                    from: ninetyStart,
                    through: today,
                    totalsByDay: totalsByDay,
                    calendar: calendar)),
            .sixMonths: PiChartDataset(
                range: .sixMonths,
                unitLabel: "day",
                buckets: self.dailyBuckets(
                    from: sixMonthStart,
                    through: today,
                    totalsByDay: totalsByDay,
                    calendar: calendar)),
            .oneYear: PiChartDataset(
                range: .oneYear,
                unitLabel: "week",
                buckets: self.weeklyBuckets(
                    from: oneYearStart,
                    through: today,
                    totalsByDay: totalsByDay,
                    calendar: calendar)),
        ]

        guard let earliestEligibleDay = eligibleRows
            .map({ calendar.startOfDay(for: $0.timeCreated) })
            .filter({ $0 <= today })
            .min()
        else {
            // There is no meaningful all-time start without an eligible row. The
            // fixed ranges still contain zero-filled buckets; All is empty.
            datasets[.all] = PiChartDataset(
                range: .all,
                unitLabel: "week",
                buckets: [])
            return datasets
        }

        let weeklyCount = self.weeklyBucketCount(
            from: earliestEligibleDay,
            through: today,
            calendar: calendar)
        if weeklyCount <= Self.allWeeklyBucketThreshold {
            datasets[.all] = PiChartDataset(
                range: .all,
                unitLabel: "week",
                buckets: self.weeklyBuckets(
                    from: earliestEligibleDay,
                    through: today,
                    totalsByDay: totalsByDay,
                    calendar: calendar))
        } else {
            datasets[.all] = PiChartDataset(
                range: .all,
                unitLabel: "month",
                buckets: self.monthlyBuckets(
                    from: earliestEligibleDay,
                    through: today,
                    totalsByDay: totalsByDay,
                    calendar: calendar))
        }

        return datasets
    }

    /// Compatibility wrapper for the original 90-day daily chart API.
    static func dailyTokenUsage(
        rows: [PiUsageRow],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [PiDailyUsageBucket] {
        self.chartDatasets(rows: rows, now: now, calendar: calendar)[.ninetyDays]?.buckets.map {
            PiDailyUsageBucket(day: $0.startDate, totalTokens: $0.totalTokens)
        } ?? []
    }

    static func groupByModel(
        rows: [PiUsageRow],
        window: PiUsageWindow,
        limit: Int = 5,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [PiGroupSummary] {
        self.group(
            rows: rows,
            window: window,
            limit: limit,
            now: now,
            calendar: calendar,
            key: { row in
                let model = row.model?.trimmingCharacters(in: .whitespacesAndNewlines)
                return (model?.isEmpty == false) ? model! : "unknown"
            }
        )
    }

    static func groupByProvider(
        rows: [PiUsageRow],
        window: PiUsageWindow,
        limit: Int = 5,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [PiGroupSummary] {
        self.group(
            rows: rows,
            window: window,
            limit: limit,
            now: now,
            calendar: calendar,
            key: { row in
                let provider = row.provider?.trimmingCharacters(in: .whitespacesAndNewlines)
                return (provider?.isEmpty == false) ? provider! : "unknown"
            }
        )
    }

    static func groupByProject(
        rows: [PiUsageRow],
        window: PiUsageWindow,
        limit: Int = 5,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [PiGroupSummary] {
        self.group(
            rows: rows,
            window: window,
            limit: limit,
            now: now,
            calendar: calendar,
            key: { row in
                let cwd = row.cwd?.trimmingCharacters(in: .whitespacesAndNewlines)
                return (cwd?.isEmpty == false) ? cwd! : "unknown"
            }
        )
    }

    private static func tokenTotalsByDay(
        rows: [PiUsageRow],
        calendar: Calendar
    ) -> [Date: Int] {
        var totalsByDay: [Date: Int] = [:]
        for row in rows {
            let day = calendar.startOfDay(for: row.timeCreated)
            let rowTokens = self.tokenCount(for: row)
            totalsByDay[day] = PiTokenTotals.saturatedNonnegativeSum([
                totalsByDay[day] ?? 0,
                rowTokens,
            ])
        }
        return totalsByDay
    }

    private static func dailyBuckets(
        from startDate: Date,
        through endDate: Date,
        totalsByDay: [Date: Int],
        calendar: Calendar
    ) -> [PiChartBucket] {
        guard startDate <= endDate else { return [] }

        var buckets: [PiChartBucket] = []
        var day = startDate
        while day <= endDate {
            buckets.append(PiChartBucket(
                startDate: day,
                endDate: day,
                totalTokens: max(0, totalsByDay[day] ?? 0)))

            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: day),
                  nextDay > day
            else {
                break
            }
            day = nextDay
        }
        return buckets
    }

    private static func weeklyBuckets(
        from startDate: Date,
        through endDate: Date,
        totalsByDay: [Date: Int],
        calendar: Calendar
    ) -> [PiChartBucket] {
        self.fixedWidthBuckets(
            from: startDate,
            through: endDate,
            dayWidth: 7,
            totalsByDay: totalsByDay,
            calendar: calendar)
    }

    private static func fixedWidthBuckets(
        from startDate: Date,
        through endDate: Date,
        dayWidth: Int,
        totalsByDay: [Date: Int],
        calendar: Calendar
    ) -> [PiChartBucket] {
        guard startDate <= endDate, dayWidth > 0 else { return [] }

        var buckets: [PiChartBucket] = []
        var bucketStart = startDate
        while bucketStart <= endDate {
            let candidateEnd = calendar.date(
                byAdding: .day,
                value: dayWidth - 1,
                to: bucketStart) ?? bucketStart
            let bucketEnd = min(candidateEnd, endDate)
            buckets.append(PiChartBucket(
                startDate: bucketStart,
                endDate: bucketEnd,
                totalTokens: self.tokenTotal(
                    from: bucketStart,
                    through: bucketEnd,
                    totalsByDay: totalsByDay,
                    calendar: calendar)))

            guard let nextStart = calendar.date(
                byAdding: .day,
                value: dayWidth,
                to: bucketStart),
                  nextStart > bucketStart
            else {
                break
            }
            bucketStart = nextStart
        }
        return buckets
    }

    private static func monthlyBuckets(
        from earliestDay: Date,
        through today: Date,
        totalsByDay: [Date: Int],
        calendar: Calendar
    ) -> [PiChartBucket] {
        guard earliestDay <= today else { return [] }

        var monthComponents = calendar.dateComponents([.year, .month], from: earliestDay)
        monthComponents.day = 1
        guard let firstMonth = calendar.date(from: monthComponents) else { return [] }
        var monthStart = calendar.startOfDay(for: firstMonth)

        var buckets: [PiChartBucket] = []
        while monthStart <= today {
            guard let nextMonthDate = calendar.date(byAdding: .month, value: 1, to: monthStart) else {
                break
            }
            let nextMonth = calendar.startOfDay(for: nextMonthDate)
            guard nextMonth > monthStart else { break }
            let lastDayDate = calendar.date(byAdding: .day, value: -1, to: nextMonth) ?? monthStart
            let lastDayOfMonth = calendar.startOfDay(for: lastDayDate)
            let bucketStart = max(earliestDay, monthStart)
            let bucketEnd = min(today, lastDayOfMonth)
            if bucketStart <= bucketEnd {
                buckets.append(PiChartBucket(
                    startDate: bucketStart,
                    endDate: bucketEnd,
                    totalTokens: self.tokenTotal(
                        from: bucketStart,
                        through: bucketEnd,
                        totalsByDay: totalsByDay,
                        calendar: calendar)))
            }
            monthStart = nextMonth
        }
        return buckets
    }

    private static func weeklyBucketCount(
        from startDate: Date,
        through endDate: Date,
        calendar: Calendar
    ) -> Int {
        guard startDate <= endDate else { return 0 }

        var count = 0
        var bucketStart = startDate
        while bucketStart <= endDate {
            count += 1
            if count > Self.allWeeklyBucketThreshold {
                return count
            }
            guard let nextStart = calendar.date(byAdding: .day, value: 7, to: bucketStart),
                  nextStart > bucketStart
            else {
                break
            }
            bucketStart = nextStart
        }
        return count
    }

    private static func tokenTotal(
        from startDate: Date,
        through endDate: Date,
        totalsByDay: [Date: Int],
        calendar: Calendar
    ) -> Int {
        guard startDate <= endDate else { return 0 }

        var total = 0
        var day = startDate
        while day <= endDate {
            total = PiTokenTotals.saturatedNonnegativeSum([
                total,
                totalsByDay[day] ?? 0,
            ])
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: day),
                  nextDay > day
            else {
                break
            }
            day = nextDay
        }
        return total
    }

    private static func filteredRows(
        rows: [PiUsageRow],
        window: PiUsageWindow,
        now: Date,
        calendar: Calendar
    ) -> [PiUsageRow] {
        rows.filter { row in
            self.contains(row.timeCreated, in: window, now: now, calendar: calendar)
        }
    }

    private static func contains(
        _ date: Date,
        in window: PiUsageWindow,
        now: Date,
        calendar: Calendar
    ) -> Bool {
        switch window {
        case .today:
            return calendar.isDate(date, inSameDayAs: now)
        case .lastSevenDays:
            let cutoff = now.addingTimeInterval(-(7 * 24 * 60 * 60))
            return date >= cutoff && date <= now
        case .lastThirtyDays:
            let cutoff = now.addingTimeInterval(-(30 * 24 * 60 * 60))
            return date >= cutoff && date <= now
        case .lastNinetyDays:
            let today = calendar.startOfDay(for: now)
            guard let firstDay = calendar.date(
                byAdding: .day,
                value: -(Self.ninetyDayChartDayCount - 1),
                to: today)
            else {
                return false
            }
            return date >= firstDay && date <= now
        }
    }

    static func requestCount(rows: [PiUsageRow]) -> Int {
        self.requestSum(rows)
    }

    private static func requestSum(_ rows: [PiUsageRow]) -> Int {
        rows.reduce(0) { total, row in
            PiTokenTotals.saturatedNonnegativeSum([total, row.requestCount])
        }
    }

    private static func tokenSum(
        _ rows: [PiUsageRow],
        keyPath: KeyPath<PiUsageRow, Int>
    ) -> Int {
        rows.reduce(0) { total, row in
            PiTokenTotals.saturatedNonnegativeSum([total, row[keyPath: keyPath]])
        }
    }

    private static func tokenCount(for row: PiUsageRow) -> Int {
        PiTokenTotals.saturatedNonnegativeSum([
            row.inputTokens,
            row.outputTokens,
            row.cacheReadTokens,
            row.cacheWriteTokens,
        ])
    }

    private static func group(
        rows: [PiUsageRow],
        window: PiUsageWindow,
        limit: Int,
        now: Date,
        calendar: Calendar,
        key: (PiUsageRow) -> String
    ) -> [PiGroupSummary] {
        let filtered = self.filteredRows(rows: rows, window: window, now: now, calendar: calendar)
        var buckets: [String: (count: Int, cost: Double, input: Int, output: Int, cacheRead: Int, cacheWrite: Int)] = [:]

        for row in filtered {
            let label = key(row)
            var value = buckets[label] ?? (0, 0, 0, 0, 0, 0)
            value.count = PiTokenTotals.saturatedNonnegativeSum([value.count, row.requestCount])
            value.cost = PiTokenTotals.saturatedNonnegativeCostSum([value.cost, row.costUSD])
            value.input = PiTokenTotals.saturatedNonnegativeSum([value.input, row.inputTokens])
            value.output = PiTokenTotals.saturatedNonnegativeSum([value.output, row.outputTokens])
            value.cacheRead = PiTokenTotals.saturatedNonnegativeSum([value.cacheRead, row.cacheReadTokens])
            value.cacheWrite = PiTokenTotals.saturatedNonnegativeSum([value.cacheWrite, row.cacheWriteTokens])
            buckets[label] = value
        }

        return buckets.map { label, value in
            PiGroupSummary(
                label: label,
                requestCount: value.count,
                totalCostUSD: value.cost,
                totalInputTokens: value.input,
                totalOutputTokens: value.output,
                totalCacheReadTokens: value.cacheRead,
                totalCacheWriteTokens: value.cacheWrite
            )
        }
        .sorted { lhs, rhs in
            if lhs.totalCostUSD != rhs.totalCostUSD {
                return lhs.totalCostUSD > rhs.totalCostUSD
            }
            if lhs.requestCount != rhs.requestCount {
                return lhs.requestCount > rhs.requestCount
            }
            return lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
        }
        .prefix(max(0, limit))
        .map { $0 }
    }
}

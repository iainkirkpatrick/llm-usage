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

struct PiDailyUsageBucket: Sendable, Equatable {
    let day: Date
    let totalTokens: Int
}

enum PiUsageAggregation {
    static let dailyChartDayCount = 90

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

    static func dailyTokenUsage(
        rows: [PiUsageRow],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [PiDailyUsageBucket] {
        let today = calendar.startOfDay(for: now)
        guard let firstDay = calendar.date(
            byAdding: .day,
            value: -(self.dailyChartDayCount - 1),
            to: today)
        else {
            return []
        }

        var totalsByDay: [Date: Int] = [:]
        for row in rows {
            guard row.timeCreated <= now else { continue }

            let day = calendar.startOfDay(for: row.timeCreated)
            guard day >= firstDay, day <= today else { continue }

            let rowTokens = self.tokenCount(for: row)
            totalsByDay[day] = PiTokenTotals.saturatedNonnegativeSum([totalsByDay[day] ?? 0, rowTokens])
        }

        var buckets: [PiDailyUsageBucket] = []
        buckets.reserveCapacity(self.dailyChartDayCount)
        for offset in 0..<self.dailyChartDayCount {
            guard let day = calendar.date(byAdding: .day, value: offset, to: firstDay) else {
                continue
            }
            buckets.append(PiDailyUsageBucket(day: day, totalTokens: totalsByDay[day] ?? 0))
        }
        return buckets
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
                value: -(self.dailyChartDayCount - 1),
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

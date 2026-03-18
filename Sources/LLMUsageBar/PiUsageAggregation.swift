import Foundation

enum PiUsageWindow {
    case today
    case lastSevenDays
    case lastThirtyDays

    var title: String {
        switch self {
        case .today: "Today"
        case .lastSevenDays: "Last 7d"
        case .lastThirtyDays: "Last 30d"
        }
    }
}

enum PiUsageAggregation {
    static func summary(
        rows: [PiUsageRow],
        window: PiUsageWindow,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> PiSummary {
        let filtered = self.filteredRows(rows: rows, window: window, now: now, calendar: calendar)

        return PiSummary(
            requestCount: filtered.count,
            totalCostUSD: filtered.reduce(0) { $0 + $1.costUSD },
            totalInputTokens: filtered.reduce(0) { $0 + $1.inputTokens },
            totalOutputTokens: filtered.reduce(0) { $0 + $1.outputTokens },
            totalCacheReadTokens: filtered.reduce(0) { $0 + $1.cacheReadTokens },
            totalCacheWriteTokens: filtered.reduce(0) { $0 + $1.cacheWriteTokens }
        )
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
        }
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
            value.count += 1
            value.cost += row.costUSD
            value.input += row.inputTokens
            value.output += row.outputTokens
            value.cacheRead += row.cacheReadTokens
            value.cacheWrite += row.cacheWriteTokens
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

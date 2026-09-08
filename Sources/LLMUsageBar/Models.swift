import Foundation

struct RateWindow: Sendable {
    let usedPercent: Double
    let resetAt: Date?
    var remainingPercent: Double { max(0, 100 - usedPercent) }
}

struct CodexResetCredit: Sendable {
    let id: String
    let resetType: String?
    let status: String?
    let grantedAt: Date?
    let expiresAt: Date?
    let title: String?
    let description: String?
}

struct CodexResetCredits: Sendable {
    let availableCount: Int
    let credits: [CodexResetCredit]
    var earliestExpiry: Date? { credits.compactMap(\.expiresAt).min() }
}

struct CodexResetRedemptionResult: Sendable {
    let outcome: String
    let refreshError: String?
}

struct CodexSnapshot: Sendable {
    let session: RateWindow?
    let weekly: RateWindow?
    let creditsRemaining: Double?
    let resetCredits: CodexResetCredits?
    let sourceLabel: String
    let updatedAt: Date
    let email: String?
    let planType: String?

    init(
        session: RateWindow?,
        weekly: RateWindow?,
        creditsRemaining: Double?,
        resetCredits: CodexResetCredits?,
        sourceLabel: String,
        updatedAt: Date,
        email: String? = nil,
        planType: String? = nil)
    {
        self.session = session
        self.weekly = weekly
        self.creditsRemaining = creditsRemaining
        self.resetCredits = resetCredits
        self.sourceLabel = sourceLabel
        self.updatedAt = updatedAt
        self.email = email
        self.planType = planType
    }
}

struct CodexAccountSnapshot: Sendable {
    let id: String
    let label: String
    let email: String?
    let usage: CodexSnapshot?
    let error: String?

    var displayLabel: String {
        if let email, !email.isEmpty, email.caseInsensitiveCompare(self.label) != .orderedSame {
            return "\(self.label) — \(email)"
        }
        return self.label
    }
}

struct OpenCodeGoLimits: Sendable {
    let fiveHour: RateWindow?
    let weekly: RateWindow?
    let monthly: RateWindow?
    let updatedAt: Date
}

struct OpenCodeUsageRow: Sendable {
    let timeCreated: Date
    let model: String
    let inputTokens: Int
    let outputTokens: Int
    let reasoningTokens: Int
    let cacheReadTokens: Int
    let cacheWrite5mTokens: Int
    let cacheWrite1hTokens: Int
    let costUSD: Double
    let plan: String?
}

struct OpenCodeModelSummary: Sendable {
    let model: String
    let requestCount: Int
    let totalCostUSD: Double
    let totalInputTokens: Int
    let totalOutputTokens: Int

    static func aggregate(
        rows: [OpenCodeUsageRow],
        window: TimeInterval,
        now: Date = Date()) -> [OpenCodeModelSummary]
    {
        let models = ["glm-5", "kimi-k2.5", "minimax-m2.5"]
        let cutoff = now.addingTimeInterval(-window)

        var buckets: [String: (count: Int, cost: Double, input: Int, output: Int)] = [:]
        for model in models {
            buckets[model] = (0, 0, 0, 0)
        }

        for row in rows where row.timeCreated >= cutoff {
            let key = models.first(where: { row.model.lowercased().contains($0) })
            guard let key else { continue }

            var value = buckets[key] ?? (0, 0, 0, 0)
            value.count += 1
            value.cost += row.costUSD
            value.input += row.inputTokens + row.cacheReadTokens + row.cacheWrite5mTokens + row.cacheWrite1hTokens
            value.output += row.outputTokens + row.reasoningTokens
            buckets[key] = value
        }

        return models.map { model in
            let value = buckets[model] ?? (0, 0, 0, 0)
            return OpenCodeModelSummary(
                model: model,
                requestCount: value.count,
                totalCostUSD: value.cost,
                totalInputTokens: value.input,
                totalOutputTokens: value.output
            )
        }
    }
}

struct OpenCodeSnapshot: Sendable {
    let workspaceID: String
    let limits: OpenCodeGoLimits?
    let rows: [OpenCodeUsageRow]
    let updatedAt: Date
}

enum PiChartRange: String, CaseIterable, Hashable, Sendable {
    case ninetyDays = "90d"
    case sixMonths = "6m"
    case oneYear = "1y"
    case all = "all"

    var title: String {
        switch self {
        case .ninetyDays: "90d"
        case .sixMonths: "6m"
        case .oneYear: "1y"
        case .all: "All"
        }
    }
}

/// A chart bucket covers local calendar days inclusively. `startDate` and `endDate`
/// are both local start-of-day values; a daily bucket therefore has equal dates.
struct PiChartBucket: Sendable, Equatable {
    let startDate: Date
    let endDate: Date
    let totalTokens: Int
}

/// Precomputed data for one selectable chart range. Keeping range metadata beside
/// the buckets lets the view change ranges without re-reading or re-aggregating rows.
struct PiChartDataset: Sendable, Equatable {
    let range: PiChartRange
    let unitLabel: String
    let buckets: [PiChartBucket]

    var rangeKey: String { self.range.rawValue }
    var rangeTitle: String { self.range.title }
    var title: String { self.rangeTitle }
}

struct PiUsageRow: Sendable {
    let timeCreated: Date
    let sessionFile: String
    let sessionID: String?
    let cwd: String?
    let provider: String?
    let model: String?
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let cacheWriteTokens: Int
    let totalTokens: Int
    let costUSD: Double
    /// The number of requests represented by this row. Main assistant messages contribute one;
    /// a completed subagent summary contributes its number of model turns.
    let requestCount: Int

    init(
        timeCreated: Date,
        sessionFile: String,
        sessionID: String?,
        cwd: String?,
        provider: String?,
        model: String?,
        inputTokens: Int,
        outputTokens: Int,
        cacheReadTokens: Int,
        cacheWriteTokens: Int,
        totalTokens: Int,
        costUSD: Double,
        requestCount: Int = 1
    ) {
        self.timeCreated = timeCreated
        self.sessionFile = sessionFile
        self.sessionID = sessionID
        self.cwd = cwd
        self.provider = provider
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.totalTokens = totalTokens
        self.costUSD = costUSD
        self.requestCount = requestCount
    }

    var requestCountContribution: Int { self.requestCount }
}

enum PiTokenTotals {
    static func saturatedNonnegativeSum(_ values: [Int]) -> Int {
        values.reduce(0) { total, value in
            let (sum, overflow) = total.addingReportingOverflow(max(0, value))
            return overflow ? Int.max : sum
        }
    }

    static func saturatedNonnegativeCostSum(_ values: [Double]) -> Double {
        values.reduce(0) { total, value in
            guard value.isFinite, value >= 0 else { return total }
            let maximum = Double.greatestFiniteMagnitude
            guard total <= maximum - value else { return maximum }
            return total + value
        }
    }
}

struct PiSummary: Sendable {
    let requestCount: Int
    let totalCostUSD: Double
    let totalInputTokens: Int
    let totalOutputTokens: Int
    let totalCacheReadTokens: Int
    let totalCacheWriteTokens: Int

    var totalTokens: Int {
        PiTokenTotals.saturatedNonnegativeSum([
            self.totalInputTokens,
            self.totalOutputTokens,
            self.totalCacheReadTokens,
            self.totalCacheWriteTokens,
        ])
    }
}

struct PiGroupSummary: Sendable {
    let label: String
    let requestCount: Int
    let totalCostUSD: Double
    let totalInputTokens: Int
    let totalOutputTokens: Int
    let totalCacheReadTokens: Int
    let totalCacheWriteTokens: Int

    var totalTokens: Int {
        PiTokenTotals.saturatedNonnegativeSum([
            self.totalInputTokens,
            self.totalOutputTokens,
            self.totalCacheReadTokens,
            self.totalCacheWriteTokens,
        ])
    }
}

struct PiSnapshot: Sendable {
    let sessionsDirectory: String
    let rows: [PiUsageRow]
    let sessionCount: Int
    let forkedSessionCount: Int
    let zeroCostRowCount: Int
    let updatedAt: Date
}

struct AppSnapshot: Sendable {
    let codex: CodexSnapshot?
    let codexAccounts: [CodexAccountSnapshot]
    let openCode: OpenCodeSnapshot?
    let pi: PiSnapshot?
    let errors: [String]
    let updatedAt: Date

    init(
        codex: CodexSnapshot?,
        codexAccounts: [CodexAccountSnapshot] = [],
        openCode: OpenCodeSnapshot?,
        pi: PiSnapshot?,
        errors: [String],
        updatedAt: Date)
    {
        self.codex = codex
        self.codexAccounts = codexAccounts
        self.openCode = openCode
        self.pi = pi
        self.errors = errors
        self.updatedAt = updatedAt
    }
}

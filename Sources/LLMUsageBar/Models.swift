import Foundation

struct RateWindow: Sendable {
    let usedPercent: Double
    let resetAt: Date?

    var remainingPercent: Double {
        max(0, 100 - self.usedPercent)
    }
}

struct CodexSnapshot: Sendable {
    let session: RateWindow?
    let weekly: RateWindow?
    let creditsRemaining: Double?
    let updatedAt: Date
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
            guard row.plan == nil || row.plan == "sub" else { continue }

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
}

struct PiSummary: Sendable {
    let requestCount: Int
    let totalCostUSD: Double
    let totalInputTokens: Int
    let totalOutputTokens: Int
    let totalCacheReadTokens: Int
    let totalCacheWriteTokens: Int

    var totalTokens: Int {
        self.totalInputTokens + self.totalOutputTokens + self.totalCacheReadTokens + self.totalCacheWriteTokens
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
        self.totalInputTokens + self.totalOutputTokens + self.totalCacheReadTokens + self.totalCacheWriteTokens
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
    let openCode: OpenCodeSnapshot?
    let pi: PiSnapshot?
    let errors: [String]
    let updatedAt: Date
}

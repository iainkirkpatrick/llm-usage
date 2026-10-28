import Foundation

/// Metadata only. Claude Code owns credentials in the profile's Keychain item or credential file.
/// nil configDirectory means the *unset* CLAUDE_CONFIG_DIR/default login, not an explicitly set ~/.claude.
struct ClaudeAccountProfile: Codable, Equatable, Sendable {
    let id: UUID
    var label: String
    var configDirectory: String?
    var accountID: String?
    var email: String?
    let createdAt: Date

    init(id: UUID = UUID(), label: String, configDirectory: String? = nil,
         accountID: String? = nil, email: String? = nil, createdAt: Date = Date()) {
        self.id = id
        self.label = label
        self.configDirectory = configDirectory
        self.accountID = accountID
        self.email = email
        self.createdAt = createdAt
    }

    var directoryURL: URL {
        if let configDirectory {
            return URL(fileURLWithPath: (configDirectory as NSString).expandingTildeInPath,
                       isDirectory: true).standardizedFileURL
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true)
    }
}

struct ClaudeNamedRateWindow: Sendable {
    let title: String
    let window: RateWindow
}

struct ClaudeExtraUsage: Sendable {
    let usedUSD: Double?
    let limitUSD: Double?
}

struct ClaudeQuotaSnapshot: Sendable {
    /// Verified account UUID + organization UUID, from the same OAuth credential as the quota request.
    let accountID: String
    let email: String?
    let planType: String?
    let fiveHour: RateWindow?
    let weekly: RateWindow?
    let modelWindows: [ClaudeNamedRateWindow]
    let extraUsage: ClaudeExtraUsage?
    let updatedAt: Date
}

struct ClaudeTokenUsage: Sendable {
    let timeCreated: Date
    let model: String
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let cacheWriteTokens: Int

    var totalTokens: Int {
        PiTokenTotals.saturatedNonnegativeSum([inputTokens, outputTokens, cacheReadTokens, cacheWriteTokens])
    }
}

struct ClaudeTokenSummary: Sendable, Equatable {
    let requests: Int
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let cacheWriteTokens: Int

    var totalTokens: Int {
        PiTokenTotals.saturatedNonnegativeSum([inputTokens, outputTokens, cacheReadTokens, cacheWriteTokens])
    }

    static func aggregate(rows: [ClaudeTokenUsage], since: Date, now: Date = Date()) -> Self {
        let eligible = rows.filter { $0.timeCreated >= since && $0.timeCreated <= now }
        return Self(
            requests: eligible.count,
            inputTokens: PiTokenTotals.saturatedNonnegativeSum(eligible.map(\.inputTokens)),
            outputTokens: PiTokenTotals.saturatedNonnegativeSum(eligible.map(\.outputTokens)),
            cacheReadTokens: PiTokenTotals.saturatedNonnegativeSum(eligible.map(\.cacheReadTokens)),
            cacheWriteTokens: PiTokenTotals.saturatedNonnegativeSum(eligible.map(\.cacheWriteTokens)))
    }
}

struct ClaudeLocalUsage: Sendable {
    let rows: [ClaudeTokenUsage]
    let fileCount: Int
    let unreadableFileCount: Int
    let updatedAt: Date
}

struct ClaudeAccountSnapshot: Sendable {
    let id: UUID
    let label: String
    let quota: ClaudeQuotaSnapshot?
    let localUsage: ClaudeLocalUsage?
    let quotaError: String?
    let localError: String?
}

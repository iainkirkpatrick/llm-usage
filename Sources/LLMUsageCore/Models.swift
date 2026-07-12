import Foundation

public struct RateWindow: Sendable {
    public let usedPercent: Double
    public let resetAt: Date?

    public init(usedPercent: Double, resetAt: Date?) {
        self.usedPercent = usedPercent
        self.resetAt = resetAt
    }

    public var remainingPercent: Double { max(0, 100 - usedPercent) }
}

public struct CodexResetCredit: Sendable {
    public let id: String
    public let resetType: String?
    public let status: String?
    public let grantedAt: Date?
    public let expiresAt: Date?
    public let title: String?
    public let description: String?

    public init(id: String, resetType: String?, status: String?, grantedAt: Date?, expiresAt: Date?, title: String?, description: String?) {
        self.id = id; self.resetType = resetType; self.status = status; self.grantedAt = grantedAt
        self.expiresAt = expiresAt; self.title = title; self.description = description
    }
}

public struct CodexResetCredits: Sendable {
    public let availableCount: Int
    public let credits: [CodexResetCredit]
    public init(availableCount: Int, credits: [CodexResetCredit]) { self.availableCount = availableCount; self.credits = credits }
    public var earliestExpiry: Date? { credits.compactMap(\.expiresAt).min() }
}

public struct CodexResetRedemptionResult: Sendable {
    public let outcome: String
    public let refreshError: String?
    public init(outcome: String, refreshError: String?) { self.outcome = outcome; self.refreshError = refreshError }
}

public struct CodexSnapshot: Sendable {
    public let session: RateWindow?
    public let weekly: RateWindow?
    public let creditsRemaining: Double?
    public let resetCredits: CodexResetCredits?
    public let sourceLabel: String
    public let updatedAt: Date

    public init(session: RateWindow?, weekly: RateWindow?, creditsRemaining: Double?, resetCredits: CodexResetCredits?, sourceLabel: String, updatedAt: Date) {
        self.session = session; self.weekly = weekly; self.creditsRemaining = creditsRemaining
        self.resetCredits = resetCredits; self.sourceLabel = sourceLabel; self.updatedAt = updatedAt
    }
}

public enum CodexWindowClassifier {
    public enum Kind: Equatable { case session, weekly }
    public static func kind(durationMinutes: Int?, resetAt: Date?, now: Date = Date()) -> Kind {
        if let durationMinutes { return durationMinutes < 24 * 60 ? .session : .weekly }
        if let resetAt, resetAt.timeIntervalSince(now) > 24 * 60 * 60 { return .weekly }
        return .session
    }
}

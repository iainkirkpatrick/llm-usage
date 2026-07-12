import LLMUsageCore
import Foundation
import UserNotifications

private enum CodexResetRedemptionError: LocalizedError {
    case refreshInProgress
    case redemptionInProgress
    case retryPendingReset
    case selectedCreditUnavailable

    var errorDescription: String? {
        switch self {
        case .refreshInProgress:
            return "Codex usage is refreshing. Wait for it to finish, then try again."
        case .redemptionInProgress:
            return "A saved reset is already being redeemed."
        case .retryPendingReset:
            return "The previous reset attempt has an unknown result. Retry that same reset before choosing another."
        case .selectedCreditUnavailable:
            return "That saved reset is no longer available on the currently authenticated Codex account."
        }
    }
}

private struct PendingCodexResetRedemption: Codable {
    let creditID: String
    let idempotencyKey: String
}

private enum PendingCodexResetRedemptionStore {
    private static let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".llm-usage-bar", isDirectory: true)
        .appendingPathComponent("pending-codex-reset.json")

    static func load() -> PendingCodexResetRedemption? {
        guard let data = try? Data(contentsOf: self.fileURL) else { return nil }
        return try? JSONDecoder().decode(PendingCodexResetRedemption.self, from: data)
    }

    static func save(_ pending: PendingCodexResetRedemption) throws {
        let directory = self.fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(pending)
        try data.write(to: self.fileURL, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: self.fileURL.path)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: self.fileURL)
    }
}

@MainActor
final class AppState {
    private(set) var snapshot: AppSnapshot = AppSnapshot(codex: nil, openCode: nil, pi: nil, errors: [], updatedAt: .distantPast)
    private(set) var isRefreshing = false
    private var isRedeemingCodexReset = false
    private var pendingCodexResetRedemption: PendingCodexResetRedemption?
    private var codexResetRefreshRequired = false

    private let codexFetcher = CodexFetcher()
    private let openCodeFetcher = OpenCodeGoFetcher()
    private let piFetcher = PiSessionsFetcher()
    private var config: AppConfig

    init(config: AppConfig) {
        self.config = config
        self.pendingCodexResetRedemption = PendingCodexResetRedemptionStore.load()
    }

    var currentConfig: AppConfig {
        self.config
    }

    func reloadConfig() {
        self.config = ConfigStore.load()
    }

    @discardableResult
    func persistConfig(_ config: AppConfig) -> Bool {
        self.config = config
        return ConfigStore.save(config)
    }

    var refreshInterval: TimeInterval {
        TimeInterval(max(30, self.config.refreshIntervalSeconds))
    }

    var canRedeemCodexResets: Bool {
        !self.codexResetRefreshRequired && !self.isRefreshing && !self.isRedeemingCodexReset
    }

    func consumeCodexResetCredit(creditID: String, automatic: Bool = false) async throws -> CodexResetRedemptionResult {
        guard !automatic || (self.config.codexEnabled && self.config.autoRedeemExpiringCodexResets) else {
            throw CodexResetRedemptionError.selectedCreditUnavailable
        }
        guard !self.isRefreshing else { throw CodexResetRedemptionError.refreshInProgress }
        guard !self.isRedeemingCodexReset else { throw CodexResetRedemptionError.redemptionInProgress }

        self.isRedeemingCodexReset = true
        defer { self.isRedeemingCodexReset = false }

        let currentCodex = try await self.codexFetcher.fetch()
        guard let currentResetCredits = currentCodex.resetCredits,
              currentResetCredits.availableCount > 0,
              let currentCredit = currentResetCredits.credits.first(where: { $0.id == creditID })
        else {
            throw CodexResetRedemptionError.selectedCreditUnavailable
        }
        if automatic {
            let notificationSettings = await UNUserNotificationCenter.current().notificationSettings()
            guard notificationSettings.authorizationStatus == .authorized ||
                    notificationSettings.authorizationStatus == .provisional else {
                throw CodexResetRedemptionError.selectedCreditUnavailable
            }
            let now = Date()
            guard self.config.codexEnabled,
                  self.config.autoRedeemExpiringCodexResets,
                  currentCredit.status?.lowercased() == "available",
                  let expiry = currentCredit.expiresAt,
                  expiry > now,
                  expiry.timeIntervalSince(now) <= 60 * 60
            else {
                throw CodexResetRedemptionError.selectedCreditUnavailable
            }
        }

        let attempt: PendingCodexResetRedemption
        if let pending = self.pendingCodexResetRedemption {
            guard pending.creditID == creditID else { throw CodexResetRedemptionError.retryPendingReset }
            attempt = pending
        } else {
            attempt = PendingCodexResetRedemption(creditID: creditID, idempotencyKey: UUID().uuidString)
            try PendingCodexResetRedemptionStore.save(attempt)
            self.pendingCodexResetRedemption = attempt
        }

        let finalAuthorizationCheck: (@MainActor @Sendable () async -> Bool)?
        if automatic {
            finalAuthorizationCheck = { [weak self] in
                guard let self,
                      self.config.codexEnabled,
                      self.config.autoRedeemExpiringCodexResets
                else { return false }
                let settings = await UNUserNotificationCenter.current().notificationSettings()
                return settings.authorizationStatus == .authorized ||
                    settings.authorizationStatus == .provisional
            }
        } else {
            finalAuthorizationCheck = nil
        }

        let outcome = try await self.codexFetcher.consumeResetCredit(
            creditID: attempt.creditID,
            idempotencyKey: attempt.idempotencyKey,
            finalAuthorizationCheck: finalAuthorizationCheck
        )
        self.pendingCodexResetRedemption = nil
        PendingCodexResetRedemptionStore.clear()

        do {
            let refreshedCodex = try await self.codexFetcher.fetch()
            self.applyCodexRefresh(refreshedCodex)
            return CodexResetRedemptionResult(outcome: outcome, refreshError: nil)
        } catch {
            self.codexResetRefreshRequired = true
            return CodexResetRedemptionResult(outcome: outcome, refreshError: error.localizedDescription)
        }
    }

    func refresh() async {
        guard !self.isRefreshing, !self.isRedeemingCodexReset else { return }
        self.isRefreshing = true
        defer { self.isRefreshing = false }

        AppLog.info("Refresh started: codex=\(self.config.codexEnabled) openCode=\(self.config.openCodeEnabled) pi=\(self.config.piEnabled)")

        var codexResult: CodexSnapshot?
        var openCodeResult: OpenCodeSnapshot?
        var piResult: PiSnapshot?
        var errors: [String] = []

        if self.config.codexEnabled {
            do {
                codexResult = try await self.codexFetcher.fetch()
                AppLog.info("Codex refresh succeeded via \(codexResult?.sourceLabel ?? "unknown")")
            } catch {
                let message = "Codex: \(error.localizedDescription)"
                errors.append(message)
                AppLog.error(message)
            }
        }

        if self.config.openCodeEnabled {
            do {
                openCodeResult = try await self.openCodeFetcher.fetch(
                    cookieHeader: self.config.openCodeCookieHeader,
                    workspaceID: self.config.openCodeWorkspaceID
                )
                AppLog.info("OpenCode refresh succeeded: workspace=\(openCodeResult?.workspaceID ?? "unknown") rows=\(openCodeResult?.rows.count ?? 0)")
            } catch {
                let message = "OpenCode Go: \(error.localizedDescription)"
                errors.append(message)
                AppLog.error(message)
            }
        }

        if self.config.piEnabled {
            do {
                piResult = try self.piFetcher.fetch(
                    sessionsDirectory: self.config.piSessionsDirectory,
                    deduplicateForkHistory: self.config.piDeduplicateForkHistory
                )
                AppLog.info("Pi refresh succeeded: sessions=\(piResult?.sessionCount ?? 0) rows=\(piResult?.rows.count ?? 0)")
            } catch {
                let message = "Pi: \(error.localizedDescription)"
                errors.append(message)
                AppLog.error(message)
            }
        }

        self.snapshot = AppSnapshot(
            codex: codexResult,
            openCode: openCodeResult,
            pi: piResult,
            errors: errors,
            updatedAt: Date()
        )
        if let codexResult {
            self.codexResetRefreshRequired = false
            self.clearResolvedPendingCodexReset(using: codexResult)
        }

        if errors.isEmpty {
            AppLog.info("Refresh completed without errors")
        } else {
            AppLog.error("Refresh completed with \(errors.count) error(s): \(errors.joined(separator: " | "))")
        }
    }

    private func applyCodexRefresh(_ codex: CodexSnapshot) {
        self.snapshot = AppSnapshot(
            codex: codex,
            openCode: self.snapshot.openCode,
            pi: self.snapshot.pi,
            errors: self.snapshot.errors.filter { !$0.hasPrefix("Codex:") },
            updatedAt: Date()
        )
        self.codexResetRefreshRequired = false
        self.clearResolvedPendingCodexReset(using: codex)
    }

    private func clearResolvedPendingCodexReset(using codex: CodexSnapshot) {
        guard let pending = self.pendingCodexResetRedemption,
              let credits = codex.resetCredits?.credits,
              !credits.isEmpty,
              !credits.contains(where: { $0.id == pending.creditID })
        else {
            return
        }
        self.pendingCodexResetRedemption = nil
        PendingCodexResetRedemptionStore.clear()
    }
}

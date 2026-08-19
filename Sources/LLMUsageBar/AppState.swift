import Foundation
import UserNotifications

private enum CodexResetRedemptionError: LocalizedError {
    case refreshInProgress
    case redemptionInProgress
    case retryPendingReset
    case selectedCreditUnavailable
    case accountUnavailable

    var errorDescription: String? {
        switch self {
        case .refreshInProgress:
            return "Codex usage is refreshing. Wait for it to finish, then try again."
        case .redemptionInProgress:
            return "A saved reset is already being redeemed."
        case .retryPendingReset:
            return "The previous reset attempt has an unknown result. Retry that same reset before choosing another."
        case .selectedCreditUnavailable:
            return "That saved reset is no longer available on the selected Codex account."
        case .accountUnavailable:
            return "The selected Codex account has no current usage data. Refresh it before using a reset."
        }
    }
}

private struct PendingCodexResetRedemption: Codable {
    let accountID: String
    let creditID: String
    let idempotencyKey: String

    init(accountID: String = "legacy-unscoped", creditID: String, idempotencyKey: String) {
        // Legacy pre-account reset records have no safe managed-account identity. Keep them as a
        // blocked migration record rather than allowing a retry through a different account.
        self.accountID = accountID == "ambient" ? "legacy-unscoped" : accountID
        self.creditID = creditID
        self.idempotencyKey = idempotencyKey
    }

    private enum CodingKeys: String, CodingKey {
        case accountID
        case creditID
        case idempotencyKey
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Pre-multi-account pending files had no safe managed-account identity. Preserve them as
        // blocked migration records so reset retries cannot cross into a managed account.
        let accountID = try container.decodeIfPresent(String.self, forKey: .accountID) ?? "legacy-unscoped"
        self.accountID = accountID == "ambient" ? "legacy-unscoped" : accountID
        self.creditID = try container.decode(String.self, forKey: .creditID)
        self.idempotencyKey = try container.decode(String.self, forKey: .idempotencyKey)
    }
}

private enum PendingCodexResetRedemptionStore {
    private static let fileURL = ConfigStore.appDirectoryURL
        .appendingPathComponent("pending-codex-reset.json")

    static func load() -> PendingCodexResetRedemption? {
        guard (try? ConfigStore.validateAppOwnedFile(self.fileURL)) != nil,
              let data = try? Data(contentsOf: self.fileURL)
        else { return nil }
        return try? JSONDecoder().decode(PendingCodexResetRedemption.self, from: data)
    }

    static func save(_ pending: PendingCodexResetRedemption) throws {
        try ConfigStore.ensureAppDirectory()
        try AppOwnedPathSafety.validateRegularFile(at: self.fileURL)
        let data = try JSONEncoder().encode(pending)
        let temporary = self.fileURL.deletingLastPathComponent()
            .appendingPathComponent(".pending-codex-reset-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary, options: [.atomic])
        try AppOwnedPathSafety.hardenRegularFile(at: temporary, permissions: 0o600)
        let existing = try AppOwnedPathSafety.info(at: self.fileURL)
        if existing.exists {
            _ = try FileManager.default.replaceItemAt(
                self.fileURL,
                withItemAt: temporary,
                backupItemName: nil,
                options: [])
        } else {
            try FileManager.default.moveItem(at: temporary, to: self.fileURL)
        }
        let installed = try AppOwnedPathSafety.info(at: self.fileURL)
        guard installed.permissions == 0o600 else {
            throw AppOwnedPathError.permissionHardeningFailed(self.fileURL.path)
        }
    }

    static func clear() throws {
        let info = try AppOwnedPathSafety.info(at: self.fileURL)
        guard info.exists else { return }
        try AppOwnedPathSafety.validateRegularFile(at: self.fileURL, allowMissing: false)
        try FileManager.default.removeItem(at: self.fileURL)
    }
}

@MainActor
final class AppState {
    private(set) var snapshot: AppSnapshot = AppSnapshot(
        codex: nil,
        codexAccounts: [],
        openCode: nil,
        pi: nil,
        errors: [],
        updatedAt: .distantPast)
    private(set) var isRefreshing = false
    private(set) var isAuthenticatingCodexAccount = false
    private(set) var authenticatingCodexAccountID: UUID?
    private var isRedeemingCodexReset = false
    private var pendingCodexResetRedemption: PendingCodexResetRedemption?
    private var codexResetRefreshRequired = Set<String>()

    private let codexFetcher = CodexNodeBridge()
    private let codexLoginRunner = CodexLoginRunner()
    private let managedHomeStore = ManagedCodexHomeStore()
    private let openCodeFetcher = OpenCodeGoFetcher()
    private let piFetcher = PiSessionsFetcher()
    private var config: AppConfig

    init(config: AppConfig) {
        self.config = config
        self.normalizePrimaryCodexAccount()
        self.pendingCodexResetRedemption = PendingCodexResetRedemptionStore.load()
        do {
            try self.managedHomeStore.recoverQuarantinedHomes(
                for: Set(config.codexManagedAccounts.map(\.id)))
        } catch {
            AppLog.error("Managed Codex removal recovery failed: \(error.localizedDescription)")
        }
    }

    var currentConfig: AppConfig {
        self.config
    }

    var primaryCodexAccountKey: String {
        guard let id = self.config.codexPrimaryAccountID,
              self.config.codexManagedAccounts.contains(where: { $0.id == id })
        else {
            return self.config.codexManagedAccounts.first?.id.uuidString ?? "none"
        }
        return id.uuidString
    }

    var managedCodexAccounts: [CodexManagedAccountProfile] {
        self.config.codexManagedAccounts
    }

    @discardableResult
    func persistConfig(_ config: AppConfig) -> Bool {
        guard ConfigStore.save(config) else { return false }
        self.config = config
        return true
    }

    func reloadConfig() {
        self.config = ConfigStore.load()
        self.normalizePrimaryCodexAccount()
        self.applyPrimaryCodexSelectionToSnapshot()
    }

    private func normalizePrimaryCodexAccount() {
        if let configured = self.config.codexPrimaryAccountID,
           self.config.codexManagedAccounts.contains(where: { $0.id == configured })
        {
            return
        }
        guard let first = self.config.codexManagedAccounts.first?.id else {
            guard self.config.codexPrimaryAccountID != nil else { return }
            var next = self.config
            next.codexPrimaryAccountID = nil
            self.config = next
            _ = ConfigStore.save(next)
            return
        }

        var next = self.config
        next.codexPrimaryAccountID = first
        self.config = next
        _ = ConfigStore.save(next)
    }

    var refreshInterval: TimeInterval {
        TimeInterval(max(30, self.config.refreshIntervalSeconds))
    }

    var canRedeemCodexResets: Bool {
        self.canRedeemCodexResets(for: self.primaryCodexAccountKey)
    }

    var isCodexAccountOperationInProgress: Bool {
        self.isRefreshing || self.isRedeemingCodexReset || self.isAuthenticatingCodexAccount
    }

    func canRedeemCodexResets(for accountID: String) -> Bool {
        guard !self.codexResetRefreshRequired.contains(accountID),
              !self.isRefreshing,
              !self.isRedeemingCodexReset,
              self.snapshot.codexAccounts.contains(where: { $0.id == accountID && $0.usage != nil })
        else { return false }
        if let pending = self.pendingCodexResetRedemption {
            return pending.accountID == accountID
        }
        return true
    }

    func canRedeemCodexReset(accountID: String, creditID: String) -> Bool {
        guard self.canRedeemCodexResets(for: accountID) else { return false }
        guard let pending = self.pendingCodexResetRedemption else { return true }
        return pending.accountID == accountID && pending.creditID == creditID
    }

    func createManagedCodexAccount(label: String) throws -> CodexManagedAccountProfile {
        guard !self.isCodexAccountOperationInProgress else {
            throw self.isAuthenticatingCodexAccount
                ? ManagedCodexAccountError.authenticationInProgress
                : ManagedCodexAccountError.accountOperationInProgress
        }
        let normalized = Self.normalizedAccountLabel(label)
        guard !normalized.isEmpty else {
            throw ManagedCodexAccountError.configWriteFailed
        }

        let profile = CodexManagedAccountProfile(label: normalized)
        _ = try self.managedHomeStore.prepareAccountHome(for: profile.id)

        var next = self.config
        next.codexManagedAccounts.append(profile)
        if next.codexPrimaryAccountID == nil {
            next.codexPrimaryAccountID = profile.id
        }
        guard ConfigStore.save(next) else {
            do {
                try self.managedHomeStore.removeAccountHome(for: profile.id)
            } catch {
                throw ManagedCodexAccountError.stagingCleanupFailed(
                    "The new account was not saved, but its empty home could not be removed: \(error.localizedDescription)")
            }
            throw ManagedCodexAccountError.configWriteFailed
        }
        self.config = next
        self.applyPrimaryCodexSelectionToSnapshot()
        return profile
    }

    func authenticateManagedCodexAccount(id: UUID, timeout: TimeInterval = 120) async throws {
        guard !self.isCodexAccountOperationInProgress else {
            throw self.isAuthenticatingCodexAccount
                ? ManagedCodexAccountError.authenticationInProgress
                : ManagedCodexAccountError.accountOperationInProgress
        }
        guard self.config.codexManagedAccounts.contains(where: { $0.id == id }) else {
            throw ManagedCodexAccountError.accountNotFound
        }

        self.isAuthenticatingCodexAccount = true
        self.authenticatingCodexAccountID = id
        defer {
            self.isAuthenticatingCodexAccount = false
            self.authenticatingCodexAccountID = nil
        }

        // Never let `codex login` write into the live account home. A cancelled or failed login can
        // create/overwrite arbitrary files, so it gets a private sibling staging home and only a
        // validated auth.json is atomically installed after a successful exit.
        let stagingHome = try self.managedHomeStore.prepareLoginStagingHome(for: id)
        var shouldCleanStaging = true
        do {
            let result = await self.codexLoginRunner.run(codexHome: stagingHome, timeout: timeout)
            guard result.succeeded else {
                throw ManagedCodexAccountError.loginFailed(result)
            }
            try Task.checkCancellation()
            try self.managedHomeStore.commitStagedAuth(for: id, stagingHome: stagingHome)
            try self.managedHomeStore.removeLoginStagingHome(stagingHome, accountID: id)
            shouldCleanStaging = false
            guard self.updateManagedAccountMetadata(id: id, email: nil, planType: nil, authenticatedNow: true) else {
                throw ManagedCodexAccountError.configWriteFailed
            }
        } catch {
            if shouldCleanStaging {
                do {
                    try self.managedHomeStore.removeLoginStagingHome(stagingHome, accountID: id)
                    shouldCleanStaging = false
                } catch let cleanupError {
                    throw ManagedCodexAccountError.stagingCleanupFailed(
                        "\(error.localizedDescription) Temporary-home cleanup also failed: \(cleanupError.localizedDescription)")
                }
            }
            throw error
        }
    }

    func removeManagedCodexAccount(id: UUID) throws {
        guard !self.isCodexAccountOperationInProgress else {
            throw self.isAuthenticatingCodexAccount
                ? ManagedCodexAccountError.authenticationInProgress
                : ManagedCodexAccountError.accountOperationInProgress
        }
        guard self.config.codexManagedAccounts.contains(where: { $0.id == id }) else {
            throw ManagedCodexAccountError.accountNotFound
        }
        if let pending = self.pendingCodexResetRedemption, pending.accountID == id.uuidString {
            throw ManagedCodexAccountError.resetPending(
                "Retry that same reset on this account before removing it.")
        }

        let original = self.config
        var next = original
        next.codexManagedAccounts.removeAll { $0.id == id }
        // Removal never silently promotes another account until the credential-home and metadata
        // transactions have completed. The primary is normalized after the commit.
        if next.codexPrimaryAccountID == id {
            next.codexPrimaryAccountID = next.codexManagedAccounts.first?.id
        }

        // Keep the renamed home recoverable until metadata has been committed. The transaction
        // helper also restores both resources if final quarantine deletion fails; `self.config` is
        // deliberately updated only after all filesystem and metadata work has completed.
        let removal = try self.managedHomeStore.stageAccountHomeRemoval(for: id)
        do {
            try ManagedCodexAccountRemovalTransaction.commit(
                original: original,
                next: next,
                removal: removal,
                save: ConfigStore.save,
                finalize: { removal in
                    try self.managedHomeStore.finalizeAccountHomeRemoval(removal)
                },
                restore: { removal in
                    try self.managedHomeStore.restoreAccountHome(removal)
                })
        } catch let error as ManagedCodexAccountRemovalTransactionError {
            throw ManagedCodexAccountError.removalFailed(error.localizedDescription)
        }
        self.config = next
        self.codexResetRefreshRequired.remove(id.uuidString)
        self.snapshot = AppSnapshot(
            codex: self.snapshot.codex,
            codexAccounts: self.snapshot.codexAccounts.filter { $0.id != id.uuidString },
            openCode: self.snapshot.openCode,
            pi: self.snapshot.pi,
            errors: self.snapshot.errors,
            updatedAt: self.snapshot.updatedAt)
        self.applyPrimaryCodexSelectionToSnapshot()
    }

    func selectPrimaryCodexAccount(_ id: UUID) {
        guard self.config.codexManagedAccounts.contains(where: { $0.id == id }) else { return }
        var next = self.config
        next.codexPrimaryAccountID = id
        guard self.persistConfig(next) else { return }
        self.applyPrimaryCodexSelectionToSnapshot()
    }

    @discardableResult
    func updateManagedAccountMetadata(id: UUID, email: String?, planType: String?, authenticatedNow: Bool = false) -> Bool {
        guard var profile = self.config.codexManagedAccounts.first(where: { $0.id == id }) else { return false }
        var next = self.config
        guard let index = next.codexManagedAccounts.firstIndex(where: { $0.id == id }) else { return false }
        profile.email = email ?? profile.email
        profile.planType = planType ?? profile.planType
        if authenticatedNow { profile.lastAuthenticatedAt = Date() }
        next.codexManagedAccounts[index] = profile
        guard ConfigStore.save(next) else { return false }
        self.config = next
        return true
    }

    func consumeCodexResetCredit(creditID: String, automatic: Bool = false) async throws -> CodexResetRedemptionResult {
        try await self.consumeCodexResetCredit(
            accountID: self.primaryCodexAccountKey,
            creditID: creditID,
            automatic: automatic)
    }

    func consumeCodexResetCredit(
        accountID: String,
        creditID: String,
        automatic: Bool = false) async throws -> CodexResetRedemptionResult
    {
        guard !automatic || (self.config.codexEnabled && self.config.autoRedeemExpiringCodexResets) else {
            throw CodexResetRedemptionError.selectedCreditUnavailable
        }
        guard !self.isRefreshing else { throw CodexResetRedemptionError.refreshInProgress }
        guard !self.isRedeemingCodexReset else { throw CodexResetRedemptionError.redemptionInProgress }
        guard !self.codexResetRefreshRequired.contains(accountID) else {
            throw CodexResetRedemptionError.accountUnavailable
        }
        guard self.snapshot.codexAccounts.contains(where: { $0.id == accountID && $0.usage != nil }) else {
            throw CodexResetRedemptionError.accountUnavailable
        }
        if automatic && accountID != self.primaryCodexAccountKey {
            throw CodexResetRedemptionError.selectedCreditUnavailable
        }

        self.isRedeemingCodexReset = true
        defer { self.isRedeemingCodexReset = false }

        let currentCodex = try await self.fetchCodexAccount(accountID: accountID)
        guard let currentResetCredits = currentCodex.resetCredits,
              currentResetCredits.availableCount > 0,
              let currentCredit = currentResetCredits.credits.first(where: { $0.id == creditID }),
              currentCredit.status?.lowercased() == "available"
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
            guard let expiry = currentCredit.expiresAt,
                  expiry > now,
                  expiry.timeIntervalSince(now) <= 60 * 60
            else {
                throw CodexResetRedemptionError.selectedCreditUnavailable
            }
        }

        if automatic {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            guard self.config.codexEnabled,
                  self.config.autoRedeemExpiringCodexResets,
                  settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
            else { throw CodexResetRedemptionError.selectedCreditUnavailable }
        }

        let attempt: PendingCodexResetRedemption
        if let pending = self.pendingCodexResetRedemption {
            guard pending.accountID == accountID, pending.creditID == creditID else {
                throw CodexResetRedemptionError.retryPendingReset
            }
            attempt = pending
        } else {
            attempt = PendingCodexResetRedemption(
                accountID: accountID,
                creditID: creditID,
                idempotencyKey: UUID().uuidString)
            try PendingCodexResetRedemptionStore.save(attempt)
            self.pendingCodexResetRedemption = attempt
        }

        let outcome = try await self.consumeCodexCredit(
            accountID: accountID,
            creditID: attempt.creditID,
            idempotencyKey: attempt.idempotencyKey)
        var pendingPersistenceError: String?
        do {
            try PendingCodexResetRedemptionStore.clear()
            self.pendingCodexResetRedemption = nil
        } catch {
            // Keep the in-memory pending record when its durable clear fails. A later retry must
            // reuse the same idempotency key rather than risking a second redemption.
            pendingPersistenceError = "Could not clear the durable reset record: \(error.localizedDescription)"
            self.codexResetRefreshRequired.insert(accountID)
        }

        do {
            let refreshedCodex = try await self.fetchCodexAccount(accountID: accountID)
            self.applyCodexRefresh(refreshedCodex, accountID: accountID)
            return CodexResetRedemptionResult(outcome: outcome, refreshError: pendingPersistenceError)
        } catch {
            self.codexResetRefreshRequired.insert(accountID)
            let refreshError = [pendingPersistenceError, error.localizedDescription]
                .compactMap { $0 }
                .joined(separator: " ")
            return CodexResetRedemptionResult(outcome: outcome, refreshError: refreshError)
        }
    }

    func refresh(onStart: () -> Void) async {
        guard !self.isRefreshing, !self.isRedeemingCodexReset else { return }
        self.isRefreshing = true
        onStart()
        defer { self.isRefreshing = false }

        AppLog.info("Refresh started: codex=\(self.config.codexEnabled) openCode=\(self.config.openCodeEnabled) pi=\(self.config.piEnabled) managedCodex=\(self.config.codexManagedAccounts.count)")

        var codexResult: CodexSnapshot?
        var codexAccounts: [CodexAccountSnapshot] = []
        var openCodeResult: OpenCodeSnapshot?
        var piResult: PiSnapshot?
        var errors: [String] = []

        if self.config.codexEnabled {
            let codexRefresh = await self.refreshCodexAccounts()
            codexResult = codexRefresh.selected
            codexAccounts = codexRefresh.accounts
            errors.append(contentsOf: codexRefresh.errors)
            if let codexResult {
                AppLog.info("Codex refresh succeeded via \(codexResult.sourceLabel)")
            }
        }

        if self.config.openCodeEnabled {
            do {
                openCodeResult = try await self.openCodeFetcher.fetch(
                    cookieHeader: self.config.openCodeCookieHeader,
                    workspaceID: self.config.openCodeWorkspaceID)
                AppLog.info("OpenCode refresh succeeded: workspace=\(openCodeResult?.workspaceID ?? "unknown") rows=\(openCodeResult?.rows.count ?? 0)")
            } catch {
                let message = "OpenCode Go: \(error.localizedDescription)"
                errors.append(message)
                AppLog.error(message)
            }
        }

        if self.config.piEnabled {
            do {
                let fetcher = self.piFetcher
                let sessionsDirectory = self.config.piSessionsDirectory
                let deduplicateForkHistory = self.config.piDeduplicateForkHistory
                piResult = try await Task.detached(priority: .utility) {
                    try fetcher.fetch(
                        sessionsDirectory: sessionsDirectory,
                        deduplicateForkHistory: deduplicateForkHistory)
                }.value
                AppLog.info("Pi refresh succeeded: sessions=\(piResult?.sessionCount ?? 0) rows=\(piResult?.rows.count ?? 0)")
            } catch {
                let message = "Pi: \(error.localizedDescription)"
                errors.append(message)
                AppLog.error(message)
            }
        }

        self.snapshot = AppSnapshot(
            codex: codexResult,
            codexAccounts: codexAccounts,
            openCode: openCodeResult,
            pi: piResult,
            errors: errors,
            updatedAt: Date())

        for account in codexAccounts {
            if let usage = account.usage {
                self.codexResetRefreshRequired.remove(account.id)
                self.clearResolvedPendingCodexReset(using: usage, accountID: account.id)
            }
        }
        if let pending = self.pendingCodexResetRedemption,
           !codexAccounts.contains(where: { $0.id == pending.accountID && $0.usage != nil }) {
            // Keep the unknown-result guard scoped to the account whose request is pending.
            self.codexResetRefreshRequired.insert(pending.accountID)
        }

        if errors.isEmpty {
            AppLog.info("Refresh completed without errors")
        } else {
            AppLog.error("Refresh completed with \(errors.count) error(s): \(errors.joined(separator: " | "))")
        }
    }

    private func refreshCodexAccounts() async -> (
        selected: CodexSnapshot?,
        accounts: [CodexAccountSnapshot],
        errors: [String])
    {
        let profiles = self.config.codexManagedAccounts
        var accounts: [CodexAccountSnapshot] = []
        var errors: [String] = []

        for profile in profiles {
            do {
                let usage = try await self.fetchManagedCodexAccount(id: profile.id)
                self.updateManagedAccountMetadata(
                    id: profile.id,
                    email: usage.email,
                    planType: usage.planType)
                accounts.append(CodexAccountSnapshot(
                    id: profile.id.uuidString,
                    label: profile.label,
                    email: usage.email ?? profile.email,
                    usage: usage,
                    error: nil))
            } catch {
                let message = "Codex \(profile.label): \(error.localizedDescription)"
                accounts.append(CodexAccountSnapshot(
                    id: profile.id.uuidString,
                    label: profile.label,
                    email: profile.email,
                    usage: nil,
                    error: error.localizedDescription))
                errors.append(message)
                AppLog.error(message)
            }
        }

        let selected = accounts.first {
            $0.id == self.primaryCodexAccountKey && $0.usage != nil
        }?.usage
        return (selected: selected, accounts: accounts, errors: errors)
    }

    private func fetchManagedCodexAccount(id: UUID) async throws -> CodexSnapshot {
        try self.managedHomeStore.secureAuthFile(for: id)
        do {
            let usage = try await self.codexFetcher.fetchManaged(codexHome: self.managedHomeStore.homeURL(for: id))
            try self.managedHomeStore.secureAuthFile(for: id)
            return usage
        } catch {
            do {
                try self.managedHomeStore.secureAuthFile(for: id)
            } catch let hardeningError {
                throw hardeningError
            }
            throw error
        }
    }

    private func fetchCodexAccount(accountID: String) async throws -> CodexSnapshot {
        guard let id = UUID(uuidString: accountID),
              self.config.codexManagedAccounts.contains(where: { $0.id == id })
        else { throw CodexResetRedemptionError.accountUnavailable }
        return try await self.fetchManagedCodexAccount(id: id)
    }

    private func consumeCodexCredit(accountID: String, creditID: String, idempotencyKey: String) async throws -> String {
        guard let id = UUID(uuidString: accountID),
              self.config.codexManagedAccounts.contains(where: { $0.id == id })
        else { throw CodexResetRedemptionError.accountUnavailable }
        return try await self.codexFetcher.consumeResetCredit(
            creditID: creditID,
            idempotencyKey: idempotencyKey,
            codexHome: self.managedHomeStore.homeURL(for: id))
    }

    private func applyCodexRefresh(_ codex: CodexSnapshot, accountID: String) {
        var accounts = self.snapshot.codexAccounts
        if let index = accounts.firstIndex(where: { $0.id == accountID }) {
            let old = accounts[index]
            accounts[index] = CodexAccountSnapshot(
                id: old.id,
                label: old.label,
                email: codex.email ?? old.email,
                usage: codex,
                error: nil)
        }
        let selected = accounts.first { $0.id == self.primaryCodexAccountKey && $0.usage != nil }?.usage
        self.snapshot = AppSnapshot(
            codex: selected,
            codexAccounts: accounts,
            openCode: self.snapshot.openCode,
            pi: self.snapshot.pi,
            errors: self.snapshot.errors.filter { !$0.hasPrefix("Codex") },
            updatedAt: Date())
        self.codexResetRefreshRequired.remove(accountID)
        self.clearResolvedPendingCodexReset(using: codex, accountID: accountID)
    }

    private func clearResolvedPendingCodexReset(using codex: CodexSnapshot, accountID: String) {
        guard let pending = self.pendingCodexResetRedemption,
              pending.accountID == accountID,
              let credits = codex.resetCredits?.credits,
              !credits.isEmpty,
              !credits.contains(where: { $0.id == pending.creditID })
        else {
            return
        }
        do {
            try PendingCodexResetRedemptionStore.clear()
            self.pendingCodexResetRedemption = nil
        } catch {
            AppLog.error("Could not clear the resolved Codex reset record: \(error.localizedDescription)")
        }
    }

    private func applyPrimaryCodexSelectionToSnapshot() {
        let selected = self.snapshot.codexAccounts.first {
            $0.id == self.primaryCodexAccountKey && $0.usage != nil
        }?.usage
        self.snapshot = AppSnapshot(
            codex: selected,
            codexAccounts: self.snapshot.codexAccounts,
            openCode: self.snapshot.openCode,
            pi: self.snapshot.pi,
            errors: self.snapshot.errors,
            updatedAt: self.snapshot.updatedAt)
    }

    private static func normalizedAccountLabel(_ value: String) -> String {
        let flattened = value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard flattened.count > 80 else { return flattened }
        return String(flattened.prefix(80)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

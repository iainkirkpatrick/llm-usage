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

private struct PendingCodexResetRedemptionStore {
    let fileURL: URL

    private func prepareDirectory() throws {
        if self.fileURL.deletingLastPathComponent().standardizedFileURL == ConfigStore.appDirectoryURL.standardizedFileURL {
            try ConfigStore.ensureAppDirectory()
        } else {
            try AppOwnedPathSafety.ensureDirectoryTree(at: self.fileURL.deletingLastPathComponent(), permissions: 0o700)
        }
        try AppOwnedPathSafety.validateRegularFile(at: self.fileURL)
    }

    func load() -> PendingCodexResetRedemption? {
        guard (try? self.prepareDirectory()) != nil,
              let data = try? Data(contentsOf: self.fileURL)
        else { return nil }
        return try? JSONDecoder().decode(PendingCodexResetRedemption.self, from: data)
    }

    func save(_ pending: PendingCodexResetRedemption) throws {
        try self.prepareDirectory()
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

    func clear() throws {
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
    private(set) var isHandingOffCodexAccount = false
    private(set) var handoffRecoveryError: String?
    private(set) var detectedPiCodexAccountID: UUID?
    private var piUsageObservation = PiCodexUsageObservation(accountID: nil, error: "Not checked yet")
    private(set) var isAuthenticatingClaudeAccount = false
    private(set) var authenticatingClaudeAccountID: UUID?
    private let claudeFetcher = ClaudeUsageFetcher()
    private let claudeSessionsFetcher = ClaudeSessionsFetcher()
    private var isRedeemingCodexReset = false
    private var pendingCodexResetRedemption: PendingCodexResetRedemption?
    private var codexResetRefreshRequired = Set<String>()

    private let codexFetcher: any CodexUsageFetching
    private let codexLoginRunner = CodexLoginRunner()
    private let managedHomeStore: ManagedCodexHomeStore
    private let piCodexHandoff: PiCodexCredentialHandoff
    private let pendingCodexResetStore: PendingCodexResetRedemptionStore
    private let openCodeFetcher = OpenCodeGoFetcher()
    private let piFetcher = PiSessionsFetcher()
    private var config: AppConfig
    private let logInfo: (String) -> Void
    private let logError: (String) -> Void

    init(
        config: AppConfig,
        codexFetcher: any CodexUsageFetching = CodexNodeBridge(),
        piCodexHandoff: PiCodexCredentialHandoff = PiCodexCredentialHandoff(),
        pendingCodexResetURL: URL = ConfigStore.appDirectoryURL.appendingPathComponent("pending-codex-reset.json"),
        logInfo: @escaping (String) -> Void = AppLog.info,
        logError: @escaping (String) -> Void = AppLog.error)
    {
        self.config = config
        self.logInfo = logInfo
        self.logError = logError
        self.codexFetcher = codexFetcher
        self.piCodexHandoff = piCodexHandoff
        self.managedHomeStore = piCodexHandoff.managedHomeStore
        self.pendingCodexResetStore = PendingCodexResetRedemptionStore(fileURL: pendingCodexResetURL)
        self.normalizePrimaryCodexAccount()
        self.pendingCodexResetRedemption = self.pendingCodexResetStore.load()
        do {
            try self.managedHomeStore.recoverQuarantinedHomes(
                for: Set(config.codexManagedAccounts.map(\.id)))
        } catch {
            self.logError("Managed Codex removal recovery failed: \(error.localizedDescription)")
        }
        do {
            try self.piCodexHandoff.recoverIfNeeded(config: self.config)
        } catch {
            self.recordHandoffFailureIfJournalRemains(error)
        }
        self.observePiAccount()
        self.applyClaudeAccountListToSnapshot()
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

    var piHandoffAccountID: UUID? {
        self.config.codexPiHandoffAccountID
    }

    var activePiCodexAccountID: UUID? { self.detectedPiCodexAccountID }

    var isPiHandoffOutOfSync: Bool {
        self.piUsageObservation.handoffIsOutOfSync(
            profiles: self.managedCodexAccounts, recordedHandoff: self.piHandoffAccountID)
    }

    var piHandoffStatus: String {
        if let error = self.handoffRecoveryError {
            return "Pi handoff needs recovery: \(error)"
        }
        if self.isPiHandoffOutOfSync {
            let actual = self.detectedPiCodexAccountID.flatMap { id in
                self.managedCodexAccounts.first(where: { $0.id == id })?.label
            } ?? "an unknown or unavailable account"
            return "Pi login changed externally; currently \(actual). Clear the stale handoff to recover."
        }
        if let id = self.config.codexPiHandoffAccountID,
           let profile = self.config.codexManagedAccounts.first(where: { $0.id == id })
        {
            return "Active in Pi: \(profile.label)"
        }
        if let id = self.detectedPiCodexAccountID,
           let profile = self.config.codexManagedAccounts.first(where: { $0.id == id })
        {
            return "Active in Pi: \(profile.label) (not managed yet)"
        }
        return "No managed Codex account is active in Pi"
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
        do {
            try self.piCodexHandoff.recoverIfNeeded(config: self.config)
            self.handoffRecoveryError = nil
        } catch {
            self.recordHandoffFailureIfJournalRemains(error)
        }
        self.observePiAccount()
        self.applyPrimaryCodexSelectionToSnapshot()
        self.applyClaudeAccountListToSnapshot()
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
        self.isRefreshing || self.isRedeemingCodexReset || self.isAuthenticatingCodexAccount || self.isHandingOffCodexAccount || self.isAuthenticatingClaudeAccount
    }

    func canRedeemCodexResets(for accountID: String) -> Bool {
        // Read-only observation must never authorize spending through a stale native copy.
        guard let id = UUID(uuidString: accountID),
              let profile = self.managedCodexAccounts.first(where: { $0.id == id }) else { return false }
        if case .unavailable = self.piUsageObservation.spendingSource(
            for: profile, profiles: self.managedCodexAccounts, recordedHandoff: self.piHandoffAccountID) { return false }
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

    func pendingCodexResetCreditID(for accountID: String) -> String? {
        guard let pending = self.pendingCodexResetRedemption, pending.accountID == accountID else { return nil }
        return pending.creditID
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
        guard self.config.codexPiHandoffAccountID != id else {
            throw PiCodexCredentialHandoffError.handoffStateInvalid(
                "sign in again is disabled while this account is active in Pi; release the Pi handoff first")
        }
        if let handoffRecoveryError {
            throw PiCodexCredentialHandoffError.recoveryRequired(handoffRecoveryError)
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
            let authenticatedAccountID = try self.managedHomeStore.commitStagedAuth(for: id, stagingHome: stagingHome)
            try self.managedHomeStore.removeLoginStagingHome(stagingHome, accountID: id)
            shouldCleanStaging = false
            guard self.updateManagedAccountMetadata(
                id: id,
                email: nil,
                planType: nil,
                accountID: authenticatedAccountID,
                authenticatedNow: true) else {
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
        guard self.config.codexPiHandoffAccountID != id else {
            throw PiCodexCredentialHandoffError.handoffStateInvalid(
                "release the Pi handoff before removing this account")
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
            claudeAccounts: self.snapshot.claudeAccounts,
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
    func useManagedCodexAccountInPi(id: UUID) async throws -> String? {
        guard !self.isCodexAccountOperationInProgress else {
            throw ManagedCodexAccountError.accountOperationInProgress
        }
        guard self.config.codexManagedAccounts.contains(where: { $0.id == id }) else {
            throw PiCodexCredentialHandoffError.accountNotFound
        }
        if let handoffRecoveryError {
            throw PiCodexCredentialHandoffError.recoveryRequired(handoffRecoveryError)
        }
        let configAtStart = self.config
        guard let expectedConfig = ConfigStore.diskSnapshot(matching: configAtStart) else {
            throw PiCodexCredentialHandoffError.concurrentChange(
                "the managed-account configuration on disk is stale")
        }

        self.isHandingOffCodexAccount = true
        defer { self.isHandingOffCodexAccount = false }
        let handoff = self.piCodexHandoff
        let result: PiCodexHandoffResult
        do {
            result = try await Task.detached(priority: .utility) {
                try handoff.activate(
                    accountID: id,
                    config: configAtStart,
                    saveConfig: { next in
                        ConfigStore.saveIfUnchanged(next, expected: expectedConfig)
                    })
            }.value
        } catch {
            self.recordHandoffFailureIfJournalRemains(error)
            throw error
        }
        self.config = result.config
        self.observePiAccount()
        if let warning = result.warning,
           let journalInfo = try? AppOwnedPathSafety.info(at: self.piCodexHandoff.journalURL),
           journalInfo.exists
        {
            self.handoffRecoveryError = warning
        } else {
            // A journal-first cleanup failure leaves only a nonessential protected backup; it does
            // not block future handoffs because there is no recovery authority left to replay.
            self.handoffRecoveryError = nil
        }
        self.applyPrimaryCodexSelectionToSnapshot()
        return result.warning
    }

    @discardableResult
    func releaseManagedCodexAccountFromPi(id: UUID) async throws -> String? {
        guard !self.isCodexAccountOperationInProgress else {
            throw ManagedCodexAccountError.accountOperationInProgress
        }
        guard self.config.codexPiHandoffAccountID == id else {
            throw PiCodexCredentialHandoffError.handoffStateInvalid("this account is not active in Pi")
        }
        if let handoffRecoveryError {
            throw PiCodexCredentialHandoffError.recoveryRequired(handoffRecoveryError)
        }
        let configAtStart = self.config
        guard let expectedConfig = ConfigStore.diskSnapshot(matching: configAtStart) else {
            throw PiCodexCredentialHandoffError.concurrentChange(
                "the managed-account configuration on disk is stale")
        }

        self.isHandingOffCodexAccount = true
        defer { self.isHandingOffCodexAccount = false }
        let handoff = self.piCodexHandoff
        let result: PiCodexHandoffResult
        do {
            result = try await Task.detached(priority: .utility) {
                try handoff.deactivate(
                    accountID: id,
                    config: configAtStart,
                    saveConfig: { next in
                        ConfigStore.saveIfUnchanged(next, expected: expectedConfig)
                    })
            }.value
        } catch {
            self.recordHandoffFailureIfJournalRemains(error)
            throw error
        }
        self.config = result.config
        self.observePiAccount()
        if let warning = result.warning,
           let journalInfo = try? AppOwnedPathSafety.info(at: self.piCodexHandoff.journalURL),
           journalInfo.exists
        {
            self.handoffRecoveryError = warning
        } else {
            self.handoffRecoveryError = nil
        }
        self.applyPrimaryCodexSelectionToSnapshot()
        return result.warning
    }

    private func recordHandoffFailureIfJournalRemains(_ error: Error) {
        guard let info = try? AppOwnedPathSafety.info(at: self.piCodexHandoff.journalURL),
              info.exists else {
            self.handoffRecoveryError = nil
            return
        }
        self.handoffRecoveryError = error.localizedDescription
        self.logError("Pi Codex handoff requires recovery: \(error.localizedDescription)")
    }

    @discardableResult
    func updateManagedAccountMetadata(
        id: UUID,
        email: String?,
        planType: String?,
        accountID: String? = nil,
        authenticatedNow: Bool = false) -> Bool
    {
        guard var profile = self.config.codexManagedAccounts.first(where: { $0.id == id }) else { return false }
        var next = self.config
        guard let index = next.codexManagedAccounts.firstIndex(where: { $0.id == id }) else { return false }
        profile.email = email ?? profile.email
        profile.planType = planType ?? profile.planType
        if let accountID, !accountID.isEmpty {
            if let existing = profile.accountID, existing != accountID { return false }
            profile.accountID = accountID
        }
        if authenticatedNow { profile.lastAuthenticatedAt = Date() }
        guard profile != next.codexManagedAccounts[index] else { return true }
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

        let existingAttempt = self.pendingCodexResetRedemption
        if let existingAttempt {
            guard existingAttempt.accountID == accountID, existingAttempt.creditID == creditID else {
                throw CodexResetRedemptionError.retryPendingReset
            }
        }
        self.isRedeemingCodexReset = true
        defer { self.isRedeemingCodexReset = false }

        let currentCodex = try await self.fetchCodexAccount(accountID: accountID)
        // A lost successful response may leave this credit redeemed, expired, or absent. Only
        // NEW requests require availability; an exact pending retry must reuse its original key.
        if existingAttempt == nil {
            guard let currentResetCredits = currentCodex.resetCredits,
                  currentResetCredits.availableCount > 0,
                  let currentCredit = currentResetCredits.credits.first(where: { $0.id == creditID }),
                  currentCredit.status?.lowercased() == "available"
            else {
                throw CodexResetRedemptionError.selectedCreditUnavailable
            }
            if automatic {
                let now = Date()
                guard let expiry = currentCredit.expiresAt,
                      expiry > now,
                      expiry.timeIntervalSince(now) <= 60 * 60
                else {
                    throw CodexResetRedemptionError.selectedCreditUnavailable
                }
            }
        }

        if automatic {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            guard self.config.codexEnabled,
                  self.config.autoRedeemExpiringCodexResets,
                  settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
            else { throw CodexResetRedemptionError.selectedCreditUnavailable }
        }

        // Finish all local ownership/credential checks before recording an uncertain request.
        // There is no suspension between this fresh observation, persistence, and bridge dispatch.
        let target = try self.prepareCodexReset(accountID: accountID)
        let attempt: PendingCodexResetRedemption
        if let existingAttempt {
            attempt = existingAttempt
        } else {
            attempt = PendingCodexResetRedemption(
                accountID: accountID,
                creditID: creditID,
                idempotencyKey: UUID().uuidString)
            try self.pendingCodexResetStore.save(attempt)
            self.pendingCodexResetRedemption = attempt
        }

        // Once dispatched, errors may hide a successful consume. Preserve the durable attempt
        // and reuse its key on retry; never clear it merely because the bridge reports an error.
        let outcome = try await self.codexFetcher.consumeResetCredit(
            creditID: attempt.creditID,
            idempotencyKey: attempt.idempotencyKey,
            expectedChatGPTAccountID: target.expectedAccountID,
            codexHome: target.codexHome)
        var pendingPersistenceError: String?
        do {
            try self.pendingCodexResetStore.clear()
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
        guard !self.isRefreshing, !self.isRedeemingCodexReset, !self.isAuthenticatingClaudeAccount else { return }
        self.isRefreshing = true
        onStart()
        defer { self.isRefreshing = false }

        self.logInfo("Refresh started: codex=\(self.config.codexEnabled) openCode=\(self.config.openCodeEnabled) pi=\(self.config.piEnabled) managedCodex=\(self.config.codexManagedAccounts.count)")

        self.observePiAccount()

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
                self.logInfo("Codex refresh succeeded via \(codexResult.sourceLabel)")
            }
        }

        if self.config.openCodeEnabled {
            do {
                openCodeResult = try await self.openCodeFetcher.fetch(
                    cookieHeader: self.config.openCodeCookieHeader,
                    workspaceID: self.config.openCodeWorkspaceID)
                self.logInfo("OpenCode refresh succeeded: workspace=\(openCodeResult?.workspaceID ?? "unknown") rows=\(openCodeResult?.rows.count ?? 0)")
            } catch {
                let message = "OpenCode Go: \(error.localizedDescription)"
                errors.append(message)
                self.logError(message)
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
                self.logInfo("Pi refresh succeeded: sessions=\(piResult?.sessionCount ?? 0) rows=\(piResult?.rows.count ?? 0)")
            } catch {
                let message = "Pi: \(error.localizedDescription)"
                errors.append(message)
                self.logError(message)
            }
        }

        var claudeAccounts: [ClaudeAccountSnapshot] = []
        if self.config.claudeEnabled {
            for profile in self.config.claudeAccounts {
                let account = await self.fetchClaudeAccount(profile: profile, allowKeychainPrompt: false)
                claudeAccounts.append(account)
                if let error = account.quotaError { errors.append("Claude \(profile.label): \(error)") }
                if let error = account.localError { errors.append("Claude \(profile.label) local logs: \(error)") }
            }
        }

        self.snapshot = AppSnapshot(
            codex: codexResult,
            codexAccounts: codexAccounts,
            claudeAccounts: claudeAccounts,
            openCode: openCodeResult,
            pi: piResult,
            errors: errors,
            updatedAt: Date())

        for account in codexAccounts where account.usage != nil {
            self.codexResetRefreshRequired.remove(account.id)
        }
        if let pending = self.pendingCodexResetRedemption,
           !codexAccounts.contains(where: { $0.id == pending.accountID && $0.usage != nil }) {
            // Keep the unknown-result guard scoped to the account whose request is pending.
            self.codexResetRefreshRequired.insert(pending.accountID)
        }

        if errors.isEmpty {
            self.logInfo("Refresh completed without errors")
        } else {
            self.logError("Refresh completed with \(errors.count) error(s): \(errors.joined(separator: " | "))")
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
                self.logError(message)
            }
        }

        let selected = accounts.first {
            $0.id == self.primaryCodexAccountKey && $0.usage != nil
        }?.usage
        return (selected: selected, accounts: accounts, errors: errors)
    }

    private func resolvedManagedCodexProfile(id: UUID) throws -> CodexManagedAccountProfile {
        guard var profile = self.managedCodexAccounts.first(where: { $0.id == id }) else {
            throw ManagedCodexAccountError.accountNotFound
        }
        // Legacy homes may predate identity metadata. Resolve before choosing a credential source,
        // otherwise a duplicate of Pi's live account would incorrectly refresh as a native home.
        if profile.accountID == nil {
            guard let identity = try self.managedHomeStore.accountID(for: id) else {
                throw CodexResetRedemptionError.accountUnavailable
            }
            guard self.updateManagedAccountMetadata(id: id, email: nil, planType: nil, accountID: identity) else {
                throw PiCodexCredentialHandoffError.configSaveFailed
            }
            profile.accountID = identity
        }
        return profile
    }

    private func fetchManagedCodexAccount(id: UUID) async throws -> CodexSnapshot {
        let profile = try self.resolvedManagedCodexProfile(id: id)
        self.observePiAccount()
        switch self.piUsageObservation.source(for: profile, profiles: self.managedCodexAccounts, recordedHandoff: self.piHandoffAccountID) {
        case .pi:
            guard let expected = profile.accountID else { throw CodexResetRedemptionError.accountUnavailable }
            try self.piCodexHandoff.validateActiveCredential(for: profile)
            let usage = try await self.codexFetcher.fetchPiAuth(expectedAccountID: expected)
            try self.piCodexHandoff.validateActiveCredential(for: profile)
            return usage
        case let .unavailable(message):
            throw PiCodexCredentialHandoffError.handoffStateInvalid(message)
        case .native: break
        }

        try self.managedHomeStore.secureAuthFile(for: id)
        let nativeID = try self.managedHomeStore.accountID(for: id)
        guard nativeID == profile.accountID else {
            throw PiCodexCredentialHandoffError.managedCredentialIdentityMismatch(
                expected: profile.accountID ?? "unavailable", actual: nativeID ?? "unavailable")
        }
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

    private func prepareCodexReset(accountID: String) throws -> (expectedAccountID: String, codexHome: URL?) {
        guard let id = UUID(uuidString: accountID) else { throw CodexResetRedemptionError.accountUnavailable }
        let profile = try self.resolvedManagedCodexProfile(id: id)
        // This fresh execution-time observation is essential: Pi can change after menu preflight.
        // Read-only tracking of an unowned Pi login must never fall through to native spending.
        self.observePiAccount()
        let source = self.piUsageObservation.spendingSource(
            for: profile, profiles: self.managedCodexAccounts, recordedHandoff: self.piHandoffAccountID)
        if case let .unavailable(message) = source {
            throw PiCodexCredentialHandoffError.handoffStateInvalid(message)
        }
        if source == .pi {
            guard let profileAccountID = profile.accountID, !profileAccountID.isEmpty else {
                throw CodexResetRedemptionError.accountUnavailable
            }
            try self.piCodexHandoff.validateActiveCredential(for: profile)
            return (profileAccountID, nil)
        }

        try self.managedHomeStore.secureAuthFile(for: id, requireExisting: true)
        let discoveredAccountID = try self.managedHomeStore.accountID(for: id)
        guard let profileAccountID = profile.accountID, !profileAccountID.isEmpty else {
            throw CodexResetRedemptionError.accountUnavailable
        }
        guard discoveredAccountID == profileAccountID else {
            throw PiCodexCredentialHandoffError.managedCredentialIdentityMismatch(
                expected: profileAccountID, actual: discoveredAccountID ?? "unavailable")
        }
        return (profileAccountID, self.managedHomeStore.homeURL(for: id))
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
            claudeAccounts: self.snapshot.claudeAccounts,
            openCode: self.snapshot.openCode,
            pi: self.snapshot.pi,
            errors: self.snapshot.errors.filter { !$0.hasPrefix("Codex") },
            updatedAt: Date())
        self.codexResetRefreshRequired.remove(accountID)
        // A missing/terminal credit is not a confirmed outcome. Keep an unknown request and its
        // idempotency key until the explicit retry returns an authoritative consume result.
    }

    private func applyPrimaryCodexSelectionToSnapshot() {
        let selected = self.snapshot.codexAccounts.first {
            $0.id == self.primaryCodexAccountKey && $0.usage != nil
        }?.usage
        self.snapshot = AppSnapshot(
            codex: selected,
            codexAccounts: self.snapshot.codexAccounts,
            claudeAccounts: self.snapshot.claudeAccounts,
            openCode: self.snapshot.openCode,
            pi: self.snapshot.pi,
            errors: self.snapshot.errors,
            updatedAt: self.snapshot.updatedAt)
    }

    private func observePiAccount() {
        do {
            let accountID = try self.piCodexHandoff.piAuthStore.currentOAuthAccountID()
            self.piUsageObservation = PiCodexUsageObservation(accountID: accountID, error: nil)
        } catch {
            self.piUsageObservation = PiCodexUsageObservation(accountID: nil, error: error.localizedDescription)
        }
        self.detectedPiCodexAccountID = self.piUsageObservation.matchingProfile(in: self.managedCodexAccounts)
    }

    func forgetStalePiHandoff() async throws {
        guard !self.isCodexAccountOperationInProgress else { throw ManagedCodexAccountError.accountOperationInProgress }
        let configAtStart = self.config
        guard let expected = ConfigStore.diskSnapshot(matching: configAtStart) else {
            throw PiCodexCredentialHandoffError.configSaveFailed
        }
        self.isHandingOffCodexAccount = true
        defer { self.isHandingOffCodexAccount = false }
        let handoff = self.piCodexHandoff
        let next = try await Task.detached(priority: .utility) {
            try handoff.forgetStaleHandoff(config: configAtStart) { next in
                ConfigStore.saveIfUnchanged(next, expected: expected)
            }
        }.value
        self.config = next
        self.observePiAccount()
    }

    var claudeAccounts: [ClaudeAccountProfile] { self.config.claudeAccounts }

    func createClaudeAccount(label: String) throws -> ClaudeAccountProfile {
        guard !self.isCodexAccountOperationInProgress else { throw ClaudeProfileError.busy }
        let label = Self.normalizedAccountLabel(label)
        guard !label.isEmpty else { throw ClaudeProfileError.invalidLabel }
        let id = UUID()
        try ConfigStore.ensureAppDirectory()
        let root = ConfigStore.appDirectoryURL.appendingPathComponent("claude-accounts", isDirectory: true)
        try AppOwnedPathSafety.ensureDirectory(at: root)
        let directory = root.appendingPathComponent(id.uuidString, isDirectory: true)
        try AppOwnedPathSafety.ensureDirectory(at: directory)
        // Use this stable path for login: Keychain service names depend on the config directory.
        let profile = ClaudeAccountProfile(id: id, label: label, configDirectory: directory.path)
        return try self.registerClaudeAccount(profile)
    }

    func addClaudeAccount(label: String, configDirectory: String?) throws -> ClaudeAccountProfile {
        guard !self.isCodexAccountOperationInProgress else { throw ClaudeProfileError.busy }
        let label = Self.normalizedAccountLabel(label)
        guard !label.isEmpty else { throw ClaudeProfileError.invalidLabel }
        if let raw = configDirectory,
           !(raw as NSString).expandingTildeInPath.hasPrefix("/") { throw ClaudeProfileError.invalidDirectory }
        let directory = configDirectory.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).standardizedFileURL.path }
        return try self.registerClaudeAccount(ClaudeAccountProfile(label: label, configDirectory: directory))
    }

    private func registerClaudeAccount(_ profile: ClaudeAccountProfile) throws -> ClaudeAccountProfile {
        try ClaudeProfileValidation.validate(profile, among: self.claudeAccounts)
        var next = self.config
        next.claudeAccounts.append(profile)
        guard ConfigStore.save(next) else { throw ClaudeProfileError.saveFailed }
        self.config = next
        self.applyClaudeAccountListToSnapshot()
        return profile
    }

    func removeClaudeAccount(id: UUID) throws {
        guard !self.isCodexAccountOperationInProgress else { throw ClaudeProfileError.busy }
        guard self.claudeAccounts.contains(where: { $0.id == id }) else { throw ClaudeProfileError.notFound }
        var next = self.config
        next.claudeAccounts.removeAll { $0.id == id }
        guard ConfigStore.save(next) else { throw ClaudeProfileError.saveFailed }
        self.config = next
        // Never delete another application's settings, history, or Keychain item.
        self.applyClaudeAccountListToSnapshot()
    }

    func authenticateClaudeAccount(id: UUID) async throws {
        guard !self.isCodexAccountOperationInProgress else { throw ClaudeProfileError.busy }
        guard let profile = self.claudeAccounts.first(where: { $0.id == id }) else { throw ClaudeProfileError.notFound }
        self.isAuthenticatingClaudeAccount = true
        self.authenticatingClaudeAccountID = id
        do {
            try await ClaudeCLI.login(profile: profile)
        } catch {
            self.isAuthenticatingClaudeAccount = false
            self.authenticatingClaudeAccountID = nil
            throw error
        }
        self.isAuthenticatingClaudeAccount = false
        self.authenticatingClaudeAccountID = nil
        await self.refreshClaudeAccount(id: id, allowKeychainPrompt: true)
    }

    func refreshClaudeAccount(id: UUID, allowKeychainPrompt: Bool) async {
        guard !self.isCodexAccountOperationInProgress,
              let profile = self.claudeAccounts.first(where: { $0.id == id }) else { return }
        self.isRefreshing = true
        defer { self.isRefreshing = false }
        let result = await self.fetchClaudeAccount(profile: profile, allowKeychainPrompt: allowKeychainPrompt)
        guard self.claudeAccounts.contains(where: { $0.id == id }) else { return }
        var accounts = self.snapshot.claudeAccounts.filter { $0.id != id }
        accounts.append(result)
        let order = self.claudeAccounts.map(\.id)
        self.replaceClaudeSnapshots(accounts.sorted { order.firstIndex(of: $0.id)! < order.firstIndex(of: $1.id)! })
    }

    private func fetchClaudeAccount(profile: ClaudeAccountProfile, allowKeychainPrompt: Bool) async -> ClaudeAccountSnapshot {
        let sessions = self.claudeSessionsFetcher
        let localTask = Task.detached(priority: .utility) { try sessions.fetch(profile: profile) }
        var quota: ClaudeQuotaSnapshot?
        var quotaError: String?
        do {
            quota = try await self.claudeFetcher.fetch(profile: profile, allowKeychainPrompt: allowKeychainPrompt)
            if let quota, let index = self.config.claudeAccounts.firstIndex(where: { $0.id == profile.id }),
               self.config.claudeAccounts[index].accountID != quota.accountID || self.config.claudeAccounts[index].email != quota.email {
                var next = self.config
                next.claudeAccounts[index].accountID = quota.accountID
                next.claudeAccounts[index].email = quota.email
                guard ConfigStore.save(next) else { throw ClaudeProfileError.saveFailed }
                self.config = next
            }
        } catch { quotaError = error.localizedDescription; quota = nil }
        var local: ClaudeLocalUsage?
        var localError: String?
        do { local = try await localTask.value }
        catch { localError = error.localizedDescription }
        return ClaudeAccountSnapshot(id: profile.id, label: profile.label, quota: quota, localUsage: local,
                                     quotaError: quotaError, localError: localError)
    }

    private func applyClaudeAccountListToSnapshot() {
        let existing = self.snapshot.claudeAccounts
        self.replaceClaudeSnapshots(self.claudeAccounts.map { profile in
            existing.first(where: { $0.id == profile.id }) ?? ClaudeAccountSnapshot(
                id: profile.id, label: profile.label, quota: nil, localUsage: nil, quotaError: nil, localError: nil)
        })
    }

    private func replaceClaudeSnapshots(_ accounts: [ClaudeAccountSnapshot]) {
        var errors = self.snapshot.errors.filter { !$0.hasPrefix("Claude ") }
        for account in accounts {
            if let error = account.quotaError { errors.append("Claude \(account.label): \(error)") }
            if let error = account.localError { errors.append("Claude \(account.label) local logs: \(error)") }
        }
        self.snapshot = AppSnapshot(codex: self.snapshot.codex, codexAccounts: self.snapshot.codexAccounts,
                                    claudeAccounts: accounts, openCode: self.snapshot.openCode, pi: self.snapshot.pi,
                                    errors: errors, updatedAt: self.snapshot.updatedAt)
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

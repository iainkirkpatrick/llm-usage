import AppKit
import Foundation
import UserNotifications

@MainActor
final class AppController: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var refreshTask: Task<Void, Never>?
    private var state: AppState!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        if self.hasExistingInstance() {
            NSApp.terminate(nil)
            return
        }

        ConfigStore.writeDefaultIfMissing()
        self.state = AppState(config: ConfigStore.load())

        if let button = self.statusItem.button {
            button.title = "LLM"
            button.image = nil
            button.imagePosition = .imageLeading
        }

        self.rebuildMenu()

        Task { [weak self] in
            await self?.refreshAndUpdateMenu()
        }

        self.startRefreshLoop()
    }

    func applicationWillTerminate(_ notification: Notification) {
        self.refreshTask?.cancel()
    }

    private func hasExistingInstance() -> Bool {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let currentPath = Bundle.main.executableURL?.resolvingSymlinksInPath().path
            ?? ProcessInfo.processInfo.arguments.first

        for app in NSWorkspace.shared.runningApplications {
            guard app.processIdentifier != currentPID else { continue }

            if let currentPath,
               let otherPath = app.executableURL?.resolvingSymlinksInPath().path,
               otherPath == currentPath
            {
                return true
            }
        }

        return false
    }

    private func startRefreshLoop() {
        self.refreshTask?.cancel()
        self.refreshTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(self.state.refreshInterval * 1_000_000_000))
                await self.refreshAndUpdateMenu()
            }
        }
    }

    private func refreshAndUpdateMenu() async {
        await self.state.refresh {
            self.rebuildMenu()
        }
        await self.handleExpiringCodexResets()
        self.rebuildMenu()
    }

    private func handleExpiringCodexResets() async {
        guard let resetCredits = self.state.snapshot.codex?.resetCredits else { return }
        let now = Date()
        let expiringCredits = resetCredits.credits
            .compactMap { credit -> (credit: CodexResetCredit, expiry: Date)? in
                guard let expiry = credit.expiresAt, expiry > now else { return nil }
                return (credit, expiry)
            }
            .sorted { $0.expiry < $1.expiry }

        for item in expiringCredits {
            let seconds = item.expiry.timeIntervalSince(now)
            let label = item.credit.title ?? item.credit.description ?? "Saved Codex reset"
            if seconds <= 24 * 60 * 60 {
                self.sendResetExpiryNotificationOnce(
                    key: "\(item.credit.id):24h",
                    title: "Codex reset expires soon",
                    body: "\(label) expires in \(Formatting.relativeReset(item.expiry))."
                )
            }
            if seconds <= 6 * 60 * 60 {
                self.sendResetExpiryNotificationOnce(
                    key: "\(item.credit.id):6h",
                    title: "Codex reset expires in \(Formatting.relativeReset(item.expiry))",
                    body: "\(label) is still available."
                )
            }
        }

        guard self.state.currentConfig.autoRedeemExpiringCodexResets,
              self.state.canRedeemCodexResets,
              await self.notificationsAuthorized(),
              let candidate = expiringCredits.first,
              candidate.expiry.timeIntervalSince(now) <= 60 * 60,
              self.claimAutoRedemptionAttempt(for: candidate.credit.id, now: now)
        else {
            return
        }

        do {
            let result = try await self.state.consumeCodexResetCredit(creditID: candidate.credit.id, automatic: true)
            let label = candidate.credit.title ?? candidate.credit.description ?? "Saved Codex reset"
            let body: String
            switch result.outcome {
            case "reset", "alreadyRedeemed", "already_redeemed":
                body = "\(label) was redeemed automatically before expiry."
            default:
                body = "\(label) was not redeemed automatically (\(result.outcome))."
            }
            self.sendResetExpiryNotificationOnce(
                key: "\(candidate.credit.id):auto",
                title: "Codex expiring reset checked",
                body: body
            )
        } catch {
            self.sendResetExpiryNotificationOnce(
                key: "\(candidate.credit.id):auto-error",
                title: "Could not auto-use Codex reset",
                body: error.localizedDescription
            )
        }
    }

    private func sendResetExpiryNotificationOnce(key: String, title: String, body: String) {
        guard self.claimPersistentKey(key, storageKey: "codex-reset-expiry-notifications") else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "llm-usage-reset-\(key)", content: content, trigger: nil)) { _ in }
    }

    private func notificationsAuthorized() async -> Bool {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
    }

    private func claimAutoRedemptionAttempt(for creditID: String, now: Date) -> Bool {
        let storageKey = "codex-reset-auto-redemption-attempt"
        if let timestamp = UserDefaults.standard.object(forKey: storageKey) as? Date,
           now.timeIntervalSince(timestamp) < 24 * 60 * 60 {
            return false
        }
        UserDefaults.standard.set(now, forKey: storageKey)
        UserDefaults.standard.set(creditID, forKey: "\(storageKey)-credit-id")
        return true
    }

    private func claimPersistentKey(_ key: String, storageKey: String) -> Bool {
        var keys = Set(UserDefaults.standard.stringArray(forKey: storageKey) ?? [])
        guard keys.insert(key).inserted else { return false }
        UserDefaults.standard.set(Array(keys), forKey: storageKey)
        return true
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        let snapshot = self.state.snapshot

        let titleItem = NSMenuItem(title: "LLM Usage Bar", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)

        let updateStatus = self.state.isRefreshing
            ? "Updating…"
            : "Last updated: \(Formatting.lastUpdated(snapshot.updatedAt))"
        let updatedItem = NSMenuItem(
            title: updateStatus,
            action: nil,
            keyEquivalent: ""
        )
        updatedItem.isEnabled = false
        menu.addItem(updatedItem)

        menu.addItem(.separator())
        self.addCodexSection(to: menu, snapshot: snapshot)

        // OpenCode Go collection and settings remain available, but its menu section is hidden until it is needed again.
        menu.addItem(.separator())
        self.addPiSection(to: menu, snapshot: snapshot)

        if !snapshot.errors.isEmpty {
            menu.addItem(.separator())
            let errorItem = NSMenuItem(title: "⚠︎ Errors (\(snapshot.errors.count))", action: nil, keyEquivalent: "")
            let errorMenu = NSMenu(title: "Errors")
            for error in snapshot.errors {
                let item = NSMenuItem(title: self.truncated(error, limit: 90), action: nil, keyEquivalent: "")
                item.isEnabled = false
                errorMenu.addItem(item)
            }
            errorItem.submenu = errorMenu
            menu.addItem(errorItem)
        }

        menu.addItem(.separator())

        let refreshItem = NSMenuItem(title: "Refresh now", action: #selector(self.refreshNow), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        self.addSettingsSection(to: menu)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit", action: #selector(self.quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        self.statusItem.menu = menu
        self.updateStatusTitle(snapshot: snapshot)
    }

    private func addCodexSection(to menu: NSMenu, snapshot: AppSnapshot) {
        let header = NSMenuItem(title: "Codex", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        guard let codex = snapshot.codex else {
            menu.addItem(self.disabledItem("No data"))
            return
        }

        let session = NSMenuItem(
            title: "Session left: \(Formatting.percent(codex.session?.remainingPercent)) (resets in \(Formatting.relativeReset(codex.session?.resetAt)))",
            action: nil,
            keyEquivalent: ""
        )
        session.isEnabled = false
        menu.addItem(session)

        let weekly = NSMenuItem(
            title: "Weekly left: \(Formatting.percent(codex.weekly?.remainingPercent)) (resets in \(Formatting.relativeReset(codex.weekly?.resetAt)))",
            action: nil,
            keyEquivalent: ""
        )
        weekly.isEnabled = false
        menu.addItem(weekly)

        let credits = NSMenuItem(title: "Credits: \(Formatting.currency(codex.creditsRemaining))", action: nil, keyEquivalent: "")
        credits.isEnabled = false
        menu.addItem(credits)

        if let resetCredits = codex.resetCredits {
            let title = resetCredits.availableCount == 1
                ? "Saved resets: 1 available"
                : "Saved resets: \(resetCredits.availableCount) available"
            let resetItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let resetMenu = NSMenu(title: "Saved resets")

            if resetCredits.availableCount == 0 {
                resetMenu.addItem(self.disabledItem("No saved resets"))
            } else {
                if resetCredits.credits.isEmpty {
                    resetMenu.addItem(self.disabledItem("Details unavailable; redemption is disabled to avoid spending an unspecified reset."))
                } else if self.state.canRedeemCodexResets {
                    for credit in resetCredits.credits {
                        let label = credit.title ?? credit.description ?? "Saved usage-limit reset"
                        let expiry = Formatting.dateTime(credit.expiresAt)
                        let useReset = NSMenuItem(title: "Use: \(label) — expires \(expiry)…", action: #selector(self.useSavedReset), keyEquivalent: "")
                        useReset.target = self
                        useReset.representedObject = credit.id
                        resetMenu.addItem(useReset)
                    }
                } else {
                    resetMenu.addItem(.separator())
                    resetMenu.addItem(self.disabledItem("Refresh Codex usage successfully before using another reset."))
                }
            }

            resetItem.submenu = resetMenu
            menu.addItem(resetItem)
        }

        let source = NSMenuItem(title: "Source: \(codex.sourceLabel)", action: nil, keyEquivalent: "")
        source.isEnabled = false
        menu.addItem(source)
    }

    private func addOpenCodeSection(to menu: NSMenu, snapshot: AppSnapshot) {
        let header = NSMenuItem(title: "OpenCode Go", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        guard let openCode = snapshot.openCode else {
            menu.addItem(self.disabledItem("No data"))
            return
        }

        let workspace = NSMenuItem(title: "Workspace: \(openCode.workspaceID)", action: nil, keyEquivalent: "")
        workspace.isEnabled = false
        menu.addItem(workspace)

        if let limits = openCode.limits {
            let fiveHour = NSMenuItem(
                title: "5h left: \(Formatting.percent(limits.fiveHour?.remainingPercent)) (resets in \(Formatting.relativeReset(limits.fiveHour?.resetAt)))",
                action: nil,
                keyEquivalent: ""
            )
            fiveHour.isEnabled = false
            menu.addItem(fiveHour)

            let weekly = NSMenuItem(
                title: "Weekly left: \(Formatting.percent(limits.weekly?.remainingPercent)) (resets in \(Formatting.relativeReset(limits.weekly?.resetAt)))",
                action: nil,
                keyEquivalent: ""
            )
            weekly.isEnabled = false
            menu.addItem(weekly)

            let monthly = NSMenuItem(
                title: "Monthly left: \(Formatting.percent(limits.monthly?.remainingPercent)) (resets in \(Formatting.relativeReset(limits.monthly?.resetAt)))",
                action: nil,
                keyEquivalent: ""
            )
            monthly.isEnabled = false
            menu.addItem(monthly)
        } else {
            menu.addItem(self.disabledItem("Billing summary unavailable from current OpenCode API"))
        }

        menu.addItem(self.disabledItem("Usage rows fetched: \(Formatting.compactNumber(openCode.rows.count))"))

        let latestUsage = openCode.rows.first?.timeCreated
        if let latestUsage {
            menu.addItem(self.disabledItem("Latest usage: \(Formatting.lastUpdated(latestUsage))"))
        }

        let lastFiveHours = OpenCodeModelSummary.aggregate(rows: openCode.rows, window: 5 * 60 * 60)
        let lastSevenDays = OpenCodeModelSummary.aggregate(rows: openCode.rows, window: 7 * 24 * 60 * 60)

        menu.addItem(.separator())
        let fiveHeader = NSMenuItem(title: "Usage history (last 5h)", action: nil, keyEquivalent: "")
        fiveHeader.isEnabled = false
        menu.addItem(fiveHeader)

        for item in lastFiveHours {
            let row = NSMenuItem(
                title: "• \(item.model): \(item.requestCount) req • \(Formatting.currency(item.totalCostUSD))",
                action: nil,
                keyEquivalent: ""
            )
            row.isEnabled = false
            menu.addItem(row)
        }

        menu.addItem(.separator())
        let weekHeader = NSMenuItem(title: "Usage history (last 7d)", action: nil, keyEquivalent: "")
        weekHeader.isEnabled = false
        menu.addItem(weekHeader)

        for item in lastSevenDays {
            let row = NSMenuItem(
                title: "• \(item.model): \(item.requestCount) req • \(Formatting.currency(item.totalCostUSD))",
                action: nil,
                keyEquivalent: ""
            )
            row.isEnabled = false
            menu.addItem(row)
        }
    }

    private func addPiSection(to menu: NSMenu, snapshot: AppSnapshot) {
        let header = NSMenuItem(title: "Pi", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        guard let pi = snapshot.pi else {
            menu.addItem(self.disabledItem("No data"))
            return
        }

        let today = PiUsageAggregation.summary(rows: pi.rows, window: .today)
        let lastSevenDays = PiUsageAggregation.summary(rows: pi.rows, window: .lastSevenDays)
        let lastThirtyDays = PiUsageAggregation.summary(rows: pi.rows, window: .lastThirtyDays)

        menu.addItem(self.disabledItem("All-time: \(Formatting.compactNumber(pi.sessionCount)) files • \(Formatting.compactNumber(pi.rows.count)) assistant responses"))
        menu.addItem(self.disabledItem("Dir: \(Formatting.abbreviatedPath(pi.sessionsDirectory))"))
        menu.addItem(self.disabledItem("Today: \(self.piSummaryText(today))"))
        menu.addItem(self.disabledItem("Last 7d: \(self.piSummaryText(lastSevenDays))"))
        menu.addItem(self.disabledItem("Last 30d: \(self.piSummaryText(lastThirtyDays))"))

        menu.addItem(.separator())

        let topModels = PiUsageAggregation.groupByModel(rows: pi.rows, window: .lastSevenDays)
        menu.addItem(self.groupSubmenuItem(
            title: "Top models (7d)",
            groups: topModels,
            transformLabel: { $0 }
        ))

        let topProviders = PiUsageAggregation.groupByProvider(rows: pi.rows, window: .lastThirtyDays)
        menu.addItem(self.groupSubmenuItem(
            title: "Top providers (30d)",
            groups: topProviders,
            transformLabel: { $0 }
        ))

        let topProjects = PiUsageAggregation.groupByProject(rows: pi.rows, window: .lastThirtyDays)
        menu.addItem(self.groupSubmenuItem(
            title: "Top projects (30d)",
            groups: topProjects,
            transformLabel: { Formatting.abbreviatedPath($0) }
        ))

        let dataQuality = NSMenuItem(title: "Data quality", action: nil, keyEquivalent: "")
        let dataQualityMenu = NSMenu(title: "Data quality")
        dataQualityMenu.addItem(self.disabledItem("Zero-cost rows: \(Formatting.compactNumber(pi.zeroCostRowCount))"))
        dataQualityMenu.addItem(self.disabledItem("Forked sessions: \(Formatting.compactNumber(pi.forkedSessionCount))"))
        dataQualityMenu.addItem(self.disabledItem("Fork dedupe: \(self.state.currentConfig.piDeduplicateForkHistory ? "on" : "off")"))
        dataQuality.submenu = dataQualityMenu
        menu.addItem(dataQuality)
    }

    private func addSettingsSection(to menu: NSMenu) {
        let config = self.state.currentConfig

        let settingsItem = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        let settingsMenu = NSMenu(title: "Settings")

        let codexToggle = NSMenuItem(title: "Enable Codex", action: #selector(self.toggleCodexEnabled), keyEquivalent: "")
        codexToggle.target = self
        codexToggle.state = config.codexEnabled ? .on : .off
        settingsMenu.addItem(codexToggle)

        let autoRedeemResetsToggle = NSMenuItem(title: "Auto-use Codex resets in final hour", action: #selector(self.toggleAutoRedeemExpiringCodexResets), keyEquivalent: "")
        autoRedeemResetsToggle.target = self
        autoRedeemResetsToggle.state = config.autoRedeemExpiringCodexResets ? .on : .off
        autoRedeemResetsToggle.isEnabled = config.codexEnabled
        settingsMenu.addItem(autoRedeemResetsToggle)

        // OpenCode Go settings remain implemented but are intentionally hidden until needed again.
        let piToggle = NSMenuItem(title: "Enable Pi", action: #selector(self.togglePiEnabled), keyEquivalent: "")
        piToggle.target = self
        piToggle.state = config.piEnabled ? .on : .off
        settingsMenu.addItem(piToggle)

        let launchAtLoginItem = NSMenuItem(title: "Start at login", action: #selector(self.toggleLaunchAtLogin), keyEquivalent: "")
        launchAtLoginItem.target = self
        launchAtLoginItem.state = LaunchAtLoginManager.isEnabled() ? .on : .off
        settingsMenu.addItem(launchAtLoginItem)

        let refreshItem = NSMenuItem(title: "Refresh interval", action: nil, keyEquivalent: "")
        let refreshMenu = NSMenu(title: "Refresh interval")
        for seconds in [60, 300, 600, 1800] {
            let item = NSMenuItem(title: self.refreshLabel(seconds), action: #selector(self.setRefreshInterval(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = seconds
            item.state = config.refreshIntervalSeconds == seconds ? .on : .off
            refreshMenu.addItem(item)
        }
        refreshItem.submenu = refreshMenu
        settingsMenu.addItem(refreshItem)

        settingsMenu.addItem(.separator())

        let piDedupeToggle = NSMenuItem(title: "Deduplicate Pi fork history", action: #selector(self.togglePiDeduplicateForkHistory), keyEquivalent: "")
        piDedupeToggle.target = self
        piDedupeToggle.state = config.piDeduplicateForkHistory ? .on : .off
        settingsMenu.addItem(piDedupeToggle)

        let setPiSessionsDir = NSMenuItem(title: "Set Pi sessions directory…", action: #selector(self.setPiSessionsDirectory), keyEquivalent: "")
        setPiSessionsDir.target = self
        settingsMenu.addItem(setPiSessionsDir)

        let clearPiSessionsDir = NSMenuItem(title: "Clear Pi sessions directory", action: #selector(self.clearPiSessionsDirectory), keyEquivalent: "")
        clearPiSessionsDir.target = self
        clearPiSessionsDir.isEnabled = (config.piSessionsDirectory?.isEmpty == false)
        settingsMenu.addItem(clearPiSessionsDir)

        settingsMenu.addItem(.separator())

        let revealConfig = NSMenuItem(title: "Reveal config in Finder", action: #selector(self.revealConfigFile), keyEquivalent: "")
        revealConfig.target = self
        settingsMenu.addItem(revealConfig)

        if ConfigStore.isEnvironmentOverrideActive {
            settingsMenu.addItem(.separator())
            let notice = NSMenuItem(title: "Env overrides are active", action: nil, keyEquivalent: "")
            notice.isEnabled = false
            settingsMenu.addItem(notice)
        }

        settingsItem.submenu = settingsMenu
        menu.addItem(settingsItem)
    }

    private func refreshLabel(_ seconds: Int) -> String {
        switch seconds {
        case 60: "Every 1 minute"
        case 300: "Every 5 minutes"
        case 600: "Every 10 minutes"
        case 1800: "Every 30 minutes"
        default: "Every \(seconds)s"
        }
    }

    private func applyConfigMutation(_ mutate: (inout AppConfig) -> Void, refresh: Bool = true) {
        var config = self.state.currentConfig
        mutate(&config)
        _ = self.state.persistConfig(config)
        self.startRefreshLoop()
        self.rebuildMenu()

        if refresh {
            Task { [weak self] in
                await self?.refreshAndUpdateMenu()
            }
        }
    }

    private func showAlert(title: String, message: String, style: NSAlert.Style = .informational) {
        NSRunningApplication.current.activate()
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = style
        alert.addButton(withTitle: "OK")
        _ = alert.runModal()
    }

    private func promptForValue(
        title: String,
        message: String,
        defaultValue: String,
        placeholder: String
    ) -> String? {
        NSRunningApplication.current.activate()
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 420, height: 24))
        input.isEditable = true
        input.isSelectable = true
        input.stringValue = defaultValue
        input.placeholderString = placeholder
        alert.accessoryView = input

        let alertWindow = alert.window
        alertWindow.initialFirstResponder = input
        alertWindow.makeFirstResponder(input)

        let result = alert.runModal()
        guard result == .alertFirstButtonReturn else { return nil }
        return input.stringValue
    }

    private func truncated(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let prefix = text.prefix(max(0, limit - 1))
        return "\(prefix)…"
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func piSummaryText(_ summary: PiSummary) -> String {
        "\(Formatting.currency(summary.totalCostUSD)) • \(Formatting.compactNumber(summary.requestCount)) req • \(Formatting.tokens(summary.totalTokens))"
    }

    private func groupSubmenuItem(
        title: String,
        groups: [PiGroupSummary],
        transformLabel: (String) -> String
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: title)

        if groups.isEmpty {
            submenu.addItem(self.disabledItem("No usage"))
        } else {
            for group in groups {
                let label = self.truncated(transformLabel(group.label), limit: 64)
                submenu.addItem(self.disabledItem(
                    "• \(label): \(Formatting.currency(group.totalCostUSD)) • \(Formatting.compactNumber(group.requestCount)) req • \(Formatting.tokens(group.totalTokens))"
                ))
            }
        }

        item.submenu = submenu
        return item
    }

    private func updateStatusTitle(snapshot: AppSnapshot) {
        let codexSession = snapshot.codex?.session.map { Int($0.remainingPercent.rounded()) }
        let codexSessionResetAt = snapshot.codex?.session?.resetAt
        let codexWeekly = snapshot.codex?.weekly.map { Int($0.remainingPercent.rounded()) }
        let codexWeeklyResetAt = snapshot.codex?.weekly?.resetAt

        let goSession = snapshot.openCode?.limits?.fiveHour.map { Int($0.remainingPercent.rounded()) }
        let goSessionResetAt = snapshot.openCode?.limits?.fiveHour?.resetAt
        let goWeekly = snapshot.openCode?.limits?.weekly.map { Int($0.remainingPercent.rounded()) }
        let goWeeklyResetAt = snapshot.openCode?.limits?.weekly?.resetAt

        guard let button = self.statusItem.button else { return }

        if let image = StatusIconText.makeStackedImage(
            codexSession: codexSession,
            codexSessionResetAt: codexSessionResetAt,
            codexWeekly: codexWeekly,
            codexWeeklyResetAt: codexWeeklyResetAt,
            openCodeSession: goSession,
            openCodeSessionResetAt: goSessionResetAt,
            openCodeWeekly: goWeekly,
            openCodeWeeklyResetAt: goWeeklyResetAt
        ) {
            button.image = image
            button.imagePosition = .imageOnly
            button.title = ""
        } else {
            button.image = nil
            button.title = "LLM"
        }
    }

    @objc private func refreshNow() {
        Task { [weak self] in
            await self?.refreshAndUpdateMenu()
        }
    }

    @objc private func useSavedReset(_ sender: NSMenuItem) {
        guard let resetCredits = self.state.snapshot.codex?.resetCredits,
              resetCredits.availableCount > 0
        else {
            self.showAlert(title: "No saved reset available", message: "Refresh Codex usage and try again.", style: .warning)
            return
        }

        guard let creditID = sender.representedObject as? String,
              let selectedCredit = resetCredits.credits.first(where: { $0.id == creditID })
        else {
            self.showAlert(title: "Saved reset is no longer available", message: "Refresh Codex usage and choose a current reset.", style: .warning)
            return
        }

        let label = selectedCredit.title ?? selectedCredit.description ?? "the selected saved reset"
        let expiry = " It expires \(Formatting.dateTime(selectedCredit.expiresAt))."

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Use saved Codex reset?"
        alert.informativeText = "This will spend one saved reset to refresh your Codex rate-limit windows. This cannot be undone.\n\nSelected: \(label).\(expiry)"
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Use reset")
        NSRunningApplication.current.activate()
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertSecondButtonReturn else { return }

        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.state.consumeCodexResetCredit(creditID: creditID)
                self.rebuildMenu()
                self.showResetOutcome(result)
            } catch {
                self.rebuildMenu()
                self.showAlert(title: "Could not use saved reset", message: error.localizedDescription, style: .warning)
            }
        }
    }

    private func showResetOutcome(_ result: CodexResetRedemptionResult) {
        let refreshNote = result.refreshError.map { "\n\nThe reset result is confirmed, but usage could not be refreshed: \($0). Use Refresh now before choosing another reset." } ?? ""

        switch result.outcome {
        case "reset", "alreadyRedeemed", "already_redeemed":
            let message = result.refreshError == nil
                ? "Codex usage was refreshed and the display has been updated."
                : "Codex reset was applied.\(refreshNote)"
            self.showAlert(title: "Saved reset used", message: message)
        case "nothingToReset", "nothing_to_reset":
            self.showAlert(title: "No usage window needed resetting", message: "Your saved reset was not used.\(refreshNote)", style: .warning)
        case "noCredit", "no_credit":
            self.showAlert(title: "No saved reset available", message: "The available reset credits changed before redemption.\(refreshNote)", style: .warning)
        default:
            self.showAlert(title: "Saved reset was not applied", message: "Codex returned: \(result.outcome).\(refreshNote)", style: .warning)
        }
    }

    @objc private func toggleCodexEnabled() {
        self.applyConfigMutation { $0.codexEnabled.toggle() }
    }

    @objc private func toggleAutoRedeemExpiringCodexResets() {
        let enabled = self.state.currentConfig.autoRedeemExpiringCodexResets
        guard !enabled else {
            self.applyConfigMutation { $0.autoRedeemExpiringCodexResets = false }
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Auto-use expiring Codex resets?"
        alert.informativeText = "When a known saved reset reaches its final hour, LLM Usage Bar will redeem that specific credit automatically. It will notify you at 24 hours, 6 hours, and after redemption. This spends a reset credit and cannot be undone."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Enable auto-use")
        NSRunningApplication.current.activate()
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertSecondButtonReturn else { return }

        Task { [weak self] in
            guard let self else { return }
            let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) == true
            guard granted else {
                self.showAlert(title: "Notifications are required", message: "Auto-use remains off because LLM Usage Bar needs to notify you before and after an expiring reset is redeemed.", style: .warning)
                return
            }
            self.applyConfigMutation { $0.autoRedeemExpiringCodexResets = true }
        }
    }

    @objc private func toggleOpenCodeEnabled() {
        self.applyConfigMutation { $0.openCodeEnabled.toggle() }
    }

    @objc private func togglePiEnabled() {
        self.applyConfigMutation { $0.piEnabled.toggle() }
    }

    @objc private func togglePiDeduplicateForkHistory() {
        self.applyConfigMutation { $0.piDeduplicateForkHistory.toggle() }
    }

    @objc private func toggleLaunchAtLogin() {
        let target = !LaunchAtLoginManager.isEnabled()
        do {
            try LaunchAtLoginManager.setEnabled(target)
            self.rebuildMenu()
            if target {
                self.showAlert(title: "Start at login enabled", message: "LLM Usage Bar will launch automatically when you sign in.")
            } else {
                self.showAlert(title: "Start at login disabled", message: "LLM Usage Bar will no longer launch automatically.")
            }
        } catch {
            self.showAlert(title: "Could not update login item", message: error.localizedDescription, style: .warning)
        }
    }

    @objc private func setRefreshInterval(_ sender: NSMenuItem) {
        guard let seconds = sender.representedObject as? Int else { return }
        self.applyConfigMutation({ $0.refreshIntervalSeconds = max(30, seconds) }, refresh: false)
    }

    @objc private func setPiSessionsDirectory() {
        let current = self.state.currentConfig.piSessionsDirectory ?? ""
        guard let value = self.promptForValue(
            title: "Pi Sessions Directory",
            message: "Set a custom pi sessions directory, or leave empty to use ~/.pi/agent/sessions.",
            defaultValue: current,
            placeholder: "~/.pi/agent/sessions"
        ) else { return }

        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        self.applyConfigMutation {
            $0.piSessionsDirectory = normalized.isEmpty ? nil : normalized
        }
    }

    @objc private func clearPiSessionsDirectory() {
        self.applyConfigMutation {
            $0.piSessionsDirectory = nil
        }
    }

    @objc private func importOpenCodeCookieFromBrowser() {
        do {
            let session = try OpenCodeCookieAutoImporter.importSession()
            self.applyConfigMutation {
                $0.openCodeCookieHeader = session.cookieHeader
            }
            self.showAlert(
                title: "OpenCode cookie imported",
                message: "Imported from \(session.sourceLabel)."
            )
        } catch {
            self.showAlert(
                title: "Could not import OpenCode cookie",
                message: error.localizedDescription,
                style: .warning
            )
        }
    }

    @objc private func setOpenCodeCookie() {
        let current = self.state.currentConfig.openCodeCookieHeader ?? ""
        guard let value = self.promptForValue(
            title: "OpenCode Cookie",
            message: "Paste your Cookie header value (example: auth=...)",
            defaultValue: current,
            placeholder: "auth=..."
        ) else { return }

        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        self.applyConfigMutation {
            $0.openCodeCookieHeader = normalized.isEmpty ? nil : normalized
        }
    }

    @objc private func clearOpenCodeCookie() {
        self.applyConfigMutation {
            $0.openCodeCookieHeader = nil
        }
    }

    @objc private func setOpenCodeWorkspace() {
        let current = self.state.currentConfig.openCodeWorkspaceID ?? ""
        guard let value = self.promptForValue(
            title: "OpenCode Workspace ID",
            message: "Set wrk_... to pin a workspace, or leave empty for auto-detect.",
            defaultValue: current,
            placeholder: "wrk_..."
        ) else { return }

        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        self.applyConfigMutation {
            $0.openCodeWorkspaceID = normalized.isEmpty ? nil : normalized
        }
    }

    @objc private func clearOpenCodeWorkspace() {
        self.applyConfigMutation {
            $0.openCodeWorkspaceID = nil
        }
    }

    @objc private func revealConfigFile() {
        ConfigStore.writeDefaultIfMissing()
        NSWorkspace.shared.activateFileViewerSelecting([ConfigStore.fileURL])
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

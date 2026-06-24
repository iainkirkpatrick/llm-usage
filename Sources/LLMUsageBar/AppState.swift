import Foundation

@MainActor
final class AppState {
    private(set) var snapshot: AppSnapshot = AppSnapshot(codex: nil, openCode: nil, pi: nil, errors: [], updatedAt: .distantPast)
    private(set) var isRefreshing = false

    private let codexFetcher = CodexFetcher()
    private let openCodeFetcher = OpenCodeGoFetcher()
    private let piFetcher = PiSessionsFetcher()
    private var config: AppConfig

    init(config: AppConfig) {
        self.config = config
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

    func refresh() async {
        guard !self.isRefreshing else { return }
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

        if errors.isEmpty {
            AppLog.info("Refresh completed without errors")
        } else {
            AppLog.error("Refresh completed with \(errors.count) error(s): \(errors.joined(separator: " | "))")
        }
    }
}

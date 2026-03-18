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

        var codexResult: CodexSnapshot?
        var openCodeResult: OpenCodeSnapshot?
        var piResult: PiSnapshot?
        var errors: [String] = []

        if self.config.codexEnabled {
            do {
                codexResult = try await self.codexFetcher.fetch()
            } catch {
                errors.append("Codex: \(error.localizedDescription)")
            }
        }

        if self.config.openCodeEnabled {
            do {
                openCodeResult = try await self.openCodeFetcher.fetch(
                    cookieHeader: self.config.openCodeCookieHeader,
                    workspaceID: self.config.openCodeWorkspaceID
                )
            } catch {
                errors.append("OpenCode Go: \(error.localizedDescription)")
            }
        }

        if self.config.piEnabled {
            do {
                piResult = try self.piFetcher.fetch(
                    sessionsDirectory: self.config.piSessionsDirectory,
                    deduplicateForkHistory: self.config.piDeduplicateForkHistory
                )
            } catch {
                errors.append("Pi: \(error.localizedDescription)")
            }
        }

        self.snapshot = AppSnapshot(
            codex: codexResult,
            openCode: openCodeResult,
            pi: piResult,
            errors: errors,
            updatedAt: Date()
        )
    }
}

import Foundation

struct AppConfig: Codable {
    var refreshIntervalSeconds: Int
    var codexEnabled: Bool
    var openCodeEnabled: Bool
    var openCodeWorkspaceID: String?
    var openCodeCookieHeader: String?
    var piEnabled: Bool
    var piSessionsDirectory: String?
    var piDeduplicateForkHistory: Bool
    var autoRedeemExpiringCodexResets: Bool

    static let `default` = AppConfig(
        refreshIntervalSeconds: 300,
        codexEnabled: true,
        openCodeEnabled: true,
        openCodeWorkspaceID: nil,
        openCodeCookieHeader: nil,
        piEnabled: true,
        piSessionsDirectory: nil,
        piDeduplicateForkHistory: true,
        autoRedeemExpiringCodexResets: false
    )

    init(
        refreshIntervalSeconds: Int,
        codexEnabled: Bool,
        openCodeEnabled: Bool,
        openCodeWorkspaceID: String?,
        openCodeCookieHeader: String?,
        piEnabled: Bool,
        piSessionsDirectory: String?,
        piDeduplicateForkHistory: Bool,
        autoRedeemExpiringCodexResets: Bool
    ) {
        self.refreshIntervalSeconds = refreshIntervalSeconds
        self.codexEnabled = codexEnabled
        self.openCodeEnabled = openCodeEnabled
        self.openCodeWorkspaceID = openCodeWorkspaceID
        self.openCodeCookieHeader = openCodeCookieHeader
        self.piEnabled = piEnabled
        self.piSessionsDirectory = piSessionsDirectory
        self.piDeduplicateForkHistory = piDeduplicateForkHistory
        self.autoRedeemExpiringCodexResets = autoRedeemExpiringCodexResets
    }

    private enum CodingKeys: String, CodingKey {
        case refreshIntervalSeconds
        case codexEnabled
        case openCodeEnabled
        case openCodeWorkspaceID
        case openCodeCookieHeader
        case piEnabled
        case piSessionsDirectory
        case piDeduplicateForkHistory
        case autoRedeemExpiringCodexResets
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Self.default

        self.refreshIntervalSeconds = try container.decodeIfPresent(Int.self, forKey: .refreshIntervalSeconds) ?? defaults.refreshIntervalSeconds
        self.codexEnabled = try container.decodeIfPresent(Bool.self, forKey: .codexEnabled) ?? defaults.codexEnabled
        self.openCodeEnabled = try container.decodeIfPresent(Bool.self, forKey: .openCodeEnabled) ?? defaults.openCodeEnabled
        self.openCodeWorkspaceID = try container.decodeIfPresent(String.self, forKey: .openCodeWorkspaceID)
        self.openCodeCookieHeader = try container.decodeIfPresent(String.self, forKey: .openCodeCookieHeader)
        self.piEnabled = try container.decodeIfPresent(Bool.self, forKey: .piEnabled) ?? defaults.piEnabled
        self.piSessionsDirectory = try container.decodeIfPresent(String.self, forKey: .piSessionsDirectory)
        self.piDeduplicateForkHistory = try container.decodeIfPresent(Bool.self, forKey: .piDeduplicateForkHistory) ?? defaults.piDeduplicateForkHistory
        self.autoRedeemExpiringCodexResets = try container.decodeIfPresent(Bool.self, forKey: .autoRedeemExpiringCodexResets) ?? defaults.autoRedeemExpiringCodexResets
    }
}

enum ConfigStore {
    static let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".llm-usage-bar", isDirectory: true)
        .appendingPathComponent("config.json")

    static var isEnvironmentOverrideActive: Bool {
        !self.environmentOverrides.isEmpty
    }

    private static var environmentOverrides: [String: String] {
        let env = ProcessInfo.processInfo.environment
        let keys = [
            "LLM_BAR_OPENCODE_COOKIE",
            "LLM_BAR_OPENCODE_WORKSPACE_ID",
            "LLM_BAR_REFRESH_SECONDS",
            "LLM_BAR_PI_SESSIONS_DIR",
            "LLM_BAR_PI_DEDUPE_FORKS",
        ]

        var overrides: [String: String] = [:]
        for key in keys {
            guard let value = env[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
                continue
            }
            overrides[key] = value
        }
        return overrides
    }

    static func load() -> AppConfig {
        if let env = Self.loadFromEnvironment() {
            return env
        }

        guard let data = try? Data(contentsOf: self.fileURL) else {
            self.writeDefaultIfMissing()
            return .default
        }

        do {
            return try JSONDecoder().decode(AppConfig.self, from: data)
        } catch {
            return .default
        }
    }

    @discardableResult
    static func save(_ config: AppConfig) -> Bool {
        do {
            let dir = self.fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(config)
            try data.write(to: self.fileURL, options: [.atomic])
            try FileManager.default.setAttributes([
                .posixPermissions: NSNumber(value: Int16(0o600)),
            ], ofItemAtPath: self.fileURL.path)
            return true
        } catch {
            return false
        }
    }

    static func loadFromEnvironment() -> AppConfig? {
        let env = ProcessInfo.processInfo.environment
        guard self.isEnvironmentOverrideActive else {
            return nil
        }

        var config = AppConfig.default
        config.openCodeCookieHeader = self.normalizedString(env["LLM_BAR_OPENCODE_COOKIE"])
        config.openCodeWorkspaceID = self.normalizedString(env["LLM_BAR_OPENCODE_WORKSPACE_ID"])
        config.piSessionsDirectory = self.normalizedString(env["LLM_BAR_PI_SESSIONS_DIR"])

        if let refresh = env["LLM_BAR_REFRESH_SECONDS"], let value = Int(refresh), value >= 30 {
            config.refreshIntervalSeconds = value
        }

        if let piDeduplicateForkHistory = self.parseBool(env["LLM_BAR_PI_DEDUPE_FORKS"]) {
            config.piDeduplicateForkHistory = piDeduplicateForkHistory
        }

        return config
    }

    static func writeDefaultIfMissing() {
        guard !FileManager.default.fileExists(atPath: self.fileURL.path) else { return }
        _ = self.save(.default)
    }

    private static func normalizedString(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        return raw
    }

    private static func parseBool(_ raw: String?) -> Bool? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !raw.isEmpty else {
            return nil
        }

        switch raw {
        case "1", "true", "yes", "on":
            return true
        case "0", "false", "no", "off":
            return false
        default:
            return nil
        }
    }
}

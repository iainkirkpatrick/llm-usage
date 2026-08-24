import Darwin
import Foundation

struct CodexManagedAccountProfile: Codable, Sendable, Equatable {
    let id: UUID
    var label: String
    var email: String?
    var planType: String?
    // ChatGPT account identity is deliberately metadata only. OAuth tokens remain in the
    // isolated native home when this account is inactive, or in Pi auth.json while it is handed
    // off to Pi.
    var accountID: String?
    let createdAt: Date
    var lastAuthenticatedAt: Date?

    init(
        id: UUID = UUID(),
        label: String,
        email: String? = nil,
        planType: String? = nil,
        accountID: String? = nil,
        createdAt: Date = Date(),
        lastAuthenticatedAt: Date? = nil)
    {
        self.id = id
        self.label = label
        self.email = email
        self.planType = planType
        self.accountID = accountID
        self.createdAt = createdAt
        self.lastAuthenticatedAt = lastAuthenticatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case label
        case email
        case planType
        case accountID
        case createdAt
        case lastAuthenticatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.label = try container.decode(String.self, forKey: .label)
        self.email = try container.decodeIfPresent(String.self, forKey: .email)
        self.planType = try container.decodeIfPresent(String.self, forKey: .planType)
        self.accountID = try container.decodeIfPresent(String.self, forKey: .accountID)
        self.createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        self.lastAuthenticatedAt = try container.decodeIfPresent(Date.self, forKey: .lastAuthenticatedAt)
    }
}

struct AppConfig: Codable, Equatable, Sendable {
    var refreshIntervalSeconds: Int
    var codexEnabled: Bool
    var openCodeEnabled: Bool
    var openCodeWorkspaceID: String?
    var openCodeCookieHeader: String?
    var piEnabled: Bool
    var piSessionsDirectory: String?
    var piDeduplicateForkHistory: Bool
    var autoRedeemExpiringCodexResets: Bool
    var codexManagedAccounts: [CodexManagedAccountProfile]
    var codexPrimaryAccountID: UUID?
    // When non-nil, this profile's live OAuth credential is in Pi auth.json rather than its
    // managed CODEX_HOME. The native home is intentionally kept without auth.json so two
    // independently-refreshing copies cannot exist.
    var codexPiHandoffAccountID: UUID?

    static let `default` = AppConfig(
        refreshIntervalSeconds: 300,
        codexEnabled: true,
        openCodeEnabled: true,
        openCodeWorkspaceID: nil,
        openCodeCookieHeader: nil,
        piEnabled: true,
        piSessionsDirectory: nil,
        piDeduplicateForkHistory: true,
        autoRedeemExpiringCodexResets: false,
        codexManagedAccounts: [],
        codexPrimaryAccountID: nil,
        codexPiHandoffAccountID: nil
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
        autoRedeemExpiringCodexResets: Bool,
        codexManagedAccounts: [CodexManagedAccountProfile] = [],
        codexPrimaryAccountID: UUID? = nil,
        codexPiHandoffAccountID: UUID? = nil
    ) {
        self.refreshIntervalSeconds = refreshIntervalSeconds
        self.codexEnabled = codexEnabled
        self.openCodeEnabled = openCodeEnabled
        self.openCodeWorkspaceID = openCodeWorkspaceID
        self.piEnabled = piEnabled
        self.piSessionsDirectory = piSessionsDirectory
        self.openCodeCookieHeader = openCodeCookieHeader
        self.piDeduplicateForkHistory = piDeduplicateForkHistory
        self.autoRedeemExpiringCodexResets = autoRedeemExpiringCodexResets
        self.codexManagedAccounts = codexManagedAccounts
        self.codexPrimaryAccountID = codexPrimaryAccountID
        self.codexPiHandoffAccountID = codexPiHandoffAccountID
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
        case codexManagedAccounts
        case codexPrimaryAccountID
        case codexPiHandoffAccountID
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
        self.codexManagedAccounts = try container.decodeIfPresent([CodexManagedAccountProfile].self, forKey: .codexManagedAccounts) ?? defaults.codexManagedAccounts
        self.codexPrimaryAccountID = try container.decodeIfPresent(UUID.self, forKey: .codexPrimaryAccountID)
        self.codexPiHandoffAccountID = try container.decodeIfPresent(UUID.self, forKey: .codexPiHandoffAccountID)
    }
}

struct ConfigDiskSnapshot: Equatable, Sendable {
    let exists: Bool
    let data: Data?
}

struct AppOwnedPathInfo: Sendable {
    let exists: Bool
    let isSymbolicLink: Bool
    let isDirectory: Bool
    let isRegularFile: Bool
    let permissions: Int
    let device: UInt64
    let inode: UInt64
}

enum AppOwnedPathError: LocalizedError, Equatable, Sendable {
    case symbolicLink(String)
    case notDirectory(String)
    case notRegularFile(String)
    case filesystem(String, String)
    case permissionHardeningFailed(String)

    var errorDescription: String? {
        switch self {
        case let .symbolicLink(path):
            return "Refusing to use a symbolic link in the app-owned path: \(path)"
        case let .notDirectory(path):
            return "App-owned path is not a directory: \(path)"
        case let .notRegularFile(path):
            return "App-owned path is not a regular file: \(path)"
        case let .filesystem(path, message):
            return "Could not inspect app-owned path \(path): \(message)"
        case let .permissionHardeningFailed(path):
            return "Could not secure app-owned path permissions: \(path)"
        }
    }
}

enum AppOwnedPathSafety {
    static func info(at url: URL) throws -> AppOwnedPathInfo {
        var fileStat = Darwin.stat()
        let result = url.withUnsafeFileSystemRepresentation { pointer -> Int32 in
            guard let pointer else { return -1 }
            return Darwin.lstat(pointer, &fileStat)
        }

        guard result == 0 else {
            let errorCode = errno
            if errorCode == ENOENT || errorCode == ENOTDIR {
                return AppOwnedPathInfo(
                    exists: false,
                    isSymbolicLink: false,
                    isDirectory: false,
                    isRegularFile: false,
                    permissions: 0,
                    device: 0,
                    inode: 0)
            }
            throw AppOwnedPathError.filesystem(
                url.path,
                String(cString: strerror(errorCode)))
        }

        let type = fileStat.st_mode & S_IFMT
        return AppOwnedPathInfo(
            exists: true,
            isSymbolicLink: type == S_IFLNK,
            isDirectory: type == S_IFDIR,
            isRegularFile: type == S_IFREG,
            permissions: Int(fileStat.st_mode & 0o777),
            device: UInt64(fileStat.st_dev),
            inode: UInt64(fileStat.st_ino))
    }

    static func ensureDirectory(at url: URL, permissions: Int = 0o700) throws {
        let current = try self.info(at: url)
        if current.exists {
            guard !current.isSymbolicLink else {
                throw AppOwnedPathError.symbolicLink(url.path)
            }
            guard current.isDirectory else {
                throw AppOwnedPathError.notDirectory(url.path)
            }
        } else {
            do {
                try FileManager.default.createDirectory(
                    at: url,
                    withIntermediateDirectories: false,
                    attributes: nil)
            } catch {
                throw AppOwnedPathError.filesystem(url.path, error.localizedDescription)
            }
        }

        do {
            try FileManager.default.setAttributes([
                .posixPermissions: NSNumber(value: Int16(permissions)),
            ], ofItemAtPath: url.path)
        } catch {
            throw AppOwnedPathError.permissionHardeningFailed(url.path)
        }

        let secured = try self.info(at: url)
        guard secured.exists, !secured.isSymbolicLink, secured.isDirectory,
              secured.permissions == permissions
        else {
            throw AppOwnedPathError.permissionHardeningFailed(url.path)
        }
    }

    static func ensureDirectoryTree(at url: URL, permissions: Int = 0o700) throws {
        var missing: [URL] = []
        var current = url.standardizedFileURL

        while true {
            let currentInfo = try self.info(at: current)
            if currentInfo.exists {
                guard !currentInfo.isSymbolicLink else {
                    throw AppOwnedPathError.symbolicLink(current.path)
                }
                guard currentInfo.isDirectory else {
                    throw AppOwnedPathError.notDirectory(current.path)
                }
                break
            }
            missing.append(current)
            let parent = current.deletingLastPathComponent()
            guard parent.path != current.path else {
                throw AppOwnedPathError.filesystem(current.path, "no existing parent directory")
            }
            current = parent
        }

        for directory in missing.reversed() {
            try self.ensureDirectory(at: directory, permissions: permissions)
        }
    }

    static func validateRegularFile(at url: URL, allowMissing: Bool = true) throws {
        let current = try self.info(at: url)
        guard current.exists else {
            if allowMissing { return }
            throw AppOwnedPathError.notRegularFile(url.path)
        }
        guard !current.isSymbolicLink else {
            throw AppOwnedPathError.symbolicLink(url.path)
        }
        guard current.isRegularFile else {
            throw AppOwnedPathError.notRegularFile(url.path)
        }
    }

    static func hardenRegularFile(at url: URL, permissions: Int = 0o600) throws {
        try self.validateRegularFile(at: url, allowMissing: false)
        do {
            try FileManager.default.setAttributes([
                .posixPermissions: NSNumber(value: Int16(permissions)),
            ], ofItemAtPath: url.path)
        } catch {
            throw AppOwnedPathError.permissionHardeningFailed(url.path)
        }
        let secured = try self.info(at: url)
        guard secured.exists, !secured.isSymbolicLink, secured.isRegularFile,
              secured.permissions == permissions
        else {
            throw AppOwnedPathError.permissionHardeningFailed(url.path)
        }
    }
}

private enum ConfigStoreError: Error {
    case concurrentChange
}

// The lock is an advisory, kernel-owned lock on a protected regular file. The pathname is never
// deleted as stale: flock releases ownership when a process exits, so a crashed writer cannot
// leave a directory that a later writer has to guess about. Every ConfigStore save holds this lock
// from its current-document comparison through the atomic replacement.
private final class ConfigStoreSaveLock {
    private let descriptor: Int32

    init(at url: URL) throws {
        let descriptor = url.withUnsafeFileSystemRepresentation { pointer -> Int32 in
            guard let pointer else { return -1 }
            return Darwin.open(pointer, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        }
        guard descriptor >= 0 else {
            throw AppOwnedPathError.filesystem(
                url.path,
                String(cString: strerror(errno)))
        }
        self.descriptor = descriptor

        do {
            var fileStat = Darwin.stat()
            guard Darwin.fstat(descriptor, &fileStat) == 0,
                  fileStat.st_mode & S_IFMT == S_IFREG
            else {
                throw AppOwnedPathError.notRegularFile(url.path)
            }
            guard Darwin.fchmod(descriptor, mode_t(0o600)) == 0 else {
                throw AppOwnedPathError.permissionHardeningFailed(url.path)
            }
            while flock(descriptor, LOCK_EX) != 0 {
                guard errno == EINTR else {
                    throw AppOwnedPathError.filesystem(
                        url.path,
                        String(cString: strerror(errno)))
                }
            }
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
    }

    deinit {
        _ = flock(self.descriptor, LOCK_UN)
        _ = Darwin.close(self.descriptor)
    }
}

enum ConfigStore {
    static let appDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".llm-usage-bar", isDirectory: true)

    static let fileURL = ConfigStore.appDirectoryURL.appendingPathComponent("config.json")

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
        let config = self.loadPersistedConfig()
        self.writeDefaultIfMissing()
        return self.applyEnvironmentOverrides(to: config)
    }

    @discardableResult
    static func save(_ config: AppConfig) -> Bool {
        self.save(
            config,
            onlyIfCurrent: nil,
            directoryURL: self.appDirectoryURL,
            fileURL: self.fileURL)
    }

    // Credential handoff is a multi-file transaction. Refuse to overwrite a config document that
    // changed after AppState loaded it; ordinary UI saves retain their historical last-writer-wins
    // behavior for compatibility.
    @discardableResult
    static func saveIfUnchanged(_ config: AppConfig, expected: ConfigDiskSnapshot) -> Bool {
        self.save(
            config,
            onlyIfCurrent: expected,
            directoryURL: self.appDirectoryURL,
            fileURL: self.fileURL)
    }

    // Test-only storage keeps concurrency tests away from a user's real configuration while using
    // exactly the same lock and compare/replace implementation as the app-owned path.
    static func saveForTesting(
        _ config: AppConfig,
        at directoryURL: URL,
        expected: ConfigDiskSnapshot? = nil) -> Bool
    {
        let fileURL = directoryURL.appendingPathComponent("config.json")
        return self.save(
            config,
            onlyIfCurrent: expected,
            directoryURL: directoryURL,
            fileURL: fileURL)
    }

    static func diskSnapshot() -> ConfigDiskSnapshot {
        self.diskSnapshot(at: self.fileURL)
    }

    static func diskSnapshotForTesting(at directoryURL: URL) -> ConfigDiskSnapshot {
        self.diskSnapshot(at: directoryURL.appendingPathComponent("config.json"))
    }

    private static func diskSnapshot(at fileURL: URL) -> ConfigDiskSnapshot {
        guard let info = try? AppOwnedPathSafety.info(at: fileURL), info.exists else {
            return ConfigDiskSnapshot(exists: false, data: nil)
        }
        guard let data = try? Data(contentsOf: fileURL) else {
            return ConfigDiskSnapshot(exists: true, data: nil)
        }
        return ConfigDiskSnapshot(exists: true, data: data)
    }

    // Return a CAS token only when the persisted document (including its effective environment
    // overrides) is the exact configuration the caller currently owns. Capturing an arbitrary
    // disk snapshot is not sufficient: AppState may already be stale before it asks for the CAS.
    static func diskSnapshot(matching config: AppConfig) -> ConfigDiskSnapshot? {
        let snapshot = self.diskSnapshot()
        let persisted: AppConfig
        if let data = snapshot.data {
            guard let decoded = try? JSONDecoder().decode(AppConfig.self, from: data) else { return nil }
            persisted = decoded
        } else if !snapshot.exists {
            persisted = .default
        } else {
            return nil
        }
        guard self.applyEnvironmentOverrides(to: persisted) == config else { return nil }
        return snapshot
    }

    private static func save(
        _ config: AppConfig,
        onlyIfCurrent expected: ConfigDiskSnapshot?,
        directoryURL: URL,
        fileURL: URL) -> Bool
    {
        var temporaryURL: URL?
        do {
            try self.ensureAppDirectory(at: directoryURL, fileURL: fileURL)
            // Keep the lock alive for the complete compare/read/prepare/recheck/replace
            // sequence. Handoff already holds its journal and Pi locks, so this is deliberately
            // the final lock in that order; ConfigStore never acquires either of those locks.
            let saveLock = try ConfigStoreSaveLock(
                at: directoryURL.appendingPathComponent("config.json.lock"))
            defer { _ = saveLock }
            if let expected {
                guard !(expected.exists && expected.data == nil),
                      self.diskSnapshot(at: fileURL) == expected
                else { return false }
            }
            let persisted = self.loadPersistedConfigFromDisk(at: fileURL) ?? .default
            var valueToWrite = config

            // The in-memory AppConfig is the effective configuration and therefore contains env
            // values. Preserve the disk value for overridden fields so an unrelated account/UI save
            // cannot turn a process-local override into a permanent setting.
            if self.hasEnvironmentOverride("LLM_BAR_OPENCODE_COOKIE") {
                valueToWrite.openCodeCookieHeader = persisted.openCodeCookieHeader
            }
            if self.hasEnvironmentOverride("LLM_BAR_OPENCODE_WORKSPACE_ID") {
                valueToWrite.openCodeWorkspaceID = persisted.openCodeWorkspaceID
            }
            if self.hasEnvironmentOverride("LLM_BAR_PI_SESSIONS_DIR") {
                valueToWrite.piSessionsDirectory = persisted.piSessionsDirectory
            }
            if self.hasEnvironmentOverride("LLM_BAR_REFRESH_SECONDS") {
                valueToWrite.refreshIntervalSeconds = persisted.refreshIntervalSeconds
            }
            if self.hasEnvironmentOverride("LLM_BAR_PI_DEDUPE_FORKS") {
                valueToWrite.piDeduplicateForkHistory = persisted.piDeduplicateForkHistory
            }

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(valueToWrite)
            let temporary = directoryURL
                .appendingPathComponent(".config-\(UUID().uuidString).tmp")
            temporaryURL = temporary
            try data.write(to: temporary, options: [.atomic])
            try AppOwnedPathSafety.hardenRegularFile(at: temporary, permissions: 0o600)

            // Re-check immediately before replacement. This is not a kernel CAS, but catches the
            // practical case of another editor or app instance changing config during preparation.
            if let expected {
                guard self.diskSnapshot(at: fileURL) == expected else {
                    throw ConfigStoreError.concurrentChange
                }
            }
            let existing = try AppOwnedPathSafety.info(at: fileURL)
            if existing.exists {
                try AppOwnedPathSafety.validateRegularFile(at: fileURL, allowMissing: false)
                _ = try FileManager.default.replaceItemAt(
                    fileURL,
                    withItemAt: temporary,
                    backupItemName: nil,
                    options: [])
            } else {
                try FileManager.default.moveItem(at: temporary, to: fileURL)
            }
            temporaryURL = nil
            let installed = try AppOwnedPathSafety.info(at: fileURL)
            guard installed.exists, !installed.isSymbolicLink, installed.isRegularFile,
                  installed.permissions == 0o600
            else {
                throw AppOwnedPathError.permissionHardeningFailed(fileURL.path)
            }
            return true
        } catch {
            if let temporaryURL {
                try? FileManager.default.removeItem(at: temporaryURL)
            }
            return false
        }
    }

    static func loadFromEnvironment() -> AppConfig? {
        guard self.isEnvironmentOverrideActive else {
            return nil
        }
        // Do not call load() here: load() applies overrides and used to recurse back into this
        // method. Start from the persisted document exactly once.
        return self.applyEnvironmentOverrides(to: self.loadPersistedConfig())
    }

    static func writeDefaultIfMissing() {
        guard (try? self.validateAppOwnedPaths()) != nil else { return }
        guard let info = try? AppOwnedPathSafety.info(at: self.fileURL), info.exists == false else { return }
        _ = self.save(.default)
    }

    static func ensureAppDirectory() throws {
        try self.validateAppOwnedPaths()
        let directoryInfo = try AppOwnedPathSafety.info(at: self.appDirectoryURL)
        if !directoryInfo.exists {
            let parent = self.appDirectoryURL.deletingLastPathComponent()
            let parentInfo = try AppOwnedPathSafety.info(at: parent)
            guard parentInfo.exists, parentInfo.isDirectory else {
                throw AppOwnedPathError.notDirectory(parent.path)
            }
            try AppOwnedPathSafety.ensureDirectory(at: self.appDirectoryURL)
        } else {
            try AppOwnedPathSafety.ensureDirectory(at: self.appDirectoryURL)
        }
        try self.validateAppOwnedPaths()
    }

    private static func ensureAppDirectory(at directoryURL: URL, fileURL: URL) throws {
        if directoryURL.standardizedFileURL.path == self.appDirectoryURL.standardizedFileURL.path {
            try self.ensureAppDirectory()
            return
        }
        try AppOwnedPathSafety.ensureDirectoryTree(at: directoryURL, permissions: 0o700)
        try AppOwnedPathSafety.validateRegularFile(at: fileURL)
    }

    static func validateAppOwnedFile(_ url: URL) throws {
        try self.ensureAppDirectory()
        try AppOwnedPathSafety.validateRegularFile(at: url)
    }

    private static func validateAppOwnedPaths() throws {
        let directory = try AppOwnedPathSafety.info(at: self.appDirectoryURL)
        if directory.exists {
            guard !directory.isSymbolicLink else {
                throw AppOwnedPathError.symbolicLink(self.appDirectoryURL.path)
            }
            guard directory.isDirectory else {
                throw AppOwnedPathError.notDirectory(self.appDirectoryURL.path)
            }
        }

        try AppOwnedPathSafety.validateRegularFile(at: self.fileURL)
    }

    private static func loadPersistedConfig() -> AppConfig {
        guard (try? self.validateAppOwnedPaths()) != nil else {
            return .default
        }
        return self.loadPersistedConfigFromDisk() ?? .default
    }

    private static func loadPersistedConfigFromDisk() -> AppConfig? {
        self.loadPersistedConfigFromDisk(at: self.fileURL)
    }

    private static func loadPersistedConfigFromDisk(at fileURL: URL) -> AppConfig? {
        guard let info = try? AppOwnedPathSafety.info(at: fileURL), info.exists else {
            return nil
        }
        guard let data = try? Data(contentsOf: fileURL) else {
            return nil
        }
        return try? JSONDecoder().decode(AppConfig.self, from: data)
    }

    private static func hasEnvironmentOverride(_ key: String) -> Bool {
        self.environmentOverrides[key] != nil
    }

    private static func applyEnvironmentOverrides(to base: AppConfig) -> AppConfig {
        let env = ProcessInfo.processInfo.environment
        var config = base
        config.openCodeCookieHeader = self.normalizedString(env["LLM_BAR_OPENCODE_COOKIE"]) ?? config.openCodeCookieHeader
        config.openCodeWorkspaceID = self.normalizedString(env["LLM_BAR_OPENCODE_WORKSPACE_ID"]) ?? config.openCodeWorkspaceID
        config.piSessionsDirectory = self.normalizedString(env["LLM_BAR_PI_SESSIONS_DIR"]) ?? config.piSessionsDirectory

        if let refresh = env["LLM_BAR_REFRESH_SECONDS"], let value = Int(refresh), value >= 30 {
            config.refreshIntervalSeconds = value
        }

        if let piDeduplicateForkHistory = self.parseBool(env["LLM_BAR_PI_DEDUPE_FORKS"]) {
            config.piDeduplicateForkHistory = piDeduplicateForkHistory
        }

        return config
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

import Darwin
import Foundation

struct ManagedCodexHomeRemoval: Sendable {
    let originalURL: URL
    let quarantineURL: URL
}

// A removal is a two-resource transaction: the credential home is first moved to a recoverable
// quarantine, then metadata is committed, and only then is the quarantine deleted. Keeping this
// orchestration separate makes the failure paths explicit and allows them to be fault-injected in
// unit tests without changing ConfigStore's process-wide behavior.
enum ManagedCodexAccountRemovalTransactionError: LocalizedError, Sendable {
    case metadataSaveFailed(String)
    case credentialFinalizationFailed(String)

    var errorDescription: String? {
        switch self {
        case let .metadataSaveFailed(message):
            return "Managed Codex account metadata could not be committed safely: \(message)"
        case let .credentialFinalizationFailed(message):
            return "Managed Codex account removal could not be finalized safely: \(message)"
        }
    }
}

enum ManagedCodexAccountRemovalTransaction {
    static func commit(
        original: AppConfig,
        next: AppConfig,
        removal: ManagedCodexHomeRemoval?,
        save: (AppConfig) -> Bool,
        finalize: (ManagedCodexHomeRemoval) throws -> Void,
        restore: (ManagedCodexHomeRemoval) throws -> Void) throws
    {
        // The quarantine must still exist while metadata is written. ConfigStore.save is atomic,
        // but a false result can still represent a failure after replacement, so explicitly write
        // the original document back before reporting failure.
        guard save(next) else {
            var failures = ["Could not save the account-removal metadata."]
            if let removal {
                do {
                    try restore(removal)
                } catch {
                    failures.append("Credential restore also failed: \(error.localizedDescription)")
                }
            }
            if !save(original) {
                failures.append("Restoring the original account metadata also failed.")
            }
            throw ManagedCodexAccountRemovalTransactionError.metadataSaveFailed(
                failures.joined(separator: " "))
        }

        guard let removal else { return }
        do {
            try finalize(removal)
        } catch {
            var failures = ["Credential-home quarantine deletion failed: \(error.localizedDescription)"]
            // Both rollback operations are best effort and must be attempted independently. In
            // particular, a metadata rollback must still be attempted if moving the home back
            // fails, and vice versa.
            do {
                try restore(removal)
            } catch {
                failures.append("Credential restore also failed: \(error.localizedDescription)")
            }
            if !save(original) {
                failures.append("Restoring the original account metadata also failed.")
            }
            throw ManagedCodexAccountRemovalTransactionError.credentialFinalizationFailed(
                failures.joined(separator: " "))
        }
    }
}

struct ManagedCodexHomeStore: @unchecked Sendable {
    let root: URL
    private let fileManager: FileManager

    init(
        root: URL = ConfigStore.appDirectoryURL.appendingPathComponent("codex-accounts", isDirectory: true),
        fileManager: FileManager = .default)
    {
        self.root = root.standardizedFileURL
        self.fileManager = fileManager
    }

    func homeURL(for accountID: UUID) -> URL {
        self.root.appendingPathComponent(accountID.uuidString, isDirectory: true)
    }

    @discardableResult
    func prepareAccountHome(for accountID: UUID) throws -> URL {
        try self.prepareRoot(create: true)
        let home = self.homeURL(for: accountID)
        try self.ensureDirectory(home)
        return home
    }

    func prepareLoginStagingHome(for accountID: UUID) throws -> URL {
        let home = try self.prepareAccountHome(for: accountID)
        let staging = home.appendingPathComponent(
            ".login-staging-\(UUID().uuidString)",
            isDirectory: true)
        try self.validateManagedPath(staging, allowMissing: true)
        try AppOwnedPathSafety.ensureDirectory(at: staging, permissions: 0o700)
        return staging
    }

    func removeLoginStagingHome(_ staging: URL, accountID: UUID) throws {
        let home = try self.prepareAccountHome(for: accountID)
        let stagingPath = staging.standardizedFileURL.path
        let homePath = home.standardizedFileURL.path
        let prefix = homePath.hasSuffix("/") ? homePath : homePath + "/"
        guard stagingPath.hasPrefix(prefix), stagingPath != homePath else {
            throw ManagedCodexHomeStoreError.unsafeHome(stagingPath)
        }
        try self.validateManagedPath(staging, allowMissing: true)
        let info = try AppOwnedPathSafety.info(at: staging)
        guard !info.exists || !info.isSymbolicLink else {
            throw ManagedCodexHomeStoreError.symbolicLink(staging.path)
        }
        if info.exists {
            try self.fileManager.removeItem(at: staging)
        }
    }

    func secureAuthFile(for accountID: UUID, requireExisting: Bool = false) throws {
        let home = try self.prepareAccountHome(for: accountID)
        let authURL = home.appendingPathComponent("auth.json")
        let info = try AppOwnedPathSafety.info(at: authURL)
        guard info.exists else {
            if requireExisting { throw ManagedCodexHomeStoreError.missingAuthFile(authURL.path) }
            return
        }
        guard !info.isSymbolicLink else {
            throw ManagedCodexHomeStoreError.symbolicLink(authURL.path)
        }
        guard info.isRegularFile else {
            throw ManagedCodexHomeStoreError.invalidAuthFile(authURL.path)
        }
        try AppOwnedPathSafety.hardenRegularFile(at: authURL, permissions: 0o600)
    }

    func validateAuthCredentials(in home: URL) throws {
        try self.validateManagedPath(home, allowMissing: false)
        let info = try AppOwnedPathSafety.info(at: home)
        guard info.exists, !info.isSymbolicLink, info.isDirectory else {
            throw ManagedCodexHomeStoreError.invalidAuthFile(home.path)
        }

        let authURL = home.appendingPathComponent("auth.json")
        try AppOwnedPathSafety.validateRegularFile(at: authURL, allowMissing: false)
        let authInfo = try AppOwnedPathSafety.info(at: authURL)
        guard authInfo.permissions == 0o600 else {
            throw ManagedCodexHomeStoreError.insecureAuthFile(authURL.path)
        }

        let data: Data
        do {
            data = try Data(contentsOf: authURL)
        } catch {
            throw ManagedCodexHomeStoreError.invalidAuthFile(authURL.path)
        }
        guard data.count <= 1_000_000 else {
            throw ManagedCodexHomeStoreError.invalidAuthFile(authURL.path)
        }

        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw ManagedCodexHomeStoreError.invalidAuthFile(authURL.path)
        }
        guard let dictionary = object as? [String: Any] else {
            throw ManagedCodexHomeStoreError.invalidAuthType(authURL.path)
        }

        if let type = dictionary["type"] as? String,
           !["oauth", "chatgpt", "chatgptOAuth"].contains(type) {
            throw ManagedCodexHomeStoreError.invalidAuthType(authURL.path)
        }
        if let authMode = dictionary["auth_mode"] as? String,
           !["chatgpt", "oauth"].contains(authMode.lowercased()) {
            throw ManagedCodexHomeStoreError.invalidAuthType(authURL.path)
        }
        if let apiKey = dictionary["OPENAI_API_KEY"], !(apiKey is NSNull) {
            // This flow is explicitly ChatGPT OAuth. Do not accept an API-key credential or an
            // arbitrary value in a file that the app is about to install as an account credential.
            throw ManagedCodexHomeStoreError.invalidAuthType(authURL.path)
        }

        guard let tokens = dictionary["tokens"] as? [String: Any],
              Self.nonEmptyString(tokens["access_token"]),
              Self.nonEmptyString(tokens["refresh_token"])
        else {
            throw ManagedCodexHomeStoreError.invalidAuthType(authURL.path)
        }
        if let accountID = tokens["account_id"], !Self.nonEmptyString(accountID) {
            throw ManagedCodexHomeStoreError.invalidAuthType(authURL.path)
        }
    }

    func commitStagedAuth(for accountID: UUID, stagingHome: URL) throws {
        let home = try self.prepareAccountHome(for: accountID)
        try self.validateManagedPath(stagingHome, allowMissing: false)
        let stagingInfo = try AppOwnedPathSafety.info(at: stagingHome)
        guard stagingInfo.exists, !stagingInfo.isSymbolicLink, stagingInfo.isDirectory else {
            throw ManagedCodexHomeStoreError.invalidAuthFile(stagingHome.path)
        }

        let stagedAuth = stagingHome.appendingPathComponent("auth.json")
        try AppOwnedPathSafety.hardenRegularFile(at: stagedAuth, permissions: 0o600)
        try self.validateAuthCredentials(in: stagingHome)

        let targetAuth = home.appendingPathComponent("auth.json")
        let targetInfo = try AppOwnedPathSafety.info(at: targetAuth)
        if targetInfo.exists {
            guard !targetInfo.isSymbolicLink else {
                throw ManagedCodexHomeStoreError.symbolicLink(targetAuth.path)
            }
            guard targetInfo.isRegularFile else {
                throw ManagedCodexHomeStoreError.invalidAuthFile(targetAuth.path)
            }
        }

        // Both files are under the same managed account tree. rename(2) replaces the old auth file
        // atomically and never exposes the staging directory's other files as the live CODEX_HOME.
        let result = stagedAuth.withUnsafeFileSystemRepresentation { sourcePointer -> Int32 in
            targetAuth.withUnsafeFileSystemRepresentation { targetPointer -> Int32 in
                guard let sourcePointer, let targetPointer else { return -1 }
                return Darwin.rename(sourcePointer, targetPointer)
            }
        }
        guard result == 0 else {
            throw AppOwnedPathError.filesystem(targetAuth.path, String(cString: strerror(errno)))
        }

        // rename preserves the already-validated 0600 mode of the staged inode. There is no
        // fallible post-replacement mutation that could report failure after the old credential
        // has been replaced.
    }

    func removeAccountHome(for accountID: UUID) throws {
        let home = self.homeURL(for: accountID)
        try self.validateManagedPath(home, allowMissing: true)
        let info = try AppOwnedPathSafety.info(at: home)
        guard !info.exists else {
            guard !info.isSymbolicLink else {
                throw ManagedCodexHomeStoreError.symbolicLink(home.path)
            }
            guard info.isDirectory else {
                throw ManagedCodexHomeStoreError.notDirectory(home.path)
            }
            try self.fileManager.removeItem(at: home)
            return
        }
    }

    func stageAccountHomeRemoval(for accountID: UUID) throws -> ManagedCodexHomeRemoval? {
        try self.prepareRoot(create: false)
        let home = self.homeURL(for: accountID)
        try self.validateManagedPath(home, allowMissing: true)
        let homeInfo = try AppOwnedPathSafety.info(at: home)
        guard homeInfo.exists else { return nil }
        guard !homeInfo.isSymbolicLink else {
            throw ManagedCodexHomeStoreError.symbolicLink(home.path)
        }
        guard homeInfo.isDirectory else {
            throw ManagedCodexHomeStoreError.notDirectory(home.path)
        }

        let quarantine = self.root.appendingPathComponent(
            ".removing-\(accountID.uuidString)-\(UUID().uuidString)",
            isDirectory: true)
        try self.validateManagedPath(quarantine, allowMissing: true)
        guard !(try AppOwnedPathSafety.info(at: quarantine)).exists else {
            throw ManagedCodexHomeStoreError.unsafeHome(quarantine.path)
        }
        do {
            try self.fileManager.moveItem(at: home, to: quarantine)
        } catch {
            throw ManagedCodexHomeStoreError.removalFailed(error.localizedDescription)
        }
        return ManagedCodexHomeRemoval(originalURL: home, quarantineURL: quarantine)
    }

    func restoreAccountHome(_ removal: ManagedCodexHomeRemoval) throws {
        try self.validateManagedPath(removal.originalURL, allowMissing: true)
        try self.validateManagedPath(removal.quarantineURL, allowMissing: false)
        let originalInfo = try AppOwnedPathSafety.info(at: removal.originalURL)
        guard !originalInfo.exists else {
            throw ManagedCodexHomeStoreError.unsafeHome(removal.originalURL.path)
        }
        do {
            try self.fileManager.moveItem(at: removal.quarantineURL, to: removal.originalURL)
        } catch {
            throw ManagedCodexHomeStoreError.removalFailed(error.localizedDescription)
        }
    }

    func finalizeAccountHomeRemoval(_ removal: ManagedCodexHomeRemoval) throws {
        try self.validateManagedPath(removal.quarantineURL, allowMissing: true)
        let info = try AppOwnedPathSafety.info(at: removal.quarantineURL)
        guard !info.exists || !info.isSymbolicLink else {
            throw ManagedCodexHomeStoreError.symbolicLink(removal.quarantineURL.path)
        }
        if info.exists {
            guard info.isDirectory else {
                throw ManagedCodexHomeStoreError.notDirectory(removal.quarantineURL.path)
            }
            do {
                try self.fileManager.removeItem(at: removal.quarantineURL)
            } catch {
                throw ManagedCodexHomeStoreError.removalFailed(error.localizedDescription)
            }
        }
    }

    func validateManagedHome(_ url: URL) throws {
        try self.validateManagedPath(url, allowMissing: true)
    }

    func recoverQuarantinedHomes(for accountIDs: Set<UUID>) throws {
        try self.prepareRoot(create: false)
        let rootInfo = try AppOwnedPathSafety.info(at: self.root)
        guard rootInfo.exists else { return }
        let entries = try self.fileManager.contentsOfDirectory(
            at: self.root,
            includingPropertiesForKeys: nil,
            options: [])
        let prefix = ".removing-"
        for entry in entries {
            let name = entry.lastPathComponent
            guard name.hasPrefix(prefix), name.count >= prefix.count + 36 else { continue }
            let idText = String(name.dropFirst(prefix.count).prefix(36))
            guard let accountID = UUID(uuidString: idText), accountIDs.contains(accountID) else {
                // Do not guess whether an unknown quarantine is safe to delete. Leave it in place
                // for explicit recovery rather than risking credential loss.
                continue
            }
            let home = self.homeURL(for: accountID)
            let homeInfo = try AppOwnedPathSafety.info(at: home)
            let quarantineInfo = try AppOwnedPathSafety.info(at: entry)
            guard quarantineInfo.exists, !quarantineInfo.isSymbolicLink, quarantineInfo.isDirectory else {
                throw ManagedCodexHomeStoreError.symbolicLink(entry.path)
            }
            if homeInfo.exists {
                throw ManagedCodexHomeStoreError.removalFailed(
                    "Both the live and quarantined homes exist for account \(accountID.uuidString).")
            }
            try self.restoreAccountHome(
                ManagedCodexHomeRemoval(originalURL: home, quarantineURL: entry))
        }
    }

    private func prepareRoot(create: Bool) throws {
        let defaultRoot = ConfigStore.appDirectoryURL
            .appendingPathComponent("codex-accounts", isDirectory: true)
            .standardizedFileURL
        if self.root.path == defaultRoot.path {
            try ConfigStore.ensureAppDirectory()
        }

        let rootInfo = try AppOwnedPathSafety.info(at: self.root)
        if !rootInfo.exists {
            guard create else { return }
            if self.root.path == defaultRoot.path {
                try AppOwnedPathSafety.ensureDirectory(at: self.root, permissions: 0o700)
            } else {
                try AppOwnedPathSafety.ensureDirectoryTree(at: self.root, permissions: 0o700)
            }
        } else {
            guard !rootInfo.isSymbolicLink else {
                throw ManagedCodexHomeStoreError.symbolicLink(self.root.path)
            }
            guard rootInfo.isDirectory else {
                throw ManagedCodexHomeStoreError.notDirectory(self.root.path)
            }
            try AppOwnedPathSafety.ensureDirectory(at: self.root, permissions: 0o700)
        }
    }

    private func ensureDirectory(_ url: URL) throws {
        try self.validateManagedPath(url, allowMissing: true)
        do {
            try AppOwnedPathSafety.ensureDirectory(at: url, permissions: 0o700)
        } catch let error as AppOwnedPathError {
            throw error
        } catch {
            throw ManagedCodexHomeStoreError.removalFailed(error.localizedDescription)
        }
    }

    private func validateManagedPath(_ url: URL, allowMissing: Bool) throws {
        let rootPath = self.root.standardizedFileURL.path
        let targetPath = url.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard targetPath.hasPrefix(prefix), targetPath != rootPath else {
            throw ManagedCodexHomeStoreError.unsafeHome(targetPath)
        }

        let rootInfo = try AppOwnedPathSafety.info(at: self.root)
        if rootInfo.exists {
            guard !rootInfo.isSymbolicLink else {
                throw ManagedCodexHomeStoreError.symbolicLink(self.root.path)
            }
            guard rootInfo.isDirectory else {
                throw ManagedCodexHomeStoreError.notDirectory(self.root.path)
            }
        }

        var current = url.standardizedFileURL
        while current.path != rootPath {
            let info = try AppOwnedPathSafety.info(at: current)
            if info.exists {
                guard !info.isSymbolicLink else {
                    throw ManagedCodexHomeStoreError.symbolicLink(current.path)
                }
            } else if !allowMissing {
                throw ManagedCodexHomeStoreError.unsafeHome(current.path)
            }
            let parent = current.deletingLastPathComponent()
            guard parent.path != current.path else {
                throw ManagedCodexHomeStoreError.unsafeHome(targetPath)
            }
            current = parent
        }
    }

    private static func nonEmptyString(_ value: Any?) -> Bool {
        guard let value = value as? String else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

enum ManagedCodexHomeStoreError: LocalizedError, Equatable, Sendable {
    case unsafeHome(String)
    case symbolicLink(String)
    case notDirectory(String)
    case missingAuthFile(String)
    case invalidAuthFile(String)
    case invalidAuthType(String)
    case insecureAuthFile(String)
    case removalFailed(String)

    var errorDescription: String? {
        switch self {
        case let .unsafeHome(path):
            return "Refusing to use a managed Codex home outside the app-owned account directory: \(path)"
        case let .symbolicLink(path):
            return "Refusing to use a symbolic link in the managed Codex credential path: \(path)"
        case let .notDirectory(path):
            return "Managed Codex path is not a directory: \(path)"
        case let .missingAuthFile(path):
            return "Codex login completed without creating the isolated auth.json: \(path)"
        case let .invalidAuthFile(path):
            return "Managed Codex auth.json is unreadable or not a regular JSON file: \(path)"
        case let .invalidAuthType(path):
            return "Managed Codex auth.json does not contain a supported ChatGPT OAuth credential: \(path)"
        case let .insecureAuthFile(path):
            return "Managed Codex auth.json could not be secured to mode 0600: \(path)"
        case let .removalFailed(message):
            return "Managed Codex account home removal failed: \(message)"
        }
    }
}

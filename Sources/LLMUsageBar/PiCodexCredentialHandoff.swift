import CryptoKit
import Darwin
import Foundation

struct PiCodexOAuthCredential: Equatable, Sendable {
    let access: String
    let refresh: String
    let expires: Double
    let accountID: String

    var isExpired: Bool { self.expires <= Date().timeIntervalSince1970 * 1000 }
}

enum PiCodexCredentialHandoffError: LocalizedError, Equatable, Sendable {
    case accountNotFound
    case accountAlreadyActive
    case handoffStateInvalid(String)
    case recoveryRequired(String)
    case piAuthUnsafe(String)
    case piAuthBusy
    case lockOwnershipLost(String)
    case piAuthMalformed(String)
    case piCredentialMissing
    case piCredentialIdentityMismatch(expected: String, actual: String)
    case invalidPiCredential(String)
    case managedCredentialMissing(String)
    case invalidManagedCredential(String)
    case managedCredentialIdentityMismatch(expected: String, actual: String)
    case concurrentChange(String)
    case configSaveFailed
    case filesystem(String)
    case rollbackFailed(String)
    case cleanupFailed(String)

    var errorDescription: String? {
        switch self {
        case .accountNotFound:
            return "The managed Codex account no longer exists."
        case .accountAlreadyActive:
            return "This managed Codex account is already the active Pi account."
        case let .handoffStateInvalid(message):
            return "The managed Codex ↔ Pi handoff state is inconsistent: \(message)"
        case let .recoveryRequired(message):
            return "A previous managed Codex ↔ Pi handoff needs recovery before another switch: \(message)"
        case let .piAuthUnsafe(path):
            return "Refusing to use the Pi credential path because it is unsafe: \(path)"
        case .piAuthBusy:
            return "Pi's auth.json is busy. Exit Pi or wait for its token refresh to finish, then try again."
        case let .lockOwnershipLost(path):
            return "The credential transaction lost ownership of its cooperative lock: \(path). The transaction was aborted and must be recovered before another switch."
        case let .piAuthMalformed(message):
            return "Pi auth.json is not a supported credential document: \(message)"
        case .piCredentialMissing:
            return "Pi does not contain an openai-codex OAuth credential."
        case let .piCredentialIdentityMismatch(expected, actual):
            return "Pi's openai-codex credential belongs to a different ChatGPT account (expected \(expected), found \(actual))."
        case let .invalidPiCredential(message):
            return "Pi's openai-codex credential is invalid: \(message)"
        case let .managedCredentialMissing(path):
            return "The managed Codex account has no isolated auth.json: \(path)"
        case let .invalidManagedCredential(message):
            return "The managed Codex auth.json is not a supported ChatGPT OAuth credential: \(message)"
        case let .managedCredentialIdentityMismatch(expected, actual):
            return "The managed Codex credential belongs to a different ChatGPT account (expected \(expected), found \(actual))."
        case let .concurrentChange(path):
            return "The credential changed while it was being switched. No account was activated; try again after Pi finishes refreshing: \(path)"
        case .configSaveFailed:
            return "The credentials were not switched because the managed-account configuration could not be saved safely."
        case let .filesystem(message):
            return "The credential handoff could not access its protected files: \(message)"
        case let .rollbackFailed(message):
            return "The credential handoff failed and could not fully roll back safely: \(message)"
        case let .cleanupFailed(message):
            return "The account is active, but protected handoff cleanup needs attention: \(message)"
        }
    }
}

struct PiCodexHandoffResult: Sendable {
    let config: AppConfig
    let warning: String?
}

fileprivate struct PiAuthDocument {
    let data: Data
    let existedBeforeLock: Bool
    let object: [String: Any]

    var credentialObject: [String: Any]? {
        self.object["openai-codex"] as? [String: Any]
    }

    var credential: PiCodexOAuthCredential? {
        guard let credentialObject else { return nil }
        return try? PiCodexCredentialCodec.piCredential(from: credentialObject)
    }
}

private struct NativeCodexCredential {
    let data: Data
    let object: [String: Any]
    let access: String
    let refresh: String
    let accountID: String
    let expires: Double

    var piObject: [String: Any] {
        [
            "type": "oauth",
            "access": self.access,
            "refresh": self.refresh,
            "expires": self.expires,
            "accountId": self.accountID,
        ]
    }

    static func from(data: Data, path: String, expectedAccountID: String?) throws -> NativeCodexCredential {
        guard data.count <= 1_000_000 else {
            throw PiCodexCredentialHandoffError.invalidManagedCredential("the file is too large")
        }
        let object = try PiCodexCredentialCodec.jsonObject(from: data) { message in
            .invalidManagedCredential("\(path): \(message)")
        }
        if let type = object["type"] as? String,
           !["oauth", "chatgpt", "chatgptOAuth"].contains(type)
        {
            throw PiCodexCredentialHandoffError.invalidManagedCredential("unsupported authentication type")
        }
        if let mode = object["auth_mode"] as? String,
           !["chatgpt", "oauth"].contains(mode.lowercased())
        {
            throw PiCodexCredentialHandoffError.invalidManagedCredential("unsupported authentication mode")
        }
        if let apiKey = object["OPENAI_API_KEY"], !(apiKey is NSNull) {
            throw PiCodexCredentialHandoffError.invalidManagedCredential("an API-key credential cannot be handed off to Pi")
        }
        guard let tokens = object["tokens"] as? [String: Any],
              let access = PiCodexCredentialCodec.nonEmptyString(tokens["access_token"]),
              let refresh = PiCodexCredentialCodec.nonEmptyString(tokens["refresh_token"])
        else {
            throw PiCodexCredentialHandoffError.invalidManagedCredential("access_token and refresh_token are required")
        }

        let declaredAccountID = PiCodexCredentialCodec.nonEmptyString(tokens["account_id"])
        if tokens["account_id"] != nil, declaredAccountID == nil {
            throw PiCodexCredentialHandoffError.invalidManagedCredential("account_id must be a non-empty string")
        }
        let tokenAccountID = PiCodexCredentialCodec.jwtAccountID(access)
        guard let accountID = declaredAccountID ?? tokenAccountID else {
            throw PiCodexCredentialHandoffError.invalidManagedCredential("the ChatGPT account identity is missing")
        }
        if let declaredAccountID, let tokenAccountID, declaredAccountID != tokenAccountID {
            throw PiCodexCredentialHandoffError.invalidManagedCredential("account_id does not match the access token")
        }
        if let expectedAccountID, expectedAccountID != accountID {
            throw PiCodexCredentialHandoffError.managedCredentialIdentityMismatch(
                expected: expectedAccountID,
                actual: accountID)
        }

        return NativeCodexCredential(
            data: data,
            object: object,
            access: access,
            refresh: refresh,
            accountID: accountID,
            // Native Codex auth.json normally has no expiry. A JWT expiry is the safest value;
            // zero deliberately makes Pi refresh immediately when the token is opaque.
            expires: PiCodexCredentialCodec.jwtExpiryMilliseconds(access) ?? 0)
    }

    static func fromPi(_ credential: PiCodexOAuthCredential) -> NativeCodexCredential {
        let tokens: [String: Any] = [
            "access_token": credential.access,
            "refresh_token": credential.refresh,
            "account_id": credential.accountID,
        ]
        let object: [String: Any] = [
            "OPENAI_API_KEY": NSNull(),
            "tokens": tokens,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted])) ?? Data()
        return NativeCodexCredential(
            data: data,
            object: object,
            access: credential.access,
            refresh: credential.refresh,
            accountID: credential.accountID,
            expires: credential.expires)
    }
}

private enum PiCodexCredentialCodec {
    static func jsonObject(
        from data: Data,
        mapError: (String) -> PiCodexCredentialHandoffError) throws -> [String: Any]
    {
        let value: Any
        do {
            value = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw mapError("invalid JSON")
        }
        guard let object = value as? [String: Any] else {
            throw mapError("the top-level value must be a JSON object")
        }
        return object
    }

    static func nonEmptyString(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    static func piCredential(from object: [String: Any]) throws -> PiCodexOAuthCredential {
        guard object["type"] as? String == "oauth" else {
            throw PiCodexCredentialHandoffError.invalidPiCredential("type must be oauth")
        }
        guard let access = self.nonEmptyString(object["access"]),
              let refresh = self.nonEmptyString(object["refresh"]),
              let accountID = self.nonEmptyString(object["accountId"])
        else {
            throw PiCodexCredentialHandoffError.invalidPiCredential("access, refresh, and accountId are required")
        }
        guard let expiresNumber = object["expires"] as? NSNumber,
              !self.isBooleanNumber(object["expires"]),
              expiresNumber.doubleValue.isFinite,
              expiresNumber.doubleValue >= 0
        else {
            throw PiCodexCredentialHandoffError.invalidPiCredential("expires must be a finite non-negative number")
        }
        if let tokenAccountID = self.jwtAccountID(access), tokenAccountID != accountID {
            throw PiCodexCredentialHandoffError.piCredentialIdentityMismatch(
                expected: accountID,
                actual: tokenAccountID)
        }
        if let apiKey = object["OPENAI_API_KEY"], !(apiKey is NSNull) {
            throw PiCodexCredentialHandoffError.invalidPiCredential("an OAuth entry cannot contain an API key")
        }
        return PiCodexOAuthCredential(
            access: access,
            refresh: refresh,
            expires: expiresNumber.doubleValue,
            accountID: accountID)
    }

    static func jwtAccountID(_ token: String) -> String? {
        guard let payload = self.jwtPayload(token),
              let auth = payload["https://api.openai.com/auth"] as? [String: Any]
        else { return nil }
        return self.nonEmptyString(auth["chatgpt_account_id"] ?? auth["account_id"])
    }

    static func jwtExpiryMilliseconds(_ token: String) -> Double? {
        guard let payload = self.jwtPayload(token),
              let value = payload["exp"] as? NSNumber,
              !self.isBooleanNumber(payload["exp"]),
              value.doubleValue.isFinite,
              value.doubleValue >= 0
        else { return nil }
        return value.doubleValue * 1000
    }

    private static func isBooleanNumber(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    private static func jwtPayload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var encoded = String(parts[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded),
              let object = try? JSONSerialization.jsonObject(with: data, options: []),
              let payload = object as? [String: Any]
        else { return nil }
        return payload
    }
}

private enum SecureAtomicCredentialFile {
    static func createIfMissing(
        data: Data,
        at url: URL,
        permissions: Int = 0o600,
        tolerateExisting: Bool = true) throws
    {
        let descriptor = url.withUnsafeFileSystemRepresentation { pointer -> Int32 in
            guard let pointer else { return -1 }
            return Darwin.open(pointer, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(permissions))
        }
        if descriptor < 0 {
            let errorCode = errno
            if tolerateExisting, errorCode == EEXIST { return }
            throw PiCodexCredentialHandoffError.filesystem("could not create \(url.path): \(String(cString: strerror(errorCode)))")
        }
        do {
            try self.write(data, to: descriptor, path: url.path)
        } catch {
            _ = Darwin.close(descriptor)
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        guard Darwin.close(descriptor) == 0 else {
            throw PiCodexCredentialHandoffError.filesystem("could not close \(url.path)")
        }
        try self.verify(url, permissions: permissions)
    }

    static func replace(data: Data, at url: URL, permissions: Int = 0o600) throws {
        let parent = url.deletingLastPathComponent()
        let temporary = parent.appendingPathComponent(
            ".handoff-\(UUID().uuidString).tmp",
            isDirectory: false)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try self.createIfMissing(
            data: data,
            at: temporary,
            permissions: permissions,
            tolerateExisting: false)

        let targetInfo = try AppOwnedPathSafety.info(at: url)
        if targetInfo.exists {
            guard !targetInfo.isSymbolicLink, targetInfo.isRegularFile else {
                throw PiCodexCredentialHandoffError.piAuthUnsafe(url.path)
            }
        }
        let result = temporary.withUnsafeFileSystemRepresentation { sourcePointer -> Int32 in
            url.withUnsafeFileSystemRepresentation { targetPointer -> Int32 in
                guard let sourcePointer, let targetPointer else { return -1 }
                return Darwin.rename(sourcePointer, targetPointer)
            }
        }
        guard result == 0 else {
            throw PiCodexCredentialHandoffError.filesystem("could not atomically replace \(url.path): \(String(cString: strerror(errno)))")
        }
        try self.verify(url, permissions: permissions)
    }

    static func move(from source: URL, to destination: URL) throws {
        let sourceInfo = try AppOwnedPathSafety.info(at: source)
        guard sourceInfo.exists, !sourceInfo.isSymbolicLink, sourceInfo.isRegularFile else {
            throw PiCodexCredentialHandoffError.piAuthUnsafe(source.path)
        }
        let destinationInfo = try AppOwnedPathSafety.info(at: destination)
        guard !destinationInfo.exists else {
            throw PiCodexCredentialHandoffError.concurrentChange(destination.path)
        }
        let result = source.withUnsafeFileSystemRepresentation { sourcePointer -> Int32 in
            destination.withUnsafeFileSystemRepresentation { destinationPointer -> Int32 in
                guard let sourcePointer, let destinationPointer else { return -1 }
                return Darwin.rename(sourcePointer, destinationPointer)
            }
        }
        guard result == 0 else {
            throw PiCodexCredentialHandoffError.filesystem("could not move protected credential: \(String(cString: strerror(errno)))")
        }
    }

    static func remove(_ url: URL) throws {
        let info = try AppOwnedPathSafety.info(at: url)
        guard !info.exists else {
            guard !info.isSymbolicLink, info.isRegularFile else {
                throw PiCodexCredentialHandoffError.piAuthUnsafe(url.path)
            }
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                throw PiCodexCredentialHandoffError.filesystem("could not remove \(url.path): \(error.localizedDescription)")
            }
            return
        }
    }

    private static func write(_ data: Data, to descriptor: Int32, path: String) throws {
        var written = 0
        while written < data.count {
            let count = data.withUnsafeBytes { rawBuffer -> Int in
                guard let base = rawBuffer.baseAddress else { return -1 }
                return Darwin.write(
                    descriptor,
                    base.advanced(by: written),
                    data.count - written)
            }
            guard count > 0 else {
                throw PiCodexCredentialHandoffError.filesystem("could not write \(path): \(String(cString: strerror(errno)))")
            }
            written += count
        }
        guard Darwin.fsync(descriptor) == 0 else {
            throw PiCodexCredentialHandoffError.filesystem("could not flush \(path): \(String(cString: strerror(errno)))")
        }
    }

    private static func verify(_ url: URL, permissions: Int) throws {
        let info = try AppOwnedPathSafety.info(at: url)
        guard info.exists, !info.isSymbolicLink, info.isRegularFile, info.permissions == permissions else {
            throw PiCodexCredentialHandoffError.piAuthUnsafe(url.path)
        }
    }
}

private final class HandoffDirectoryLockState: @unchecked Sendable {
    let url: URL
    let identity: (device: UInt64, inode: UInt64)
    private var descriptor: Int32
    private let mutex = NSLock()
    private var timer: DispatchSourceTimer?
    private var released = false
    private var compromised = false
    private var lossMessage: String?

    init(url: URL, identity: (device: UInt64, inode: UInt64), descriptor: Int32) {
        self.url = url
        self.identity = identity
        self.descriptor = descriptor
    }

    var isCompromised: Bool {
        self.mutex.lock()
        defer { self.mutex.unlock() }
        return self.compromised
    }

    func startHeartbeat(_ timer: DispatchSourceTimer) {
        self.mutex.lock()
        guard !self.released else {
            self.mutex.unlock()
            timer.cancel()
            return
        }
        self.timer = timer
        self.mutex.unlock()

        timer.setEventHandler { [weak self] in self?.heartbeat() }
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
        timer.resume()
    }

    func checkOwnership() throws {
        self.mutex.lock()
        guard !self.released else {
            self.mutex.unlock()
            return
        }
        if self.compromised {
            let message = self.lossMessage ?? self.url.path
            self.mutex.unlock()
            throw PiCodexCredentialHandoffError.lockOwnershipLost(message)
        }
        let descriptor = self.descriptor
        let expected = self.identity
        self.mutex.unlock()

        var descriptorInfo = Darwin.stat()
        guard Darwin.fstat(descriptor, &descriptorInfo) == 0,
              UInt64(descriptorInfo.st_dev) == expected.device,
              UInt64(descriptorInfo.st_ino) == expected.inode,
              descriptorInfo.st_mode & S_IFMT == S_IFDIR
        else {
            throw self.markCompromised("the lock descriptor no longer refers to the owned inode")
        }

        let currentInfo: AppOwnedPathInfo
        do {
            currentInfo = try AppOwnedPathSafety.info(at: self.url)
        } catch {
            throw self.markCompromised("the lock path could not be inspected")
        }
        guard currentInfo.exists, !currentInfo.isSymbolicLink, currentInfo.isDirectory,
              currentInfo.device == expected.device, currentInfo.inode == expected.inode
        else {
            throw self.markCompromised("the lock path was removed or replaced")
        }

        self.mutex.lock()
        let lost = self.compromised
        let message = self.lossMessage ?? self.url.path
        self.mutex.unlock()
        if lost { throw PiCodexCredentialHandoffError.lockOwnershipLost(message) }
    }

    func markReleased() -> Bool {
        self.mutex.lock()
        guard !self.released else {
            self.mutex.unlock()
            return false
        }
        self.released = true
        let timer = self.timer
        self.timer = nil
        let descriptor = self.descriptor
        self.descriptor = -1
        self.mutex.unlock()

        timer?.setEventHandler {}
        timer?.cancel()
        if descriptor >= 0 { _ = Darwin.close(descriptor) }
        return true
    }

    private func heartbeat() {
        do { try self.checkOwnership() }
        catch { return }

        self.mutex.lock()
        guard !self.released, !self.compromised, self.descriptor >= 0 else {
            self.mutex.unlock()
            return
        }
        let descriptor = self.descriptor
        var now = timeval()
        gettimeofday(&now, nil)
        var times = [now, now]
        let result = times.withUnsafeMutableBufferPointer {
            Darwin.futimes(descriptor, $0.baseAddress)
        }
        self.mutex.unlock()
        if result != 0 {
            _ = self.markCompromised("the lock heartbeat could not refresh the owned inode")
        }
    }

    private func markCompromised(_ message: String) -> PiCodexCredentialHandoffError {
        self.mutex.lock()
        if !self.released {
            self.compromised = true
            self.lossMessage = message
        }
        let finalMessage = self.lossMessage ?? message
        self.mutex.unlock()
        return .lockOwnershipLost("\(self.url.path): \(finalMessage)")
    }
}

// Pi's proper-lockfile uses mkdir(<auth>.lock), refreshes mtime, and removes only its own
// directory. Swift cannot safely perform proper-lockfile's stale-owner recovery, so an existing
// lock is always busy; in particular, never delete a lock merely because its mtime looks old.
// Unlike the old best-effort heartbeat, this lock records inode replacement as compromised and
// makes the transaction check fail closed before any later credential/config mutation.
final class HandoffDirectoryLock: @unchecked Sendable {
    let url: URL
    private var state: HandoffDirectoryLockState?
    private var compromisedAfterRelease = false

    init(url: URL) {
        self.url = url
    }

    var isCompromised: Bool { self.compromisedAfterRelease || (self.state?.isCompromised ?? false) }

    func acquire() throws {
        let result = self.url.withUnsafeFileSystemRepresentation { pointer -> Int32 in
            guard let pointer else { return -1 }
            return Darwin.mkdir(pointer, mode_t(0o700))
        }
        guard result == 0 else {
            let errorCode = errno
            if errorCode == EEXIST {
                let info = try AppOwnedPathSafety.info(at: self.url)
                guard !info.isSymbolicLink, info.isDirectory else {
                    throw PiCodexCredentialHandoffError.piAuthUnsafe(self.url.path)
                }
                throw PiCodexCredentialHandoffError.piAuthBusy
            }
            throw PiCodexCredentialHandoffError.filesystem(
                "could not acquire \(self.url.path): \(String(cString: strerror(errorCode)))")
        }

        let createdInfo: AppOwnedPathInfo
        do {
            createdInfo = try AppOwnedPathSafety.info(at: self.url)
            guard createdInfo.exists, !createdInfo.isSymbolicLink, createdInfo.isDirectory else {
                throw PiCodexCredentialHandoffError.piAuthUnsafe(self.url.path)
            }
        } catch {
            // The inode could already have been replaced while it was being inspected. Without a
            // verified identity, leave the path untouched rather than trying to clean it up.
            throw error
        }
        let descriptor = self.url.withUnsafeFileSystemRepresentation { pointer -> Int32 in
            guard let pointer else { return -1 }
            return Darwin.open(pointer, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            self.removeOwnedDirectory(identity: (createdInfo.device, createdInfo.inode))
            throw PiCodexCredentialHandoffError.filesystem(
                "could not open \(self.url.path): \(String(cString: strerror(errno)))")
        }

        do {
            try AppOwnedPathSafety.ensureDirectory(at: self.url, permissions: 0o700)
            let info = try AppOwnedPathSafety.info(at: self.url)
            var descriptorInfo = Darwin.stat()
            guard Darwin.fstat(descriptor, &descriptorInfo) == 0,
                  info.exists, !info.isSymbolicLink, info.isDirectory,
                  info.device == createdInfo.device, info.inode == createdInfo.inode,
                  UInt64(descriptorInfo.st_dev) == info.device,
                  UInt64(descriptorInfo.st_ino) == info.inode,
                  descriptorInfo.st_mode & S_IFMT == S_IFDIR
            else {
                throw PiCodexCredentialHandoffError.piAuthUnsafe(self.url.path)
            }

            let state = HandoffDirectoryLockState(
                url: self.url,
                identity: (info.device, info.inode),
                descriptor: descriptor)
            self.state = state
            let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
            state.startHeartbeat(timer)
        } catch {
            _ = Darwin.close(descriptor)
            self.removeOwnedDirectory(identity: (createdInfo.device, createdInfo.inode))
            throw error
        }
    }

    func checkOwnership() throws {
        guard let state = self.state else {
            throw PiCodexCredentialHandoffError.handoffStateInvalid("the cooperative lock is not acquired")
        }
        try state.checkOwnership()
    }

    func release() {
        guard let state = self.state else { return }
        // Catch a replacement that happened between the last transaction check and release. This
        // call is deliberately best effort because release cannot safely report a new error.
        if !state.isCompromised { try? state.checkOwnership() }
        let compromised = state.isCompromised
        guard state.markReleased() else { return }
        self.compromisedAfterRelease = self.compromisedAfterRelease || compromised
        self.state = nil
        // rmdir is deliberately used instead of FileManager.removeItem: a lock directory must be
        // empty, and an ownership mismatch must never remove a replacement lock. A compromised
        // lock is never removed even if its replacement happens to have the same shape.
        guard !compromised else { return }
        self.removeOwnedDirectory(identity: state.identity)
    }

    private func removeOwnedDirectory(identity: (device: UInt64, inode: UInt64)? = nil) {
        guard let info = try? AppOwnedPathSafety.info(at: self.url),
              info.exists, !info.isSymbolicLink, info.isDirectory,
              identity == nil || (info.device == identity!.device && info.inode == identity!.inode)
        else { return }
        self.url.withUnsafeFileSystemRepresentation { pointer in
            guard let pointer else { return }
            _ = Darwin.rmdir(pointer)
        }
    }
}

struct PiAuthStore: Sendable {
    let authURL: URL

    init(
        authURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pi/agent/auth.json"))
    {
        self.authURL = authURL.standardizedFileURL
    }

    var lockURL: URL {
        self.authURL.deletingLastPathComponent()
            .appendingPathComponent("\(self.authURL.lastPathComponent).lock", isDirectory: true)
    }

    fileprivate func withLockedDocument<T>(_ body: (PiAuthDocument, HandoffDirectoryLock) throws -> T) throws -> T {
        try self.ensureParentDirectory()
        let lock = HandoffDirectoryLock(url: self.lockURL)
        try lock.acquire()
        defer { lock.release() }
        try lock.checkOwnership()

        let initialInfo = try AppOwnedPathSafety.info(at: self.authURL)
        if !initialInfo.exists {
            try SecureAtomicCredentialFile.createIfMissing(
                data: Data("{}\n".utf8),
                at: self.authURL,
                permissions: 0o600)
            try lock.checkOwnership()
        }

        try self.secureAuthFile()
        try lock.checkOwnership()
        let raw = try Data(contentsOf: self.authURL)
        guard raw.count <= 1_000_000 else {
            throw PiCodexCredentialHandoffError.piAuthMalformed("the file is too large")
        }
        let object = try PiCodexCredentialCodec.jsonObject(from: raw) { message in
            .piAuthMalformed(message)
        }
        let document = PiAuthDocument(data: raw, existedBeforeLock: initialInfo.exists, object: object)
        do {
            let result = try body(document, lock)
            try lock.checkOwnership()
            return result
        } catch {
            // If a body failed for an unrelated reason but the heartbeat also noticed inode
            // replacement, ownership loss wins: never report a credential transaction as if it
            // completed while another lock owner may have taken over.
            try lock.checkOwnership()
            throw error
        }
    }

    func validateActiveCredential(expectedAccountID: String) throws {
        try self.withLockedDocument { document, _ in
            guard let credentialObject = document.credentialObject else {
                throw PiCodexCredentialHandoffError.piCredentialMissing
            }
            let credential = try PiCodexCredentialCodec.piCredential(from: credentialObject)
            guard credential.accountID == expectedAccountID else {
                throw PiCodexCredentialHandoffError.piCredentialIdentityMismatch(
                    expected: expectedAccountID,
                    actual: credential.accountID)
            }
        }
    }

    func readRawDocument() throws -> Data {
        try self.withLockedDocument { document, _ in document.data }
    }

    func currentOAuthAccountID() throws -> String? {
        try self.withLockedDocument { document, _ in
            guard let credentialObject = document.credentialObject else { return nil }
            return try PiCodexCredentialCodec.piCredential(from: credentialObject).accountID
        }
    }

    fileprivate func replaceDocument(
        _ object: [String: Any],
        expectedData: Data,
        originalExisted: Bool,
        lock: HandoffDirectoryLock) throws
    {
        try lock.checkOwnership()
        let info = try AppOwnedPathSafety.info(at: self.authURL)
        guard info.exists, !info.isSymbolicLink, info.isRegularFile, info.permissions == 0o600 else {
            throw PiCodexCredentialHandoffError.piAuthUnsafe(self.authURL.path)
        }
        let current = try Data(contentsOf: self.authURL)
        guard current == expectedData else {
            throw PiCodexCredentialHandoffError.concurrentChange(self.authURL.path)
        }
        let data = try self.serializedData(for: object)
        try lock.checkOwnership()
        try SecureAtomicCredentialFile.replace(data: data, at: self.authURL, permissions: 0o600)
        // A heartbeat can notice inode replacement immediately after rename. The mutation is then
        // rolled back (or left journaled for recovery), never silently treated as committed.
        try lock.checkOwnership()
        _ = originalExisted // The file is intentionally retained after a successful handoff.
    }

    fileprivate func serializedData(for object: [String: Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw PiCodexCredentialHandoffError.piAuthMalformed("the replacement is not valid JSON")
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }

    fileprivate func restoreRawDocument(
        data: Data,
        existed: Bool,
        expectedCurrent: Data?,
        lock: HandoffDirectoryLock) throws
    {
        try lock.checkOwnership()
        let info = try AppOwnedPathSafety.info(at: self.authURL)
        let current: Data?
        if info.exists {
            guard !info.isSymbolicLink, info.isRegularFile else {
                throw PiCodexCredentialHandoffError.piAuthUnsafe(self.authURL.path)
            }
            current = try Data(contentsOf: self.authURL)
        } else {
            current = nil
        }
        if let expectedCurrent, current != expectedCurrent {
            throw PiCodexCredentialHandoffError.concurrentChange(self.authURL.path)
        }
        try lock.checkOwnership()
        if existed {
            try SecureAtomicCredentialFile.replace(data: data, at: self.authURL, permissions: 0o600)
        } else if current != nil {
            try SecureAtomicCredentialFile.remove(self.authURL)
        }
        try lock.checkOwnership()
    }

    private func ensureParentDirectory() throws {
        let parent = self.authURL.deletingLastPathComponent()
        do {
            try AppOwnedPathSafety.ensureDirectoryTree(at: parent, permissions: 0o700)
        } catch let error as AppOwnedPathError {
            throw PiCodexCredentialHandoffError.piAuthUnsafe(error.localizedDescription)
        } catch {
            throw PiCodexCredentialHandoffError.piAuthUnsafe(parent.path)
        }
    }

    private func secureAuthFile() throws {
        let info = try AppOwnedPathSafety.info(at: self.authURL)
        guard info.exists, !info.isSymbolicLink, info.isRegularFile else {
            throw PiCodexCredentialHandoffError.piAuthUnsafe(self.authURL.path)
        }
        do {
            try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: self.authURL.path)
        } catch {
            throw PiCodexCredentialHandoffError.piAuthUnsafe(self.authURL.path)
        }
        let secured = try AppOwnedPathSafety.info(at: self.authURL)
        guard secured.permissions == 0o600 else {
            throw PiCodexCredentialHandoffError.piAuthUnsafe(self.authURL.path)
        }
    }
}

private struct PiHandoffJournal: Codable {
    var operation: String
    var phase: String
    // Profile UUIDs identify app-managed homes. They are never compared with ChatGPT account
    // identities; the latter are recorded separately below.
    var targetProfileID: String
    var previousProfileID: String?
    var committedProfileID: String?
    var targetChatGPTAccountID: String
    var previousChatGPTAccountID: String?
    // Hashes bind recovery to the exact credential snapshots written by this transaction.
    var targetCredentialHash: String
    var previousCredentialHash: String?
    var stagingPath: String?
    var oldAuthPath: String?
    var oldAuthBackupPath: String?
    var piBackupPath: String
    var piPreimageHash: String
    var postPiPath: String?
    var postPiHash: String?
    var piExisted: Bool
}

struct PiCodexCredentialHandoff: Sendable {
    let managedHomeStore: ManagedCodexHomeStore
    let piAuthStore: PiAuthStore
    let journalRoot: URL

    init(
        managedHomeStore: ManagedCodexHomeStore = ManagedCodexHomeStore(),
        piAuthStore: PiAuthStore = PiAuthStore(),
        journalRoot: URL = ConfigStore.appDirectoryURL)
    {
        self.managedHomeStore = managedHomeStore
        self.piAuthStore = piAuthStore
        self.journalRoot = journalRoot.standardizedFileURL
    }

    var journalURL: URL {
        self.journalRoot.appendingPathComponent("codex-pi-handoff.json")
    }

    func validateActiveCredential(for profile: CodexManagedAccountProfile) throws {
        guard let accountID = Self.normalizedAccountID(profile.accountID) else {
            throw PiCodexCredentialHandoffError.handoffStateInvalid("the active profile has no ChatGPT account identity")
        }
        try self.piAuthStore.validateActiveCredential(expectedAccountID: accountID)
    }

    func managedProfileActiveInPi(_ profiles: [CodexManagedAccountProfile]) throws -> UUID? {
        guard let accountID = try self.piAuthStore.currentOAuthAccountID() else { return nil }
        return profiles.first(where: { Self.normalizedAccountID($0.accountID) == accountID })?.id
    }

    func recoverIfNeeded(config: AppConfig) throws {
        let journalInfo = try AppOwnedPathSafety.info(at: self.journalURL)
        guard journalInfo.exists else { return }
        guard !journalInfo.isSymbolicLink, journalInfo.isRegularFile, journalInfo.permissions == 0o600 else {
            throw PiCodexCredentialHandoffError.recoveryRequired("the handoff journal is not a protected regular file")
        }
        let data = try Data(contentsOf: self.journalURL)
        let journal: PiHandoffJournal
        do {
            journal = try JSONDecoder().decode(PiHandoffJournal.self, from: data)
        } catch {
            throw PiCodexCredentialHandoffError.recoveryRequired("the handoff journal is unreadable")
        }
        try self.validateJournal(journal)

        let appLock = HandoffDirectoryLock(
            url: self.journalRoot.appendingPathComponent("codex-pi-handoff.lock", isDirectory: true))
        try self.prepareJournalRoot()
        try appLock.acquire()
        defer { appLock.release() }
        try appLock.checkOwnership()

        try self.validateJournalIdentities(journal, config: config)
        let currentMarker = config.codexPiHandoffAccountID?.uuidString.lowercased()
        let committedMarker = journal.committedProfileID?.lowercased()
        let previousMarker = journal.previousProfileID?.lowercased()
        if currentMarker == committedMarker {
            try self.recoverCommitted(journal, appLock: appLock)
        } else if currentMarker == previousMarker {
            try self.recoverRolledBack(journal, appLock: appLock)
        } else {
            throw PiCodexCredentialHandoffError.recoveryRequired(
                "the configuration marker does not match either side of the interrupted transaction")
        }
        try appLock.checkOwnership()
    }

    func activate(
        accountID: UUID,
        config: AppConfig,
        saveConfig: @Sendable @escaping (AppConfig) -> Bool) throws -> PiCodexHandoffResult
    {
        guard let targetProfile = config.codexManagedAccounts.first(where: { $0.id == accountID }) else {
            throw PiCodexCredentialHandoffError.accountNotFound
        }
        if config.codexPiHandoffAccountID == accountID {
            throw PiCodexCredentialHandoffError.accountAlreadyActive
        }
        let existingJournal = try AppOwnedPathSafety.info(at: self.journalURL)
        if existingJournal.exists {
            throw PiCodexCredentialHandoffError.recoveryRequired("an older transaction is still recorded")
        }

        try self.prepareJournalRoot()
        let appLock = HandoffDirectoryLock(
            url: self.journalRoot.appendingPathComponent("codex-pi-handoff.lock", isDirectory: true))
        try appLock.acquire()
        defer { appLock.release() }
        try appLock.checkOwnership()
        let lockedJournal = try AppOwnedPathSafety.info(at: self.journalURL)
        guard !lockedJournal.exists else {
            throw PiCodexCredentialHandoffError.recoveryRequired("another handoff transaction is recorded")
        }

        return try self.piAuthStore.withLockedDocument { document, piLock in
            try self.checkOwnership(appLock: appLock, piLock: piLock)
            let targetHome = try self.managedHomeStore.prepareAccountHome(for: accountID)
            let targetAuth = targetHome.appendingPathComponent("auth.json")
            let targetNative = try self.readNativeCredential(
                accountID: accountID,
                profile: targetProfile,
                authURL: targetAuth)
            let piCredential = try self.readPiCredential(document)
            var next = config
            try self.setProfileAccountID(
                accountID: accountID,
                accountIDValue: targetNative.accountID,
                in: &next)

            let previousID = config.codexPiHandoffAccountID
            var previousCredential: PiCodexOAuthCredential?
            if let previousID {
                guard let previousProfile = config.codexManagedAccounts.first(where: { $0.id == previousID }) else {
                    throw PiCodexCredentialHandoffError.handoffStateInvalid("the active profile is missing")
                }
                guard let previousAccountID = Self.normalizedAccountID(previousProfile.accountID) else {
                    throw PiCodexCredentialHandoffError.handoffStateInvalid("the active profile has no ChatGPT account identity")
                }
                previousCredential = piCredential
                guard let previousCredential else { throw PiCodexCredentialHandoffError.piCredentialMissing }
                guard previousAccountID == previousCredential.accountID else {
                    throw PiCodexCredentialHandoffError.piCredentialIdentityMismatch(
                        expected: previousAccountID,
                        actual: previousCredential.accountID)
                }
                try self.ensureActiveHomeIsEmpty(for: previousID)
                try self.setProfileAccountID(
                    accountID: previousID,
                    accountIDValue: previousCredential.accountID,
                    in: &next)
            } else if let piCredential, piCredential.accountID != targetNative.accountID {
                throw PiCodexCredentialHandoffError.piCredentialIdentityMismatch(
                    expected: targetNative.accountID,
                    actual: piCredential.accountID)
            }

            // When switching away, Pi currently contains the old active account. The target's
            // isolated native credential is the source for the new Pi entry. On first adoption,
            // an existing same-identity Pi entry is already the latest source and is preserved.
            let targetPiObject = previousID == nil
                ? (document.credentialObject ?? targetNative.piObject)
                : targetNative.piObject
            let targetStaging = targetAuth.deletingLastPathComponent().appendingPathComponent(
                ".pi-handoff-auth-\(UUID().uuidString)")
            let oldAuth: URL? = previousID.map { self.managedHomeStore.homeURL(for: $0).appendingPathComponent("auth.json") }
            let piBackup = self.journalRoot.appendingPathComponent(".codex-pi-handoff-\(UUID().uuidString).pi.bak")
            let oldBackup = previousID.map { _ in self.journalRoot.appendingPathComponent(".codex-pi-handoff-\(UUID().uuidString).old.bak") }
            var journal = PiHandoffJournal(
                operation: "activate",
                phase: "prepared",
                targetProfileID: accountID.uuidString,
                previousProfileID: previousID?.uuidString,
                committedProfileID: accountID.uuidString,
                targetChatGPTAccountID: targetNative.accountID,
                previousChatGPTAccountID: previousID == nil ? nil : previousCredential?.accountID,
                targetCredentialHash: Self.sha256(targetNative.data),
                previousCredentialHash: nil,
                stagingPath: targetStaging.path,
                oldAuthPath: oldAuth?.path,
                oldAuthBackupPath: oldBackup?.path,
                piBackupPath: piBackup.path,
                piPreimageHash: Self.sha256(document.data),
                postPiPath: nil,
                postPiHash: nil,
                piExisted: document.existedBeforeLock)

            try self.writeBackup(document.data, to: piBackup)
            try self.writeJournal(journal)
            var targetWasStaged = false
            var oldAuthData: Data?
            var postPiData: Data?
            var piWasUpdated = false
            var configSaved = false
            do {
                try self.moveTargetAuthToStaging(from: targetAuth, to: targetStaging)
                targetWasStaged = true
                journal.phase = "target-staged"
                try self.writeJournal(journal)

                if let previousCredential, let oldAuth, let oldBackup {
                    let oldNative = NativeCodexCredential.fromPi(previousCredential)
                    oldAuthData = oldNative.data
                    journal.previousCredentialHash = Self.sha256(oldNative.data)
                    try self.writeBackup(oldNative.data, to: oldBackup)
                    try self.writeNative(oldNative.data, at: oldAuth, expectedMissing: true)
                    journal.phase = "previous-persisted"
                    try self.writeJournal(journal)
                }

                var updatedObject = document.object
                updatedObject["openai-codex"] = targetPiObject
                let intendedPiData = try self.piAuthStore.serializedData(for: updatedObject)
                let postPiPath = self.journalRoot.appendingPathComponent(".codex-pi-handoff-\(UUID().uuidString).post.bak")
                journal.postPiPath = postPiPath.path
                journal.postPiHash = Self.sha256(intendedPiData)
                try self.writeBackup(intendedPiData, to: postPiPath)
                journal.phase = "pi-prepared"
                try self.writeJournal(journal)
                postPiData = intendedPiData
                piWasUpdated = true
                try self.checkOwnership(appLock: appLock, piLock: piLock)
                try self.piAuthStore.replaceDocument(
                    updatedObject,
                    expectedData: document.data,
                    originalExisted: document.existedBeforeLock,
                    lock: piLock)
                try self.checkOwnership(appLock: appLock, piLock: piLock)
                journal.phase = "pi-updated"
                try self.writeJournal(journal)

                next.codexPiHandoffAccountID = accountID
                next.codexPrimaryAccountID = accountID
                // Ownership must still hold immediately before and after the config commit. If it
                // is lost after the write, leave the journal authoritative for startup recovery.
                try self.checkOwnership(appLock: appLock, piLock: piLock)
                guard saveConfig(next) else { throw PiCodexCredentialHandoffError.configSaveFailed }
                configSaved = true
                try self.checkOwnership(appLock: appLock, piLock: piLock)
                journal.phase = "committed"
                try self.writeJournal(journal)
            } catch let originalError {
                if configSaved {
                    // Once the durable marker is written, do not roll credentials back under a
                    // compromised lock: that could leave the marker and files on opposite sides.
                    // Leave the committed journal for recovery, and surface ownership loss rather
                    // than reporting success.
                    if self.isLockOwnershipLoss(originalError) { throw originalError }
                    return PiCodexHandoffResult(
                        config: next,
                        warning: "The switch completed, but its protected recovery journal could not be finalized: \(originalError.localizedDescription)")
                }
                do {
                    try self.rollbackActivation(
                        document: document,
                        targetAuth: targetAuth,
                        targetStaging: targetStaging,
                        targetWasStaged: targetWasStaged,
                        oldAuth: oldAuth,
                        oldAuthData: oldAuthData,
                        targetCredentialHash: Self.sha256(targetNative.data),
                        postPiData: postPiData,
                        piWasUpdated: piWasUpdated,
                        appLock: appLock,
                        piLock: piLock)
                    try self.validateRollbackBackups(journal)
                    try self.removeJournalArtifacts(journal) {
                        try self.checkOwnership(appLock: appLock, piLock: piLock)
                    }
                } catch let rollbackError {
                    if self.isLockOwnershipLoss(originalError) { throw originalError }
                    throw PiCodexCredentialHandoffError.rollbackFailed(
                        "\(rollbackError.localizedDescription) Original error: \(originalError.localizedDescription)")
                }
                throw originalError
            }

            var warning: String?
            do {
                try appLock.checkOwnership()
                try self.removeStagedTarget(targetStaging, expectedHash: journal.targetCredentialHash)
                try self.removeJournalArtifacts(journal) {
                    try self.checkOwnership(appLock: appLock, piLock: piLock)
                }
            } catch {
                if self.isLockOwnershipLoss(error) { throw error }
                warning = error.localizedDescription
            }
            try appLock.checkOwnership()
            _ = targetWasStaged
            return PiCodexHandoffResult(config: next, warning: warning)
        }
    }

    func deactivate(
        accountID: UUID,
        config: AppConfig,
        saveConfig: @Sendable @escaping (AppConfig) -> Bool) throws -> PiCodexHandoffResult
    {
        guard config.codexPiHandoffAccountID == accountID else {
            throw PiCodexCredentialHandoffError.handoffStateInvalid("this account is not active in Pi")
        }
        guard let profile = config.codexManagedAccounts.first(where: { $0.id == accountID }) else {
            throw PiCodexCredentialHandoffError.accountNotFound
        }
        let existingJournal = try AppOwnedPathSafety.info(at: self.journalURL)
        if existingJournal.exists {
            throw PiCodexCredentialHandoffError.recoveryRequired("an older transaction is still recorded")
        }
        try self.prepareJournalRoot()
        let appLock = HandoffDirectoryLock(
            url: self.journalRoot.appendingPathComponent("codex-pi-handoff.lock", isDirectory: true))
        try appLock.acquire()
        defer { appLock.release() }
        try appLock.checkOwnership()
        let lockedJournal = try AppOwnedPathSafety.info(at: self.journalURL)
        guard !lockedJournal.exists else {
            throw PiCodexCredentialHandoffError.recoveryRequired("another handoff transaction is recorded")
        }

        return try self.piAuthStore.withLockedDocument { document, piLock in
            try self.checkOwnership(appLock: appLock, piLock: piLock)
            guard let piCredential = try self.readPiCredential(document) else {
                throw PiCodexCredentialHandoffError.piCredentialMissing
            }
            if let profileAccountID = Self.normalizedAccountID(profile.accountID), profileAccountID != piCredential.accountID {
                throw PiCodexCredentialHandoffError.piCredentialIdentityMismatch(
                    expected: profileAccountID,
                    actual: piCredential.accountID)
            }
            let home = try self.managedHomeStore.prepareAccountHome(for: accountID)
            let authURL = home.appendingPathComponent("auth.json")
            try self.ensureActiveHomeIsEmpty(for: accountID)
            let native = NativeCodexCredential.fromPi(piCredential)
            let piBackup = self.journalRoot.appendingPathComponent(".codex-pi-handoff-\(UUID().uuidString).pi.bak")
            let oldBackup = self.journalRoot.appendingPathComponent(".codex-pi-handoff-\(UUID().uuidString).old.bak")
            var journal = PiHandoffJournal(
                operation: "deactivate",
                phase: "prepared",
                targetProfileID: accountID.uuidString,
                previousProfileID: accountID.uuidString,
                committedProfileID: nil,
                targetChatGPTAccountID: piCredential.accountID,
                previousChatGPTAccountID: piCredential.accountID,
                targetCredentialHash: Self.sha256(native.data),
                previousCredentialHash: Self.sha256(native.data),
                stagingPath: nil,
                oldAuthPath: authURL.path,
                oldAuthBackupPath: oldBackup.path,
                piBackupPath: piBackup.path,
                piPreimageHash: Self.sha256(document.data),
                postPiPath: nil,
                postPiHash: nil,
                piExisted: document.existedBeforeLock)
            try self.writeBackup(document.data, to: piBackup)
            try self.writeBackup(native.data, to: oldBackup)
            try self.writeJournal(journal)

            var nativeWritten = false
            var postPiData: Data?
            var piWasUpdated = false
            var configSaved = false
            var next = config
            do {
                try self.writeNative(native.data, at: authURL, expectedMissing: true)
                nativeWritten = true
                journal.phase = "native-persisted"
                try self.writeJournal(journal)

                var updatedObject = document.object
                updatedObject.removeValue(forKey: "openai-codex")
                let intendedPiData = try self.piAuthStore.serializedData(for: updatedObject)
                let postPiPath = self.journalRoot.appendingPathComponent(".codex-pi-handoff-\(UUID().uuidString).post.bak")
                journal.postPiPath = postPiPath.path
                journal.postPiHash = Self.sha256(intendedPiData)
                try self.writeBackup(intendedPiData, to: postPiPath)
                journal.phase = "pi-prepared"
                try self.writeJournal(journal)
                postPiData = intendedPiData
                piWasUpdated = true
                try self.checkOwnership(appLock: appLock, piLock: piLock)
                try self.piAuthStore.replaceDocument(
                    updatedObject,
                    expectedData: document.data,
                    originalExisted: document.existedBeforeLock,
                    lock: piLock)
                try self.checkOwnership(appLock: appLock, piLock: piLock)
                journal.phase = "pi-updated"
                try self.writeJournal(journal)

                next.codexPiHandoffAccountID = nil
                try self.setProfileAccountID(
                    accountID: accountID,
                    accountIDValue: piCredential.accountID,
                    in: &next)
                try self.checkOwnership(appLock: appLock, piLock: piLock)
                guard saveConfig(next) else { throw PiCodexCredentialHandoffError.configSaveFailed }
                configSaved = true
                try self.checkOwnership(appLock: appLock, piLock: piLock)
                journal.phase = "committed"
                try self.writeJournal(journal)
            } catch let originalError {
                if configSaved {
                    // The durable marker is authoritative after commit. A compromised lock must
                    // leave the journal for recovery instead of attempting a conflicting rollback.
                    if self.isLockOwnershipLoss(originalError) { throw originalError }
                    return PiCodexHandoffResult(
                        config: next,
                        warning: "The Pi handoff was released, but its protected recovery journal could not be finalized: \(originalError.localizedDescription)")
                }
                do {
                    try self.rollbackDeactivation(
                        document: document,
                        authURL: authURL,
                        native: native,
                        nativeWritten: nativeWritten,
                        postPiData: postPiData,
                        piWasUpdated: piWasUpdated,
                        appLock: appLock,
                        piLock: piLock)
                    try self.validateRollbackBackups(journal)
                    try self.removeJournalArtifacts(journal) {
                        try self.checkOwnership(appLock: appLock, piLock: piLock)
                    }
                } catch let rollbackError {
                    if self.isLockOwnershipLoss(originalError) { throw originalError }
                    throw PiCodexCredentialHandoffError.rollbackFailed(
                        "\(rollbackError.localizedDescription) Original error: \(originalError.localizedDescription)")
                }
                throw originalError
            }

            var warning: String?
            do {
                try appLock.checkOwnership()
                try self.removeJournalArtifacts(journal) {
                    try self.checkOwnership(appLock: appLock, piLock: piLock)
                }
            } catch {
                if self.isLockOwnershipLoss(error) { throw error }
                warning = error.localizedDescription
            }
            try appLock.checkOwnership()
            return PiCodexHandoffResult(config: next, warning: warning)
        }
    }

    private func readPiCredential(_ document: PiAuthDocument) throws -> PiCodexOAuthCredential? {
        guard let object = document.credentialObject else { return nil }
        do {
            return try PiCodexCredentialCodec.piCredential(from: object)
        } catch let error as PiCodexCredentialHandoffError {
            throw error
        } catch {
            throw PiCodexCredentialHandoffError.invalidPiCredential(error.localizedDescription)
        }
    }

    private func readNativeCredential(
        accountID: UUID,
        profile: CodexManagedAccountProfile,
        authURL: URL) throws -> NativeCodexCredential
    {
        let info = try AppOwnedPathSafety.info(at: authURL)
        guard info.exists else {
            throw PiCodexCredentialHandoffError.managedCredentialMissing(authURL.path)
        }
        guard !info.isSymbolicLink, info.isRegularFile else {
            throw PiCodexCredentialHandoffError.invalidManagedCredential("\(authURL.path) is not a regular file")
        }
        try self.managedHomeStore.secureAuthFile(for: accountID, requireExisting: true)
        let data = try Data(contentsOf: authURL)
        return try NativeCodexCredential.from(
            data: data,
            path: authURL.path,
            expectedAccountID: Self.normalizedAccountID(profile.accountID))
    }

    private func ensureActiveHomeIsEmpty(for accountID: UUID) throws {
        let home = try self.managedHomeStore.prepareAccountHome(for: accountID)
        let auth = home.appendingPathComponent("auth.json")
        let info = try AppOwnedPathSafety.info(at: auth)
        guard !info.exists else {
            if info.isSymbolicLink { throw PiCodexCredentialHandoffError.piAuthUnsafe(auth.path) }
            throw PiCodexCredentialHandoffError.handoffStateInvalid(
                "the account's managed home still contains auth.json; refusing to keep two live credential copies")
        }
    }

    private func moveTargetAuthToStaging(from auth: URL, to staging: URL) throws {
        let info = try AppOwnedPathSafety.info(at: auth)
        guard info.exists, !info.isSymbolicLink, info.isRegularFile else {
            throw PiCodexCredentialHandoffError.managedCredentialMissing(auth.path)
        }
        let stagingInfo = try AppOwnedPathSafety.info(at: staging)
        guard !stagingInfo.exists else { throw PiCodexCredentialHandoffError.concurrentChange(staging.path) }
        try SecureAtomicCredentialFile.move(from: auth, to: staging)
        let moved = try AppOwnedPathSafety.info(at: staging)
        guard moved.exists, !moved.isSymbolicLink, moved.isRegularFile, moved.permissions == 0o600 else {
            throw PiCodexCredentialHandoffError.piAuthUnsafe(staging.path)
        }
    }

    private func removeStagedTarget(_ staging: URL, expectedHash: String? = nil) throws {
        let info = try AppOwnedPathSafety.info(at: staging)
        if info.exists {
            guard !info.isSymbolicLink, info.isRegularFile else {
                throw PiCodexCredentialHandoffError.cleanupFailed(staging.path)
            }
            if let expectedHash {
                let data = try Data(contentsOf: staging)
                guard Self.sha256(data) == expectedHash else {
                    throw PiCodexCredentialHandoffError.concurrentChange(staging.path)
                }
            }
            try SecureAtomicCredentialFile.remove(staging)
        }
    }

    private func writeNative(_ data: Data, at auth: URL, expectedMissing: Bool) throws {
        let info = try AppOwnedPathSafety.info(at: auth)
        if expectedMissing, info.exists {
            throw PiCodexCredentialHandoffError.concurrentChange(auth.path)
        }
        try SecureAtomicCredentialFile.replace(data: data, at: auth, permissions: 0o600)
    }

    private func removeGeneratedNative(_ data: Data, at auth: URL) throws {
        let info = try AppOwnedPathSafety.info(at: auth)
        guard info.exists else { return }
        guard !info.isSymbolicLink, info.isRegularFile else {
            throw PiCodexCredentialHandoffError.piAuthUnsafe(auth.path)
        }
        guard try Data(contentsOf: auth) == data else {
            throw PiCodexCredentialHandoffError.concurrentChange(auth.path)
        }
        try SecureAtomicCredentialFile.remove(auth)
    }

    private func restoreStagedTarget(_ staging: URL, to auth: URL, expectedHash: String? = nil) throws {
        let stagingInfo = try AppOwnedPathSafety.info(at: staging)
        guard stagingInfo.exists else {
            throw PiCodexCredentialHandoffError.recoveryRequired("the staged target credential is missing")
        }
        guard !stagingInfo.isSymbolicLink, stagingInfo.isRegularFile else {
            throw PiCodexCredentialHandoffError.piAuthUnsafe(staging.path)
        }
        if let expectedHash {
            let data = try Data(contentsOf: staging)
            guard Self.sha256(data) == expectedHash else {
                throw PiCodexCredentialHandoffError.recoveryRequired("the staged target credential is corrupt")
            }
        }
        let authInfo = try AppOwnedPathSafety.info(at: auth)
        guard !authInfo.exists else { throw PiCodexCredentialHandoffError.concurrentChange(auth.path) }
        try SecureAtomicCredentialFile.move(from: staging, to: auth)
    }

    private func restorePiDocument(
        document: PiAuthDocument,
        postPiData: Data?,
        lock: HandoffDirectoryLock) throws
    {
        try lock.checkOwnership()
        let info = try AppOwnedPathSafety.info(at: self.piAuthStore.authURL)
        guard info.exists, !info.isSymbolicLink, info.isRegularFile else {
            throw PiCodexCredentialHandoffError.concurrentChange(self.piAuthStore.authURL.path)
        }
        let current = try Data(contentsOf: self.piAuthStore.authURL)
        if current == document.data {
            if !document.existedBeforeLock {
                try self.piAuthStore.restoreRawDocument(
                    data: document.data,
                    existed: false,
                    expectedCurrent: document.data,
                    lock: lock)
            }
            return
        }
        guard let postPiData, current == postPiData else {
            throw PiCodexCredentialHandoffError.concurrentChange(self.piAuthStore.authURL.path)
        }
        try self.piAuthStore.restoreRawDocument(
            data: document.data,
            existed: document.existedBeforeLock,
            expectedCurrent: postPiData,
            lock: lock)
    }

    private func rollbackActivation(
        document: PiAuthDocument,
        targetAuth: URL,
        targetStaging: URL,
        targetWasStaged: Bool,
        oldAuth: URL?,
        oldAuthData: Data?,
        targetCredentialHash: String,
        postPiData: Data?,
        piWasUpdated: Bool,
        appLock: HandoffDirectoryLock,
        piLock: HandoffDirectoryLock) throws
    {
        var failures: [String] = []
        if piWasUpdated {
            do {
                try self.checkOwnership(appLock: appLock, piLock: piLock)
                try self.restorePiDocument(document: document, postPiData: postPiData, lock: piLock)
                try self.checkOwnership(appLock: appLock, piLock: piLock)
            } catch { failures.append("Pi auth restore: \(error.localizedDescription)") }
        }
        if let oldAuth, let oldAuthData {
            do {
                try appLock.checkOwnership()
                try self.removeGeneratedNative(oldAuthData, at: oldAuth)
                try appLock.checkOwnership()
            }
            catch { failures.append("previous managed home restore: \(error.localizedDescription)") }
        }
        var stagingExists = false
        do {
            try appLock.checkOwnership()
            stagingExists = try AppOwnedPathSafety.info(at: targetStaging).exists
        } catch {
            failures.append("target managed home inspection: \(error.localizedDescription)")
        }
        if targetWasStaged || stagingExists {
            do {
                try appLock.checkOwnership()
                try self.restoreStagedTarget(
                    targetStaging,
                    to: targetAuth,
                    expectedHash: targetCredentialHash)
                try appLock.checkOwnership()
            }
            catch { failures.append("target managed home restore: \(error.localizedDescription)") }
        }
        if !failures.isEmpty { throw PiCodexCredentialHandoffError.rollbackFailed(failures.joined(separator: " ")) }
    }

    private func rollbackDeactivation(
        document: PiAuthDocument,
        authURL: URL,
        native: NativeCodexCredential,
        nativeWritten: Bool,
        postPiData: Data?,
        piWasUpdated: Bool,
        appLock: HandoffDirectoryLock,
        piLock: HandoffDirectoryLock) throws
    {
        var failures: [String] = []
        if piWasUpdated {
            do {
                try self.checkOwnership(appLock: appLock, piLock: piLock)
                try self.restorePiDocument(document: document, postPiData: postPiData, lock: piLock)
                try self.checkOwnership(appLock: appLock, piLock: piLock)
            } catch { failures.append("Pi auth restore: \(error.localizedDescription)") }
        }
        var nativeExists = false
        do {
            try appLock.checkOwnership()
            nativeExists = try AppOwnedPathSafety.info(at: authURL).exists
        } catch {
            failures.append("managed home inspection: \(error.localizedDescription)")
        }
        if nativeWritten || nativeExists {
            do {
                try appLock.checkOwnership()
                try self.removeGeneratedNative(native.data, at: authURL)
                try appLock.checkOwnership()
            }
            catch { failures.append("managed home restore: \(error.localizedDescription)") }
        }
        if !failures.isEmpty { throw PiCodexCredentialHandoffError.rollbackFailed(failures.joined(separator: " ")) }
    }

    private func setProfileAccountID(
        accountID: UUID,
        accountIDValue: String,
        in config: inout AppConfig) throws
    {
        guard let index = config.codexManagedAccounts.firstIndex(where: { $0.id == accountID }) else {
            throw PiCodexCredentialHandoffError.accountNotFound
        }
        if let current = Self.normalizedAccountID(config.codexManagedAccounts[index].accountID), current != accountIDValue {
            throw PiCodexCredentialHandoffError.managedCredentialIdentityMismatch(
                expected: current,
                actual: accountIDValue)
        }
        config.codexManagedAccounts[index].accountID = accountIDValue
    }

    private func prepareJournalRoot() throws {
        do {
            try AppOwnedPathSafety.ensureDirectoryTree(at: self.journalRoot, permissions: 0o700)
        } catch {
            throw PiCodexCredentialHandoffError.filesystem("could not secure the handoff journal directory")
        }
    }

    private func writeBackup(_ data: Data, to url: URL) throws {
        try SecureAtomicCredentialFile.replace(data: data, at: url, permissions: 0o600)
    }

    private func writeJournal(_ journal: PiHandoffJournal) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try self.writeBackup(encoder.encode(journal), to: self.journalURL)
        } catch {
            throw PiCodexCredentialHandoffError.filesystem("could not write the protected handoff journal")
        }
    }

    private func removeJournalArtifacts(
        _ journal: PiHandoffJournal,
        ownershipCheck: (() throws -> Void)? = nil) throws
    {
        // Once the caller has proved the committed or rolled-back invariant, the journal is no
        // longer needed as authority. Remove it first. If a nonessential backup then cannot be
        // deleted, an orphaned protected artifact is safer than a journal that points at a backup
        // which was already deleted and can no longer support recovery.
        try ownershipCheck?()
        do { try SecureAtomicCredentialFile.remove(self.journalURL) }
        catch { throw PiCodexCredentialHandoffError.cleanupFailed(self.journalURL.path) }

        var failures: [String] = []
        for path in [journal.piBackupPath, journal.postPiPath, journal.oldAuthBackupPath].compactMap({ $0 }) {
            do { try SecureAtomicCredentialFile.remove(URL(fileURLWithPath: path)) }
            catch { failures.append(path) }
        }
        if !failures.isEmpty {
            throw PiCodexCredentialHandoffError.cleanupFailed(
                "protected handoff backups could not be removed: \(failures.joined(separator: ", "))")
        }
        try ownershipCheck?()
    }

    private func validateJournal(_ journal: PiHandoffJournal) throws {
        let phases = ["prepared", "target-staged", "previous-persisted", "native-persisted", "pi-prepared", "pi-updated", "committed"]
        guard ["activate", "deactivate"].contains(journal.operation),
              phases.contains(journal.phase),
              (journal.operation == "activate"
                ? ["prepared", "target-staged", "previous-persisted", "pi-prepared", "pi-updated", "committed"].contains(journal.phase)
                : ["prepared", "native-persisted", "pi-prepared", "pi-updated", "committed"].contains(journal.phase)),
              let targetID = UUID(uuidString: journal.targetProfileID),
              self.isNonEmpty(journal.targetChatGPTAccountID),
              self.isHash(journal.targetCredentialHash),
              self.isHash(journal.piPreimageHash),
              self.isUnderAppDirectory(journal.piBackupPath)
        else { throw PiCodexCredentialHandoffError.recoveryRequired("the journal contains unsafe transaction metadata") }
        do {
            try self.managedHomeStore.validateManagedHome(self.managedHomeStore.homeURL(for: targetID))
        } catch {
            throw PiCodexCredentialHandoffError.recoveryRequired("the target managed home is unsafe")
        }
        if let committed = journal.committedProfileID {
            guard UUID(uuidString: committed) != nil,
                  committed.caseInsensitiveCompare(journal.targetProfileID) == .orderedSame
            else { throw PiCodexCredentialHandoffError.recoveryRequired("the journal contains an invalid committed profile") }
        } else if journal.operation == "activate" {
            throw PiCodexCredentialHandoffError.recoveryRequired("the activation journal has no committed profile")
        }
        if let previous = journal.previousProfileID {
            guard let previousID = UUID(uuidString: previous) else {
                throw PiCodexCredentialHandoffError.recoveryRequired("the journal contains an invalid previous profile")
            }
            guard self.isNonEmpty(journal.previousChatGPTAccountID ?? "") else {
                throw PiCodexCredentialHandoffError.recoveryRequired("the journal is missing the previous ChatGPT account identity")
            }
            do {
                try self.managedHomeStore.validateManagedHome(self.managedHomeStore.homeURL(for: previousID))
            } catch {
                throw PiCodexCredentialHandoffError.recoveryRequired("the previous managed home is unsafe")
            }
            let expectedOldAuth = self.managedHomeStore.homeURL(for: previousID)
                .appendingPathComponent("auth.json").standardizedFileURL.path
            guard let oldAuthPath = journal.oldAuthPath,
                  URL(fileURLWithPath: oldAuthPath).standardizedFileURL.path == expectedOldAuth,
                  self.isUnderManagedRoot(oldAuthPath),
                  journal.oldAuthBackupPath.map(self.isUnderAppDirectory) ?? false
            else {
                throw PiCodexCredentialHandoffError.recoveryRequired("the journal contains an unexpected previous managed-home path")
            }
        } else {
            guard journal.previousChatGPTAccountID == nil,
                  journal.oldAuthPath == nil,
                  journal.oldAuthBackupPath == nil
            else { throw PiCodexCredentialHandoffError.recoveryRequired("the journal contains an unexpected previous credential") }
        }
        for path in [journal.postPiPath].compactMap({ $0 }) {
            guard self.isUnderAppDirectory(path) else {
                throw PiCodexCredentialHandoffError.recoveryRequired("the journal contains a path outside the app directory")
            }
        }
        if journal.operation == "activate" {
            guard let stagingPath = journal.stagingPath,
                  self.isUnderManagedHome(stagingPath, accountID: targetID),
                  URL(fileURLWithPath: stagingPath).deletingLastPathComponent().standardizedFileURL.path == self.managedHomeStore.homeURL(for: targetID).standardizedFileURL.path,
                  URL(fileURLWithPath: stagingPath).lastPathComponent.hasPrefix(".pi-handoff-auth-")
            else {
                throw PiCodexCredentialHandoffError.recoveryRequired("the journal contains an unsafe managed-home staging path")
            }
        } else {
            guard journal.stagingPath == nil,
                  journal.previousProfileID?.caseInsensitiveCompare(journal.targetProfileID) == .orderedSame
            else { throw PiCodexCredentialHandoffError.recoveryRequired("the deactivation journal contains invalid profile metadata") }
        }
        if journal.postPiPath != nil {
            guard let hash = journal.postPiHash, self.isHash(hash) else {
                throw PiCodexCredentialHandoffError.recoveryRequired("the journal is missing the post-Pi snapshot hash")
            }
        }
        if journal.phase == "pi-prepared" || journal.phase == "pi-updated" || journal.phase == "committed" {
            guard journal.postPiPath != nil else {
                throw PiCodexCredentialHandoffError.recoveryRequired("the journal has no post-Pi snapshot")
            }
        }
        if journal.operation == "activate", journal.previousProfileID != nil,
           ["previous-persisted", "pi-prepared", "pi-updated", "committed"].contains(journal.phase)
        {
            guard let hash = journal.previousCredentialHash, self.isHash(hash) else {
                throw PiCodexCredentialHandoffError.recoveryRequired("the journal is missing the previous credential snapshot hash")
            }
        }
        if journal.operation == "deactivate" {
            guard let hash = journal.previousCredentialHash, self.isHash(hash),
                  journal.targetChatGPTAccountID == journal.previousChatGPTAccountID
            else { throw PiCodexCredentialHandoffError.recoveryRequired("the deactivation journal has invalid credential metadata") }
        }
    }

    private func validateJournalIdentities(_ journal: PiHandoffJournal, config: AppConfig) throws {
        guard let targetID = UUID(uuidString: journal.targetProfileID),
              let targetProfile = config.codexManagedAccounts.first(where: { $0.id == targetID })
        else { throw PiCodexCredentialHandoffError.recoveryRequired("the journal target profile no longer exists") }
        if let accountID = Self.normalizedAccountID(targetProfile.accountID), accountID != journal.targetChatGPTAccountID {
            throw PiCodexCredentialHandoffError.recoveryRequired("the target profile identity does not match the journal")
        }
        if let previousText = journal.previousProfileID {
            guard let previousID = UUID(uuidString: previousText),
                  let previousProfile = config.codexManagedAccounts.first(where: { $0.id == previousID })
            else { throw PiCodexCredentialHandoffError.recoveryRequired("the journal previous profile no longer exists") }
            if let accountID = Self.normalizedAccountID(previousProfile.accountID),
               accountID != journal.previousChatGPTAccountID
            {
                throw PiCodexCredentialHandoffError.recoveryRequired("the previous profile identity does not match the journal")
            }
        }
    }

    private func isUnderAppDirectory(_ path: String) -> Bool {
        let root = self.journalRoot.standardizedFileURL.path
        let prefix = root.hasSuffix("/") ? root : root + "/"
        let candidate = URL(fileURLWithPath: path).standardizedFileURL.path
        return candidate.hasPrefix(prefix) && candidate != self.journalURL.path
    }

    private func isUnderManagedRoot(_ path: String) -> Bool {
        let root = self.managedHomeStore.root.standardizedFileURL.path
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return URL(fileURLWithPath: path).standardizedFileURL.path.hasPrefix(prefix)
    }

    private func isUnderManagedHome(_ path: String, accountID: UUID) -> Bool {
        let home = self.managedHomeStore.homeURL(for: accountID).standardizedFileURL.path
        let prefix = home.hasSuffix("/") ? home : home + "/"
        return URL(fileURLWithPath: path).standardizedFileURL.path.hasPrefix(prefix)
    }

    private func readProtectedBackup(at url: URL, expectedHash: String) throws -> Data {
        let info = try AppOwnedPathSafety.info(at: url)
        guard info.exists, !info.isSymbolicLink, info.isRegularFile, info.permissions == 0o600 else {
            throw PiCodexCredentialHandoffError.recoveryRequired("a protected transaction backup is unsafe or missing")
        }
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch { throw PiCodexCredentialHandoffError.recoveryRequired("a protected transaction backup could not be read") }
        guard Self.sha256(data) == expectedHash else {
            throw PiCodexCredentialHandoffError.recoveryRequired("a protected transaction backup is corrupt")
        }
        return data
    }

    private func validateRollbackBackups(_ journal: PiHandoffJournal) throws {
        _ = try self.readProtectedBackup(
            at: URL(fileURLWithPath: journal.piBackupPath),
            expectedHash: journal.piPreimageHash)
        if let postPath = journal.postPiPath, let postHash = journal.postPiHash {
            _ = try self.readProtectedBackup(at: URL(fileURLWithPath: postPath), expectedHash: postHash)
        }
        let previousWasPersisted = ["previous-persisted", "pi-prepared", "pi-updated", "committed"].contains(journal.phase)
        if journal.operation == "deactivate" {
            guard let oldBackupPath = journal.oldAuthBackupPath,
                  let oldHash = journal.previousCredentialHash
            else { throw PiCodexCredentialHandoffError.recoveryRequired("the rollback credential backup is missing") }
            _ = try self.readProtectedBackup(at: URL(fileURLWithPath: oldBackupPath), expectedHash: oldHash)
        } else if journal.previousProfileID != nil,
                  let oldBackupPath = journal.oldAuthBackupPath
        {
            let oldBackupInfo = try AppOwnedPathSafety.info(at: URL(fileURLWithPath: oldBackupPath))
            if previousWasPersisted || oldBackupInfo.exists {
                guard let oldHash = journal.previousCredentialHash else {
                    throw PiCodexCredentialHandoffError.recoveryRequired("the rollback credential backup is missing")
                }
                _ = try self.readProtectedBackup(at: URL(fileURLWithPath: oldBackupPath), expectedHash: oldHash)
            }
        }
    }

    private func recoverCommitted(_ journal: PiHandoffJournal, appLock: HandoffDirectoryLock) throws {
        guard let postPath = journal.postPiPath, let postHash = journal.postPiHash else {
            throw PiCodexCredentialHandoffError.recoveryRequired("the committed transaction has no post-Pi snapshot")
        }
        let postData = try self.readProtectedBackup(at: URL(fileURLWithPath: postPath), expectedHash: postHash)
        try self.piAuthStore.withLockedDocument { document, piLock in
            try self.checkOwnership(appLock: appLock, piLock: piLock)
            // Exact bytes, not merely account identity, prove that Pi was not logged in again
            // between the commit and recovery. This is especially important for deactivation.
            guard document.data == postData else {
                throw PiCodexCredentialHandoffError.recoveryRequired("Pi auth changed after the handoff commit")
            }
            let targetID = try self.profileID(journal.targetProfileID)
            if journal.operation == "activate" {
                guard let credentialObject = document.credentialObject else {
                    throw PiCodexCredentialHandoffError.recoveryRequired("the committed Pi credential is missing")
                }
                let credential = try PiCodexCredentialCodec.piCredential(from: credentialObject)
                guard credential.accountID == journal.targetChatGPTAccountID else {
                    throw PiCodexCredentialHandoffError.recoveryRequired("the committed Pi credential has the wrong ChatGPT identity")
                }
                try self.ensureActiveHomeIsEmpty(for: targetID)
                if let stagingPath = journal.stagingPath {
                    try appLock.checkOwnership()
                    try self.removeStagedTarget(
                        URL(fileURLWithPath: stagingPath),
                        expectedHash: journal.targetCredentialHash)
                    try appLock.checkOwnership()
                }
            } else {
                guard document.credentialObject == nil else {
                    throw PiCodexCredentialHandoffError.recoveryRequired("Pi auth contains a credential after deactivation")
                }
                guard let oldAuthPath = journal.oldAuthPath else {
                    throw PiCodexCredentialHandoffError.recoveryRequired("the deactivation journal has no managed credential path")
                }
                let info = try AppOwnedPathSafety.info(at: URL(fileURLWithPath: oldAuthPath))
                guard info.exists, !info.isSymbolicLink, info.isRegularFile, info.permissions == 0o600,
                      Self.sha256(try Data(contentsOf: URL(fileURLWithPath: oldAuthPath))) == journal.targetCredentialHash
                else { throw PiCodexCredentialHandoffError.recoveryRequired("the released managed credential is missing or changed") }
            }
            // Keep both locks until the invariant and journal cleanup are complete. Otherwise a
            // cooperative Pi login or another handoff could race in after verification.
            try self.removeJournalArtifacts(journal) {
                try self.checkOwnership(appLock: appLock, piLock: piLock)
            }
        }
    }

    private func recoverRolledBack(_ journal: PiHandoffJournal, appLock: HandoffDirectoryLock) throws {
        let backup = try self.readProtectedBackup(
            at: URL(fileURLWithPath: journal.piBackupPath),
            expectedHash: journal.piPreimageHash)
        let postData: Data?
        if let postPath = journal.postPiPath, let postHash = journal.postPiHash {
            postData = try self.readProtectedBackup(at: URL(fileURLWithPath: postPath), expectedHash: postHash)
        } else {
            postData = nil
        }
        let targetID = try self.profileID(journal.targetProfileID)

        // Hold Pi's lock across the native-home checks and journal removal. A fresh Pi login is
        // not allowed to race in after the pre-image was proven and before recovery is finalized.
        try self.piAuthStore.withLockedDocument { document, piLock in
            try self.checkOwnership(appLock: appLock, piLock: piLock)
            if document.data == backup {
                if !journal.piExisted {
                    try self.piAuthStore.restoreRawDocument(
                        data: backup,
                        existed: false,
                        expectedCurrent: backup,
                        lock: piLock)
                }
            } else {
                guard let postData, document.data == postData else {
                    throw PiCodexCredentialHandoffError.recoveryRequired("Pi auth changed outside the recorded transaction")
                }
                try self.piAuthStore.restoreRawDocument(
                    data: backup,
                    existed: journal.piExisted,
                    expectedCurrent: postData,
                    lock: piLock)
            }
            try appLock.checkOwnership()

            if journal.operation == "activate" {
                let targetAuth = self.managedHomeStore.homeURL(for: targetID).appendingPathComponent("auth.json")
                guard let stagingPath = journal.stagingPath else {
                    throw PiCodexCredentialHandoffError.recoveryRequired("the activation journal has no staging path")
                }
                let staging = URL(fileURLWithPath: stagingPath)
                let stagingInfo = try AppOwnedPathSafety.info(at: staging)
                let targetInfo = try AppOwnedPathSafety.info(at: targetAuth)
                // The phase record can lag a completed filesystem rename by one journal write.
                // Presence of the staged file is therefore authoritative for this invariant.
                let targetWasStaged = stagingInfo.exists || ["target-staged", "previous-persisted", "pi-prepared", "pi-updated"].contains(journal.phase)
                if targetWasStaged {
                    if stagingInfo.exists {
                        try appLock.checkOwnership()
                        let stagedData = try Data(contentsOf: staging)
                        guard stagingInfo.permissions == 0o600,
                              Self.sha256(stagedData) == journal.targetCredentialHash else {
                            throw PiCodexCredentialHandoffError.recoveryRequired("the staged target credential is corrupt")
                        }
                        guard !targetInfo.exists else {
                            throw PiCodexCredentialHandoffError.recoveryRequired("both staged and live target credentials exist")
                        }
                        try SecureAtomicCredentialFile.move(from: staging, to: targetAuth)
                        try appLock.checkOwnership()
                    } else {
                        guard targetInfo.exists, !targetInfo.isSymbolicLink, targetInfo.isRegularFile,
                              targetInfo.permissions == 0o600,
                              Self.sha256(try Data(contentsOf: targetAuth)) == journal.targetCredentialHash
                        else { throw PiCodexCredentialHandoffError.recoveryRequired("the target credential was not restored") }
                    }
                } else {
                    guard !stagingInfo.exists, targetInfo.exists, !targetInfo.isSymbolicLink, targetInfo.isRegularFile,
                          targetInfo.permissions == 0o600,
                          Self.sha256(try Data(contentsOf: targetAuth)) == journal.targetCredentialHash
                    else { throw PiCodexCredentialHandoffError.recoveryRequired("the target credential changed before staging") }
                }

                if let previousText = journal.previousProfileID {
                    let previousID = try self.profileID(previousText)
                    let oldAuth = self.managedHomeStore.homeURL(for: previousID).appendingPathComponent("auth.json")
                    let oldInfo = try AppOwnedPathSafety.info(at: oldAuth)
                    let oldBackupInfo = try AppOwnedPathSafety.info(at: URL(fileURLWithPath: journal.oldAuthBackupPath ?? ""))
                    // A native write can complete before the phase record is durable. Treat either
                    // the file or its backup as evidence that the previous-persisted step ran.
                    let previousPhase = oldInfo.exists || oldBackupInfo.exists || ["previous-persisted", "pi-prepared", "pi-updated"].contains(journal.phase)
                    if previousPhase {
                        guard let oldBackupPath = journal.oldAuthBackupPath,
                              let oldHash = journal.previousCredentialHash else {
                            throw PiCodexCredentialHandoffError.recoveryRequired("the previous credential backup is missing from the journal")
                        }
                        let oldData = try self.readProtectedBackup(at: URL(fileURLWithPath: oldBackupPath), expectedHash: oldHash)
                        try appLock.checkOwnership()
                        try self.removeGeneratedNative(oldData, at: oldAuth)
                        try appLock.checkOwnership()
                    } else {
                        let info = try AppOwnedPathSafety.info(at: oldAuth)
                        guard !info.exists else {
                            throw PiCodexCredentialHandoffError.recoveryRequired("the previous managed home changed before persistence")
                        }
                    }
                }
            } else {
                guard let oldAuthPath = journal.oldAuthPath,
                      let oldBackupPath = journal.oldAuthBackupPath,
                      let oldHash = journal.previousCredentialHash else {
                    throw PiCodexCredentialHandoffError.recoveryRequired("the deactivation credential backup is missing from the journal")
                }
                let oldAuth = URL(fileURLWithPath: oldAuthPath)
                let oldData = try self.readProtectedBackup(at: URL(fileURLWithPath: oldBackupPath), expectedHash: oldHash)
                let info = try AppOwnedPathSafety.info(at: oldAuth)
                // As with activation, the native file can exist even when native-persisted was
                // not written to the journal yet.
                let nativePhase = info.exists || ["native-persisted", "pi-prepared", "pi-updated"].contains(journal.phase)
                if nativePhase {
                    try appLock.checkOwnership()
                    try self.removeGeneratedNative(oldData, at: oldAuth)
                    try appLock.checkOwnership()
                } else {
                    guard !info.exists else {
                        throw PiCodexCredentialHandoffError.recoveryRequired("the managed home changed before persistence")
                    }
                }
            }
            try self.removeJournalArtifacts(journal) {
                try self.checkOwnership(appLock: appLock, piLock: piLock)
            }
        }
    }

    private func checkOwnership(
        appLock: HandoffDirectoryLock,
        piLock: HandoffDirectoryLock) throws
    {
        // Lock acquisition order is journal/app -> Pi -> ConfigStore. This helper only checks
        // already-held locks; it never acquires another lock and therefore cannot introduce an
        // inverse-order deadlock.
        try appLock.checkOwnership()
        try piLock.checkOwnership()
    }

    private func isLockOwnershipLoss(_ error: Error) -> Bool {
        guard let handoffError = error as? PiCodexCredentialHandoffError else { return false }
        if case .lockOwnershipLost = handoffError { return true }
        return false
    }

    private func profileID(_ text: String) throws -> UUID {
        guard let id = UUID(uuidString: text) else {
            throw PiCodexCredentialHandoffError.recoveryRequired("the journal contains an invalid profile UUID")
        }
        return id
    }

    private func isNonEmpty(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func isHash(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func normalizedAccountID(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}

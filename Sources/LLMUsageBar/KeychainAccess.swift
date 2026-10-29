import Foundation
import Security

/// LAContext.interactionNotAllowed does not suppress legacy login-Keychain ACL dialogs.
/// This legacy switch is process-wide, so every app-owned Keychain read must use this
/// gate, including interactive reads, and must finish synchronously inside the lock.
enum KeychainAccess {
    private static let lock = NSLock()

    static func withInteraction<T>(allowed: Bool, _ operation: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        var previous = DarwinBoolean(false)
        guard SecKeychainGetUserInteractionAllowed(&previous) == errSecSuccess else {
            throw ClaudeBackendError.keychainUnavailable
        }
        guard SecKeychainSetUserInteractionAllowed(allowed) == errSecSuccess else {
            throw ClaudeBackendError.keychainUnavailable
        }
        defer { SecKeychainSetUserInteractionAllowed(previous.boolValue) }
        return try operation()
    }
}

import CryptoKit
import Darwin
import Foundation
import LocalAuthentication
import Security

/// Intentionally contains no provider text, paths, tokens, or CLI output.
enum ClaudeBackendError: Error, LocalizedError, Equatable, Sendable {
    case credentialsMissing, credentialsInvalid, credentialsExpired, scopeMissing, unsafeCredentialFile
    case keychainUnavailable, credentialStoresConflict, identityMissing, identityMismatch, credentialChanged
    case unauthorized, forbidden, rateLimited, backoff, network, invalidResponse, quotaMissing
    case cliMissing, cliLaunchFailed, cliFailed, loginTimedOut

    var errorDescription: String? {
        switch self {
        case .credentialsMissing: return "No Claude Code login found. Sign in with Claude Code for this profile."
        case .credentialsInvalid: return "Claude Code credentials are invalid. Sign in again with Claude Code."
        case .credentialsExpired: return "Open this profile in Claude Code to refresh its login, or sign in again. LLM Usage never refreshes Claude tokens."
        case .scopeMissing: return "Claude Code login lacks user:profile permission. Sign in again with Claude Code."
        case .unsafeCredentialFile: return "Claude Code credential file is unsafe or too large. Use a regular credential file and sign in again."
        case .keychainUnavailable: return "Claude Code Keychain credentials are unavailable. Choose Refresh / allow Keychain access, or unlock your Keychain."
        case .credentialStoresConflict: return "This profile has different Keychain and credential-file logins. Resolve the conflicting Claude Code logins before tracking."
        case .identityMissing: return "Claude could not verify both account and organization identity."
        case .identityMismatch: return "This directory now belongs to another Claude account. Remove this profile and add it again."
        case .credentialChanged: return "Claude Code login changed during refresh. Try refreshing again."
        case .unauthorized: return "Claude login is no longer authorized. Sign in again with Claude Code."
        case .forbidden: return "Claude quota access is not permitted. Sign in again with Claude Code."
        case .rateLimited: return "Claude is rate limiting quota checks. Please wait before refreshing."
        case .backoff: return "Claude quota checks are temporarily paused. Please try again later."
        case .network: return "Could not connect to Claude quota service."
        case .invalidResponse: return "Claude returned an invalid quota response."
        case .quotaMissing: return "Claude did not return quota limits for this account."
        case .cliMissing: return "Claude Code CLI was not found. Install it or set LLM_BAR_CLAUDE_PATH."
        case .cliLaunchFailed: return "Could not start Claude Code sign-in."
        case .cliFailed: return "Claude Code sign-in did not complete successfully. Try signing in again."
        case .loginTimedOut: return "Claude Code sign-in timed out. Try signing in again."
        }
    }
}

struct ClaudeCredential: Sendable {
    let accessToken: String
    let expiresAt: Date
    let scopes: [String]?
    let subscriptionType: String?
    let rateLimitTier: String?

    static func parse(_ data: Data, now: Date = Date()) throws -> Self {
        guard data.count <= ClaudeCredentials.maximumFileSize,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String,
              !token.isEmpty, token.utf8.count <= 64 * 1024,
              !token.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }),
              let milliseconds = ClaudeJSON.number(oauth["expiresAt"]), milliseconds > 0
        else { throw ClaudeBackendError.credentialsInvalid }
        let expiresAt = Date(timeIntervalSince1970: milliseconds / 1000)
        guard expiresAt > now else { throw ClaudeBackendError.credentialsExpired }
        var scopes: [String]?
        if let supplied = oauth["scopes"] {
            guard let strings = supplied as? [String] else { throw ClaudeBackendError.credentialsInvalid }
            guard strings.contains("user:profile") else { throw ClaudeBackendError.scopeMissing }
            scopes = strings
        }
        return Self(accessToken: token, expiresAt: expiresAt, scopes: scopes,
                    subscriptionType: oauth["subscriptionType"] as? String,
                    rateLimitTier: oauth["rateLimitTier"] as? String)
    }
}

// JSONSerialization bridges booleans and numbers through NSNumber. Never accept bools as amounts.
enum ClaudeJSON {
    static func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
        let number = value.doubleValue
        return number.isFinite ? number : nil
    }
}

enum ClaudeCredentials {
    static let maximumFileSize = 1_048_576
    typealias Reader = @Sendable (ClaudeAccountProfile, Bool) throws -> ClaudeCredential
    typealias KeychainReader = @Sendable (String, Bool) throws -> Data?

    static func serviceName(for profile: ClaudeAccountProfile) -> String {
        guard profile.configDirectory != nil else { return "Claude Code-credentials" }
        let path = profile.directoryURL.path.precomposedStringWithCanonicalMapping
        let digest = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
        return "Claude Code-credentials-" + digest.prefix(8)
    }

    static func fingerprint(_ credential: ClaudeCredential, profile: ClaudeAccountProfile) -> String {
        let tokenDigest = SHA256.hash(data: Data(credential.accessToken.utf8)).map { String(format: "%02x", $0) }.joined()
        return SHA256.hash(data: Data((serviceName(for: profile) + "\0" + tokenDigest).utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    static func read(profile: ClaudeAccountProfile, allowKeychainPrompt: Bool = false) throws -> ClaudeCredential {
        try read(profile: profile, allowKeychainPrompt: allowKeychainPrompt, keychain: readKeychain)
    }

    static func read(profile: ClaudeAccountProfile, allowKeychainPrompt: Bool,
                     keychain: KeychainReader) throws -> ClaudeCredential {
        if let raw = profile.configDirectory,
           (!(raw as NSString).expandingTildeInPath.hasPrefix("/") || raw.contains("\0")) {
            throw ClaudeBackendError.credentialsInvalid
        }
        let url = profile.directoryURL.appendingPathComponent(".credentials.json")
        var fileError: ClaudeBackendError?
        var fileCredential: ClaudeCredential?
        if let data = try readFile(url) {
            do { fileCredential = try ClaudeCredential.parse(data) }
            catch { fileError = error as? ClaudeBackendError ?? .credentialsInvalid }
        }
        // Keychain is Claude Code's primary macOS store. Do not silently use a leftover file
        // after native sign-in changes Keychain, or guess which of two different logins is current.
        // A denied/locked Keychain is an error, not evidence that its login is absent.
        if let data = try keychain(serviceName(for: profile), allowKeychainPrompt) {
            let credential = try ClaudeCredential.parse(data)
            if let fileCredential, fileCredential.accessToken != credential.accessToken {
                throw ClaudeBackendError.credentialStoresConflict
            }
            return credential
        }
        if let fileCredential { return fileCredential }
        throw fileError ?? .credentialsMissing
    }

    private static func readFile(_ url: URL) throws -> Data? {
        // O_NOFOLLOW plus fstat avoids a symlink check/open race and caps even growing files.
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            throw ClaudeBackendError.unsafeCredentialFile
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size >= 0, info.st_size <= maximumFileSize else {
            throw ClaudeBackendError.unsafeCredentialFile
        }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = Darwin.read(fd, &buffer, min(buffer.count, maximumFileSize + 1 - result.count))
            if count == 0 { return result }
            if count < 0 {
                if errno == EINTR { continue }
                throw ClaudeBackendError.unsafeCredentialFile
            }
            result.append(contentsOf: buffer.prefix(count))
            guard result.count <= maximumFileSize else { throw ClaudeBackendError.unsafeCredentialFile }
        }
    }

    private static func readKeychain(service: String, interactive: Bool) throws -> Data? {
        let context = LAContext()
        context.interactionNotAllowed = !interactive
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context,
        ]
        var result: CFTypeRef?
        let status = try KeychainAccess.withInteraction(allowed: interactive) {
            SecItemCopyMatching(query as CFDictionary, &result)
        }
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw ClaudeBackendError.keychainUnavailable
        }
        guard data.count <= maximumFileSize else { throw ClaudeBackendError.credentialsInvalid }
        return data
    }
}

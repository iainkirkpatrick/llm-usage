import Foundation
import Darwin

/// Best-effort metadata only, never authenticated account identity. OAuth quota
/// routing requires the authenticated profile API. The separate Claude Code source
/// can use a historical profile email as an expected association, not UUID proof.
enum ClaudeDefaultIdentityHint {
    private static let maximumFileSize = 1_048_576

    static func read(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String? {
        let paths = [
            home.appendingPathComponent(".claude.json"),
            home.appendingPathComponent(".claude", isDirectory: true).appendingPathComponent(".claude.json")
        ]
        let identities = paths.compactMap(readIdentity(at:))
        guard let first = identities.first else { return nil }
        return identities.dropFirst().allSatisfy { $0 == first } ? first : nil
    }

    static func parse(_ data: Data) -> String? {
        guard data.count <= maximumFileSize,
              let root = try? JSONSerialization.jsonObject(with: data),
              let dictionary = root as? [String: Any],
              let oauthAccount = dictionary["oauthAccount"] as? [String: Any],
              let accountUUID = oauthAccount["accountUuid"] as? String,
              let organizationUUID = oauthAccount["organizationUuid"] as? String,
              let account = canonicalUUID(accountUUID),
              let organization = canonicalUUID(organizationUUID) else { return nil }
        return "\(account):\(organization)"
    }

    /// Canonicalizes only a pair of UUIDs; the resulting string remains an
    /// untrusted hint and must be checked against authenticated profile data.
    static func canonicalIdentity(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let parts = raw.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let account = canonicalUUID(String(parts[0])),
              let organization = canonicalUUID(String(parts[1])) else { return nil }
        return "\(account):\(organization)"
    }

    /// Bootstrap an expected CLI email from the configured profile's own metadata
    /// only when its complete historical UUID pair matches the saved OAuth pin.
    /// This cannot adopt an ambient account or manufacture a verified UUID.
    static func configuredEmail(profile: ClaudeAccountProfile) -> String? {
        guard profile.configDirectory != nil,
              let expected = canonicalIdentity(profile.accountID),
              let data = readData(at: profile.directoryURL.appendingPathComponent(".claude.json")),
              parse(data) == expected,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = root["oauthAccount"] as? [String: Any],
              let email = account["emailAddress"] as? String, !email.isEmpty, email.contains("@"),
              email.utf8.count <= 320,
              !email.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return email
    }

    private static func canonicalUUID(_ value: String) -> String? {
        let bytes = Array(value.utf8)
        guard bytes.count == 36,
              bytes[8] == 45, bytes[13] == 45, bytes[18] == 45, bytes[23] == 45 else { return nil }
        for (index, byte) in bytes.enumerated() where index != 8 && index != 13 && index != 18 && index != 23 {
            guard (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte) else { return nil }
        }
        return value.lowercased()
    }

    private static func readIdentity(at url: URL) -> String? {
        guard let data = readData(at: url) else { return nil }
        return parse(data)
    }

    private static func readData(at url: URL) -> Data? {
        let descriptor = url.path.withCString { path in
            open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        }
        guard descriptor >= 0 else { return nil }
        defer { _ = close(descriptor) }

        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size >= 0,
              info.st_size <= maximumFileSize else { return nil }

        var data = Data()
        data.reserveCapacity(Int(info.st_size))
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if count == 0 { break }
            guard data.count + count <= maximumFileSize else { return nil }
            data.append(contentsOf: buffer[..<count])
        }
        return data
    }
}

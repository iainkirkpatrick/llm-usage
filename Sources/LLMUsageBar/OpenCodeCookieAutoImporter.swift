import Foundation

#if os(macOS)
import CommonCrypto
import SQLite3
import Security

enum OpenCodeCookieAutoImportError: LocalizedError {
    case noCookies
    case browserError(String)

    var errorDescription: String? {
        switch self {
        case .noCookies:
            "No OpenCode cookies found in Chromium/Chrome."
        case let .browserError(message):
            message
        }
    }
}

struct OpenCodeCookieAutoImporter {
    struct SessionInfo: Sendable {
        let cookieHeader: String
        let sourceLabel: String
    }

    private enum BrowserFamily {
        case chromium
        case chrome
    }

    private struct CookieStore {
        let family: BrowserFamily
        let label: String
        let cookiesDBPath: String
    }

    private struct CandidateCookie {
        let value: String
        let score: Int
    }

    static func importSession() throws -> SessionInfo {
        let stores = self.findCookieStores()
        var lastError: Error?

        for store in stores {
            do {
                let cookies = try self.readCookies(from: store)
                let hasAuth = cookies["auth"] != nil || cookies["__Host-auth"] != nil
                guard hasAuth else { continue }

                let cookieHeader = cookies
                    .sorted(by: { lhs, rhs in
                        if lhs.key == "auth" || lhs.key == "__Host-auth" { return true }
                        if rhs.key == "auth" || rhs.key == "__Host-auth" { return false }
                        return lhs.key < rhs.key
                    })
                    .map { "\($0.key)=\($0.value)" }
                    .joined(separator: "; ")

                return SessionInfo(cookieHeader: cookieHeader, sourceLabel: store.label)
            } catch {
                lastError = error
            }
        }

        if let lastError {
            throw OpenCodeCookieAutoImportError.browserError(lastError.localizedDescription)
        }

        throw OpenCodeCookieAutoImportError.noCookies
    }

    static func tryImportCookieHeader() -> String? {
        try? self.importSession().cookieHeader
    }

    private static func findCookieStores() -> [CookieStore] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let roots: [(BrowserFamily, String, String)] = [
            (.chromium, "Chromium", "\(home)/Library/Application Support/Chromium"),
            (.chrome, "Chrome", "\(home)/Library/Application Support/Google/Chrome"),
        ]

        var stores: [CookieStore] = []
        for (family, label, root) in roots {
            guard let contents = try? FileManager.default.contentsOfDirectory(atPath: root) else { continue }

            for name in contents.sorted() {
                guard name == "Default" || name.hasPrefix("Profile ") || name.hasPrefix("user-") else { continue }

                let profile = "\(root)/\(name)"
                let networkDB = "\(profile)/Network/Cookies"
                let legacyDB = "\(profile)/Cookies"

                if FileManager.default.fileExists(atPath: networkDB) {
                    stores.append(CookieStore(family: family, label: "\(label) \(name)", cookiesDBPath: networkDB))
                } else if FileManager.default.fileExists(atPath: legacyDB) {
                    stores.append(CookieStore(family: family, label: "\(label) \(name)", cookiesDBPath: legacyDB))
                }
            }
        }

        return stores
    }

    private static func readCookies(from store: CookieStore) throws -> [String: String] {
        var db: OpaquePointer?
        let openResult = sqlite3_open_v2(store.cookiesDBPath, &db, SQLITE_OPEN_READONLY, nil)
        guard openResult == SQLITE_OK, let db else {
            throw OpenCodeCookieAutoImportError.browserError("Could not open cookie DB: \(store.label)")
        }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT name, value, encrypted_value, host_key, path
        FROM cookies
        WHERE host_key LIKE '%opencode.ai%'
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw OpenCodeCookieAutoImportError.browserError("Could not query cookie DB: \(store.label)")
        }
        defer { sqlite3_finalize(stmt) }

        var picked: [String: CandidateCookie] = [:]

        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let namePtr = sqlite3_column_text(stmt, 0) else { continue }
            let name = String(cString: namePtr)

            let value = (sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? "")

            var decryptedValue: String?
            if !value.isEmpty {
                decryptedValue = value
            } else {
                let blobLength = Int(sqlite3_column_bytes(stmt, 2))
                if blobLength > 0,
                   let blobPtr = sqlite3_column_blob(stmt, 2)
                {
                    let encrypted = Data(bytes: blobPtr, count: blobLength)
                    decryptedValue = self.decryptCookieValue(encrypted, family: store.family)
                }
            }

            guard let finalValue = decryptedValue, !finalValue.isEmpty else { continue }

            let host = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? ""
            let path = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? ""

            let score = self.cookieScore(name: name, host: host, path: path)
            if let existing = picked[name], existing.score >= score {
                continue
            }
            picked[name] = CandidateCookie(value: finalValue, score: score)
        }

        return picked.mapValues(\.value)
    }

    private static func cookieScore(name: String, host: String, path: String) -> Int {
        var score = 0
        if host == "opencode.ai" || host == ".opencode.ai" {
            score += 100
        } else if host.contains("opencode.ai") {
            score += 50
        }

        if path == "/" {
            score += 10
        }

        if name == "auth" || name == "__Host-auth" {
            score += 1000
        }

        return score
    }

    private static func decryptCookieValue(_ encrypted: Data, family: BrowserFamily) -> String? {
        guard encrypted.count >= 3 else { return nil }

        // Chromium cookies on macOS are usually AES-CBC with a v10/v11 prefix.
        guard encrypted.starts(with: Data([0x76, 0x31, 0x30])) || encrypted.starts(with: Data([0x76, 0x31, 0x31])) else {
            return String(data: encrypted, encoding: .utf8)
        }

        guard let key = self.deriveCookieKey(family: family) else { return nil }

        let cipher = encrypted.dropFirst(3)
        let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)

        guard let plaintext = self.aesCBCDecrypt(data: Data(cipher), key: key, iv: iv) else { return nil }

        if let value = String(data: plaintext, encoding: .utf8), !value.isEmpty {
            return value
        }

        // Newer Chromium builds may prefix decrypted cookie payloads with a 32-byte
        // domain hash before the UTF-8 cookie value.
        if plaintext.count > 32,
           let value = String(data: plaintext.dropFirst(32), encoding: .utf8),
           !value.isEmpty
        {
            return value
        }

        return nil
    }

    private static func deriveCookieKey(family: BrowserFamily) -> Data? {
        let password = self.safeStoragePassword(family: family)
            ?? self.safeStoragePassword(family: family == .chromium ? .chrome : .chromium)
        guard let password else { return nil }

        let passwordData = Data(password.utf8)
        let salt = Data("saltysalt".utf8)

        var key = Data(count: 16)
        let keyLength = key.count
        let status = key.withUnsafeMutableBytes { keyPtr in
            salt.withUnsafeBytes { saltPtr in
                passwordData.withUnsafeBytes { passPtr in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passPtr.bindMemory(to: Int8.self).baseAddress,
                        passwordData.count,
                        saltPtr.bindMemory(to: UInt8.self).baseAddress,
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                        1003,
                        keyPtr.bindMemory(to: UInt8.self).baseAddress,
                        keyLength
                    )
                }
            }
        }

        guard status == kCCSuccess else { return nil }
        return key
    }

    private static func safeStoragePassword(family: BrowserFamily) -> String? {
        let labels: [(service: String, account: String)] = switch family {
        case .chromium:
            [("Chromium Safe Storage", "Chromium")]
        case .chrome:
            [
                ("Chrome Safe Storage", "Chrome"),
                ("Google Chrome Safe Storage", "Chrome"),
            ]
        }

        for label in labels {
            if let value = self.keychainPassword(service: label.service, account: label.account) {
                return value
            }
        }
        return nil
    }

    private static func keychainPassword(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func aesCBCDecrypt(data: Data, key: Data, iv: Data) -> Data? {
        var outLength = 0
        var out = Data(count: data.count + kCCBlockSizeAES128)
        let outCapacity = out.count

        let status = out.withUnsafeMutableBytes { outPtr in
            data.withUnsafeBytes { dataPtr in
                key.withUnsafeBytes { keyPtr in
                    iv.withUnsafeBytes { ivPtr in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyPtr.baseAddress,
                            key.count,
                            ivPtr.baseAddress,
                            dataPtr.baseAddress,
                            data.count,
                            outPtr.baseAddress,
                            outCapacity,
                            &outLength
                        )
                    }
                }
            }
        }

        guard status == kCCSuccess else { return nil }
        out.removeSubrange(outLength..<out.count)
        return out
    }
}

#else

struct OpenCodeCookieAutoImporter {
    struct SessionInfo: Sendable {
        let cookieHeader: String
        let sourceLabel: String
    }

    static func importSession() throws -> SessionInfo {
        throw NSError(domain: "OpenCodeCookieAutoImporter", code: 1)
    }

    static func tryImportCookieHeader() -> String? {
        nil
    }
}

#endif

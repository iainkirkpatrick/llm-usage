import Foundation

enum PiSessionsError: LocalizedError {
    case unreadableDirectory(String)

    var errorDescription: String? {
        switch self {
        case let .unreadableDirectory(path):
            return "Could not read pi sessions directory: \(path)"
        }
    }
}

struct PiSessionsFetcher {
    private struct ParsedSession {
        let rows: [PiUsageRow]
        let isFork: Bool
        let zeroCostRowCount: Int
    }

    private let defaultSessionsDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".pi/agent/sessions", isDirectory: true)

    func fetch(sessionsDirectory: String?, deduplicateForkHistory: Bool) throws -> PiSnapshot {
        let directoryURL = self.resolveSessionsDirectory(sessionsDirectory)
        let exists = FileManager.default.fileExists(atPath: directoryURL.path)

        guard exists else {
            return PiSnapshot(
                sessionsDirectory: directoryURL.path,
                rows: [],
                sessionCount: 0,
                forkedSessionCount: 0,
                zeroCostRowCount: 0,
                updatedAt: Date()
            )
        }

        let files = try self.sessionFiles(at: directoryURL)
        var rows: [PiUsageRow] = []
        var forkedSessionCount = 0
        var zeroCostRowCount = 0

        for fileURL in files {
            guard let parsed = try? self.parseSessionFile(fileURL, deduplicateForkHistory: deduplicateForkHistory) else {
                continue
            }
            rows.append(contentsOf: parsed.rows)
            if parsed.isFork {
                forkedSessionCount += 1
            }
            zeroCostRowCount += parsed.zeroCostRowCount
        }

        rows.sort { $0.timeCreated > $1.timeCreated }

        return PiSnapshot(
            sessionsDirectory: directoryURL.path,
            rows: rows,
            sessionCount: files.count,
            forkedSessionCount: forkedSessionCount,
            zeroCostRowCount: zeroCostRowCount,
            updatedAt: Date()
        )
    }

    private func resolveSessionsDirectory(_ rawPath: String?) -> URL {
        guard let rawPath = rawPath?.trimmingCharacters(in: .whitespacesAndNewlines), !rawPath.isEmpty else {
            return self.defaultSessionsDirectory.standardizedFileURL
        }

        let expanded = (rawPath as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
    }

    private func sessionFiles(at directoryURL: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw PiSessionsError.unreadableDirectory(directoryURL.path)
        }

        var files: [URL] = []
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            guard fileURL.pathExtension.lowercased() == "jsonl" else { continue }
            files.append(fileURL)
        }

        return files.sorted { $0.path < $1.path }
    }

    private func parseSessionFile(_ fileURL: URL, deduplicateForkHistory: Bool) throws -> ParsedSession {
        let text = try String(contentsOf: fileURL, encoding: .utf8)

        var sessionID: String?
        var cwd: String?
        var sessionStartedAt: Date?
        var isFork = false
        var rows: [PiUsageRow] = []
        var zeroCostRowCount = 0

        for rawLine in text.split(whereSeparator: \.isNewline) {
            guard let dict = Self.jsonObject(from: rawLine) else { continue }
            guard let type = dict["type"] as? String else { continue }

            if type == "session" {
                sessionID = Self.normalizedString(dict["id"])
                cwd = Self.normalizedString(dict["cwd"])
                sessionStartedAt = Self.parseISODate(dict["timestamp"])
                isFork = Self.normalizedString(dict["parentSession"]) != nil
                continue
            }

            guard type == "message",
                  let message = dict["message"] as? [String: Any],
                  (message["role"] as? String) == "assistant",
                  let usage = message["usage"] as? [String: Any]
            else {
                continue
            }

            let timeCreated = Self.parseISODate(dict["timestamp"])
                ?? Self.parseMessageTimestamp(message["timestamp"])
                ?? sessionStartedAt
            guard let timeCreated else { continue }

            if deduplicateForkHistory,
               isFork,
               let sessionStartedAt,
               timeCreated < sessionStartedAt
            {
                continue
            }

            let inputTokens = Self.int(usage["input"]) ?? 0
            let outputTokens = Self.int(usage["output"]) ?? 0
            let cacheReadTokens = Self.int(usage["cacheRead"]) ?? 0
            let cacheWriteTokens = Self.int(usage["cacheWrite"]) ?? 0
            let totalTokens = Self.int(usage["totalTokens"])
                ?? inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens

            let cost = ((usage["cost"] as? [String: Any]).flatMap { Self.double($0["total"]) }) ?? 0
            if totalTokens > 0 && cost == 0 {
                zeroCostRowCount += 1
            }

            rows.append(
                PiUsageRow(
                    timeCreated: timeCreated,
                    sessionFile: fileURL.path,
                    sessionID: sessionID,
                    cwd: cwd,
                    provider: Self.normalizedString(message["provider"]),
                    model: Self.normalizedString(message["model"]),
                    inputTokens: inputTokens,
                    outputTokens: outputTokens,
                    cacheReadTokens: cacheReadTokens,
                    cacheWriteTokens: cacheWriteTokens,
                    totalTokens: totalTokens,
                    costUSD: cost
                )
            )
        }

        return ParsedSession(rows: rows, isFork: isFork, zeroCostRowCount: zeroCostRowCount)
    }

    private static func jsonObject(from rawLine: Substring) -> [String: Any]? {
        let data = Data(rawLine.utf8)
        guard let object = try? JSONSerialization.jsonObject(with: data, options: []),
              let dict = object as? [String: Any]
        else {
            return nil
        }
        return dict
    }

    private static func parseISODate(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) {
            return date
        }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }

    private static func parseMessageTimestamp(_ value: Any?) -> Date? {
        switch value {
        case let number as NSNumber:
            let raw = number.doubleValue
            if raw > 1_000_000_000_000 {
                return Date(timeIntervalSince1970: raw / 1000)
            }
            if raw > 1_000_000_000 {
                return Date(timeIntervalSince1970: raw)
            }
            return nil
        case let string as String:
            if let raw = Double(string.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return self.parseMessageTimestamp(raw as NSNumber)
            }
            return nil
        default:
            return nil
        }
    }

    private static func normalizedString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func int(_ value: Any?) -> Int? {
        switch value {
        case let number as NSNumber:
            number.intValue
        case let string as String:
            Int(string.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            nil
        }
    }

    private static func double(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber:
            number.doubleValue
        case let string as String:
            Double(string.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            nil
        }
    }
}

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

struct PiSessionsFetcher: Sendable {
    private final class TelemetryCache: @unchecked Sendable {
        private struct FileMetadata {
            let path: String
            let resourceIdentifier: String?
            let size: UInt64
            let modificationDate: Date?
        }

        private let lock = NSLock()
        private var metadata: FileMetadata?
        private var byteOffset: UInt64 = 0
        private var incompleteLine = Data()
        private var rows: [PiUsageRow] = []

        func rows(for fileURL: URL) -> [PiUsageRow] {
            self.lock.lock()
            defer { self.lock.unlock() }

            guard let currentMetadata = try? Self.fileMetadata(for: fileURL) else {
                // A missing or temporarily unreadable telemetry file must not make the
                // fetch fail, and cached rows must not survive a removed file.
                self.reset()
                return []
            }

            if self.shouldReset(for: currentMetadata) {
                self.reset()
            }

            do {
                let result = try Self.readNewData(
                    from: fileURL,
                    offset: self.byteOffset,
                    incompleteLine: self.incompleteLine)
                self.byteOffset = result.offset
                self.incompleteLine = result.incompleteLine
                self.rows.append(contentsOf: result.rows)
                self.metadata = (try? Self.fileMetadata(for: fileURL))
                    ?? FileMetadata(
                        path: currentMetadata.path,
                        resourceIdentifier: currentMetadata.resourceIdentifier,
                        size: result.offset,
                        modificationDate: currentMetadata.modificationDate)
            } catch {
                // Telemetry is auxiliary data. Keep a previously parsed snapshot when a
                // read fails, but do not turn the failure into a sessions fetch error.
                return self.rows
            }

            return self.rows
        }

        private func reset() {
            self.metadata = nil
            self.byteOffset = 0
            self.incompleteLine.removeAll(keepingCapacity: false)
            self.rows.removeAll(keepingCapacity: false)
        }

        private func shouldReset(for current: FileMetadata) -> Bool {
            guard let previous = self.metadata else { return false }
            if previous.path != current.path {
                return true
            }
            if previous.resourceIdentifier != current.resourceIdentifier,
               previous.resourceIdentifier != nil || current.resourceIdentifier != nil
            {
                return true
            }
            if current.size < self.byteOffset {
                return true
            }
            // If resource identifiers are unavailable (or an application rewrites a file
            // in place), a changed timestamp at the same offset indicates replacement.
            if current.size == self.byteOffset,
               previous.modificationDate != current.modificationDate
            {
                return true
            }
            return false
        }

        private static func fileMetadata(for fileURL: URL) throws -> FileMetadata {
            let values = try fileURL.resourceValues(forKeys: [
                .isRegularFileKey, .fileResourceIdentifierKey, .fileSizeKey,
                .contentModificationDateKey,
            ])
            guard values.isRegularFile == true, let fileSize = values.fileSize, fileSize >= 0 else {
                throw CocoaError(.fileReadUnknown)
            }
            return FileMetadata(
                path: fileURL.path,
                resourceIdentifier: values.fileResourceIdentifier.map { String(describing: $0) },
                size: UInt64(fileSize),
                modificationDate: values.contentModificationDate)
        }

        private static func readNewData(
            from fileURL: URL,
            offset: UInt64,
            incompleteLine: Data
        ) throws -> (offset: UInt64, incompleteLine: Data, rows: [PiUsageRow]) {
            let handle = try FileHandle(forReadingFrom: fileURL)
            defer { try? handle.close() }
            try handle.seek(toOffset: offset)

            var nextOffset = offset
            var buffered = incompleteLine
            var rows: [PiUsageRow] = []

            while true {
                guard let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty else {
                    break
                }
                nextOffset += UInt64(chunk.count)
                buffered.append(chunk)

                guard let newline = buffered.lastIndex(of: 0x0A) else { continue }
                let completeEnd = buffered.index(after: newline)
                let completeData = buffered[..<completeEnd]
                for rawLine in completeData.split(separator: 0x0A, omittingEmptySubsequences: true) {
                    let lineData = Data(rawLine)
                    if let row = PiSessionsFetcher.parseTelemetryRecord(lineData, fileURL: fileURL) {
                        rows.append(row)
                    }
                }
                buffered = Data(buffered[completeEnd...])
            }

            return (nextOffset, buffered, rows)
        }
    }

    private struct ParsedSession {
        let rows: [PiUsageRow]
        let isFork: Bool
        let zeroCostRowCount: Int
    }

    private let defaultSessionsDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".pi/agent/sessions", isDirectory: true)
    private let telemetryCache = TelemetryCache()

    func fetch(sessionsDirectory: String?, deduplicateForkHistory: Bool) throws -> PiSnapshot {
        let directoryURL = self.resolveSessionsDirectory(sessionsDirectory)
        let exists = FileManager.default.fileExists(atPath: directoryURL.path)

        var files: [URL] = []
        var rows: [PiUsageRow] = []
        var forkedSessionCount = 0
        var zeroCostRowCount = 0

        if exists {
            files = try self.sessionFiles(at: directoryURL)
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
        }

        // Session JSONL contains the main calls. Pi's telemetry is also where subagent calls
        // are recorded, so only append the latter to avoid counting main calls twice.
        let telemetryRows = self.parseTelemetryFile(at: self.telemetryFileURL(for: directoryURL))
        rows.append(contentsOf: telemetryRows)
        zeroCostRowCount += telemetryRows.reduce(into: 0) { count, row in
            if row.totalTokens > 0 && row.costUSD == 0 {
                count += 1
            }
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

    private func telemetryFileURL(for sessionsDirectory: URL) -> URL? {
        guard sessionsDirectory.lastPathComponent == "sessions" else { return nil }
        return sessionsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("telemetry/events.jsonl", isDirectory: false)
    }

    private func parseTelemetryFile(at fileURL: URL?) -> [PiUsageRow] {
        guard let fileURL else { return [] }
        return self.telemetryCache.rows(for: fileURL)
    }

    private static func parseTelemetryRecord(_ rawLine: Data, fileURL: URL) -> PiUsageRow? {
        guard let dict = Self.jsonObject(from: rawLine),
              (dict["type"] as? String) == "provider_call"
        else {
            return nil
        }

        let isSubagent = Self.normalizedString(dict["execution_scope"]) == "subagent"
            || (Self.numericInt(dict["subagent_depth"]) ?? 0) > 0
        guard isSubagent,
              let timeCreated = Self.parseTelemetryDate(dict["message_completion_at"])
                  ?? Self.parseTelemetryDate(dict["timestamp"]),
              let inputTokens = Self.nonNegativeInt(dict["input"]),
              let outputTokens = Self.nonNegativeInt(dict["output"])
        else {
            return nil
        }

        // Cache counters, totalTokens, and cost are absent from some finalized calls.
        // They are optional usage details, whereas input/output plus a timestamp identify
        // a usable provider call. Derive or zero-fill the optional values instead of
        // discarding the entire record.
        let cacheReadTokens = Self.nonNegativeInt(dict["cacheRead"]) ?? 0
        let cacheWriteTokens = Self.nonNegativeInt(dict["cacheWrite"]) ?? 0
        let totalTokens = Self.nonNegativeInt(dict["totalTokens"])
            ?? inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens
        let cost = Self.nonNegativeDouble(dict["cost"]) ?? 0

        return PiUsageRow(
            timeCreated: timeCreated,
            sessionFile: fileURL.path,
            sessionID: Self.normalizedString(dict["session_id"]),
            cwd: Self.normalizedString(dict["cwd"]),
            provider: Self.normalizedString(dict["provider"]),
            model: Self.normalizedString(dict["model"]),
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheReadTokens: cacheReadTokens,
            cacheWriteTokens: cacheWriteTokens,
            totalTokens: totalTokens,
            costUSD: cost
        )
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
        self.jsonObject(from: Data(rawLine.utf8))
    }

    private static func jsonObject(from rawLine: Data) -> [String: Any]? {
        guard let object = try? JSONSerialization.jsonObject(with: rawLine, options: []),
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

    private static func parseTelemetryDate(_ value: Any?) -> Date? {
        self.parseISODate(value) ?? self.parseMessageTimestamp(value)
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

    private static func numericInt(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, !Self.isBoolean(number) else { return nil }
        let raw = number.doubleValue
        guard raw.isFinite, raw.rounded() == raw else { return nil }
        return number.intValue
    }

    private static func nonNegativeInt(_ value: Any?) -> Int? {
        guard let number = Self.numericInt(value), number >= 0 else { return nil }
        return number
    }

    private static func nonNegativeDouble(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, !Self.isBoolean(number) else { return nil }
        let raw = number.doubleValue
        guard raw.isFinite, raw >= 0 else { return nil }
        return raw
    }

    private static func isBoolean(_ number: NSNumber) -> Bool {
        let type = String(cString: number.objCType)
        return type == "c" || type == "B"
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

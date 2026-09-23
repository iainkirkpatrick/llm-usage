import Darwin
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
    private struct ParsedUsageRow: Sendable {
        let row: PiUsageRow
        let subagentIdentity: String?
    }

    private struct ParsedSession: Sendable {
        let rows: [ParsedUsageRow]
        let isFork: Bool
    }

    private struct FileIdentity: Equatable {
        let path: String
        let size: Int
        let modificationDate: Date
        let inode: UInt64?
        let deduplicateForkHistory: Bool
    }

    private struct CachedFile {
        let identity: FileIdentity
        let parsed: ParsedSession
    }

    private final class SessionCache: @unchecked Sendable {
        private let lock = NSLock()
        private var files: [String: CachedFile] = [:]

        func parsed(for identity: FileIdentity) -> ParsedSession? {
            self.lock.lock()
            defer { self.lock.unlock() }
            return self.files[identity.path]?.identity == identity
                ? self.files[identity.path]?.parsed
                : nil
        }

        func store(_ parsed: ParsedSession, for identity: FileIdentity) {
            self.lock.lock()
            self.files[identity.path] = CachedFile(identity: identity, parsed: parsed)
            self.lock.unlock()
        }

        func removeMissingFiles(in directory: URL, presentPaths: Set<String>) {
            let prefix = directory.path.hasSuffix("/") ? directory.path : directory.path + "/"
            self.lock.lock()
            self.files = self.files.filter { path, _ in
                !path.hasPrefix(prefix) || presentPaths.contains(path)
            }
            self.lock.unlock()
        }
    }

    private let cache = SessionCache()
    private let defaultSessionsDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".pi/agent/sessions", isDirectory: true)

    func fetch(sessionsDirectory: String?, deduplicateForkHistory: Bool) throws -> PiSnapshot {
        let directoryURL = self.resolveSessionsDirectory(sessionsDirectory)
        let exists = FileManager.default.fileExists(atPath: directoryURL.path)

        var files: [URL] = []
        var rows: [PiUsageRow] = []
        var forkedSessionCount = 0
        var zeroCostRowCount = 0
        var seenSubagentIdentities = Set<String>()

        if exists {
            files = try self.sessionFiles(at: directoryURL)
            let presentPaths = Set(files.map(\.path))
            self.cache.removeMissingFiles(in: directoryURL, presentPaths: presentPaths)
            for fileURL in files {
                guard let identity = self.fileIdentity(
                    for: fileURL,
                    deduplicateForkHistory: deduplicateForkHistory)
                else {
                    continue
                }

                let parsed: ParsedSession
                if let cached = self.cache.parsed(for: identity) {
                    parsed = cached
                } else {
                    guard let fresh = try? self.parseSessionFile(
                        fileURL,
                        deduplicateForkHistory: deduplicateForkHistory)
                    else {
                        continue
                    }
                    parsed = fresh
                    if self.fileIdentity(for: fileURL, deduplicateForkHistory: deduplicateForkHistory) == identity {
                        self.cache.store(fresh, for: identity)
                    }
                }

                if parsed.isFork {
                    forkedSessionCount += 1
                }

                for parsedRow in parsed.rows {
                    if let identity = parsedRow.subagentIdentity,
                       !seenSubagentIdentities.insert(identity).inserted
                    {
                        // Forks and copied session files can contain the same completed
                        // subagent result. Keep one logical result even when the copied entry
                        // is not old enough for the timestamp-based fork filter to remove it.
                        continue
                    }
                    rows.append(parsedRow.row)
                    if parsedRow.row.totalTokens > 0 && parsedRow.row.costUSD == 0 {
                        zeroCostRowCount += 1
                    }
                }
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

    private func fileIdentity(for fileURL: URL, deduplicateForkHistory: Bool) -> FileIdentity? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = attributes[.size] as? Int,
              let modificationDate = attributes[.modificationDate] as? Date
        else {
            return nil
        }
        let fileNumber = attributes[.systemFileNumber] as? NSNumber
        return FileIdentity(
            path: fileURL.path,
            size: size,
            modificationDate: modificationDate,
            inode: fileNumber?.uint64Value,
            deduplicateForkHistory: deduplicateForkHistory)
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
        let fractionalDateFormatter = ISO8601DateFormatter()
        fractionalDateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plainDateFormatter = ISO8601DateFormatter()
        plainDateFormatter.formatOptions = [.withInternetDateTime]

        var sessionID: String?
        var cwd: String?
        var sessionStartedAt: Date?
        var isFork = false
        var rows: [ParsedUsageRow] = []

        try self.forEachJSONLLine(in: fileURL) { rawLine in
            autoreleasepool {
                guard let dict = Self.jsonObject(from: rawLine) else { return }
                guard let type = dict["type"] as? String else { return }

                if type == "session" {
                    sessionID = Self.normalizedString(dict["id"])
                    cwd = Self.normalizedString(dict["cwd"])
                    sessionStartedAt = Self.parseISODate(
                        dict["timestamp"], fractional: fractionalDateFormatter, plain: plainDateFormatter)
                    isFork = Self.normalizedString(dict["parentSession"]) != nil
                    return
                }

                guard type == "message",
                      let message = dict["message"] as? [String: Any]
                else {
                    return
                }

                let role = message["role"] as? String
                if role == "assistant" {
                    guard let usage = message["usage"] as? [String: Any],
                          let timeCreated = Self.parseISODate(
                        dict["timestamp"], fractional: fractionalDateFormatter, plain: plainDateFormatter)
                              ?? Self.parseMessageTimestamp(
                                message["timestamp"], fractional: fractionalDateFormatter, plain: plainDateFormatter)
                              ?? sessionStartedAt
                    else {
                        return
                    }

                    if deduplicateForkHistory,
                       isFork,
                       let sessionStartedAt,
                       timeCreated < sessionStartedAt
                    {
                        return
                    }

                    let inputTokens = Self.usageInt(usage, key: "input")
                    let outputTokens = Self.usageInt(usage, key: "output")
                    let cacheReadTokens = Self.usageInt(usage, key: "cacheRead")
                    let cacheWriteTokens = Self.usageInt(usage, key: "cacheWrite")
                    let computedTotalTokens = PiTokenTotals.saturatedNonnegativeSum([
                        inputTokens,
                        outputTokens,
                        cacheReadTokens,
                        cacheWriteTokens,
                    ])
                    let totalTokens = Self.usageInt(usage, key: "totalTokens", default: computedTotalTokens)
                    let cost = Self.assistantCost(usage)

                    let row = PiUsageRow(
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
                        costUSD: cost,
                        requestCount: 1
                    )
                    rows.append(ParsedUsageRow(row: row, subagentIdentity: nil))
                    return
                }

                guard role == "toolResult",
                      (message["toolName"] as? String) == "subagent",
                      let details = message["details"] as? [String: Any],
                      let results = details["results"] as? [Any],
                      let timeCreated = Self.parseISODate(
                        dict["timestamp"], fractional: fractionalDateFormatter, plain: plainDateFormatter)
                          ?? Self.parseMessageTimestamp(
                            message["timestamp"], fractional: fractionalDateFormatter, plain: plainDateFormatter)
                else {
                    return
                }

                if deduplicateForkHistory,
                   isFork,
                   let sessionStartedAt,
                   timeCreated < sessionStartedAt
                {
                    return
                }

                for (resultIndex, rawResult) in results.enumerated() {
                    guard let result = rawResult as? [String: Any],
                          !Self.isIncompleteSubagentResult(result),
                          let usage = result["usage"] as? [String: Any],
                          let inputTokens = Self.optionalUsageInt(usage, key: "input"),
                          let outputTokens = Self.optionalUsageInt(usage, key: "output"),
                          let cacheReadTokens = Self.optionalUsageInt(usage, key: "cacheRead"),
                          let cacheWriteTokens = Self.optionalUsageInt(usage, key: "cacheWrite"),
                          let cost = Self.optionalUsageDouble(usage, key: "cost")
                    else {
                        // A tool result can be persisted while an individual subagent result is
                        // incomplete. Do not make an unusable result into a zero-cost usage row.
                        continue
                    }

                    let totalTokens = PiTokenTotals.saturatedNonnegativeSum([
                        inputTokens,
                        outputTokens,
                        cacheReadTokens,
                        cacheWriteTokens,
                    ])
                    let turns = Self.optionalUsageInt(usage, key: "turns") ?? 0
                    let hasNonzeroUsage = totalTokens > 0 || cost > 0
                    let requestCount = turns > 0 ? turns : (hasNonzeroUsage ? 1 : 0)

                    let row = PiUsageRow(
                        timeCreated: timeCreated,
                        sessionFile: fileURL.path,
                        sessionID: sessionID,
                        cwd: cwd,
                        provider: nil,
                        model: Self.normalizedString(result["model"]),
                        inputTokens: inputTokens,
                        outputTokens: outputTokens,
                        cacheReadTokens: cacheReadTokens,
                        cacheWriteTokens: cacheWriteTokens,
                        totalTokens: totalTokens,
                        costUSD: cost,
                        requestCount: requestCount
                    )
                    rows.append(
                        ParsedUsageRow(
                            row: row,
                            subagentIdentity: Self.subagentIdentity(
                                entry: dict,
                                message: message,
                                result: result,
                                resultIndex: resultIndex,
                                timestamp: timeCreated)
                        )
                    )
                }
            }
        }

        return ParsedSession(rows: rows, isFork: isFork)
    }

    private static func isIncompleteSubagentResult(_ result: [String: Any]) -> Bool {
        if let exitCode = Self.signedInt(result["exitCode"]), exitCode == -1 {
            return true
        }
        let stopReason = Self.normalizedString(result["stopReason"])?.lowercased()
        return stopReason == "pending" || stopReason == "running"
    }

    private static func subagentIdentity(
        entry: [String: Any],
        message: [String: Any],
        result: [String: Any],
        resultIndex: Int,
        timestamp: Date
    ) -> String {
        if let runID = Self.normalizedString(result["subagentRunId"]) {
            return "run:\(runID)"
        }

        // Session entry IDs and tool-call IDs are persisted with copied fork history. The result
        // index keeps parallel and chain results distinct when they are in the same tool result.
        let entryID = Self.normalizedString(entry["id"])
            ?? Self.normalizedString(message["id"])
        let toolCallID = Self.normalizedString(message["toolCallId"])
        if let entryID {
            return "entry:\(entryID)|toolCall:\(toolCallID ?? "")|result:\(resultIndex)"
        }

        // Older or synthetic records may lack an entry ID. This fallback still uses persisted
        // message identity and the result position, without a session-file path that changes in
        // a fork. A missing tool-call ID is unusual, but the timestamp keeps the key stable.
        return "message|toolCall:\(toolCallID ?? "")|timestamp:\(timestamp.timeIntervalSince1970)|result:\(resultIndex)"
    }

    private func forEachJSONLLine(in fileURL: URL, _ body: (Data) -> Void) throws {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        let chunkSize = 64 * 1024
        var pending = Data()
        while try autoreleasepool(invoking: { () throws -> Bool in
            // FileHandle's returned NSData is autoreleased. Drain it for every chunk,
            // not only for each JSON record (a single record can span thousands of reads).
            guard let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty else {
                return false
            }
            chunk.withUnsafeBytes { (rawBuffer: UnsafeRawBufferPointer) in
                guard let base = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    return
                }

                var cursor = 0
                while cursor < rawBuffer.count {
                    let searchStart = base.advanced(by: cursor)
                    guard let newline = memchr(searchStart, 0x0A, rawBuffer.count - cursor) else {
                        pending.append(searchStart, count: rawBuffer.count - cursor)
                        break
                    }

                    let newlineOffset = Int(bitPattern: newline) - Int(bitPattern: base)
                    let segmentLength = newlineOffset - cursor
                    if !pending.isEmpty {
                        pending.append(searchStart, count: segmentLength)
                        if pending.last == 0x0D { pending.removeLast() }
                        body(pending)
                        pending.removeAll(keepingCapacity: true)
                    } else {
                        var lineLength = segmentLength
                        if lineLength > 0, base[newlineOffset - 1] == 0x0D {
                            lineLength -= 1
                        }
                        body(Data(bytes: searchStart, count: lineLength))
                    }
                    cursor = newlineOffset + 1
                }
            }
            return true
        }) {}
        if !pending.isEmpty {
            if pending.last == 0x0D { pending.removeLast() }
            body(pending)
        }
    }

    private static func jsonObject(from rawLine: Data) -> [String: Any]? {
        guard let object = try? JSONSerialization.jsonObject(with: rawLine, options: []),
              let dict = object as? [String: Any]
        else {
            return nil
        }
        return dict
    }

    private static func parseISODate(
        _ value: Any?, fractional: ISO8601DateFormatter, plain: ISO8601DateFormatter
    ) -> Date? {
        guard let string = value as? String else { return nil }
        return fractional.date(from: string) ?? plain.date(from: string)
    }

    private static func parseMessageTimestamp(
        _ value: Any?, fractional: ISO8601DateFormatter, plain: ISO8601DateFormatter
    ) -> Date? {
        switch value {
        case let number as NSNumber:
            guard !Self.isBoolean(number) else { return nil }
            let raw = number.doubleValue
            guard raw.isFinite else { return nil }
            if raw > 1_000_000_000_000 {
                return Date(timeIntervalSince1970: raw / 1000)
            }
            if raw > 1_000_000_000 {
                return Date(timeIntervalSince1970: raw)
            }
            return nil
        case let string as String:
            guard let raw = Double(string.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                return nil
            }
            return self.parseMessageTimestamp(
                raw as NSNumber, fractional: fractional, plain: plain)
        default:
            return nil
        }
    }

    private static func normalizedString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func usageInt(_ usage: [String: Any], key: String, default fallback: Int = 0) -> Int {
        guard let value = usage[key] else { return fallback }
        return Self.nonNegativeInt(value) ?? fallback
    }

    private static func optionalUsageInt(_ usage: [String: Any], key: String) -> Int? {
        guard let value = usage[key] else { return 0 }
        return Self.nonNegativeInt(value)
    }

    private static func assistantCost(_ usage: [String: Any]) -> Double {
        if let cost = usage["cost"] as? [String: Any] {
            return Self.nonNegativeDouble(cost["total"]) ?? 0
        }
        return Self.nonNegativeDouble(usage["cost"]) ?? 0
    }

    private static func optionalUsageDouble(_ usage: [String: Any], key: String) -> Double? {
        guard let value = usage[key] else { return 0 }
        return Self.nonNegativeDouble(value)
    }

    private static func signedInt(_ value: Any?) -> Int? {
        switch value {
        case let number as NSNumber:
            guard !Self.isBoolean(number) else { return nil }
            let raw = number.doubleValue
            guard raw.isFinite, raw.rounded() == raw else { return nil }
            if raw >= Double(Int.max) {
                return Int.max
            }
            if raw <= Double(Int.min) {
                return Int.min
            }
            return Int(raw)
        case let string as String:
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            if trimmed.first == "-" {
                guard let positive = Self.nonNegativeIntegerString(String(trimmed.dropFirst())) else {
                    return nil
                }
                if positive == Int.max { return Int.min }
                return -positive
            }
            return Self.nonNegativeIntegerString(trimmed)
        default:
            return nil
        }
    }

    private static func nonNegativeInt(_ value: Any?) -> Int? {
        switch value {
        case let number as NSNumber:
            guard !Self.isBoolean(number) else { return nil }
            let raw = number.doubleValue
            guard raw.isFinite, raw >= 0, raw.rounded() == raw else { return nil }
            let maximumAsDouble = Double(Int.max)
            if raw >= maximumAsDouble {
                return Int.max
            }
            return Int(raw)
        case let string as String:
            return Self.nonNegativeIntegerString(string)
        default:
            return nil
        }
    }

    private static func nonNegativeIntegerString(_ value: String) -> Int? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var scalars = trimmed.unicodeScalars[...]
        if scalars.first?.value == 43 { // +
            scalars = scalars.dropFirst()
        }
        guard !scalars.isEmpty else { return nil }

        var result = 0
        var overflowed = false
        for scalar in scalars {
            guard scalar.value >= 48, scalar.value <= 57 else { return nil }
            let digit = Int(scalar.value - 48)
            if !overflowed {
                if result > (Int.max - digit) / 10 {
                    overflowed = true
                } else {
                    result = result * 10 + digit
                }
            }
        }
        return overflowed ? Int.max : result
    }

    private static func nonNegativeDouble(_ value: Any?) -> Double? {
        let raw: Double
        switch value {
        case let number as NSNumber:
            guard !Self.isBoolean(number) else { return nil }
            raw = number.doubleValue
        case let string as String:
            guard let parsed = Double(string.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                return nil
            }
            raw = parsed
        default:
            return nil
        }
        guard raw.isFinite, raw >= 0 else { return nil }
        return raw
    }

    private static func isBoolean(_ number: NSNumber) -> Bool {
        let type = String(cString: number.objCType)
        return type == "c" || type == "B"
    }
}

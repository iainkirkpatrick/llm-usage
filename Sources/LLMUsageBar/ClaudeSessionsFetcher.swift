import CoreFoundation
import Foundation

struct ClaudeSessionsFetcher: Sendable {
    func fetch(profile: ClaudeAccountProfile, now: Date = Date()) throws -> ClaudeLocalUsage {
        let projects = profile.directoryURL.appendingPathComponent("projects", isDirectory: true)
        if let raw = profile.configDirectory,
           (!(raw as NSString).expandingTildeInPath.hasPrefix("/") || raw.contains("\0")) {
            throw ClaudeSessionsError.unreadableProjectsDirectory("invalid profile path")
        }
        var profileIsDirectory: ObjCBool = false
        guard !Self.isSymlink(profile.directoryURL),
              FileManager.default.fileExists(atPath: profile.directoryURL.path, isDirectory: &profileIsDirectory),
              profileIsDirectory.boolValue
        else {
            throw ClaudeSessionsError.unreadableProjectsDirectory(projects.path)
        }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        let profileEntries: [String]
        do {
            profileEntries = try FileManager.default.contentsOfDirectory(atPath: profile.directoryURL.path)
        } catch {
            throw ClaudeSessionsError.unreadableProjectsDirectory(projects.path)
        }
        var isDirectory: ObjCBool = false
        guard !Self.isSymlink(projects) else {
            throw ClaudeSessionsError.unreadableProjectsDirectory(projects.path)
        }
        guard profileEntries.contains("projects") else {
            return ClaudeLocalUsage(rows: [], fileCount: 0, unreadableFileCount: 0, updatedAt: now)
        }
        guard FileManager.default.fileExists(atPath: projects.path, isDirectory: &isDirectory) else {
            throw ClaudeSessionsError.unreadableProjectsDirectory(projects.path)
        }
        guard isDirectory.boolValue else {
            throw ClaudeSessionsError.unreadableProjectsDirectory(projects.path)
        }

        let urls: [URL]
        do {
            urls = try Self.jsonlFiles(under: projects)
        } catch {
            throw ClaudeSessionsError.unreadableProjectsDirectory(projects.path)
        }

        var records: [String: Record] = [:]
        var unreadable = 0
        for url in urls {
            guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else {
                unreadable += 1
                continue
            }
            for (lineNumber, line) in text.split(whereSeparator: \.isNewline).enumerated() {
                guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)),
                      let entry = object as? [String: Any],
                      let message = entry["message"] as? [String: Any],
                      message["role"] as? String == "assistant",
                      let usage = message["usage"] as? [String: Any],
                      let timestamp = Self.isoDate(entry["timestamp"], fractional: fractional, plain: plain)
                          ?? Self.isoDate(message["timestamp"], fractional: fractional, plain: plain),
                      timestamp <= now,
                      let counters = Self.counters(usage),
                      !Self.isIncompletePlaceholder(message: message, usage: usage, counters: counters)
                else { continue }

                let requestID = Self.string(entry["requestId"]) ?? Self.string(message["requestId"])
                let messageID = Self.string(message["id"])
                // A request can contain distinct assistant messages. Match the *pair*, not either
                // identity independently, so separate message usages are never collapsed.
                let key: String
                if requestID != nil || messageID != nil {
                    let request = requestID ?? ""
                    let message = messageID ?? ""
                    key = "r\(request.utf8.count):\(request)m\(message.utf8.count):\(message)"
                } else {
                    key = "file:\(url.path):\(lineNumber)"
                }
                let row = ClaudeTokenUsage(
                    timeCreated: timestamp,
                    model: Self.string(message["model"]) ?? "",
                    inputTokens: counters[0], outputTokens: counters[1],
                    cacheReadTokens: counters[2], cacheWriteTokens: counters[3])
                let record = Record(row: row, completeness: counters.filter { $0 > 0 }.count)
                records[key] = records[key].map { Self.preferred($0, record) } ?? record
            }
        }

        let rows = records.values.map(\.row).sorted { $0.timeCreated > $1.timeCreated }
        return ClaudeLocalUsage(rows: rows, fileCount: urls.count, unreadableFileCount: unreadable, updatedAt: now)
    }

    private struct Record {
        let row: ClaudeTokenUsage
        let completeness: Int
    }

    private static func preferred(_ lhs: Record, _ rhs: Record) -> Record {
        let chosen = rhs.completeness > lhs.completeness ? rhs : lhs
        return Record(
            row: ClaudeTokenUsage(
                timeCreated: max(lhs.row.timeCreated, rhs.row.timeCreated),
                model: chosen.row.model,
                inputTokens: max(lhs.row.inputTokens, rhs.row.inputTokens),
                outputTokens: max(lhs.row.outputTokens, rhs.row.outputTokens),
                cacheReadTokens: max(lhs.row.cacheReadTokens, rhs.row.cacheReadTokens),
                cacheWriteTokens: max(lhs.row.cacheWriteTokens, rhs.row.cacheWriteTokens)),
            completeness: max(lhs.completeness, rhs.completeness))
    }

    private static func counters(_ usage: [String: Any]) -> [Int]? {
        let input = integer(usage["input_tokens"])
        let output = integer(usage["output_tokens"])
        let read = integer(usage["cache_read_input_tokens"])
        let write: Int?
        if let aggregate = usage["cache_creation_input_tokens"] {
            write = integer(aggregate)
        } else {
            let short = integer((usage["cache_creation"] as? [String: Any])?["ephemeral_5m_input_tokens"])
            let long = integer((usage["cache_creation"] as? [String: Any])?["ephemeral_1h_input_tokens"])
            write = short != nil || long != nil
                ? PiTokenTotals.saturatedNonnegativeSum([short ?? 0, long ?? 0])
                : nil
        }
        guard input != nil || output != nil || read != nil || write != nil else { return nil }
        return [input ?? 0, output ?? 0, read ?? 0, write ?? 0]
    }

    private static func isIncompletePlaceholder(message: [String: Any], usage: [String: Any], counters: [Int]) -> Bool {
        guard let stopReason = message["stop_reason"], stopReason is NSNull else { return false }
        let outputPresent = integer(usage["output_tokens"]) ?? 0
        return outputPresent == 0 && counters[2] == 0 && counters[3] == 0
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double >= 0, double.rounded() == double else { return nil }
        return double >= Double(Int.max) ? Int.max : Int(double)
    }

    private static func isoDate(_ value: Any?, fractional: ISO8601DateFormatter, plain: ISO8601DateFormatter) -> Date? {
        guard let string = value as? String else { return nil }
        return fractional.date(from: string) ?? plain.date(from: string)
    }

    private static func string(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty else { return nil }
        return value
    }

    private static func isSymlink(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeSymbolicLink
    }

    private static func jsonlFiles(under directory: URL) throws -> [URL] {
        let children = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey], options: [])
        var result: [URL] = []
        for child in children {
            if isSymlink(child) { continue }
            let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if values?.isDirectory == true {
                result.append(contentsOf: try jsonlFiles(under: child))
            } else if values?.isRegularFile == true && child.pathExtension.lowercased() == "jsonl" {
                result.append(child)
            }
        }
        return result.sorted { $0.path < $1.path }
    }
}

enum ClaudeSessionsError: LocalizedError {
    case unreadableProjectsDirectory(String)

    var errorDescription: String? {
        switch self {
        case let .unreadableProjectsDirectory(path): return "Could not read Claude projects directory: \(path)"
        }
    }
}

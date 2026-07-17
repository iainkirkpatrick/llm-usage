import Foundation
import Darwin

private final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ chunk: Data, limit: Int? = nil) { lock.lock(); defer { lock.unlock() }; data.append(chunk); if let limit, data.count > limit { data = Data(data.suffix(limit)) } }
    func value() -> Data { lock.lock(); defer { lock.unlock() }; return data }
}

private struct NodeCodexOutput: Decodable, Sendable {
    struct Window: Decodable, Sendable { let usedPercent: Double; let remainingPercent: Double; let resetAt: Date? }
    struct ResetCredits: Decodable, Sendable {
        let availableCount: Int
        let credits: [Credit]?
        struct Credit: Decodable, Sendable {
            let id: String; let resetType: String?; let status: String?
            let grantedAt: Date?; let expiresAt: Date?; let title: String?; let description: String?
        }
    }
    struct Codex: Decodable, Sendable {
        let session: Window?; let weekly: Window?; let creditsRemaining: Double?
        let resetCredits: ResetCredits?; let source: String; let updatedAt: Date
    }
    let codex: Codex
}

private struct NodeConsumeOutput: Decodable, Sendable { let outcome: String }

struct CodexNodeBridge: Sendable {
    enum BridgeError: LocalizedError {
        case nodeNotFound([String]), scriptNotFound, launchFailed(String), timedOut, malformed(String?)
        var errorDescription: String? {
            switch self {
            case let .nodeNotFound(paths): return paths.isEmpty ? "Node.js executable was not found." : "Node.js executable was not found. Checked: \(paths.joined(separator: ", "))."
            case .scriptNotFound: return "Bundled llm-usage Node script was not found."
            case let .launchFailed(message): return "Could not start bundled Codex CLI: \(message)"
            case .timedOut: return "Bundled Codex CLI timed out."
            case let .malformed(details): return details.map { "Bundled Codex CLI returned malformed JSON: \($0)" } ?? "Bundled Codex CLI returned malformed JSON."
            }
        }
    }

    func fetch() async throws -> CodexSnapshot {
        try await self.runJSON(arguments: ["codex", "--json"]) { (output: NodeCodexOutput) in
            let codex = output.codex
            guard codex.session != nil || codex.weekly != nil else { throw BridgeError.malformed("no usage windows") }
            return CodexSnapshot(
                session: codex.session.map { RateWindow(usedPercent: $0.usedPercent, resetAt: $0.resetAt) },
                weekly: codex.weekly.map { RateWindow(usedPercent: $0.usedPercent, resetAt: $0.resetAt) },
                creditsRemaining: codex.creditsRemaining,
                resetCredits: codex.resetCredits.map { summary in
                    CodexResetCredits(availableCount: max(0, summary.availableCount), credits: (summary.credits ?? []).map {
                        CodexResetCredit(id: $0.id, resetType: $0.resetType, status: $0.status, grantedAt: $0.grantedAt,
                                         expiresAt: $0.expiresAt, title: $0.title, description: $0.description)
                    })
                }, sourceLabel: codex.source, updatedAt: codex.updatedAt
            )
        }
    }

    func consumeResetCredit(creditID: String, idempotencyKey: String) async throws -> String {
        try await self.runJSON(arguments: ["codex", "reset", "consume", "--credit-id", creditID,
                                           "--idempotency-key", idempotencyKey, "--json"]) { (output: NodeConsumeOutput) in output.outcome }
    }

    private func runJSON<T: Decodable & Sendable, Result: Sendable>(arguments: [String], transform: @escaping @Sendable (T) throws -> Result) async throws -> Result {
        try await Task.detached(priority: .utility) {
            let node = try self.nodePath()
            let script = try self.scriptURL()
            let result = try Self.runProcess(node: node, script: script, arguments: arguments)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .custom { decoder in
                let value = try decoder.singleValueContainer().decode(String.self)
                if let date = Self.iso8601Date(from: value) { return date }
                throw DecodingError.dataCorruptedError(in: try decoder.singleValueContainer(),
                                                       debugDescription: "Invalid ISO-8601 date: \(value)")
            }
            do { return try transform(decoder.decode(T.self, from: result.stdout)) }
            catch { throw BridgeError.malformed(result.stderr.isEmpty ? error.localizedDescription : result.stderr) }
        }.value
    }

    static func iso8601Date(from value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: value)
    }

    private func scriptURL() throws -> URL {
        let env = ProcessInfo.processInfo.environment
        if let override = env["LLM_BAR_NODE_SCRIPT_PATH"], !override.isEmpty {
            let url = URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
            if FileManager.default.isReadableFile(atPath: url.path) { return url }
        }
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("llm-usage.mjs"),
           FileManager.default.isReadableFile(atPath: bundled.path) { return bundled }
        if let bundled = Bundle.module.url(forResource: "llm-usage", withExtension: "mjs") { return bundled }
        // Development runs use the generated bundle before an app is packaged.
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("dist-node/llm-usage.mjs")
        guard FileManager.default.isReadableFile(atPath: source.path) else { throw BridgeError.scriptNotFound }
        return source
    }

    private func nodePath() throws -> String {
        let paths = Self.nodeCandidates()
        if let path = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) { return path }
        for shell in ["/bin/zsh", "/bin/bash"] where FileManager.default.isExecutableFile(atPath: shell) {
            if let data = try? Self.runProcess(node: shell, script: nil, arguments: ["-lc", "command -v node 2>/dev/null"], timeout: 5).stdout,
               let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        throw BridgeError.nodeNotFound(paths)
    }

    private static func nodeCandidates() -> [String] {
        let env = ProcessInfo.processInfo.environment, home = FileManager.default.homeDirectoryForCurrentUser.path
        var values = [env["LLM_BAR_NODE_PATH"], "\(home)/bin/node", "\(home)/.volta/bin/node", "/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"]
        values += (env["PATH"] ?? "").split(separator: ":").map { "\($0)/node" }
        var seen = Set<String>(); return values.compactMap { raw in
            guard let raw, !raw.isEmpty else { return nil }; let path = (raw as NSString).expandingTildeInPath
            guard seen.insert(path).inserted else { return nil }; return path
        }
    }

    private static func runProcess(node: String, script: URL?, arguments: [String], timeout: TimeInterval = 30) throws -> (stdout: Data, stderr: String) {
        let process = Process(), out = Pipe(), err = Pipe()
        let stdout = LockedData(), stderr = LockedData()
        process.executableURL = URL(fileURLWithPath: node)
        process.arguments = script.map { [$0.path] + arguments } ?? arguments
        process.standardOutput = out; process.standardError = err
        out.fileHandleForReading.readabilityHandler = { handle in let data = handle.availableData; if !data.isEmpty { stdout.append(data, limit: 1_000_000) } }
        err.fileHandleForReading.readabilityHandler = { handle in let data = handle.availableData; if !data.isEmpty { stderr.append(data, limit: 4000) } }
        do { try process.run() } catch { throw BridgeError.launchFailed(error.localizedDescription) }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { usleep(20_000) }
        if process.isRunning { process.terminate(); usleep(250_000); if process.isRunning { kill(process.processIdentifier, SIGKILL) }; process.waitUntilExit(); throw BridgeError.timedOut }
        out.fileHandleForReading.readabilityHandler = nil; err.fileHandleForReading.readabilityHandler = nil
        stdout.append(out.fileHandleForReading.readDataToEndOfFile(), limit: 1_000_000)
        stderr.append(err.fileHandleForReading.readDataToEndOfFile(), limit: 4000)
        let rawError = String(decoding: stderr.value(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let resultError = Self.redact(rawError)
        guard process.terminationStatus == 0 else { throw BridgeError.launchFailed(resultError.isEmpty ? "exit status \(process.terminationStatus)" : resultError) }
        return (stdout.value(), resultError)
    }

    private static func redact(_ text: String) -> String {
        text.replacingOccurrences(of: #"Bearer\s+\S+|eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+"#,
                                  with: "[redacted]", options: .regularExpression)
    }
}

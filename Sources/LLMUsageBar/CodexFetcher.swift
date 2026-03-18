import Foundation

private struct RPCRateLimitsResponse: Decodable {
    let rateLimits: RPCRateLimitSnapshot
}

private struct RPCRateLimitSnapshot: Decodable {
    let primary: RPCRateLimitWindow?
    let secondary: RPCRateLimitWindow?
    let credits: RPCCreditsSnapshot?
}

private struct RPCRateLimitWindow: Decodable {
    let usedPercent: Double
    let resetsAt: Int?
}

private struct RPCCreditsSnapshot: Decodable {
    let balance: String?
}

enum CodexFetchError: LocalizedError {
    case executableNotFound([String])
    case launchFailed(String)
    case malformedResponse(String?)
    case noData

    var errorDescription: String? {
        switch self {
        case let .executableNotFound(candidates):
            if candidates.isEmpty {
                return "Codex executable was not found."
            }
            return "Codex executable was not found. Checked: \(candidates.joined(separator: ", "))."
        case let .launchFailed(message):
            return "Could not start codex app-server: \(message)"
        case let .malformedResponse(details):
            guard let details, !details.isEmpty else {
                return "Codex returned malformed RPC data."
            }
            return "Codex returned malformed RPC data: \(details)"
        case .noData:
            return "Codex did not provide usage windows."
        }
    }
}

private final class CodexRPCClient: @unchecked Sendable {
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let stdoutStream: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private let stderrCollector = DataAccumulator()
    private var nextID: Int = 1

    private final class LineBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func appendAndDrain(_ chunk: Data) -> [Data] {
            self.lock.lock()
            defer { self.lock.unlock() }

            self.data.append(chunk)
            var lines: [Data] = []
            while let newline = self.data.firstIndex(of: 0x0A) {
                let line = Data(self.data[..<newline])
                self.data.removeSubrange(...newline)
                if !line.isEmpty {
                    lines.append(line)
                }
            }
            return lines
        }
    }

    private final class DataAccumulator: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func append(_ chunk: Data) {
            self.lock.lock()
            defer { self.lock.unlock() }
            self.data.append(chunk)
        }

        func text(limit: Int = 400) -> String? {
            self.lock.lock()
            defer { self.lock.unlock() }

            let string = String(decoding: self.data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !string.isEmpty else { return nil }
            guard string.count > limit else { return string }
            return String(string.prefix(limit)) + "…"
        }
    }

    init() throws {
        var continuation: AsyncStream<Data>.Continuation!
        self.stdoutStream = AsyncStream<Data> { continuation = $0 }
        self.continuation = continuation

        let candidates = Self.codexExecutableCandidates()
        guard let codexPath = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw CodexFetchError.executableNotFound(candidates)
        }

        self.process.executableURL = URL(fileURLWithPath: codexPath)
        self.process.arguments = ["-s", "read-only", "-a", "untrusted", "app-server"]
        self.process.standardInput = self.stdinPipe
        self.process.standardOutput = self.stdoutPipe
        self.process.standardError = self.stderrPipe

        do {
            try self.process.run()
        } catch {
            throw CodexFetchError.launchFailed(error.localizedDescription)
        }

        let buffer = LineBuffer()
        self.stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else {
                handle.readabilityHandler = nil
                return
            }
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                self.continuation.finish()
                return
            }
            for line in buffer.appendAndDrain(chunk) {
                self.continuation.yield(line)
            }
        }

        self.stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            self?.stderrCollector.append(chunk)
        }
    }

    deinit {
        self.shutdown()
    }

    func shutdown() {
        self.stdoutPipe.fileHandleForReading.readabilityHandler = nil
        self.stderrPipe.fileHandleForReading.readabilityHandler = nil
        self.continuation.finish()

        if self.process.isRunning {
            self.process.terminate()
        }
    }

    func initialize() async throws {
        _ = try await self.request(method: "initialize", params: [
            "clientInfo": ["name": "llm-usage-bar", "version": "0.1.0"],
        ])
        try self.sendNotification(method: "initialized")
    }

    func fetchRateLimits() async throws -> RPCRateLimitSnapshot {
        let response: RPCRateLimitsResponse = try await self.requestAndDecode(method: "account/rateLimits/read")
        return response.rateLimits
    }

    private static func codexExecutableCandidates() -> [String] {
        let env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        var candidates: [String] = []

        if let override = env["LLM_BAR_CODEX_PATH"]?.trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty {
            candidates.append((override as NSString).expandingTildeInPath)
        }

        candidates.append(contentsOf: [
            "\(home)/Applications/Assistants/codex/codex",
            "\(home)/bin/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
        ])

        if let path = env["PATH"], !path.isEmpty {
            for directory in path.split(separator: ":") {
                candidates.append(String(directory) + "/codex")
            }
        }

        var seen: Set<String> = []
        return candidates.compactMap { candidate in
            let normalized = URL(fileURLWithPath: candidate).standardizedFileURL.path
            guard seen.insert(normalized).inserted else { return nil }
            return normalized
        }
    }

    private func requestAndDecode<T: Decodable>(method: String) async throws -> T {
        let message = try await self.request(method: method)
        guard let result = message["result"] else {
            throw CodexFetchError.malformedResponse(self.stderrCollector.text())
        }
        let data = try JSONSerialization.data(withJSONObject: result)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func request(method: String, params: [String: Any]? = nil) async throws -> [String: Any] {
        let id = self.nextID
        self.nextID += 1

        try self.sendRequest(id: id, method: method, params: params)

        while true {
            let message = try await self.readNextMessage()

            if message["id"] == nil {
                continue
            }

            let responseID = self.jsonID(message["id"])
            guard responseID == id else { continue }

            if let errorObject = message["error"] as? [String: Any],
               let message = errorObject["message"] as? String
            {
                throw CodexFetchError.launchFailed(message)
            }

            return message
        }
    }

    private func sendRequest(id: Int, method: String, params: [String: Any]?) throws {
        var payload: [String: Any] = [
            "id": id,
            "method": method,
            "params": params ?? [:],
        ]
        if payload["params"] == nil {
            payload["params"] = [:]
        }
        let data = try JSONSerialization.data(withJSONObject: payload)
        self.stdinPipe.fileHandleForWriting.write(data)
        self.stdinPipe.fileHandleForWriting.write(Data([0x0A]))
    }

    private func sendNotification(method: String) throws {
        let payload: [String: Any] = [
            "method": method,
            "params": [:],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        self.stdinPipe.fileHandleForWriting.write(data)
        self.stdinPipe.fileHandleForWriting.write(Data([0x0A]))
    }

    private func jsonID(_ value: Any?) -> Int? {
        switch value {
        case let int as Int:
            int
        case let number as NSNumber:
            number.intValue
        case let string as String:
            Int(string)
        default:
            nil
        }
    }

    private func readNextMessage() async throws -> [String: Any] {
        for await line in self.stdoutStream {
            if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                return object
            }
        }
        throw CodexFetchError.malformedResponse(self.stderrCollector.text())
    }
}

struct CodexFetcher {
    func fetch() async throws -> CodexSnapshot {
        let client = try CodexRPCClient()
        defer { client.shutdown() }

        try await client.initialize()
        let limits = try await client.fetchRateLimits()

        let primary = limits.primary.map { self.makeWindow($0) }
        let secondary = limits.secondary.map { self.makeWindow($0) }
        let credits = Double(limits.credits?.balance ?? "")

        guard primary != nil || secondary != nil else {
            throw CodexFetchError.noData
        }

        return CodexSnapshot(
            session: primary,
            weekly: secondary,
            creditsRemaining: credits,
            updatedAt: Date()
        )
    }

    private func makeWindow(_ window: RPCRateLimitWindow) -> RateWindow {
        let resetAt = window.resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        return RateWindow(usedPercent: window.usedPercent, resetAt: resetAt)
    }
}

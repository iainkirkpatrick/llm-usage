import Foundation
import UserNotifications

private struct RPCRateLimitsResponse: Decodable {
    let rateLimits: RPCRateLimitSnapshot
    let rateLimitResetCredits: RPCRateLimitResetCredits?
}

private struct RPCRateLimitSnapshot: Decodable {
    let primary: RPCRateLimitWindow?
    let secondary: RPCRateLimitWindow?
    let credits: RPCCreditsSnapshot?
}

private struct RPCRateLimitResetCredits: Decodable {
    let availableCount: Int
    let credits: [RPCRateLimitResetCredit]?
}

private struct RPCRateLimitResetCredit: Decodable {
    let id: String
    let resetType: String?
    let status: String?
    let grantedAt: Int?
    let expiresAt: Int?
    let title: String?
    let description: String?
}

private struct RPCRateLimitResetCreditConsumeResponse: Decodable {
    let outcome: String
}

private struct RPCRateLimitWindow: Decodable {
    let usedPercent: Double
    let resetsAt: Int?
}

private struct RPCCreditsSnapshot: Decodable {
    let balance: String?
}

private struct PiCodexAuthHelperResponse: Decodable {
    let status: String?
    let accessToken: String?
    let chatgptAccountId: String?
    let chatgptPlanType: String?
}

private struct PiCodexAuthTokens: Sendable {
    let accessToken: String
    let chatgptAccountId: String
    let chatgptPlanType: String?
}

enum CodexFetchError: LocalizedError {
    case executableNotFound([String])
    case nodeNotFound([String])
    case launchFailed(String)
    case malformedResponse(String?)
    case noData
    case autoRedemptionDisabled

    var errorDescription: String? {
        switch self {
        case let .executableNotFound(candidates):
            if candidates.isEmpty {
                return "Codex executable was not found."
            }
            return "Codex executable was not found. Checked: \(candidates.joined(separator: ", "))."
        case let .nodeNotFound(candidates):
            if candidates.isEmpty {
                return "Node.js executable was not found for Pi-backed Codex auth."
            }
            return "Node.js executable was not found for Pi-backed Codex auth. Checked: \(candidates.joined(separator: ", "))."
        case let .launchFailed(message):
            return "Could not start codex app-server: \(message)"
        case let .malformedResponse(details):
            guard let details, !details.isEmpty else {
                return "Codex returned malformed RPC data."
            }
            return "Codex returned malformed RPC data: \(details)"
        case .noData:
            return "Codex did not provide usage windows."
        case .autoRedemptionDisabled:
            return "Automatic Codex reset redemption is no longer enabled."
        }
    }
}

private enum PiCodexHelperAvailability: Error {
    case unavailable
    case noAuth
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
    private let externalAuthTokenProvider: (@Sendable (_ previousAccountID: String?) async throws -> PiCodexAuthTokens)?

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

    init(
        codexPath: String,
        externalAuthTokenProvider: (@Sendable (_ previousAccountID: String?) async throws -> PiCodexAuthTokens)? = nil
    ) throws {
        var continuation: AsyncStream<Data>.Continuation!
        self.stdoutStream = AsyncStream<Data> { continuation = $0 }
        self.continuation = continuation
        self.externalAuthTokenProvider = externalAuthTokenProvider

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
            "capabilities": ["experimentalApi": true],
        ])
        try self.sendNotification(method: "initialized")
    }

    func loginWithChatGPTTokens(_ tokens: PiCodexAuthTokens) async throws {
        var params: [String: Any] = [
            "type": "chatgptAuthTokens",
            "accessToken": tokens.accessToken,
            "chatgptAccountId": tokens.chatgptAccountId,
        ]

        if let planType = tokens.chatgptPlanType {
            params["chatgptPlanType"] = planType
        } else {
            params["chatgptPlanType"] = NSNull()
        }

        _ = try await self.request(method: "account/login/start", params: params)
    }

    func fetchRateLimits() async throws -> RPCRateLimitsResponse {
        try await self.requestAndDecode(method: "account/rateLimits/read")
    }

    func consumeRateLimitResetCredit(idempotencyKey: String, creditID: String?) async throws -> String {
        var params: [String: Any] = ["idempotencyKey": idempotencyKey]
        if let creditID {
            params["creditId"] = creditID
        }
        let response: RPCRateLimitResetCreditConsumeResponse = try await self.requestAndDecode(
            method: "account/rateLimitResetCredit/consume",
            params: params
        )
        return response.outcome
    }

    static func resolvedCodexExecutablePath() throws -> String {
        let candidates = self.codexExecutableCandidates()
        guard let codexPath = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw CodexFetchError.executableNotFound(candidates)
        }
        return codexPath
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

    private func requestAndDecode<T: Decodable>(method: String, params: [String: Any]? = nil) async throws -> T {
        let message = try await self.request(method: method, params: params)
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

            if let method = message["method"] as? String,
               message["id"] != nil
            {
                try await self.handleServerRequest(method: method, message: message)
                continue
            }

            guard message["id"] != nil else { continue }

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

    private func handleServerRequest(method: String, message: [String: Any]) async throws {
        guard let requestID = self.jsonID(message["id"]) else { return }

        switch method {
        case "account/chatgptAuthTokens/refresh":
            guard let externalAuthTokenProvider else {
                try self.sendErrorResponse(id: requestID, message: "External auth refresh is not configured.")
                return
            }

            let params = message["params"] as? [String: Any]
            let previousAccountID = params?["previousAccountId"] as? String

            do {
                let tokens = try await externalAuthTokenProvider(previousAccountID)
                try self.sendResultResponse(id: requestID, result: [
                    "accessToken": tokens.accessToken,
                    "chatgptAccountId": tokens.chatgptAccountId,
                    "chatgptPlanType": tokens.chatgptPlanType ?? NSNull(),
                ])
            } catch {
                try self.sendErrorResponse(id: requestID, message: error.localizedDescription)
            }

        default:
            try self.sendErrorResponse(id: requestID, message: "Unsupported server request: \(method)")
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
        try self.sendPayload(payload)
    }

    private func sendNotification(method: String) throws {
        let payload: [String: Any] = [
            "method": method,
            "params": [:],
        ]
        try self.sendPayload(payload)
    }

    private func sendResultResponse(id: Int, result: [String: Any]) throws {
        try self.sendPayload([
            "id": id,
            "result": result,
        ])
    }

    private func sendErrorResponse(id: Int, message: String) throws {
        try self.sendPayload([
            "id": id,
            "error": [
                "code": -32603,
                "message": message,
            ],
        ])
    }

    private func sendPayload(_ payload: [String: Any]) throws {
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

private struct PiCodexAuthFetcher {
    func fetchTokens() throws -> PiCodexAuthTokens {
        let helperURL = try self.helperScriptURL()
        let nodePath = try self.resolvedNodeExecutablePath()

        let result = try self.runProcess(
            executablePath: nodePath,
            arguments: [helperURL.path],
            environment: ProcessInfo.processInfo.environment
        )

        let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stdout.isEmpty else {
            throw CodexFetchError.malformedResponse(result.stderr.isEmpty ? nil : result.stderr)
        }

        let data = Data(stdout.utf8)
        let decoded = try JSONDecoder().decode(PiCodexAuthHelperResponse.self, from: data)

        if decoded.status == "noAuth" {
            throw PiCodexHelperAvailability.noAuth
        }

        guard let accessToken = decoded.accessToken,
              !accessToken.isEmpty,
              let accountID = decoded.chatgptAccountId,
              !accountID.isEmpty
        else {
            throw CodexFetchError.malformedResponse(result.stderr.isEmpty ? nil : result.stderr)
        }

        return PiCodexAuthTokens(
            accessToken: accessToken,
            chatgptAccountId: accountID,
            chatgptPlanType: decoded.chatgptPlanType
        )
    }

    private func helperScriptURL() throws -> URL {
        if let url = Bundle.module.url(forResource: "codex-pi-helper.bundle", withExtension: "mjs") {
            return url
        }
        throw PiCodexHelperAvailability.unavailable
    }

    private func resolvedNodeExecutablePath() throws -> String {
        let candidates = self.nodeExecutableCandidates()
        if let direct = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return direct
        }

        if let shellResolved = self.nodeFromLoginShell(shell: "/bin/zsh") {
            return shellResolved
        }

        if let shellResolved = self.nodeFromLoginShell(shell: "/bin/bash") {
            return shellResolved
        }

        throw CodexFetchError.nodeNotFound(candidates)
    }

    private func nodeExecutableCandidates() -> [String] {
        let env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        var candidates: [String] = []
        if let override = env["LLM_BAR_NODE_PATH"]?.trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty {
            candidates.append((override as NSString).expandingTildeInPath)
        }

        candidates.append(contentsOf: [
            "\(home)/bin/node",
            "\(home)/.volta/bin/node",
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
            "/usr/bin/node",
        ])

        if let path = env["PATH"], !path.isEmpty {
            for directory in path.split(separator: ":") {
                candidates.append(String(directory) + "/node")
            }
        }

        var seen: Set<String> = []
        return candidates.compactMap { candidate in
            let normalized = URL(fileURLWithPath: candidate).standardizedFileURL.path
            guard seen.insert(normalized).inserted else { return nil }
            return normalized
        }
    }

    private func nodeFromLoginShell(shell: String) -> String? {
        guard FileManager.default.isExecutableFile(atPath: shell) else { return nil }

        do {
            let result = try self.runProcess(
                executablePath: shell,
                arguments: ["-lc", "command -v node 2>/dev/null || true"],
                environment: ProcessInfo.processInfo.environment
            )
            let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) else {
                return nil
            }
            return path
        } catch {
            return nil
        }
    }

    private func runProcess(
        executablePath: String,
        arguments: [String],
        environment: [String: String]
    ) throws -> (stdout: String, stderr: String, status: Int32) {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.environment = environment
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw CodexFetchError.launchFailed(error.localizedDescription)
        }

        process.waitUntilExit()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(decoding: stdoutData, as: UTF8.self)
        let stderr = String(decoding: stderrData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if process.terminationStatus != 0 {
            if stderr.contains("noAuth") || stderr.contains("Pi Codex OAuth is unavailable") {
                throw PiCodexHelperAvailability.noAuth
            }
            throw CodexFetchError.launchFailed(stderr.isEmpty ? "Helper exited with status \(process.terminationStatus)." : stderr)
        }

        return (stdout: stdout, stderr: stderr, status: process.terminationStatus)
    }
}

struct CodexFetcher {
    func fetch() async throws -> CodexSnapshot {
        let codexPath = try CodexRPCClient.resolvedCodexExecutablePath()
        let piAuthFetcher = PiCodexAuthFetcher()

        do {
            let initialTokens = try piAuthFetcher.fetchTokens()
            let client = try CodexRPCClient(
                codexPath: codexPath,
                externalAuthTokenProvider: { _ in
                    try piAuthFetcher.fetchTokens()
                }
            )
            defer { client.shutdown() }

            try await client.initialize()
            try await client.loginWithChatGPTTokens(initialTokens)
            let limits = try await client.fetchRateLimits()
            AppLog.info("Codex Pi-auth fetch succeeded")
            return try self.makeSnapshot(limits, sourceLabel: "Pi auth")
        } catch PiCodexHelperAvailability.noAuth {
            AppLog.info("Codex Pi auth unavailable; falling back to Codex CLI: no Pi Codex auth")
        } catch PiCodexHelperAvailability.unavailable {
            AppLog.info("Codex Pi auth unavailable; falling back to Codex CLI: bundled helper unavailable")
        } catch CodexFetchError.nodeNotFound(let candidates) {
            AppLog.info("Codex Pi auth unavailable; falling back to Codex CLI: Node.js executable was not found. Checked: \(candidates.joined(separator: ", ")).")
        } catch {
            AppLog.error("Codex Pi-auth fetch failed; not falling back to Codex CLI: \(error.localizedDescription)")
            throw error
        }

        do {
            let client = try CodexRPCClient(codexPath: codexPath)
            defer { client.shutdown() }

            try await client.initialize()
            let limits = try await client.fetchRateLimits()
            AppLog.info("Codex CLI fallback succeeded")
            return try self.makeSnapshot(limits, sourceLabel: "Codex CLI")
        } catch {
            AppLog.error("Codex CLI fallback failed: \(error.localizedDescription)")
            throw error
        }
    }

    func consumeResetCredit(creditID: String, idempotencyKey: String, automatic: Bool = false) async throws -> String {
        let codexPath = try CodexRPCClient.resolvedCodexExecutablePath()
        let piAuthFetcher = PiCodexAuthFetcher()

        do {
            let initialTokens = try piAuthFetcher.fetchTokens()
            let client = try CodexRPCClient(
                codexPath: codexPath,
                externalAuthTokenProvider: { _ in
                    try piAuthFetcher.fetchTokens()
                }
            )
            defer { client.shutdown() }

            try await client.initialize()
            try await client.loginWithChatGPTTokens(initialTokens)
            if automatic {
                let authorized = await Self.autoRedemptionStillAuthorized()
                if !authorized {
                    throw CodexFetchError.autoRedemptionDisabled
                }
            }
            let outcome = try await client.consumeRateLimitResetCredit(idempotencyKey: idempotencyKey, creditID: creditID)
            AppLog.info("Codex saved reset redemption completed via Pi auth: \(outcome)")
            return outcome
        } catch PiCodexHelperAvailability.noAuth {
            AppLog.info("Codex Pi auth unavailable for saved reset redemption; falling back to Codex CLI")
        } catch PiCodexHelperAvailability.unavailable {
            AppLog.info("Codex Pi auth helper unavailable for saved reset redemption; falling back to Codex CLI")
        } catch CodexFetchError.nodeNotFound {
            AppLog.info("Node.js unavailable for Pi-backed saved reset redemption; falling back to Codex CLI")
        } catch {
            AppLog.error("Codex Pi-auth saved reset redemption failed; not falling back to Codex CLI: \(error.localizedDescription)")
            throw error
        }

        let client = try CodexRPCClient(codexPath: codexPath)
        defer { client.shutdown() }
        try await client.initialize()
        if automatic {
            let authorized = await Self.autoRedemptionStillAuthorized()
            if !authorized {
                throw CodexFetchError.autoRedemptionDisabled
            }
        }
        let outcome = try await client.consumeRateLimitResetCredit(idempotencyKey: idempotencyKey, creditID: creditID)
        AppLog.info("Codex saved reset redemption completed via Codex CLI: \(outcome)")
        return outcome
    }

    private static func autoRedemptionStillAuthorized() async -> Bool {
        let config = ConfigStore.load()
        guard config.codexEnabled, config.autoRedeemExpiringCodexResets else { return false }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
    }

    private func makeSnapshot(_ response: RPCRateLimitsResponse, sourceLabel: String) throws -> CodexSnapshot {
        let limits = response.rateLimits
        let primary = limits.primary.map { self.makeWindow($0) }
        let secondary = limits.secondary.map { self.makeWindow($0) }
        let credits = Double(limits.credits?.balance ?? "")
        let resetCredits = response.rateLimitResetCredits.map { summary in
            CodexResetCredits(
                availableCount: max(0, summary.availableCount),
                credits: (summary.credits ?? []).map { credit in
                    CodexResetCredit(
                        id: credit.id,
                        resetType: credit.resetType,
                        status: credit.status,
                        grantedAt: credit.grantedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                        expiresAt: credit.expiresAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                        title: credit.title,
                        description: credit.description
                    )
                }
            )
        }

        guard primary != nil || secondary != nil else {
            throw CodexFetchError.noData
        }

        return CodexSnapshot(
            session: primary,
            weekly: secondary,
            creditsRemaining: credits,
            resetCredits: resetCredits,
            sourceLabel: sourceLabel,
            updatedAt: Date()
        )
    }

    private func makeWindow(_ window: RPCRateLimitWindow) -> RateWindow {
        let resetAt = window.resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        return RateWindow(usedPercent: window.usedPercent, resetAt: resetAt)
    }
}

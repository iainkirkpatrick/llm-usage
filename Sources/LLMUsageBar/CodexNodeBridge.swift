import Foundation
import Darwin

private final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ chunk: Data, limit: Int? = nil) { lock.lock(); defer { lock.unlock() }; data.append(chunk); if let limit, data.count > limit { data = Data(data.suffix(limit)) } }
    func value() -> Data { lock.lock(); defer { lock.unlock() }; return data }
}

enum ProcessTreeTermination {
    private static let pollInterval: useconds_t = 20_000
    private static let descendantKillWindow: TimeInterval = 0.25
    private static let rootKillWindow: TimeInterval = 0.25

    static func descendants(of root: pid_t) -> Set<pid_t> {
        Set(self.orderedDescendants(of: root, children: self.listChildren))
    }

    // The child lookup is injectable so the recursive traversal can be tested without starting
    // real processes. Descendants are ordered deepest-first, then by PID, so killing a current
    // snapshot is less likely to reparent a still-running child before it is checked.
    static func orderedDescendants(
        of root: pid_t,
        children: (pid_t) -> [pid_t]) -> [pid_t]
    {
        guard root > 0 else { return [] }
        var pending: [(pid: pid_t, depth: Int)] = [(root, 0)]
        var next = 0
        var seen = Set([root])
        var depths: [pid_t: Int] = [:]

        while next < pending.count {
            let item = pending[next]
            next += 1
            for child in children(item.pid).filter({ $0 > 0 && $0 != root }).sorted() {
                guard seen.insert(child).inserted else { continue }
                depths[child] = item.depth + 1
                pending.append((child, item.depth + 1))
            }
        }

        return depths.keys.sorted {
            let leftDepth = depths[$0] ?? 0
            let rightDepth = depths[$1] ?? 0
            if leftDepth != rightDepth { return leftDepth > rightDepth }
            return $0 < $1
        }
    }

    // Kept as a small injectable surface for callers/tests that only need set membership.
    static func descendants(of root: pid_t, children: (pid_t) -> [pid_t]) -> Set<pid_t> {
        Set(self.orderedDescendants(of: root, children: children))
    }

    // The root is passed as its Foundation Process object rather than as a bare PID. A PID is
    // only safe to use for a descendant while a fresh traversal still verifies its ownership;
    // the Process object supplies the ownership/liveness check for the root itself.
    static func terminate(root: Process, grace: TimeInterval) {
        let rootPID = root.processIdentifier
        guard rootPID > 0, root.isRunning else { return }

        let termDeadline = Date().addingTimeInterval(max(0, grace))
        while root.isRunning && Date() < termDeadline {
            self.signalCurrentDescendants(of: root, signal: SIGTERM)
            guard root.isRunning else { return }
            usleep(self.pollInterval)
        }

        // Never carry a descendant PID from the grace-period snapshot into this phase. Every
        // SIGKILL candidate is enumerated and identity-checked again while the root is live.
        let killDeadline = Date().addingTimeInterval(self.descendantKillWindow)
        while root.isRunning && Date() < killDeadline {
            let current = self.currentDescendants(of: rootPID)
            guard !current.isEmpty else { break }
            var signaled = false
            for candidate in current {
                guard root.isRunning else { return }
                guard self.isCurrentDescendant(candidate, rootPID: rootPID), root.isRunning else {
                    continue
                }
                self.signal(candidate.identity.pid, SIGKILL)
                signaled = true
            }
            guard root.isRunning else { return }
            if !signaled { usleep(self.pollInterval) }
        }

        // Do not signal a reparented child after the root has gone away. The root itself is
        // terminated through Process ownership, with a narrowly guarded raw fallback only while
        // Foundation still reports that same root Process as running.
        guard root.isRunning else { return }
        root.terminate()
        let rootDeadline = Date().addingTimeInterval(self.rootKillWindow)
        while root.isRunning && Date() < rootDeadline { usleep(self.pollInterval) }
        guard root.isRunning else { return }
        _ = kill(root.processIdentifier, SIGKILL)
    }

    private struct ProcessIdentity: Equatable {
        let pid: pid_t
        let startSeconds: UInt64
        let startMicroseconds: UInt64
    }

    private struct Descendant {
        let identity: ProcessIdentity
        let depth: Int
    }

    private static func signalCurrentDescendants(of root: Process, signal: Int32) {
        let rootPID = root.processIdentifier
        let current = self.currentDescendants(of: rootPID)
        for candidate in current {
            guard root.isRunning else { return }
            // Re-enumerate immediately before each signal. This rejects both a reparented
            // process and a PID that exited and was reused since the prior traversal.
            guard self.isCurrentDescendant(candidate, rootPID: rootPID), root.isRunning else {
                continue
            }
            self.signal(candidate.identity.pid, signal)
        }
    }

    private static func isCurrentDescendant(_ candidate: Descendant, rootPID: pid_t) -> Bool {
        self.currentDescendants(of: rootPID).contains {
            $0.identity == candidate.identity
        }
    }

    private static func currentDescendants(of root: pid_t) -> [Descendant] {
        guard root > 0 else { return [] }
        var pending: [(pid: pid_t, depth: Int)] = [(root, 0)]
        var next = 0
        var seen = Set([root])
        var descendants: [Descendant] = []

        while next < pending.count {
            let item = pending[next]
            next += 1
            for child in self.listChildren(of: item.pid) where child > 0 && child != root {
                guard seen.insert(child).inserted,
                      let info = self.processInfo(for: child),
                      info.parent == item.pid
                else { continue }
                descendants.append(Descendant(identity: info.identity, depth: item.depth + 1))
                pending.append((child, item.depth + 1))
            }
        }

        return descendants.sorted {
            if $0.depth != $1.depth { return $0.depth > $1.depth }
            return $0.identity.pid < $1.identity.pid
        }
    }

    private static func signal(_ pid: pid_t, _ signal: Int32) {
        guard pid > 0 else { return }
        _ = kill(pid, signal)
    }

    private static func processInfo(for pid: pid_t) -> (identity: ProcessIdentity, parent: pid_t)? {
        var info = proc_bsdinfo()
        let size = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(
                pid,
                PROC_PIDTBSDINFO,
                0,
                pointer,
                Int32(MemoryLayout<proc_bsdinfo>.stride))
        }
        guard size == Int32(MemoryLayout<proc_bsdinfo>.stride),
              pid == pid_t(info.pbi_pid)
        else { return nil }
        return (
            identity: ProcessIdentity(
                pid: pid,
                startSeconds: info.pbi_start_tvsec,
                startMicroseconds: info.pbi_start_tvusec),
            parent: pid_t(info.pbi_ppid))
    }

    private static func listChildren(of parent: pid_t) -> [pid_t] {
        var capacity = 64
        for _ in 0..<8 {
            var buffer = Array(repeating: pid_t.zero, count: capacity)
            let count = buffer.withUnsafeMutableBufferPointer { buffer in
                proc_listchildpids(parent, buffer.baseAddress, Int32(buffer.count * MemoryLayout<pid_t>.stride))
            }
            guard count > 0 else { return [] }
            if count < capacity { return Array(buffer.prefix(Int(count))).sorted() }
            capacity *= 2
        }
        return []
    }
}

private final class BridgeProcessControl: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func install(process: Process) {
        self.lock.lock()
        self.process = process
        let shouldCancel = self.cancelled
        self.lock.unlock()
        if shouldCancel { ProcessTreeTermination.terminate(root: process, grace: 2) }
    }

    func cancel() {
        self.lock.lock()
        self.cancelled = true
        let process = self.process
        self.lock.unlock()
        if let process { ProcessTreeTermination.terminate(root: process, grace: 2) }
    }

    var wasCancelled: Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.cancelled
    }

    func clear() {
        self.lock.lock()
        self.process = nil
        self.lock.unlock()
    }
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
        let email: String?; let planType: String?
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

    func fetchManaged(codexHome: URL) async throws -> CodexSnapshot {
        try await self.fetch(arguments: ["codex", "--codex-home", codexHome.path, "--json"])
    }

    func consumeResetCredit(creditID: String, idempotencyKey: String, codexHome: URL) async throws -> String {
        var arguments = ["codex", "reset", "consume", "--credit-id", creditID,
                         "--idempotency-key", idempotencyKey]
        arguments += ["--codex-home", codexHome.path, "--json"]
        return try await self.runJSON(arguments: arguments) { (output: NodeConsumeOutput) in output.outcome }
    }

    private func fetch(arguments: [String]) async throws -> CodexSnapshot {
        try await self.runJSON(arguments: arguments) { (output: NodeCodexOutput) in
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
                }, sourceLabel: codex.source, updatedAt: codex.updatedAt,
                email: codex.email, planType: codex.planType
            )
        }
    }

    static func resolveCodexExecutable() -> String? {
        self.codexExecutableCandidates().first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    }

    static func codexExecutableCandidates() -> [String] {
        let env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var raw = [
            env["LLM_BAR_CODEX_PATH"],
            "\(home)/Applications/Assistants/codex/codex",
            "\(home)/bin/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "/usr/bin/codex",
        ]
        raw += (env["PATH"] ?? "").split(separator: ":").map { "\($0)/codex" }
        var seen = Set<String>()
        return raw.compactMap { value in
            guard let value, !value.isEmpty else { return nil }
            let path = (value as NSString).expandingTildeInPath
            guard seen.insert(path).inserted else { return nil }
            return path
        }
    }

    private func runJSON<T: Decodable & Sendable, Result: Sendable>(arguments: [String], transform: @escaping @Sendable (T) throws -> Result) async throws -> Result {
        let control = BridgeProcessControl()
        return try await withTaskCancellationHandler(operation: {
            try await Task.detached(priority: .utility) {
                let node = try self.nodePath(control: control)
                let script = try self.scriptURL()
                let result = try Self.runProcess(
                    node: node,
                    script: script,
                    arguments: arguments,
                    control: control)
                if control.wasCancelled { throw CancellationError() }
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
        }, onCancel: {
            control.cancel()
        })
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

    private func nodePath(control: BridgeProcessControl? = nil) throws -> String {
        let paths = Self.nodeCandidates()
        if let path = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) { return path }
        for shell in ["/bin/zsh", "/bin/bash"] where FileManager.default.isExecutableFile(atPath: shell) {
            if let data = try? Self.runProcess(node: shell, script: nil, arguments: ["-lc", "command -v node 2>/dev/null"], timeout: 5, control: control).stdout,
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

    private static func runProcess(
        node: String,
        script: URL?,
        arguments: [String],
        timeout: TimeInterval = 30,
        control: BridgeProcessControl? = nil) throws -> (stdout: Data, stderr: String)
    {
        let process = Process()
        let out = Pipe()
        let err = Pipe()
        let stdout = LockedData()
        let stderr = LockedData()
        let processControl = control ?? BridgeProcessControl()
        process.executableURL = URL(fileURLWithPath: node)
        process.arguments = script.map { [$0.path] + arguments } ?? arguments
        process.standardOutput = out
        process.standardError = err
        out.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { stdout.append(data, limit: 1_000_000) }
        }
        err.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { stderr.append(data, limit: 4_000) }
        }

        guard !processControl.wasCancelled else { throw CancellationError() }
        do {
            try process.run()
        } catch {
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            processControl.clear()
            throw BridgeError.launchFailed(error.localizedDescription)
        }

        // The bundled Node process launches the Codex app-server. Track the process tree directly;
        // Foundation's Process.run() does not allow reliably creating a process group after exec.
        processControl.install(process: process)
        defer {
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            processControl.clear()
        }

        let deadline = Date().addingTimeInterval(max(1, timeout))
        var timedOut = false
        while process.isRunning {
            if processControl.wasCancelled { break }
            if Date() >= deadline {
                timedOut = true
                break
            }
            usleep(20_000)
        }

        if processControl.wasCancelled || timedOut {
            ProcessTreeTermination.terminate(root: process, grace: 2)
        }
        process.waitUntilExit()

        // Drain anything written before termination while the handlers are still attached. Both
        // streams are capped, so a noisy failed CLI cannot grow the app's memory without bound.
        stdout.append(out.fileHandleForReading.readDataToEndOfFile(), limit: 1_000_000)
        stderr.append(err.fileHandleForReading.readDataToEndOfFile(), limit: 4_000)
        let rawError = String(decoding: stderr.value(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let resultError = Self.redact(rawError)

        if processControl.wasCancelled { throw CancellationError() }
        if timedOut { throw BridgeError.timedOut }
        guard process.terminationStatus == 0 else {
            throw BridgeError.launchFailed(resultError.isEmpty ? "exit status \(process.terminationStatus)" : resultError)
        }
        return (stdout.value(), resultError)
    }

    private static func redact(_ text: String) -> String {
        text.replacingOccurrences(of: #"Bearer\s+\S+|eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+"#,
                                  with: "[redacted]", options: .regularExpression)
    }
}

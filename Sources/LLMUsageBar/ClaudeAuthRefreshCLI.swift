import Darwin
import Foundation

/// Deliberately contains neither underlying errors nor Claude's terminal output.
enum ClaudeAuthRefreshCLIError: Error, LocalizedError, Equatable {
    case unavailable, launchFailed, timedOut, failed, setupRequired

    var errorDescription: String? {
        switch self {
        case .unavailable: return "Claude Code CLI is unavailable."
        case .launchFailed: return "Could not start Claude Code credential refresh."
        case .timedOut: return "Claude Code credential refresh timed out. Open this profile in Claude Code or sign in again."
        case .setupRequired: return "Claude Code needs interactive setup or workspace approval. Use Copy refresh setup command for this profile, finish setup in your terminal, then refresh again."
        case .failed: return "Claude Code did not refresh credentials."
        }
    }
}

private final class ClaudeRefreshCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

/// Launch and teardown are serialized with app shutdown, so an opaque interactive
/// CLI cannot outlive LLM Usage when the user quits during recovery.
private final class ClaudeRefreshProcesses: @unchecked Sendable {
    private let lock = NSLock()
    private var stopping = false
    private struct Entry {
        let process: Process
        let group: pid_t
    }
    private var processes: [UUID: Entry] = [:]

    func launch(_ process: Process) throws -> UUID {
        lock.lock(); defer { lock.unlock() }
        guard !stopping else { throw CancellationError() }
        do { try process.run() } catch { throw ClaudeAuthRefreshCLIError.launchFailed }
        let pid = process.processIdentifier
        // NSTask launches a separate process group on macOS. Verify that boundary
        // rather than ever signaling the app's group. The group remains identifiable
        // if a launcher exits before its background Claude child.
        if getpgid(pid) != pid { _ = setpgid(pid, pid) }
        guard getpgid(pid) == pid || kill(-pid, 0) == 0 else {
            ProcessTreeTermination.terminate(root: process, grace: 0.1)
            process.waitUntilExit()
            throw ClaudeAuthRefreshCLIError.launchFailed
        }
        let id = UUID()
        processes[id] = Entry(process: process, group: pid)
        return id
    }

    func finish(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        guard let entry = processes.removeValue(forKey: id) else { return }
        terminate(entry)
    }

    func stopAll() {
        lock.lock(); defer { lock.unlock() }
        stopping = true
        for entry in processes.values { terminate(entry) }
        processes.removeAll()
    }

    private func terminate(_ entry: Entry) {
        // Snapshot-based tree cleanup handles live-root children first. Group cleanup
        // also covers a wrapper that already exited, and does not depend on parentage.
        ProcessTreeTermination.terminate(root: entry.process, grace: 0.1)
        _ = kill(-entry.group, SIGKILL)
        entry.process.waitUntilExit()
    }
}

/// Delegates refresh to Claude Code's interactive status command; never calls an OAuth endpoint.
enum ClaudeAuthRefreshCLI {
    private static let processes = ClaudeRefreshProcesses()
    static func stopAll() { processes.stopAll() }
    static func refresh(profile: ClaudeAccountProfile,
                        isRefreshed: @escaping @Sendable () -> Bool) async throws {
        try Task.checkCancellation()
        let environment = ProcessInfo.processInfo.environment
        guard let executable = ClaudeCLI.resolveExecutable(environment: environment) else {
            throw ClaudeAuthRefreshCLIError.unavailable
        }
        try await refresh(profile: profile, executable: executable, environment: environment,
                          timeout: 15, workingDirectory: prepareWorkspace(profile: profile), isRefreshed: isRefreshed)
    }

    /// Stable and isolated so a user can approve this workspace once; never a repository.
    static func prepareWorkspace(profile: ClaudeAccountProfile) throws -> URL {
        try ConfigStore.ensureAppDirectory()
        let root = ConfigStore.appDirectoryURL.appendingPathComponent("claude-refresh-probes", isDirectory: true)
        try AppOwnedPathSafety.ensureDirectory(at: root)
        let directory = root.appendingPathComponent(ClaudeCredentials.serviceName(for: profile), isDirectory: true)
        try AppOwnedPathSafety.ensureDirectory(at: directory)
        return directory
    }

    /// Tests supply their own executable and environment; they never resolve the user's CLI.
    static func refresh(profile: ClaudeAccountProfile, executable: URL,
                        environment: [String: String], timeout: TimeInterval, workingDirectory: URL? = nil,
                        isRefreshed: @escaping @Sendable () -> Bool) async throws {
        let cancellation = ClaudeRefreshCancellation()
        try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            try await Task.detached(priority: .userInitiated) {
                try run(profile: profile, executable: executable, environment: environment,
                        timeout: timeout, workingDirectory: workingDirectory,
                        cancellation: cancellation, isRefreshed: isRefreshed)
            }.value
        }, onCancel: { cancellation.cancel() })
    }

    private static func run(profile: ClaudeAccountProfile, executable: URL,
                            environment: [String: String], timeout: TimeInterval, workingDirectory: URL?,
                            cancellation: ClaudeRefreshCancellation,
                            isRefreshed: @Sendable () -> Bool) throws {
        if cancellation.isCancelled { throw CancellationError() }
        guard executable.isFileURL, executable.path.hasPrefix("/"),
              timeout.isFinite, timeout > 0 else { throw ClaudeAuthRefreshCLIError.launchFailed }
        if let raw = profile.configDirectory,
           (!(raw as NSString).expandingTildeInPath.hasPrefix("/") || raw.contains("\0")) {
            throw ClaudeAuthRefreshCLIError.launchFailed
        }

        // Production uses a stable app-owned probe workspace. Fixtures use mkdtemp,
        // without touching the user's app directory or any repository.
        let directory: String
        if let workingDirectory {
            directory = workingDirectory.path
        } else {
            var template = Array(FileManager.default.temporaryDirectory
                .appendingPathComponent("llm-usage-claude-refresh-XXXXXX").path.utf8CString)
            guard let created = template.withUnsafeMutableBufferPointer({ buffer -> String? in
                guard let path = mkdtemp(buffer.baseAddress!) else { return nil }
                return String(cString: path)
            }) else { throw ClaudeAuthRefreshCLIError.launchFailed }
            directory = created
        }
        defer { if workingDirectory == nil { try? FileManager.default.removeItem(atPath: directory) } }

        var master: Int32 = -1
        var slave: Int32 = -1
        var size = winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&master, &slave, nil, nil, &size) == 0 else {
            throw ClaudeAuthRefreshCLIError.launchFailed
        }
        defer { close(master) }
        let terminal = FileHandle(fileDescriptor: slave, closeOnDealloc: true)
        defer { try? terminal.close() }
        guard fcntl(master, F_SETFD, FD_CLOEXEC) != -1,
              fcntl(slave, F_SETFD, FD_CLOEXEC) != -1,
              fcntl(master, F_SETFL, O_NONBLOCK) != -1 else {
            throw ClaudeAuthRefreshCLIError.launchFailed
        }

        let process = Process()
        process.executableURL = executable
        // /status is a local slash command, not a chat/model request. --tools "" also
        // removes the available built-ins (an empty allowlist alone is insufficient).
        // Browser detection can touch TCC-protected Chrome data even for /status;
        // disable integration explicitly, independently of the user’s saved defaults.
        process.arguments = ["--allowed-tools", "", "--tools", "", "--strict-mcp-config",
                             "--settings", "{\"disableAllHooks\":true,\"remoteControlAtStartup\":false}",
                             "--no-chrome", "/status"]
        process.currentDirectoryURL = URL(fileURLWithPath: directory, isDirectory: true)
        var childEnvironment = ClaudeCLI.loginEnvironment(profile: profile, inherited: environment)
        childEnvironment["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] = "1"
        process.environment = childEnvironment
        process.standardInput = terminal
        process.standardOutput = terminal
        process.standardError = terminal
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        let processID = try processes.launch(process)
        // On success too: an interactive CLI is normally still running.
        defer { processes.finish(processID) }
        try? terminal.close()

        // Retain only a bounded in-memory tail to recognize setup/trust barriers, never
        // as success evidence. No output is logged or persisted. Bound work per poll.
        var tail = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            if cancellation.isCancelled { throw CancellationError() }
            for _ in 0..<8 {
                let count = buffer.withUnsafeMutableBytes { Darwin.read(master, $0.baseAddress, $0.count) }
                if count <= 0 { break }
                tail.append(contentsOf: buffer.prefix(count))
                tail = Data(tail.suffix(8192))
            }
            // A real fresh credential wins even if setup appears afterwards. Never
            // answer these prompts automatically, including in the probe workspace.
            if isRefreshed() { return }
            let screen = String(decoding: tail, as: UTF8.self)
                .replacingOccurrences(of: "\u{001B}\\[[0-?]*[ -/]*[@-~]", with: "", options: .regularExpression)
                .lowercased().filter { $0.isLetter || $0.isNumber }
            if screen.contains("choosethetextstyle") || screen.contains("doyoutrustthefilesinthisfolder") {
                throw ClaudeAuthRefreshCLIError.setupRequired
            }
            if !process.isRunning {
                guard process.terminationReason == .exit, process.terminationStatus == 0 else {
                    throw ClaudeAuthRefreshCLIError.failed
                }
                if isRefreshed() { return }
                throw ClaudeAuthRefreshCLIError.failed
            }
            if ProcessInfo.processInfo.systemUptime >= deadline { throw ClaudeAuthRefreshCLIError.timedOut }
            // Never send Enter, accept trust, start login, or answer any interactive prompt.
            usleep(20_000)
        }
    }
}

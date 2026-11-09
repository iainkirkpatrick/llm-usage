import CoreFoundation
import Darwin
import Foundation

/// Owner-CLI data, not authenticated account identity. Capture time does not
/// establish when Claude measured (or cached) these windows.
struct ClaudeCodeStructuredUsage: Sendable {
    let session: RateWindow?
    let weekly: RateWindow?
    let capturedAt: Date
}

enum ClaudeCodeStructuredUsageReaderError: Error, LocalizedError, Equatable {
    case launchFailed, timedOut, outputLimit, invalidOutput, unsupported, requestFailed, interactiveRequest

    var errorDescription: String? {
        switch self {
        case .launchFailed: return "Could not start the Claude Code usage reader."
        case .timedOut: return "Claude Code usage reading timed out."
        case .outputLimit: return "Claude Code usage output exceeded its safety limit."
        case .invalidOutput: return "Claude Code returned unrecognized usage output."
        case .unsupported: return "Claude Code structured usage is unavailable."
        case .requestFailed: return "Claude Code could not read usage."
        case .interactiveRequest: return "Claude Code requested interaction. Complete setup separately."
        }
    }
}

private final class ClaudeStructuredUsageCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func check() throws {
        lock.lock(); let value = cancelled; lock.unlock()
        if value { throw CancellationError() }
    }
}

/// Transport-only fixture seam. The caller owns path/environment sanitization and
/// pre/post identity checks. Never adds privacy overrides, prompts, or credentials.
enum ClaudeCodeStructuredUsageReader {
    private static let outputLimit = 1_048_576
    private static let frameLimit = 262_144

    static func parse(_ data: Data, capturedAt: Date) throws -> ClaudeCodeStructuredUsage {
        guard data.count <= frameLimit,
              let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeCodeStructuredUsageReaderError.invalidOutput
        }
        guard let available = body["rate_limits_available"] as? NSNumber,
              CFGetTypeID(available) == CFBooleanGetTypeID() else {
            throw ClaudeCodeStructuredUsageReaderError.invalidOutput
        }
        guard available.boolValue else { throw ClaudeCodeStructuredUsageReaderError.unsupported }
        guard let rates = body["rate_limits"] as? [String: Any] else {
            throw ClaudeCodeStructuredUsageReaderError.invalidOutput
        }
        func window(_ value: Any?, percentKey: String = "utilization") throws -> RateWindow? {
            guard let value, !(value is NSNull) else { return nil }
            guard let object = value as? [String: Any],
                  let number = object[percentKey] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite, (0...100).contains(number.doubleValue) else {
                throw ClaudeCodeStructuredUsageReaderError.invalidOutput
            }
            let reset: Date?
            if let raw = object["resets_at"], !(raw is NSNull) {
                guard let date = ClaudeUsageFetcher.date(raw) else {
                    throw ClaudeCodeStructuredUsageReaderError.invalidOutput
                }
                reset = date
            } else { reset = nil }
            return RateWindow(usedPercent: number.doubleValue, resetAt: reset)
        }
        var session = try window(rates["five_hour"])
        let sevenDay = try window(rates["seven_day"])
        let oauth = try window(rates["seven_day_oauth_apps"])
        var weekly = sevenDay ?? oauth
        if let raw = rates["limits"], !(raw is NSNull) {
            guard let limits = raw as? [[String: Any]] else {
                throw ClaudeCodeStructuredUsageReaderError.invalidOutput
            }
            for limit in limits {
                switch limit["kind"] as? String {
                case "session":
                    let candidate = try window(limit, percentKey: "percent")
                    session = session ?? candidate
                case "weekly_all":
                    let candidate = try window(limit, percentKey: "percent")
                    weekly = weekly ?? candidate
                default: break
                }
            }
        }
        guard session != nil || weekly != nil else { throw ClaudeCodeStructuredUsageReaderError.unsupported }
        return ClaudeCodeStructuredUsage(session: session, weekly: weekly, capturedAt: capturedAt)
    }

    static func fetch(profile: ClaudeAccountProfile, executable: URL, environment: [String: String],
                      workingDirectory: URL, timeout: TimeInterval) async throws -> ClaudeCodeStructuredUsage {
        // Profile is intentionally not used to resolve or mutate the provided inputs.
        let cancellation = ClaudeStructuredUsageCancellation()
        let result = try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await Task.detached(priority: .userInitiated) {
                try run(executable: executable, environment: environment, directory: workingDirectory,
                        timeout: timeout, cancellation: cancellation)
            }.value
        }, onCancel: { cancellation.cancel() })
        try Task.checkCancellation()
        return result
    }

    private static func run(executable: URL, environment: [String: String], directory: URL,
                            timeout: TimeInterval, cancellation: ClaudeStructuredUsageCancellation) throws -> ClaudeCodeStructuredUsage {
        guard executable.isFileURL, directory.isFileURL, timeout.isFinite, timeout > 0 else {
            throw ClaudeCodeStructuredUsageReaderError.launchFailed
        }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        func check() throws {
            try cancellation.check()
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw ClaudeCodeStructuredUsageReaderError.timedOut
            }
        }
        try check()
        let process = Process()
        process.executableURL = executable
        process.currentDirectoryURL = directory
        process.environment = environment
        process.arguments = ["--print", "--input-format", "stream-json", "--output-format", "stream-json",
                             "--verbose", "--tools", "", "--allowed-tools", "", "--strict-mcp-config",
                             "--safe-mode", "--no-chrome", "--no-session-persistence", "--settings",
                             "{\"disableAllHooks\":true,\"remoteControlAtStartup\":false}"]
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin; process.standardOutput = stdout; process.standardError = stderr
        let input = stdin.fileHandleForWriting, out = stdout.fileHandleForReading, err = stderr.fileHandleForReading
        defer {
            for handle in [input, out, err, stdin.fileHandleForReading, stdout.fileHandleForWriting, stderr.fileHandleForWriting] {
                try? handle.close()
            }
        }
        for handle in [input, out, err] {
            guard fcntl(handle.fileDescriptor, F_SETFL, O_NONBLOCK) != -1 else {
                throw ClaudeCodeStructuredUsageReaderError.launchFailed
            }
        }
        // Pipe writes must fail with EPIPE, not terminate the hosting application.
        guard fcntl(input.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
            throw ClaudeCodeStructuredUsageReaderError.launchFailed
        }
        let owner: ClaudeOwnerProbeProcess
        do { owner = try ClaudeOwnerProbeProcess(process) }
        catch { throw ClaudeCodeStructuredUsageReaderError.launchFailed }
        return try withExtendedLifetime(owner) {
            try? stdin.fileHandleForReading.close()
            try? stdout.fileHandleForWriting.close(); try? stderr.fileHandleForWriting.close()
            let initializeID = UUID().uuidString, usageID = UUID().uuidString
            func send(id: String, request: [String: Any]) throws {
                let frame = try JSONSerialization.data(withJSONObject: ["type": "control_request", "request_id": id, "request": request]) + Data([10])
                // These two small frames fit within PIPE_BUF; never queue prompts.
                guard frame.count < 4096 else { throw ClaudeCodeStructuredUsageReaderError.invalidOutput }
                try frame.withUnsafeBytes { bytes in
                    while true {
                        try check()
                        let count = Darwin.write(input.fileDescriptor, bytes.baseAddress!, bytes.count)
                        if count == bytes.count { return }
                        if count == -1 && errno == EINTR { continue }
                        if count == -1 && (errno == EAGAIN || errno == EWOULDBLOCK) { usleep(5_000); continue }
                        throw ClaudeCodeStructuredUsageReaderError.requestFailed
                    }
                }
            }
            try send(id: initializeID, request: ["subtype": "initialize", "hooks": [String: String](),
                                               "sdkMcpServers": [String](), "promptSuggestions": false,
                                               "agentProgressSummaries": false])
            var initialized = false, result: ClaudeCodeStructuredUsage?
            var pending = Data(), total = 0, notifications = 0
            var buffer = [UInt8](repeating: 0, count: 8192)
            func consume(_ line: Data) throws {
                guard !line.isEmpty, line.count <= frameLimit,
                      let frame = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let type = frame["type"] as? String else {
                    throw ClaudeCodeStructuredUsageReaderError.invalidOutput
                }
                if type == "control_request" { throw ClaudeCodeStructuredUsageReaderError.interactiveRequest }
                if type == "system" {
                    // Only known non-usage notifications; never parse their text.
                    guard let subtype = frame["subtype"] as? String,
                          ["init", "status", "hook_started", "hook_progress", "hook_response", "task_started", "task_progress", "task_notification"].contains(subtype) else {
                        throw ClaudeCodeStructuredUsageReaderError.invalidOutput
                    }
                    notifications += 1
                    guard notifications <= 128 else { throw ClaudeCodeStructuredUsageReaderError.outputLimit }
                    return
                }
                guard type == "control_response", let response = frame["response"] as? [String: Any],
                      let id = response["request_id"] as? String,
                      id == (initialized ? usageID : initializeID), result == nil,
                      let subtype = response["subtype"] as? String else {
                    throw ClaudeCodeStructuredUsageReaderError.invalidOutput
                }
                guard subtype == "success" else {
                    if subtype == "error" { throw ClaudeCodeStructuredUsageReaderError.requestFailed }
                    throw ClaudeCodeStructuredUsageReaderError.invalidOutput
                }
                guard let body = response["response"] as? [String: Any] else {
                    throw ClaudeCodeStructuredUsageReaderError.invalidOutput
                }
                if !initialized {
                    initialized = true
                    try send(id: usageID, request: ["subtype": "get_usage", "skip_behaviors": true])
                } else {
                    result = try parse(JSONSerialization.data(withJSONObject: body), capturedAt: Date())
                    try? input.close()
                }
            }
            func drain(_ fd: Int32, isOutput: Bool) throws {
                // Bounded by aggregate bytes, with cancellation/deadline checks even
                // when a child continuously fills either pipe.
                while true {
                    try check()
                    let n = Darwin.read(fd, &buffer, buffer.count)
                    if n == 0 { return }
                    if n < 0 {
                        if errno == EINTR { continue }
                        if errno == EAGAIN || errno == EWOULDBLOCK { return }
                        throw ClaudeCodeStructuredUsageReaderError.invalidOutput
                    }
                    total += n
                    guard total <= outputLimit else { throw ClaudeCodeStructuredUsageReaderError.outputLimit }
                    if isOutput {
                        pending.append(contentsOf: buffer.prefix(n))
                        while let newline = pending.firstIndex(of: 10) {
                            let line = Data(pending[..<newline])
                            pending.removeSubrange(...newline)
                            try consume(line)
                        }
                        guard pending.count <= frameLimit else { throw ClaudeCodeStructuredUsageReaderError.outputLimit }
                    }
                }
            }
            while true {
                try check()
                try drain(out.fileDescriptor, isOutput: true)
                try drain(err.fileDescriptor, isOutput: false)
                let exited = !process.isRunning
                if exited || result != nil {
                    if exited && (process.terminationReason != .exit || process.terminationStatus != 0) {
                        throw ClaudeCodeStructuredUsageReaderError.requestFailed
                    }
                    // Quiesce all writers before the final drain, including children
                    // whose root exited. This closes the read/exit race without
                    // blocking on inherited pipe writers or accepting trailing junk.
                    owner.cleanup()
                    try drain(out.fileDescriptor, isOutput: true)
                    try drain(err.fileDescriptor, isOutput: false)
                    if !pending.isEmpty { try consume(pending); pending.removeAll() }
                    guard let result else { throw ClaudeCodeStructuredUsageReaderError.invalidOutput }
                    return result
                }
                usleep(5_000)
            }
        }
    }
}

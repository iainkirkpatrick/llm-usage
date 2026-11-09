import Darwin
import Foundation

/// Deliberately distinct from ClaudeQuotaSnapshot: owner-reported text/metadata is
/// not authenticated UUID identity bound to an OAuth quota request.
struct ClaudeOwnerAuthObservation: Equatable, Sendable {
    let email: String?
    let organizationID: String?
    let authMethod: String?
    let apiProvider: String?

    static func parse(_ data: Data) throws -> Self {
        guard data.count <= 65_536,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let loggedIn = json["loggedIn"] as? NSNumber,
              CFGetTypeID(loggedIn) == CFBooleanGetTypeID() else {
            throw ClaudeOwnerUsageProbeError.authUnavailable
        }
        guard loggedIn.boolValue else { throw ClaudeOwnerUsageProbeError.signInRequired }
        func field(_ key: String) throws -> String? {
            guard let value = json[key], !(value is NSNull) else { return nil }
            guard let string = value as? String, string.utf8.count <= 512,
                  !string.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw ClaudeOwnerUsageProbeError.authUnavailable
            }
            return string
        }
        let result = try Self(email: field("email"), organizationID: field("orgId"),
                              authMethod: field("authMethod"), apiProvider: field("apiProvider"))
        guard result.authMethod == "claude.ai", result.apiProvider == "firstParty",
              let email = result.email, !email.isEmpty,
              let org = result.organizationID, UUID(uuidString: org) != nil else {
            throw ClaudeOwnerUsageProbeError.authUnavailable
        }
        return result
    }
}

struct ClaudeOwnerUsageProbeResult: Sendable {
    let ownerReportedIdentity: ClaudeOwnerAuthObservation
    let usage: ClaudeCLIUsageReading
    let capturedAt: Date

    /// This is a diagnostic result, never a replacement for same-token API identity.
    var identityVerifiedForTrackedAccount: Bool { false }
    /// A CLI panel can start from a cached snapshot before a late warning redraw.
    /// Even a structured get_usage response can contain seeded windows without
    /// the original observation time. Capture time is not a freshness guarantee.
    var freshnessVerified: Bool { false }

    func jsonObject() -> [String: Any] {
        func window(_ value: ClaudeCLIUsageWindow?) -> Any {
            guard let value else { return NSNull() }
            return ["usedPercent": value.usedPercent, "remainingPercent": 100 - value.usedPercent,
                    "resetDescription": value.resetDescription as Any? ?? NSNull()] as [String: Any]
        }
        return [
            "source": "Claude Code /usage proof of concept",
            "identityVerifiedForTrackedAccount": identityVerifiedForTrackedAccount,
            "freshnessVerified": freshnessVerified,
            "ownerReportedIdentity": ["email": ownerReportedIdentity.email as Any? ?? NSNull(),
                                      "organizationID": ownerReportedIdentity.organizationID as Any? ?? NSNull()],
            "session": window(usage.fiveHour), "weekly": window(usage.weekly),
            "modelWindows": usage.modelWindows.map { ["title": $0.title, "window": window($0.window)] },
            "capturedAt": ISO8601DateFormatter().string(from: capturedAt)
        ]
    }
}

/// No terminal output, auth codes, provider messages, or private paths in errors.
enum ClaudeOwnerUsageProbeError: Error, LocalizedError, Equatable {
    case cliUnavailable, launchFailed, workspaceUnavailable, trafficRestricted, timedOut, outputLimit, authUnavailable
    case setupRequired, signInRequired, usageUnavailable, identityChanged, invalidOutput

    var errorDescription: String? {
        switch self {
        case .cliUnavailable: return "Claude Code CLI is unavailable."
        case .launchFailed: return "Could not start the Claude Code usage probe."
        case .workspaceUnavailable: return "Could not prepare a safe Claude Code usage-probe workspace."
        case .trafficRestricted: return "The usage probe cannot run while an explicit nonessential-traffic restriction is set. It was not overridden."
        case .timedOut: return "Claude Code usage probe timed out. No quota was accepted."
        case .outputLimit: return "Claude Code usage probe exceeded its output limit. No quota was accepted."
        case .authUnavailable: return "Claude Code did not report a supported subscription identity. No quota was accepted."
        case .setupRequired: return "Claude Code needs interactive setup or workspace approval. Complete setup in this profile’s refresh workspace yourself, then retry."
        case .signInRequired: return "Claude Code reports that this profile needs sign-in. The probe did not start a login."
        case .usageUnavailable: return "Claude Code could not load its usage panel. No quota was accepted."
        case .identityChanged: return "Claude Code’s reported login changed during the probe. No quota was accepted."
        case .invalidOutput: return "Claude Code’s usage panel was not recognized. No quota was accepted."
        }
    }
}

private final class ClaudeOwnerProbeCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func check() throws {
        lock.lock(); let value = cancelled; lock.unlock()
        if value { throw CancellationError() }
    }
}

/// Owns only a newly created process group. Every exit, including success, cleans
/// up the interactive owner CLI and any descendants; never touches user sessions.
final class ClaudeOwnerProbeProcess: @unchecked Sendable {
    let process: Process
    private let group: pid_t
    private let registry: ClaudeOwnerProbeProcessRegistry

    init(_ process: Process, registry: ClaudeOwnerProbeProcessRegistry = ClaudeOwnerProbeRegistry.shared) throws {
        self.process = process
        self.registry = registry
        guard let verifiedGroup = registry.launch(process) else {
            throw ClaudeOwnerUsageProbeError.launchFailed
        }
        group = verifiedGroup
    }

    deinit { cleanup() }

    func cleanup() {
        registry.cleanup(process, group: group)
    }
}

/// The lock covers launch and the entire bounded teardown, not just entry removal.
/// Thus shutdown waits for already-claimed cleanup and no stale lease can kill twice.
final class ClaudeOwnerProbeProcessRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    private var processes: [ObjectIdentifier: (Process, pid_t)] = [:]
    private let terminateRoot: @Sendable (Process) -> Void

    /// Internal fixture seam; invoked under the registry lock and must not reenter it.
    /// Group cleanup and root reaping remain mandatory even with an injected terminator.
    init(terminateRoot: @escaping @Sendable (Process) -> Void = {
        ProcessTreeTermination.terminate(root: $0, grace: 0.1)
    }) {
        self.terminateRoot = terminateRoot
    }

    func launch(_ process: Process) -> pid_t? {
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { return nil }
        do { try process.run() } catch { return nil }
        let pid = process.processIdentifier
        if getpgid(pid) != pid { _ = setpgid(pid, pid) }
        // Establish ownership before publishing the process. If verification fails,
        // only terminate the Foundation-owned root; never signal an unverified group.
        guard getpgid(pid) == pid || kill(-pid, 0) == 0 else {
            ProcessTreeTermination.terminate(root: process, grace: 0.1)
            process.waitUntilExit()
            return nil
        }
        processes[ObjectIdentifier(process)] = (process, pid)
        return pid
    }

    func cleanup(_ process: Process, group: pid_t) {
        lock.lock(); defer { lock.unlock() }
        let key = ObjectIdentifier(process)
        guard let entry = processes[key], entry.1 == group else { return }
        processes.removeValue(forKey: key)
        teardown(process, group: group)
    }

    func stopAll() {
        lock.lock(); defer { lock.unlock() }
        stopped = true
        let entries = Array(processes.values)
        processes.removeAll()
        for (process, group) in entries {
            teardown(process, group: group)
        }
    }

    private func teardown(_ process: Process, group: pid_t) {
        terminateRoot(process)
        // A launcher can exit before its background children. Tree discovery
        // then loses their parentage, but the verified, probe-owned group remains.
        _ = kill(-group, SIGKILL)
        process.waitUntilExit()
    }
}

private enum ClaudeOwnerProbeRegistry {
    static let shared = ClaudeOwnerProbeProcessRegistry()

    static func stopAll() { shared.stopAll() }
}

/// Owner-mediated usage runner, shared by the explicit diagnostic and app source.
/// There are no Keychain/credential readers, OAuth HTTP requests, model prompts,
/// account-routing fallbacks, or cache writes in this transport.
/// The separate Claude process can refresh its own login and can show OS prompts.
enum ClaudeOwnerUsageProbe {
    static func observeIdentity(profile: ClaudeAccountProfile, timeout: TimeInterval = 10,
                                allowRestrictedTraffic: Bool = false) async throws -> ClaudeOwnerAuthObservation {
        let environment = ProcessInfo.processInfo.environment
        guard let executable = ClaudeCLI.resolveExecutable(environment: environment) else { throw ClaudeOwnerUsageProbeError.cliUnavailable }
        let directory: URL
        do { directory = try ClaudeAuthRefreshCLI.prepareWorkspace(profile: profile) }
        catch { throw ClaudeOwnerUsageProbeError.workspaceUnavailable }
        return try await observeIdentity(profile: profile, executable: executable, environment: environment,
                                         workingDirectory: directory, timeout: timeout, allowRestrictedTraffic: allowRestrictedTraffic)
    }

    static func observeIdentity(profile: ClaudeAccountProfile, executable: URL, environment: [String: String],
                                workingDirectory: URL, timeout: TimeInterval,
                                allowRestrictedTraffic: Bool = false) async throws -> ClaudeOwnerAuthObservation {
        let cancellation = ClaudeOwnerProbeCancellation()
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            let observation = try await Task.detached(priority: .userInitiated) {
                try cancellation.check()
                try validateLaunch(profile: profile, executable: executable, environment: environment,
                                   directory: workingDirectory, timeout: timeout, allowRestrictedTraffic: allowRestrictedTraffic)
                var childEnvironment = launchEnvironment(profile: profile, inherited: environment)
                if allowRestrictedTraffic, let restriction = environment["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] {
                    childEnvironment["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] = restriction
                }
                return try auth(executable: executable, environment: childEnvironment, directory: workingDirectory,
                                deadline: ProcessInfo.processInfo.systemUptime + timeout, cancellation: cancellation)
            }.value
            try Task.checkCancellation()
            return observation
        }, onCancel: { cancellation.cancel() })
    }

    static func stopAll() { ClaudeOwnerProbeRegistry.stopAll() }

    static func run(profile: ClaudeAccountProfile) async throws -> ClaudeOwnerUsageProbeResult {
        let environment = ProcessInfo.processInfo.environment
        guard let executable = ClaudeCLI.resolveExecutable(environment: environment) else {
            throw ClaudeOwnerUsageProbeError.cliUnavailable
        }
        let directory: URL
        do { directory = try ClaudeAuthRefreshCLI.prepareWorkspace(profile: profile) }
        catch { throw ClaudeOwnerUsageProbeError.workspaceUnavailable }
        return try await run(profile: profile, executable: executable, environment: environment,
                             workingDirectory: directory, timeout: 35)
    }

    /// Fixture seam: tests supply every path/environment and never launch user Claude.
    static func run(profile: ClaudeAccountProfile, executable: URL, environment: [String: String],
                    workingDirectory: URL, timeout: TimeInterval) async throws -> ClaudeOwnerUsageProbeResult {
        let cancellation = ClaudeOwnerProbeCancellation()
        let result = try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await Task.detached(priority: .userInitiated) {
                try cancellation.check()
                try validateLaunch(profile: profile, executable: executable, environment: environment,
                                   directory: workingDirectory, timeout: timeout)
                let childEnvironment = launchEnvironment(profile: profile, inherited: environment)
                let deadline = ProcessInfo.processInfo.systemUptime + timeout
                let before = try auth(executable: executable, environment: childEnvironment, directory: workingDirectory,
                                      deadline: min(deadline, ProcessInfo.processInfo.systemUptime + 5), cancellation: cancellation)
                let usage = try capture(executable: executable, environment: childEnvironment, directory: workingDirectory,
                                        deadline: deadline, cancellation: cancellation)
                let after = try auth(executable: executable, environment: childEnvironment, directory: workingDirectory,
                                     deadline: min(deadline, ProcessInfo.processInfo.systemUptime + 5), cancellation: cancellation)
                guard before == after else { throw ClaudeOwnerUsageProbeError.identityChanged }
                try cancellation.check()
                return ClaudeOwnerUsageProbeResult(ownerReportedIdentity: after, usage: usage, capturedAt: Date())
            }.value
        }, onCancel: { cancellation.cancel() })
        try Task.checkCancellation()
        return result
    }

    private static func validateLaunch(profile: ClaudeAccountProfile, executable: URL, environment: [String: String],
                                       directory: URL, timeout: TimeInterval, allowRestrictedTraffic: Bool = false) throws {
        guard executable.isFileURL, executable.path.hasPrefix("/"), directory.isFileURL,
              directory.path.hasPrefix("/"), timeout.isFinite, timeout > 0,
              profile.configDirectory.map({ ($0 as NSString).expandingTildeInPath.hasPrefix("/") && !$0.contains("\0") }) ?? true else {
            throw ClaudeOwnerUsageProbeError.launchFailed
        }
        if !allowRestrictedTraffic, let restriction = environment["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"], !restriction.isEmpty {
            throw ClaudeOwnerUsageProbeError.trafficRestricted
        }
    }

    private static func launchEnvironment(profile: ClaudeAccountProfile, inherited: [String: String]) -> [String: String] {
        var result = ClaudeCLI.loginEnvironment(profile: profile, inherited: inherited)
        result["DISABLE_AUTOUPDATER"] = "1"
        result["DISABLE_TELEMETRY"] = "1"
        result["DISABLE_ERROR_REPORTING"] = "1"
        result["CLAUDE_CODE_DISABLE_OFFICIAL_MARKETPLACE_AUTOINSTALL"] = "1"
        result["TERM"] = "xterm-256color"
        return result
    }

    private static func check(_ cancellation: ClaudeOwnerProbeCancellation, deadline: TimeInterval) throws {
        try cancellation.check()
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw ClaudeOwnerUsageProbeError.timedOut }
    }

    private static func auth(executable: URL, environment: [String: String], directory: URL,
                             deadline: TimeInterval, cancellation: ClaudeOwnerProbeCancellation) throws -> ClaudeOwnerAuthObservation {
        try check(cancellation, deadline: deadline)
        let process = Process()
        process.executableURL = executable
        process.arguments = ["auth", "status", "--json"]
        process.environment = environment
        process.currentDirectoryURL = directory
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout; process.standardError = stderr
        let out = stdout.fileHandleForReading, err = stderr.fileHandleForReading
        defer { try? out.close(); try? err.close() }
        guard fcntl(out.fileDescriptor, F_SETFL, O_NONBLOCK) != -1,
              fcntl(err.fileDescriptor, F_SETFL, O_NONBLOCK) != -1 else { throw ClaudeOwnerUsageProbeError.launchFailed }
        let owner = try ClaudeOwnerProbeProcess(process)
        return try withExtendedLifetime(owner) {
            // Close parent writers so EOF is observable, without waiting on pipes.
            try? stdout.fileHandleForWriting.close(); try? stderr.fileHandleForWriting.close()
            var data = Data(), count = 0
            var buffer = [UInt8](repeating: 0, count: 8192)
            while true {
                try check(cancellation, deadline: deadline)
                for fd in [out.fileDescriptor, err.fileDescriptor] {
                    for _ in 0..<8 {
                        let n = Darwin.read(fd, &buffer, buffer.count)
                        if n <= 0 { break }
                        count += n
                        guard count <= 65_536 else { throw ClaudeOwnerUsageProbeError.outputLimit }
                        if fd == out.fileDescriptor { data.append(contentsOf: buffer.prefix(n)) }
                    }
                }
                if !process.isRunning {
                    // Drain one last bounded pass: process exit can race the reads.
                    for fd in [out.fileDescriptor, err.fileDescriptor] {
                        for _ in 0..<8 {
                            let n = Darwin.read(fd, &buffer, buffer.count)
                            if n <= 0 { break }
                            count += n
                            guard count <= 65_536 else { throw ClaudeOwnerUsageProbeError.outputLimit }
                            if fd == out.fileDescriptor { data.append(contentsOf: buffer.prefix(n)) }
                        }
                    }
                    let observation = try ClaudeOwnerAuthObservation.parse(data)
                    guard process.terminationReason == .exit, process.terminationStatus == 0 else {
                        throw ClaudeOwnerUsageProbeError.authUnavailable
                    }
                    return observation
                }
                usleep(20_000)
            }
        }
    }

    private static func capture(executable: URL, environment: [String: String], directory: URL,
                                deadline: TimeInterval, cancellation: ClaudeOwnerProbeCancellation) throws -> ClaudeCLIUsageReading {
        try check(cancellation, deadline: deadline)
        var master: Int32 = -1, slave: Int32 = -1
        var size = winsize(ws_row: 200, ws_col: 160, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&master, &slave, nil, nil, &size) == 0 else { throw ClaudeOwnerUsageProbeError.launchFailed }
        defer { close(master) }
        let terminal = FileHandle(fileDescriptor: slave, closeOnDealloc: true)
        defer { try? terminal.close() }
        guard fcntl(master, F_SETFL, O_NONBLOCK) != -1,
              fcntl(master, F_SETFD, FD_CLOEXEC) != -1,
              fcntl(slave, F_SETFD, FD_CLOEXEC) != -1 else { throw ClaudeOwnerUsageProbeError.launchFailed }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--allowed-tools", "", "--tools", "", "--strict-mcp-config", "--settings",
                             "{\"disableAllHooks\":true,\"remoteControlAtStartup\":false}", "--no-chrome", "--safe-mode", "/usage"]
        process.currentDirectoryURL = directory
        process.environment = environment
        process.standardInput = terminal; process.standardOutput = terminal; process.standardError = terminal
        let owner = try ClaudeOwnerProbeProcess(process)
        try? terminal.close()
        return try withExtendedLifetime(owner) {
            var screen = ClaudeCLITerminalScreen()
            var bytes = 0, buffer = [UInt8](repeating: 0, count: 8192)
            var candidate: ClaudeCLIUsageReading?, candidateSince: TimeInterval?
            var sawLoading = false
            while true {
                try check(cancellation, deadline: deadline)
                var changed = false
                func drain(_ limit: Int) throws {
                    for _ in 0..<limit {
                        try check(cancellation, deadline: deadline)
                        let n = Darwin.read(master, &buffer, buffer.count)
                        if n <= 0 { break }
                        bytes += n
                        guard bytes <= 1_048_576 else { throw ClaudeOwnerUsageProbeError.outputLimit }
                        screen.append(Data(buffer.prefix(n))); changed = true
                    }
                }
                try drain(8)
                let exited = !process.isRunning
                if exited {
                    // Exit can race the preceding read. Drain and classify the
                    // final frame before considering any earlier candidate.
                    try drain(129)
                    guard process.terminationReason == .exit, process.terminationStatus == 0 else {
                        throw ClaudeOwnerUsageProbeError.invalidOutput
                    }
                }
                let rendered = screen.text
                // Barriers are classified from the current screen only. No raw text
                // is persisted/logged, no Enter/trust/login response is ever sent.
                let words = rendered.lowercased().filter { $0.isLetter || $0.isNumber }
                if ["choosethetextstyle", "doyoutrustthefilesinthisfolder", "trustthisfolder", "selectlogintype"].contains(where: words.contains) {
                    throw ClaudeOwnerUsageProbeError.setupRequired
                }
                if ["pleaselogin", "pleasesignin", "notloggedin", "runauthlogin", "logintoclaudecode"].contains(where: words.contains) {
                    throw ClaudeOwnerUsageProbeError.signInRequired
                }
                if words.contains("failedtoloadusagedata") { throw ClaudeOwnerUsageProbeError.usageUnavailable }
                do {
                    let reading = try ClaudeCLIUsageParser.parse(screen: rendered)
                    let now = ProcessInfo.processInfo.systemUptime
                    if reading != candidate { candidate = reading; candidateSince = now }
                    // Give late model-window redraws time to finish; never capture an
                    // earlier loading frame or reuse a cleared/error screen.
                    if exited { return reading }
                    if let since = candidateSince, now - since >= 1, !changed {
                        // If it just exited, loop once more to drain/reparse and
                        // validate its status, rather than accepting stale cells.
                        if !process.isRunning { continue }
                        return reading
                    }
                } catch ClaudeCLIUsageParserError.loading {
                    sawLoading = true; candidate = nil; candidateSince = nil
                } catch {
                    candidate = nil; candidateSince = nil
                }
                if exited {
                    throw sawLoading ? ClaudeOwnerUsageProbeError.usageUnavailable : ClaudeOwnerUsageProbeError.invalidOutput
                }
                usleep(20_000)
            }
        }
    }
}

import Darwin
import Foundation

private final class ClaudeLoginControl: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

/// Drains pipes without allowing CLI output (which may contain auth codes) into errors or logs.
private final class ClaudeLoginOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    func append(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        buffer = Data((buffer + data).suffix(8192))
    }
}

enum ClaudeCLI {
    static func login(profile: ClaudeAccountProfile, timeout: TimeInterval = 180) async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let executable = resolveExecutable(environment: environment) else { throw ClaudeBackendError.cliMissing }
        try await login(profile: profile, executable: executable, environment: environment, timeout: timeout)
    }

    /// Separate seam for tests: fixtures never resolve or launch the user's CLI.
    static func login(profile: ClaudeAccountProfile, executable: URL,
                      environment: [String: String], timeout: TimeInterval) async throws {
        let control = ClaudeLoginControl()
        try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            try await Task.detached(priority: .userInitiated) {
                try run(profile: profile, executable: executable, environment: environment,
                        timeout: timeout, control: control)
            }.value
        }, onCancel: { control.cancel() })
    }

    static func loginEnvironment(profile: ClaudeAccountProfile, inherited: [String: String]) -> [String: String] {
        // Remove provider routing and injected auth, not just the two common token variables.
        let prefixes = ["ANTHROPIC_", "CLAUDE_", "AWS_", "AMAZON_", "GOOGLE_", "GCLOUD_", "AZURE_",
                        "VERTEX_", "BEDROCK_", "OPENAI_", "AI_GATEWAY_", "CLOUDFLARE_", "LLM_GATEWAY_"]
        let names: Set<String> = ["HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY", "GOOGLE_APPLICATION_CREDENTIALS",
                                  "BASH_ENV", "ENV", "NODE_OPTIONS", "NODE_EXTRA_CA_CERTS", "SSL_CERT_FILE", "SSL_CERT_DIR"]
        var environment = inherited.filter { key, _ in
            let upper = key.uppercased()
            return !prefixes.contains(where: { upper.hasPrefix($0) }) && !names.contains(upper) && !upper.hasPrefix("DYLD_")
        }
        if profile.configDirectory != nil { environment["CLAUDE_CONFIG_DIR"] = profile.directoryURL.path }
        return environment
    }

    static func resolveExecutable(environment: [String: String],
                                  home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        let manager = FileManager.default
        func executable(_ path: String) -> URL? {
            guard path.hasPrefix("/") else { return nil }
            let url = URL(fileURLWithPath: path).standardizedFileURL
            var directory: ObjCBool = false
            guard manager.fileExists(atPath: url.path, isDirectory: &directory), !directory.boolValue,
                  manager.isExecutableFile(atPath: url.path) else { return nil }
            return url
        }
        if let override = environment["LLM_BAR_CLAUDE_PATH"] {
            return executable((override as NSString).expandingTildeInPath)
        }
        let directories = [home.appendingPathComponent(".local/bin").path, home.appendingPathComponent("bin").path,
                           home.appendingPathComponent(".npm-global/bin").path, home.appendingPathComponent(".npm/bin").path,
                           "/opt/homebrew/bin", "/usr/local/bin"] + (environment["PATH"] ?? "").components(separatedBy: ":")
        for directory in directories where directory.hasPrefix("/") {
            if let url = executable((directory as NSString).appendingPathComponent("claude")) { return url }
        }
        return nil
    }

    private static func run(profile: ClaudeAccountProfile, executable: URL, environment: [String: String],
                            timeout: TimeInterval, control: ClaudeLoginControl) throws {
        if control.isCancelled { throw CancellationError() }
        guard executable.path.hasPrefix("/"), timeout.isFinite, timeout > 0 else { throw ClaudeBackendError.cliLaunchFailed }
        if let raw = profile.configDirectory,
           (!(raw as NSString).expandingTildeInPath.hasPrefix("/") || raw.contains("\0")) {
            throw ClaudeBackendError.cliLaunchFailed
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["auth", "login", "--claudeai"]
        process.environment = loginEnvironment(profile: profile, inherited: environment)
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe()
        let stderr = Pipe()
        let output = ClaudeLoginOutput()
        stdout.fileHandleForReading.readabilityHandler = { output.append($0.availableData) }
        stderr.fileHandleForReading.readabilityHandler = { output.append($0.availableData) }
        defer {
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            try? stdout.fileHandleForReading.close()
            try? stderr.fileHandleForReading.close()
        }
        process.standardOutput = stdout
        process.standardError = stderr
        do { try process.run() } catch { throw ClaudeBackendError.cliLaunchFailed }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var timedOut = false
        while process.isRunning {
            if control.isCancelled { break }
            if ProcessInfo.processInfo.systemUptime >= deadline { timedOut = true; break }
            usleep(20_000)
        }
        if control.isCancelled || timedOut { ProcessTreeTermination.terminate(root: process, grace: 0.2) }
        process.waitUntilExit()
        if control.isCancelled { throw CancellationError() }
        if timedOut { throw ClaudeBackendError.loginTimedOut }
        guard process.terminationReason == .exit, process.terminationStatus == 0 else { throw ClaudeBackendError.cliFailed }
    }
}

import Darwin
import Foundation

struct CodexLoginResult: Sendable, Equatable {
    enum Outcome: Sendable, Equatable {
        case success
        case cancelled
        case timedOut
        case missingBinary
        case launchFailed(String)
        case failed(Int32)
    }

    let outcome: Outcome
    let output: String

    var succeeded: Bool {
        if case .success = self.outcome { return true }
        return false
    }
}

enum ManagedCodexAccountError: LocalizedError, Sendable {
    case authenticationInProgress
    case accountOperationInProgress
    case loginFailed(CodexLoginResult)
    case accountNotFound
    case configWriteFailed
    case stagingCleanupFailed(String)
    case resetPending(String)
    case removalFailed(String)

    var errorDescription: String? {
        switch self {
        case .authenticationInProgress:
            return "A Codex account login is already in progress."
        case .accountOperationInProgress:
            return "Wait for the current Codex refresh or reset operation to finish."
        case let .loginFailed(result):
            switch result.outcome {
            case .cancelled:
                return "Codex login was cancelled."
            case .timedOut:
                return "Codex login timed out.\n\n\(result.output)"
            case .missingBinary:
                return "Codex CLI was not found. Install it and try again."
            case let .launchFailed(message):
                return "Could not start Codex login: \(message)"
            case let .failed(status):
                let output = result.output.isEmpty ? "No output captured." : "\n\n\(result.output)"
                return "Codex login exited with status \(status).\(output)"
            case .success:
                return nil
            }
        case .accountNotFound:
            return "The managed Codex account no longer exists."
        case .configWriteFailed:
            return "Could not save the managed Codex account configuration."
        case let .stagingCleanupFailed(message):
            return "Codex sign-in could not clean up its temporary credential directory; credentials may have been updated only after validation: \(message)"
        case let .resetPending(message):
            return "This account has a reset attempt with an unknown result. \(message)"
        case let .removalFailed(message):
            return "Managed Codex account removal was not completed safely: \(message)"
        }
    }
}

private final class LoginOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ value: Data) {
        guard !value.isEmpty else { return }
        self.lock.lock()
        self.data.append(value)
        if self.data.count > 8_000 {
            self.data = Data(self.data.suffix(8_000))
        }
        self.lock.unlock()
    }

    func value() -> Data {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.data
    }
}

private final class OAuthURLObserver: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""
    private var didOpen = false

    func observe(_ data: Data) {
        let text = String(decoding: data, as: UTF8.self)
        guard !text.isEmpty else { return }
        self.lock.lock()
        self.buffer = String((self.buffer + text).suffix(12_000))
        guard !self.didOpen,
              let url = CodexLoginRunner.safeOAuthURL(from: self.buffer)
        else {
            self.lock.unlock()
            return
        }
        self.didOpen = true
        self.lock.unlock()
        CodexLoginRunner.openSafeOAuthURL(url)
    }
}

private final class LoginProcessControl: @unchecked Sendable {
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

struct CodexLoginRunner: Sendable {
    func run(codexHome: URL, timeout: TimeInterval = 120) async -> CodexLoginResult {
        let control = LoginProcessControl()
        return await withTaskCancellationHandler(operation: {
            await Task.detached(priority: .userInitiated) {
                Self.runBlocking(codexHome: codexHome, timeout: timeout, control: control)
            }.value
        }, onCancel: {
            control.cancel()
        })
    }

    private static func runBlocking(
        codexHome: URL,
        timeout: TimeInterval,
        control: LoginProcessControl) -> CodexLoginResult
    {
        guard let executable = CodexNodeBridge.resolveCodexExecutable() else {
            return CodexLoginResult(outcome: .missingBinary, output: "")
        }

        let output = LoginOutput()
        let errorOutput = LoginOutput()
        let oauthURLObserver = OAuthURLObserver()
        let stdout = Pipe()
        let stderr = Pipe()
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            output.append(data)
            oauthURLObserver.observe(data)
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            errorOutput.append(data)
            oauthURLObserver.observe(data)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["login"]
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = codexHome.path
        process.environment = environment
        process.standardInput = FileHandle(forReadingAtPath: "/dev/null")
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            return CodexLoginResult(outcome: .launchFailed(error.localizedDescription), output: "")
        }

        // Track descendants directly instead of creating a process group after exec. The latter
        // consistently fails with EACCES for Foundation-launched processes on macOS.
        control.install(process: process)

        let deadline = Date().addingTimeInterval(max(1, timeout))
        var timedOut = false
        while process.isRunning {
            if control.wasCancelled { break }
            if Date() >= deadline {
                timedOut = true
                break
            }
            usleep(20_000)
        }

        if control.wasCancelled || timedOut {
            ProcessTreeTermination.terminate(root: process, grace: 2)
        }
        process.waitUntilExit()

        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        output.append(stdout.fileHandleForReading.readDataToEndOfFile())
        errorOutput.append(stderr.fileHandleForReading.readDataToEndOfFile())
        let cancelled = control.wasCancelled
        control.clear()

        let stdoutText = String(decoding: output.value(), as: UTF8.self)
        let stderrText = String(decoding: errorOutput.value(), as: UTF8.self)
        let combined = Self.redact([stdoutText, stderrText].filter { !$0.isEmpty }.joined(separator: "\n"))

        if cancelled { return CodexLoginResult(outcome: .cancelled, output: combined) }
        if timedOut { return CodexLoginResult(outcome: .timedOut, output: combined) }
        if process.terminationStatus == 0 { return CodexLoginResult(outcome: .success, output: combined) }
        return CodexLoginResult(outcome: .failed(process.terminationStatus), output: combined)
    }

    static func safeOAuthURL(from output: String) -> URL? {
        let pattern = #"https://[^\s\"'<>]+"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(output.startIndex..<output.endIndex, in: output)
        for match in expression.matches(in: output, range: range) {
            guard let matchRange = Range(match.range, in: output) else { continue }
            var candidate = String(output[matchRange])
            while let last = candidate.last, ".,);]}>".contains(last) {
                candidate.removeLast()
            }
            guard let url = URL(string: candidate),
                  let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  components.scheme?.lowercased() == "https",
                  components.user == nil,
                  components.password == nil,
                  components.port == nil,
                  components.fragment == nil,
                  let host = components.host?.lowercased(),
                  host == "openai.com" || host.hasSuffix(".openai.com") ||
                  host == "chatgpt.com" || host.hasSuffix(".chatgpt.com")
            else { continue }

            let unsafeQueryNames = Set(["access_token", "refresh_token", "id_token", "token", "code", "password", "secret"])
            if components.queryItems?.contains(where: { unsafeQueryNames.contains($0.name.lowercased()) }) == true {
                continue
            }
            return url
        }
        return nil
    }

    fileprivate static func openSafeOAuthURL(_ url: URL) {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/open") else { return }
        let opener = Process()
        opener.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        opener.arguments = [url.absoluteString]
        opener.standardInput = FileHandle(forReadingAtPath: "/dev/null")
        opener.standardOutput = FileHandle(forWritingAtPath: "/dev/null")
        opener.standardError = FileHandle(forWritingAtPath: "/dev/null")
        try? opener.run()
    }

    private static func redact(_ text: String) -> String {
        let bearerRedacted = text.replacingOccurrences(
            of: #"Bearer\s+\S+|eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+"#,
            with: "[redacted]",
            options: .regularExpression)
        let queryRedacted = bearerRedacted.replacingOccurrences(
            of: #"(?i)((?:access_token|refresh_token|id_token|token|code|password|secret)=)[^&\s]+"#,
            with: "$1[redacted]",
            options: .regularExpression)
        let trimmed = queryRedacted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 4_000 else { return trimmed }
        return String(trimmed.prefix(4_000)) + "…"
    }
}

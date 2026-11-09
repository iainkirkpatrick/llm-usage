import AppKit
import Darwin
import Foundation

let helperMode = CommandLine.arguments.dropFirst().first
if let mode = helperMode,
   ["--claude-owner-usage-probe", "--claude-usage-identity", "--claude-usage-cli"].contains(mode) {
    let helperTask = Task.detached {
        do {
            let environment = ProcessInfo.processInfo.environment
            let profile = ClaudeCLIUsageAdapter.profile(environment: environment)
            let data: Data
            if mode == "--claude-owner-usage-probe" {
                let result = try await ClaudeOwnerUsageProbe.run(profile: profile)
                data = try JSONSerialization.data(withJSONObject: result.jsonObject(), options: [.sortedKeys])
            } else {
                let adapter = ClaudeCLIUsageAdapter()
                let source = ConfigStore.load().claudeUsageSource
                if mode == "--claude-usage-identity" {
                    data = try await adapter.identityData(profile: profile, source: source)
                } else {
                    let milliseconds = environment["LLM_USAGE_CLAUDE_TIMEOUT_MS"].flatMap(Double.init) ?? 18_000
                    guard milliseconds.isFinite, milliseconds > 0 else { throw ClaudeCodeStructuredUsageReaderError.timedOut }
                    data = try await adapter.usageData(profile: profile, source: source,
                        expectedFingerprint: environment["LLM_USAGE_CLAUDE_FINGERPRINT"], timeout: min(18, milliseconds / 1000))
                }
            }
            try Task.checkCancellation()
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([0x0a]))
            exit(0)
        } catch {
            if error is CancellationError {
                fputs("Claude usage request cancelled.\n", stderr)
                exit(130)
            }
            fputs("Claude usage unavailable: \(ClaudeCLIUsageAdapter.diagnostic(error))\n", stderr)
            exit(1)
        }
    }
    // Cancellation must finish the owner CLI's group cleanup before exiting.
    // These helpers never initialize AppKit or start the menu-bar polling loop.
    let signals = [SIGINT, SIGTERM].map { number in
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
        source.setEventHandler { @Sendable [helperTask] in helperTask.cancel() }
        source.resume()
        return source
    }
    withExtendedLifetime(signals) { dispatchMain() }
}

let app = NSApplication.shared
let delegate = AppController()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

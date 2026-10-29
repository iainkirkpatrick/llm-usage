import AppKit
import CryptoKit
import Foundation

let helperMode = CommandLine.arguments.dropFirst().first
if helperMode == "--claude-usage-identity" {
    do {
        let environment = ProcessInfo.processInfo.environment
        let profile = ClaudeAccountProfile(label: "Claude Code", configDirectory: environment["CLAUDE_CONFIG_DIR"])
        let credential = try ClaudeCredentials.read(profile: profile)
        let tokenDigest = SHA256.hash(data: Data(credential.accessToken.utf8)).map { String(format: "%02x", $0) }.joined()
        let identity = SHA256.hash(data: Data((ClaudeCredentials.serviceName(for: profile) + "\0" + tokenDigest).utf8)).map { String(format: "%02x", $0) }.joined()
        let data = try JSONSerialization.data(withJSONObject: ["fingerprint": identity])
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0a]))
        exit(0)
    } catch {
        fputs("Claude credentials unavailable: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}
if helperMode == "--claude-usage-cli" {
    Task.detached {
        do {
            let environment = ProcessInfo.processInfo.environment
            let configDirectory = environment["CLAUDE_CONFIG_DIR"]
            let profile = ClaudeAccountProfile(label: "Claude Code", configDirectory: configDirectory)
            let quota = try await ClaudeUsageFetcher().fetch(profile: profile)
            func window(_ value: RateWindow?) -> [String: Any]? {
                guard let value else { return nil }
                return ["remainingPercent": value.remainingPercent, "usedPercent": value.usedPercent,
                        "resetAt": value.resetAt.map { ISO8601DateFormatter().string(from: $0) } as Any? ?? NSNull()]
            }
            let result: [String: Any] = ["claude": [
                "session": window(quota.fiveHour) as Any? ?? NSNull(),
                "weekly": window(quota.weekly) as Any? ?? NSNull(),
                "source": "Claude Code default",
                "updatedAt": ISO8601DateFormatter().string(from: quota.updatedAt)
            ]]
            let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([0x0a]))
        } catch {
            fputs("Claude usage unavailable: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
        exit(0)
    }
    // Keep the helper alive without initializing AppKit or starting menu-bar polling.
    dispatchMain()
}

let app = NSApplication.shared
let delegate = AppController()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

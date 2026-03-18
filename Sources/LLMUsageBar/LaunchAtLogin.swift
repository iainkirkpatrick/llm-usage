import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum LaunchAtLoginManager {
    static let label = "com.iainkirkpatrick.llmusagebar"

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(self.label).plist")
    }

    static func isEnabled() -> Bool {
        FileManager.default.fileExists(atPath: self.plistURL.path)
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try self.installAgent()
            self.bootoutExistingAgent()
            _ = self.launchctl(["bootstrap", "gui/\(self.userID())", self.plistURL.path], allowFailure: false)
            _ = self.launchctl(["enable", "gui/\(self.userID())/\(self.label)"], allowFailure: true)
            _ = self.launchctl(["kickstart", "-k", "gui/\(self.userID())/\(self.label)"], allowFailure: true)
        } else {
            self.bootoutExistingAgent()
            try? FileManager.default.removeItem(at: self.plistURL)
        }
    }

    private static func installAgent() throws {
        guard let executablePath = Self.currentExecutablePath() else {
            throw NSError(domain: "LaunchAtLoginManager", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Could not determine executable path.",
            ])
        }

        let logsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".llm-usage-bar", isDirectory: true)
        try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)

        let stdoutPath = logsDir.appendingPathComponent("launchd.stdout.log").path
        let stderrPath = logsDir.appendingPathComponent("launchd.stderr.log").path

        let plist: [String: Any] = [
            "Label": self.label,
            "ProgramArguments": [executablePath],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ProcessType": "Interactive",
            "StandardOutPath": stdoutPath,
            "StandardErrorPath": stderrPath,
        ]

        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)

        let dir = self.plistURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: self.plistURL, options: [.atomic])
    }

    private static func currentExecutablePath() -> String? {
        if let path = Bundle.main.executableURL?.path, !path.isEmpty {
            return path
        }

        let candidate = ProcessInfo.processInfo.arguments.first ?? ""
        guard !candidate.isEmpty else { return nil }

        if candidate.hasPrefix("/") {
            return candidate
        }

        let cwd = FileManager.default.currentDirectoryPath
        return URL(fileURLWithPath: cwd).appendingPathComponent(candidate).path
    }

    private static func userID() -> String {
        String(getuid())
    }

    private static func bootoutExistingAgent() {
        _ = self.launchctl(["bootout", "gui/\(self.userID())/\(self.label)"], allowFailure: true)
        _ = self.launchctl(["bootout", "gui/\(self.userID())", self.plistURL.path], allowFailure: true)
    }

    @discardableResult
    private static func launchctl(_ arguments: [String], allowFailure: Bool) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments

        let output = Pipe()
        process.standardOutput = output
        process.standardError = output

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            if allowFailure { return "" }
            return error.localizedDescription
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""

        if process.terminationStatus != 0, !allowFailure {
            // throw-like behavior via fatal error avoided; caller can inspect status by verifying file.
            return text
        }

        return text
    }
}

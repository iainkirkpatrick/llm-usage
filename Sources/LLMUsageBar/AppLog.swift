import Foundation

enum AppLog {
    static let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".llm-usage-bar", isDirectory: true)
        .appendingPathComponent("app.log")

    static func info(_ message: String) {
        self.write("INFO", message)
    }

    static func error(_ message: String) {
        self.write("ERROR", message)
    }

    private static func write(_ level: String, _ message: String) {
        do {
            let directory = self.fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            self.truncateIfNeeded(maxBytes: 256 * 1024)

            let timestamp = ISO8601DateFormatter().string(from: Date())
            let line = "[\(timestamp)] [\(level)] \(message)\n"
            let data = Data(line.utf8)

            if FileManager.default.fileExists(atPath: self.fileURL.path) {
                let handle = try FileHandle(forWritingTo: self.fileURL)
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.close()
            } else {
                try data.write(to: self.fileURL, options: [.atomic])
                try FileManager.default.setAttributes([
                    .posixPermissions: NSNumber(value: Int16(0o600)),
                ], ofItemAtPath: self.fileURL.path)
            }
        } catch {
            // Logging must never affect refresh behavior.
        }
    }

    private static func truncateIfNeeded(maxBytes: UInt64) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: self.fileURL.path),
              let size = attributes[.size] as? UInt64,
              size > maxBytes,
              let data = try? Data(contentsOf: self.fileURL)
        else {
            return
        }

        let keepBytes = Int(maxBytes / 2)
        let trimmed = data.suffix(keepBytes)
        try? Data(trimmed).write(to: self.fileURL, options: [.atomic])
    }
}

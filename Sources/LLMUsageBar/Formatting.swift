import Foundation

enum Formatting {
    static func percent(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.0f%%", value)
    }

    static func currency(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "$%.2f", value)
    }

    static func relativeReset(_ date: Date?) -> String {
        guard let date else { return "unknown" }
        let interval = Int(date.timeIntervalSinceNow)
        if interval <= 0 { return "now" }

        let days = interval / 86_400
        let hours = (interval % 86_400) / 3_600
        let minutes = (interval % 3_600) / 60

        if days > 0 {
            return hours > 0 ? "\(days)d \(hours)h" : "\(days)d"
        }
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        if minutes > 0 {
            return "\(minutes)m"
        }
        return "<1m"
    }

    static func lastUpdated(_ date: Date) -> String {
        if date == .distantPast { return "Never" }
        return date.formatted(date: .omitted, time: .shortened)
    }

    static func dateTime(_ date: Date?) -> String {
        guard let date else { return "no expiry" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    static func compactNumber(_ value: Int) -> String {
        self.compact(Double(value), suffixes: [(1_000_000_000, "B"), (1_000_000, "M"), (1_000, "k")])
    }

    static func tokens(_ value: Int) -> String {
        "\(self.compactNumber(value)) tok"
    }

    static func abbreviatedPath(_ path: String?) -> String {
        guard let path, !path.isEmpty else { return "—" }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home {
            return "~"
        }
        if path.hasPrefix(home + "/") {
            return "~" + String(path.dropFirst(home.count))
        }
        return path
    }

    private static func compact(_ value: Double, suffixes: [(Double, String)]) -> String {
        let absolute = abs(value)
        for (threshold, suffix) in suffixes {
            guard absolute >= threshold else { continue }
            let scaled = value / threshold
            let rounded = self.compactValueString(scaled)
            return "\(rounded)\(suffix)"
        }

        return String(Int(value.rounded()))
    }

    private static func compactValueString(_ value: Double) -> String {
        if value >= 10 || value.rounded() == value {
            return String(format: "%.0f", value)
        }
        return String(format: "%.1f", value)
    }
}

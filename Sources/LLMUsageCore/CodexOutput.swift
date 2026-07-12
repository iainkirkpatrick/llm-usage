import Foundation

public struct CodexCLIOutput: Encodable {
    public struct Window: Encodable {
        public let usedPercent: Double
        public let remainingPercent: Double
        public let resetAt: Date?
    }
    public struct Codex: Encodable {
        public struct ResetCredits: Encodable { public let availableCount: Int }
        public let session: Window?
        public let weekly: Window?
        public let creditsRemaining: Double?
        public let resetCredits: ResetCredits?
        public let source: String
        public let updatedAt: Date
    }
    public let codex: Codex

    public init(snapshot: CodexSnapshot) {
        func window(_ value: RateWindow) -> Window {
            Window(usedPercent: value.usedPercent, remainingPercent: value.remainingPercent, resetAt: value.resetAt)
        }
        codex = Codex(session: snapshot.session.map(window), weekly: snapshot.weekly.map(window),
                      creditsRemaining: snapshot.creditsRemaining,
                      resetCredits: snapshot.resetCredits.map { .init(availableCount: $0.availableCount) },
                      source: snapshot.sourceLabel, updatedAt: snapshot.updatedAt)
    }

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }
}

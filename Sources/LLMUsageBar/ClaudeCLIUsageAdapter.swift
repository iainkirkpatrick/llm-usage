import CryptoKit
import Foundation

/// The one-shot CLI follows the selected app source, but always uses the caller's
/// exact default/explicit CLAUDE_CONFIG_DIR. It never substitutes a tracked account.
struct ClaudeCLIUsageAdapter: Sendable {
    typealias IdentityReader = @Sendable (ClaudeAccountProfile, TimeInterval) async throws -> ClaudeOwnerAuthObservation
    typealias UsageReader = @Sendable (ClaudeAccountProfile, TimeInterval) async throws -> ClaudeCodeStructuredUsage
    typealias NativeIdentityReader = @Sendable (ClaudeAccountProfile) throws -> String
    typealias NativeUsageReader = @Sendable (ClaudeAccountProfile, String?) async throws -> ClaudeQuotaSnapshot

    private let identityReader: IdentityReader
    private let usageReader: UsageReader
    private let nativeIdentity: NativeIdentityReader
    private let nativeUsage: NativeUsageReader
    private let uptime: @Sendable () -> TimeInterval

    init(identityReader: @escaping IdentityReader = {
        try await ClaudeOwnerUsageProbe.observeIdentity(profile: $0, timeout: $1, allowRestrictedTraffic: true)
    }, usageReader: @escaping UsageReader = Self.readStructuredUsage,
         nativeIdentity: @escaping NativeIdentityReader = { profile in
             ClaudeCredentials.fingerprint(try ClaudeCredentials.read(profile: profile), profile: profile)
         }, nativeUsage: @escaping NativeUsageReader = { profile, fingerprint in
             try await ClaudeUsageFetcher().fetch(profile: profile, expectedFingerprint: fingerprint)
         }, uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.identityReader = identityReader
        self.usageReader = usageReader
        self.nativeIdentity = nativeIdentity
        self.nativeUsage = nativeUsage
        self.uptime = uptime
    }

    static func profile(environment: [String: String]) -> ClaudeAccountProfile {
        let raw = environment["CLAUDE_CONFIG_DIR"]
        return ClaudeAccountProfile(label: "Claude Code", configDirectory: raw?.isEmpty == false ? raw : nil)
    }

    static func reportedFingerprint(profile: ClaudeAccountProfile, identity: ClaudeOwnerAuthObservation) throws -> String {
        guard identity.authMethod == "claude.ai", identity.apiProvider == "firstParty",
              let email = identity.email, !email.isEmpty,
              let org = identity.organizationID, UUID(uuidString: org) != nil else {
            throw ClaudeOwnerUsageProbeError.authUnavailable
        }
        let association = "claude-code-reported-v1\0" + ClaudeCredentials.serviceName(for: profile)
            + "\0" + org.lowercased() + "\0" + email.lowercased()
        return SHA256.hash(data: Data(association.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func identityData(profile: ClaudeAccountProfile, source: ClaudeUsageSource) async throws -> Data {
        try Task.checkCancellation()
        let fingerprint: String
        if source == .claudeCode {
            fingerprint = try Self.reportedFingerprint(profile: profile, identity: await identityReader(profile, 4))
        } else { fingerprint = try nativeIdentity(profile) }
        try Task.checkCancellation()
        return try JSONSerialization.data(withJSONObject: ["fingerprint": fingerprint, "source": source.rawValue], options: [.sortedKeys])
    }

    func usageData(profile: ClaudeAccountProfile, source: ClaudeUsageSource, expectedFingerprint: String?,
                   timeout: TimeInterval = 18) async throws -> Data {
        try Task.checkCancellation()
        guard timeout.isFinite, timeout > 0 else { throw ClaudeCodeStructuredUsageReaderError.timedOut }
        if source == .oauth {
            let quota = try await nativeUsage(profile, expectedFingerprint)
            return try Self.payload(session: quota.fiveHour, weekly: quota.weekly,
                capturedAt: quota.updatedAt, source: "Claude OAuth API", reported: nil)
        }
        let deadline = uptime() + min(timeout, 18)
        func remaining() throws -> TimeInterval {
            try Task.checkCancellation()
            let seconds = deadline - uptime()
            guard seconds > 0 else { throw ClaudeCodeStructuredUsageReaderError.timedOut }
            return seconds
        }
        let before = try await identityReader(profile, min(4, remaining()))
        let fingerprint = try Self.reportedFingerprint(profile: profile, identity: before)
        if let expectedFingerprint, fingerprint != expectedFingerprint { throw ClaudeBackendError.credentialChanged }
        let budget = try remaining() - 3 // Reserve the final owner-status check.
        guard budget > 0 else { throw ClaudeCodeStructuredUsageReaderError.timedOut }
        let usage = try await usageReader(profile, budget)
        let after = try await identityReader(profile, min(3, remaining()))
        guard before == after, try Self.reportedFingerprint(profile: profile, identity: after) == fingerprint else {
            throw ClaudeOwnerUsageProbeError.identityChanged
        }
        _ = try remaining()
        return try Self.payload(session: usage.session, weekly: usage.weekly, capturedAt: usage.capturedAt,
            source: profile.configDirectory == nil ? "Claude Code default" : "Claude Code profile", reported: after)
    }

    private static func payload(session: RateWindow?, weekly: RateWindow?, capturedAt: Date,
                                source: String, reported: ClaudeOwnerAuthObservation?) throws -> Data {
        func window(_ value: RateWindow?) -> Any {
            guard let value else { return NSNull() }
            return ["remainingPercent": value.remainingPercent, "usedPercent": value.usedPercent,
                    "resetAt": value.resetAt.map { ISO8601DateFormatter().string(from: $0) } as Any? ?? NSNull()] as [String: Any]
        }
        let stamp = ISO8601DateFormatter().string(from: capturedAt)
        var body: [String: Any] = ["session": window(session), "weekly": window(weekly),
                                   "source": source, "updatedAt": stamp]
        if let reported {
            // updatedAt is retained for existing clients; for this source it is
            // explicitly capture time, not a guaranteed fresh server measurement.
            body["capturedAt"] = stamp
            body["freshnessVerified"] = false
            body["identityVerifiedForTrackedAccount"] = false
            body["reportedIdentity"] = ["email": reported.email as Any? ?? NSNull(),
                                        "organizationID": reported.organizationID as Any? ?? NSNull()]
        }
        return try JSONSerialization.data(withJSONObject: ["claude": body], options: [.sortedKeys])
    }

    private static func readStructuredUsage(profile: ClaudeAccountProfile, timeout: TimeInterval) async throws -> ClaudeCodeStructuredUsage {
        let inherited = ProcessInfo.processInfo.environment
        guard let executable = ClaudeCLI.resolveExecutable(environment: inherited) else { throw ClaudeOwnerUsageProbeError.cliUnavailable }
        let directory: URL
        do { directory = try ClaudeAuthRefreshCLI.prepareWorkspace(profile: profile) }
        catch { throw ClaudeOwnerUsageProbeError.workspaceUnavailable }
        let environment = Self.structuredEnvironment(profile: profile, inherited: inherited)
        return try await ClaudeCodeStructuredUsageReader.fetch(profile: profile, executable: executable,
            environment: environment, workingDirectory: directory, timeout: timeout)
    }

    static func structuredEnvironment(profile: ClaudeAccountProfile, inherited: [String: String]) -> [String: String] {
        var environment = ClaudeCLI.loginEnvironment(profile: profile, inherited: inherited)
        // The structured control request works with Pi's aggregate restriction.
        // Preserve that policy rather than silently opting into feature traffic.
        if let restriction = inherited["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] {
            environment["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] = restriction
        }
        environment["DISABLE_AUTOUPDATER"] = "1"
        environment["DISABLE_TELEMETRY"] = "1"
        environment["DISABLE_ERROR_REPORTING"] = "1"
        environment["CLAUDE_CODE_DISABLE_OFFICIAL_MARKETPLACE_AUTOINSTALL"] = "1"
        return environment
    }

    static func diagnostic(_ error: Error) -> String {
        if let typed = error as? ClaudeCodeStructuredUsageReaderError { return typed.localizedDescription }
        return ClaudeCodeUsageRouting.diagnostic(error)
    }
}

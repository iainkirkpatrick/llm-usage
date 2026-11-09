import Foundation

enum ClaudeCredentialRecoveryError: Error, LocalizedError {
    case coolingDown
    case notRefreshed

    var errorDescription: String? {
        switch self {
        case .coolingDown:
            return "Claude Code login refresh is cooling down. Try again in a few minutes, or sign in to this profile."
        case .notRefreshed:
            return "Claude Code did not provide a fresh login. Open this profile in Claude Code or sign in again."
        }
    }
}

/// App-only recovery: CLI usage helpers remain read-only and never launch Claude Code.
/// Claude Code is the sole token refresher; we never copy or rotate its refresh token.
actor ClaudeCredentialRecovery {
    typealias Runner = @Sendable (ClaudeAccountProfile, @escaping @Sendable () -> Bool) async throws -> Void
    private let reader: ClaudeCredentials.Reader
    private let runner: Runner
    private let now: @Sendable () -> Date
    private let cooldown: TimeInterval
    private var inFlight: [String: Task<Void, Error>] = [:]
    private var retryAfter: [String: Date] = [:]

    init(reader: @escaping ClaudeCredentials.Reader = { profile, prompt in
        try ClaudeCredentials.read(profile: profile, allowKeychainPrompt: prompt)
    }, runner: @escaping Runner = { profile, ready in
        try await ClaudeAuthRefreshCLI.refresh(profile: profile, isRefreshed: ready)
    }, now: @escaping @Sendable () -> Date = { Date() }, cooldown: TimeInterval = 300) {
        self.reader = reader
        self.runner = runner
        self.now = now
        self.cooldown = cooldown
    }

    func recover(profile: ClaudeAccountProfile) async throws {
        try Task.checkCancellation()
        let key = ClaudeCredentials.serviceName(for: profile)
        if let task = inFlight[key] {
            // A joining caller does not own cancellation. It observes cancellation
            // after the bounded shared operation; only its initiator can stop the CLI.
            try await task.value
            try Task.checkCancellation()
            return
        }
        let reader = self.reader
        let now = self.now
        // Another Claude Code process may already have refreshed this profile.
        do {
            let credential = try reader(profile, false)
            if credential.expiresAt > now() { return }
        } catch ClaudeBackendError.credentialsExpired {
            // Only expiry authorizes delegation. A changed/denied/conflicting store
            // between the original fetch and this re-read must still fail closed.
        } catch {
            throw error
        }
        guard (retryAfter[key] ?? .distantPast) <= now() else {
            throw ClaudeCredentialRecoveryError.coolingDown
        }
        retryAfter[key] = now().addingTimeInterval(cooldown)
        let runner = self.runner
        let task = Task<Void, Error> {
            let ready: @Sendable () -> Bool = {
                guard let credential = try? reader(profile, false) else { return false }
                return credential.expiresAt > now()
            }
            do {
                try await runner(profile, ready)
            } catch {
                // Claude Code may clear a rejected refresh token before reaching an
                // onboarding screen. Report the lost login, not the incidental UI.
                do { _ = try reader(profile, false) }
                catch ClaudeBackendError.credentialsCleared { throw ClaudeBackendError.credentialsCleared }
                catch { /* Preserve the runner's diagnostic for all other states. */ }
                throw error
            }
            guard ready() else { throw ClaudeCredentialRecoveryError.notRefreshed }
        }
        inFlight[key] = task
        defer { inFlight.removeValue(forKey: key) }
        // Cancelling the initiating refresh cancels all joined work. Keep the
        // cooldown even on cancellation so repeated timer/UI cancellation cannot hammer auth.
        try await withTaskCancellationHandler(operation: {
            try await task.value
        }, onCancel: { task.cancel() })
        try Task.checkCancellation()
    }
}

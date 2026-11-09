import Foundation

struct ClaudeCodeDefaultObservation: Sendable {
    let identity: ClaudeOwnerAuthObservation?
    let error: (any Error)?
}

/// CLI associations use reported organisation/email and an explicit source label,
/// never a fabricated authenticated account UUID. Existing OAuth pins stay intact.
enum ClaudeCodeUsageRouting {
    static func validate(_ identity: ClaudeOwnerAuthObservation, for profile: ClaudeAccountProfile) throws {
        guard let organization = identity.organizationID?.lowercased(), UUID(uuidString: organization) != nil,
              let email = identity.email, !email.isEmpty else { throw ClaudeOwnerUsageProbeError.authUnavailable }
        if let verified = profile.accountID {
            guard let pair = ClaudeDefaultIdentityHint.canonicalIdentity(verified),
                  pair.split(separator: ":").last.map(String.init) == organization else {
                throw ClaudeBackendError.identityMismatch
            }
        }
        if let pinned = profile.codeOrganizationID, pinned.lowercased() != organization {
            throw ClaudeBackendError.identityMismatch
        }
        for pinned in [profile.email, profile.codeEmail].compactMap({ $0 }) {
            guard pinned.caseInsensitiveCompare(email) == .orderedSame else { throw ClaudeBackendError.identityMismatch }
        }
    }

    private static func matches(_ identity: ClaudeOwnerAuthObservation, profile: ClaudeAccountProfile) -> Bool {
        // An unpinned isolated profile must not adopt an ambient login merely
        // because it is the only entry. Its first association comes from itself.
        guard profile.accountID != nil || profile.codeOrganizationID != nil,
              let email = profile.codeEmail ?? profile.email, !email.isEmpty else { return false }
        return (try? validate(identity, for: profile)) != nil
    }

    static func source(for profile: ClaudeAccountProfile, profiles: [ClaudeAccountProfile],
                       defaultIdentity: ClaudeOwnerAuthObservation?) -> ClaudeQuotaCredentialSource {
        if profile.configDirectory == nil { return .defaultClaudeCode }
        guard let identity = defaultIdentity, matches(identity, profile: profile) else { return .configuredProfile }
        let consumers = profiles.filter {
            $0.configDirectory == nil || matches(identity, profile: $0)
        }
        guard consumers.count == 1, consumers.first?.id == profile.id else { return .configuredProfile }
        return .defaultClaudeCode
    }

    static func canRetainLastKnown(after error: Error) -> Bool {
        if error is CancellationError { return false }
        if let error = error as? ClaudeBackendError {
            return error == .network || error == .rateLimited || error == .backoff || error == .invalidResponse
        }
        if let error = error as? ClaudeOwnerUsageProbeError {
            switch error {
            case .identityChanged, .signInRequired, .authUnavailable: return false
            default: return true
            }
        }
        return error is ClaudeCodeUsageFetcherError
    }

    static func diagnostic(_ error: Error) -> String {
        if error is CancellationError { return "Claude Code usage refresh was cancelled." }
        if let typed = error as? ClaudeOwnerUsageProbeError { return typed.localizedDescription }
        if let typed = error as? ClaudeBackendError { return typed.localizedDescription }
        if let typed = error as? ClaudeCodeUsageFetcherError { return typed.localizedDescription }
        return "Claude Code usage is unavailable. Try refreshing this profile again."
    }
}

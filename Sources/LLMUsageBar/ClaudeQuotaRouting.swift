import Foundation

enum ClaudeQuotaCredentialSource: Sendable, Equatable {
    case configuredProfile
    case defaultClaudeCode

    var title: String {
        switch self {
        case .configuredProfile: return "Configured Claude profile"
        case .defaultClaudeCode: return "Default Claude Code login"
        }
    }
}

/// The snapshot's account ID has been authenticated using the very credential
/// that fetched its quota. The hint is only for repair/permission decisions.
struct ClaudeDefaultQuotaObservation: Sendable {
    let quota: ClaudeQuotaSnapshot?
    let error: (any Error)?
    let identityHint: String?

    var loginAbsent: Bool {
        guard let error = error as? ClaudeBackendError else { return false }
        return error == .credentialsMissing || error == .credentialsCleared
    }
}

enum ClaudeQuotaRoutingError: Error, LocalizedError {
    case ambiguousIdentity
    case defaultIdentityUnknown

    var errorDescription: String? {
        switch self {
        case .ambiguousIdentity:
            return "Multiple tracked Claude profiles claim this subscription. Resolve duplicate account tracking before refreshing."
        case .defaultIdentityUnknown:
            return "The default Claude login could not be verified. Allow its Keychain access before automatically refreshing another copy of this account."
        }
    }
}

enum ClaudeQuotaRouting {
    enum Source {
        case configuredProfile(allowRecovery: Bool)
        case defaultClaudeCode
        case unavailable(any Error)
    }

    static func source(for profile: ClaudeAccountProfile, profiles: [ClaudeAccountProfile],
                       observation: ClaudeDefaultQuotaObservation) -> Source {
        let identity = ClaudeDefaultIdentityHint.canonicalIdentity(profile.accountID)
        if let identity,
           profiles.filter({ ClaudeDefaultIdentityHint.canonicalIdentity($0.accountID) == identity }).count != 1 {
            return .unavailable(ClaudeQuotaRoutingError.ambiguousIdentity)
        }
        // An explicitly tracked default directory must never fall back elsewhere.
        if profile.configDirectory == nil { return .defaultClaudeCode }
        if let identity, let quota = observation.quota,
           ClaudeDefaultIdentityHint.canonicalIdentity(quota.accountID) == identity {
            return .defaultClaudeCode
        }
        // A metadata hint cannot publish quota, but a denied/expired default known
        // to belong to this profile must not trigger a competing stale-copy refresh.
        if let identity, observation.quota == nil, !observation.loginAbsent,
           observation.identityHint == identity {
            return .defaultClaudeCode
        }
        // A different metadata hint is not proof that the inaccessible default is
        // another account: hints may lag a live switch. Read isolated quota if valid,
        // but do not refresh its token until default identity/absence is established.
        let defaultIsKnown = observation.quota != nil || observation.loginAbsent
        return .configuredProfile(allowRecovery: defaultIsKnown)
    }
}

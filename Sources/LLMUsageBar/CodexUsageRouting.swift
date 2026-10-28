import Foundation

/// A read-only observation, distinct from the durable credential-handoff ownership marker.
struct PiCodexUsageObservation: Sendable {
    let accountID: String?
    let error: String?

    enum Source: Equatable {
        case pi
        case native
        case unavailable(String)
    }

    func matchingProfile(in profiles: [CodexManagedAccountProfile]) -> UUID? {
        guard let accountID else { return nil }
        let matches = profiles.filter { $0.accountID?.trimmingCharacters(in: .whitespacesAndNewlines) == accountID }
        return matches.count == 1 ? matches[0].id : nil
    }

    func source(for profile: CodexManagedAccountProfile, profiles: [CodexManagedAccountProfile], recordedHandoff: UUID?) -> Source {
        // An unreadable/invalid Pi identity might be any native profile. Do not refresh a possible
        // second copy while the real owner cannot be established.
        if error != nil {
            return .unavailable("Pi account identity could not be verified. Check Pi sign-in before refreshing managed accounts.")
        }
        if let accountID, profile.accountID?.trimmingCharacters(in: .whitespacesAndNewlines) == accountID {
            guard matchingProfile(in: profiles) == profile.id else {
                return .unavailable("Pi's account matches multiple managed profiles. Resolve the duplicate account identities first.")
            }
            return .pi
        }
        if profile.id == recordedHandoff {
            return .unavailable("Pi login changed outside LLM Usage. Clear the stale Pi handoff, then sign in to this account again if needed.")
        }
        return .native
    }

    /// Being able to read a known Pi account does not grant ownership of its reset actions.
    func spendingSource(for profile: CodexManagedAccountProfile, profiles: [CodexManagedAccountProfile], recordedHandoff: UUID?) -> Source {
        guard !handoffIsOutOfSync(profiles: profiles, recordedHandoff: recordedHandoff) else {
            return .unavailable("Clear the stale Pi handoff before spending saved resets.")
        }
        let source = source(for: profile, profiles: profiles, recordedHandoff: recordedHandoff)
        if source == .pi && recordedHandoff != profile.id {
            return .unavailable("Manage this active Pi account before spending its saved resets.")
        }
        return source
    }

    func handoffIsOutOfSync(profiles: [CodexManagedAccountProfile], recordedHandoff: UUID?) -> Bool {
        guard let recordedHandoff else { return false }
        guard error == nil, let expected = profiles.first(where: { $0.id == recordedHandoff })?.accountID,
              !expected.isEmpty else { return true }
        return accountID != expected
    }
}

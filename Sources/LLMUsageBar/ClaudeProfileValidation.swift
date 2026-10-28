import Foundation

enum ClaudeProfileError: LocalizedError {
    case busy, invalidLabel, invalidDirectory, duplicateDirectory, saveFailed, notFound

    var errorDescription: String? {
        switch self {
        case .busy: "Wait for the current refresh or sign-in to finish."
        case .invalidLabel: "Enter a name for this Claude account."
        case .invalidDirectory: "Choose an existing, non-symlink Claude configuration directory using an absolute path."
        case .duplicateDirectory: "This Claude profile directory is already tracked."
        case .saveFailed: "Could not save Claude account tracking metadata."
        case .notFound: "This Claude profile is no longer tracked."
        }
    }
}

enum ClaudeProfileValidation {
    static func validate(_ profile: ClaudeAccountProfile, among profiles: [ClaudeAccountProfile]) throws {
        if let raw = profile.configDirectory {
            let expanded = (raw as NSString).expandingTildeInPath
            guard expanded.hasPrefix("/"), !expanded.contains("\0") else { throw ClaudeProfileError.invalidDirectory }
        }
        let info = try AppOwnedPathSafety.info(at: profile.directoryURL)
        guard info.exists, info.isDirectory, !info.isSymbolicLink else { throw ClaudeProfileError.invalidDirectory }
        let canonical = profile.directoryURL.resolvingSymlinksInPath().path
        guard !profiles.contains(where: { $0.directoryURL.resolvingSymlinksInPath().path == canonical }) else {
            throw ClaudeProfileError.duplicateDirectory
        }
    }
}

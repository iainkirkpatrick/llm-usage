import Foundation

private struct CLIError: LocalizedError {
    let message: String

    var errorDescription: String? { self.message }
}

private struct CodexCLIOutput: Encodable {
    struct Window: Encodable {
        let usedPercent: Double
        let remainingPercent: Double
        let resetAt: Date?
    }

    let codex: Codex

    struct Codex: Encodable {
        let session: Window?
        let weekly: Window?
        struct ResetCredits: Encodable {
            let availableCount: Int
        }

        let creditsRemaining: Double?
        let resetCredits: ResetCredits?
        let source: String
        let updatedAt: Date
    }
}

enum CLI {
    static func run(arguments: [String]) async -> Int32 {
        do {
            guard let command = arguments.first else {
                self.printUsage(to: FileHandle.standardOutput)
                return 0
            }

            switch command {
            case "help", "--help", "-h":
                self.printUsage(to: FileHandle.standardOutput)
                return 0
            case "codex":
                try await self.printCodex(arguments: Array(arguments.dropFirst()))
                return 0
            case "diagnose":
                try await self.printDiagnose()
                return 0
            default:
                throw CLIError(message: "Unknown command: \(command)")
            }
        } catch {
            self.writeLine("llm-usage-bar: \(error.localizedDescription)", to: FileHandle.standardError)
            self.writeLine("Run `llm-usage-bar help` for usage.", to: FileHandle.standardError)
            return 1
        }
    }

    private static func printCodex(arguments: [String]) async throws {
        var json = false

        for argument in arguments {
            switch argument {
            case "--json":
                json = true
            case "--help", "-h":
                self.printCodexUsage(to: FileHandle.standardOutput)
                return
            default:
                throw CLIError(message: "Unknown codex option: \(argument)")
            }
        }

        let snapshot = try await CodexFetcher().fetch()

        if json {
            try self.printJSON(self.codexOutput(from: snapshot))
        } else {
            self.writeLine("Codex usage (\(snapshot.sourceLabel))", to: FileHandle.standardOutput)
            self.writeLine("Session left: \(Formatting.percent(snapshot.session?.remainingPercent)) (resets in \(Formatting.relativeReset(snapshot.session?.resetAt)))", to: FileHandle.standardOutput)
            self.writeLine("Weekly left: \(Formatting.percent(snapshot.weekly?.remainingPercent)) (resets in \(Formatting.relativeReset(snapshot.weekly?.resetAt)))", to: FileHandle.standardOutput)
            self.writeLine("Credits: \(Formatting.currency(snapshot.creditsRemaining))", to: FileHandle.standardOutput)
            if let resetCredits = snapshot.resetCredits {
                let expiry = resetCredits.earliestExpiry.map { " (earliest expires \(Formatting.dateTime($0)))" } ?? ""
                self.writeLine("Saved resets: \(resetCredits.availableCount) available\(expiry)", to: FileHandle.standardOutput)
            }
        }
    }


    private static func printDiagnose() async throws {
        let config = ConfigStore.load()
        self.writeLine("LLM Usage Bar diagnostic", to: FileHandle.standardOutput)
        self.writeLine("Config: codex=\(config.codexEnabled) openCode=\(config.openCodeEnabled) pi=\(config.piEnabled) refresh=\(config.refreshIntervalSeconds)s", to: FileHandle.standardOutput)
        self.writeLine("Log: \(AppLog.fileURL.path)", to: FileHandle.standardOutput)

        if config.codexEnabled {
            do {
                let snapshot = try await CodexFetcher().fetch()
                self.writeLine("Codex OK: source=\(snapshot.sourceLabel) sessionLeft=\(Formatting.percent(snapshot.session?.remainingPercent)) weeklyLeft=\(Formatting.percent(snapshot.weekly?.remainingPercent)) credits=\(Formatting.currency(snapshot.creditsRemaining))", to: FileHandle.standardOutput)
            } catch {
                self.writeLine("Codex ERROR: \(error.localizedDescription)", to: FileHandle.standardOutput)
            }
        } else {
            self.writeLine("Codex disabled", to: FileHandle.standardOutput)
        }

        if config.openCodeEnabled {
            do {
                let snapshot = try await OpenCodeGoFetcher().fetch(
                    cookieHeader: config.openCodeCookieHeader,
                    workspaceID: config.openCodeWorkspaceID
                )
                let limitsText = snapshot.limits == nil ? "none" : "present"
                self.writeLine("OpenCode OK: workspace=\(snapshot.workspaceID) rows=\(snapshot.rows.count) limits=\(limitsText)", to: FileHandle.standardOutput)
            } catch {
                self.writeLine("OpenCode ERROR: \(error.localizedDescription)", to: FileHandle.standardOutput)
            }
        } else {
            self.writeLine("OpenCode disabled", to: FileHandle.standardOutput)
        }

        if config.piEnabled {
            do {
                let snapshot = try PiSessionsFetcher().fetch(
                    sessionsDirectory: config.piSessionsDirectory,
                    deduplicateForkHistory: config.piDeduplicateForkHistory
                )
                self.writeLine("Pi OK: sessions=\(snapshot.sessionCount) rows=\(snapshot.rows.count) forks=\(snapshot.forkedSessionCount) zeroCostRows=\(snapshot.zeroCostRowCount)", to: FileHandle.standardOutput)
                self.writeLine("Pi sessions: \(snapshot.sessionsDirectory)", to: FileHandle.standardOutput)
            } catch {
                self.writeLine("Pi ERROR: \(error.localizedDescription)", to: FileHandle.standardOutput)
            }
        } else {
            self.writeLine("Pi disabled", to: FileHandle.standardOutput)
        }
    }

    private static func codexOutput(from snapshot: CodexSnapshot) -> CodexCLIOutput {
        CodexCLIOutput(codex: .init(
            session: snapshot.session.map(self.windowOutput),
            weekly: snapshot.weekly.map(self.windowOutput),
            creditsRemaining: snapshot.creditsRemaining,
            resetCredits: snapshot.resetCredits.map { .init(availableCount: $0.availableCount) },
            source: snapshot.sourceLabel,
            updatedAt: snapshot.updatedAt
        ))
    }

    private static func windowOutput(from window: RateWindow) -> CodexCLIOutput.Window {
        CodexCLIOutput.Window(
            usedPercent: window.usedPercent,
            remainingPercent: window.remainingPercent,
            resetAt: window.resetAt
        )
    }

    private static func printJSON<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        FileHandle.standardOutput.write(data)
        self.writeLine("", to: FileHandle.standardOutput)
    }

    private static func printUsage(to handle: FileHandle) {
        self.writeLine("""
        Usage: llm-usage-bar <command> [options]

        Commands:
          codex [--json]    Print Codex session/weekly usage and credits
          diagnose          Check all enabled providers and print the log path
          help              Show this help
        """, to: handle)
    }

    private static func printCodexUsage(to handle: FileHandle) {
        self.writeLine("""
        Usage: llm-usage-bar codex [--json]

        Prints Codex usage using Pi-managed openai-codex auth when available,
        falling back to Codex CLI auth.
        """, to: handle)
    }

    private static func writeLine(_ line: String, to handle: FileHandle) {
        handle.write(Data((line + "\n").utf8))
    }
}

import Foundation
import LLMUsageCore

@main enum Main {
    static func main() async {
        exit(await run(Array(CommandLine.arguments.dropFirst())))
    }

    static func run(_ arguments: [String]) async -> Int32 {
        guard let command = arguments.first else { usage(); return 0 }
        do {
            switch command {
            case "help", "--help", "-h": usage()
            case "codex": try await codex(Array(arguments.dropFirst()))
            case "diagnose":
                guard arguments.count == 1 else { throw CLIError.message("diagnose takes no options") }
                return await diagnose() ? 0 : 1
            default: throw CLIError.message("Unknown command: \(command)")
            }
            return 0
        } catch {
            FileHandle.standardError.write(Data("llm-usage: \(error.localizedDescription)\nRun `llm-usage help` for usage.\n".utf8))
            return 1
        }
    }

    static func codex(_ arguments: [String]) async throws {
        if arguments.contains(where: { $0 != "--json" && $0 != "--help" && $0 != "-h" }) {
            throw CLIError.message("Unknown codex option: \(arguments.first { $0 != "--json" }!)")
        }
        if arguments.contains("--help") || arguments.contains("-h") { print("Usage: llm-usage codex [--json]"); return }
        let snapshot = try await CodexFetcher().fetch()
        if arguments.contains("--json") {
            FileHandle.standardOutput.write(try CodexCLIOutput(snapshot: snapshot).jsonData())
            print("")
        } else {
            func percent(_ value: Double?) -> String { value.map { String(format: "%.0f%%", $0) } ?? "—" }
            print("Codex usage (\(snapshot.sourceLabel))")
            print("Session left: \(percent(snapshot.session?.remainingPercent))")
            print("Weekly left: \(percent(snapshot.weekly?.remainingPercent))")
            if let credits = snapshot.creditsRemaining { print("Credits: \(credits)") } else { print("Credits: —") }
            if let resets = snapshot.resetCredits { print("Saved resets: \(resets.availableCount) available") }
        }
    }

    static func diagnose() async -> Bool {
        print("LLM Usage Codex diagnostic")
        do {
            let snapshot = try await CodexFetcher().fetch()
            print("Codex OK: source=\(snapshot.sourceLabel)")
            return true
        } catch {
            print("Codex ERROR: \(error.localizedDescription)")
            return false
        }
    }

    static func usage() {
        print("""
        Usage: llm-usage <command> [options]

        Commands:
          codex [--json]    Print Codex session/weekly usage and credits
          diagnose          Check local Codex fetching capability
          help              Show this help
        """)
    }
}

enum CLIError: LocalizedError { case message(String); var errorDescription: String? { if case let .message(value) = self { value } else { nil } } }

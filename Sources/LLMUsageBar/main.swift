import AppKit
import Foundation

let cliArguments = Array(CommandLine.arguments.dropFirst())

if !cliArguments.isEmpty {
    let exitCode = await CLI.run(arguments: cliArguments)
    exit(exitCode)
}

let app = NSApplication.shared
let delegate = AppController()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

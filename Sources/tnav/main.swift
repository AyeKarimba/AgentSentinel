import Darwin
import Foundation
import TNavCore

func printErr(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

let usage = """
tnav — route "Claude is waiting for you" to the right Terminal tab

USAGE
  tnav hook                 Consume a Claude Code hook payload on stdin (always exits 0)
  tnav jump <tty>           Focus the Terminal tab owning that tty
  tnav jump --oldest        Focus the longest-waiting session
  tnav list                 Show tracked sessions
  tnav resolve              Debug: show the tty/session this shell resolves to
  tnav spaces               Show which tabs are on the current Space, and the focus backend
  tnav prune                Drop records whose session process is gone
"""

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else {
    print(usage)
    exit(2)
}
let rest = Array(arguments.dropFirst())

switch command {
case "hook":
    exit(HookCommand.run())
case "jump":
    exit(JumpCommand.run(rest))
case "list":
    exit(ListCommand.run(rest))
case "spaces":
    exit(SpacesCommand.run(rest))
case "resolve":
    exit(ResolveCommand.run())
case "prune":
    let store = SessionStore()
    let removed = store.prune()
    print(removed.isEmpty ? "nothing to prune" : "pruned \(removed.count): \(removed.joined(separator: ", "))")
    exit(0)
case "-h", "--help", "help":
    print(usage)
    exit(0)
default:
    printErr("unknown command: \(command)\n\n\(usage)")
    exit(2)
}

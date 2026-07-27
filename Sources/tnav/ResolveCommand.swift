import Darwin
import Foundation
import TNavCore

/// Debug aid: run it inside a terminal to see exactly what the hook would resolve to.
/// This is the fastest way to diagnose "why didn't my tab get focused".
enum ResolveCommand {
    static func run() -> Int32 {
        let table = SysctlProcessTable()

        let matcher = ClaudeMatcher()
        print("ancestry (self → root):    [p_comm is unreliable; argv0 is the real signal]")
        print("  \(pad("pid", 7))\(pad("ppid", 7))\(pad("tty", 13))\(pad("p_comm", 12))\(pad("argv0", 10))claude?")
        var pid = getpid()
        var depth = 0
        while pid > 1, depth < 24, let row = table.row(for: pid) {
            let tty = row.tty.isEmpty ? "-" : row.tty
            print("  \(pad(String(row.pid), 7))\(pad(String(row.ppid), 7))\(pad(tty, 13))"
                  + "\(pad(row.command, 12))\(pad(row.argv0Basename, 10))"
                  + (matcher.matches(row) ? "yes" : ""))
            pid = row.ppid
            depth += 1
        }

        guard let identity = TTYResolver().resolve(from: getpid()) else {
            printErr("\nno controlling tty found — hooks from here would be ignored")
            return 1
        }

        print("""

            resolved:
              tty              \(identity.tty)
              sessionPid       \(identity.sessionPid)
              claudeAncestors  \(identity.claudeAncestors)
              nested           \(identity.isNested)
            """)

        if identity.isNested {
            print("\nnested session — hook events from here are intentionally ignored")
        }

        // Cross-check against what Claude Code exports about itself. A mismatch here is the
        // clearest signal that the ancestry walk has gone wrong.
        let environment = ProcessInfo.processInfo.environment
        if let claudePid = environment["CLAUDE_PID"].flatMap(Int32.init) {
            let agrees = claudePid == identity.sessionPid
            print("""

                cross-check (CLAUDE_PID from environment):
                  CLAUDE_PID       \(claudePid)
                  agrees           \(agrees ? "yes" : "NO — walk resolved \(identity.sessionPid)")
                """)
        }

        do {
            let controller = AdaptiveTabController()
            let ttys = try controller.knownTTYs()
            let matched = ttys.contains(identity.tty)
            let frontmost = try controller.frontmostTTY() ?? "(Terminal not frontmost)"
            print("""

                Terminal.app:
                  tabs open      \(ttys.count) (\(ttys.joined(separator: ", ")))
                  tty matches    \(matched ? "yes" : "NO — cannot focus this tab")
                  frontmost tty  \(frontmost)
                """)
            return matched ? 0 : 1
        } catch {
            printErr("\nTerminal.app query failed: \(error)")
            return 1
        }
    }

    private static func pad(_ value: String, _ width: Int) -> String {
        value.count >= width ? value : value + String(repeating: " ", count: width - value.count)
    }
}

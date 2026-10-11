import Foundation

/// Which terminal tab an agent session belongs to, plus enough context to tell a real
/// top-level session apart from a nested one.
public struct SessionIdentity: Equatable, Sendable {
    /// Controlling terminal of the owning session, e.g. "/dev/ttys003". This is the join
    /// key against Terminal.app's `tty of tab`.
    public let tty: String
    /// Process to watch for liveness — the nearest known agent ancestor when there is one.
    public let sessionPid: Int32
    /// Number of known-agent processes in the ancestry, of any kind.
    public let agentAncestors: Int
    /// The kind of the nearest agent ancestor, when one was recognised.
    public let nearestAgent: AgentKind?

    /// More than one agent ancestor means this event came from a nested session — Claude
    /// Code spawning `claude -p`, or Codex launched from Claude's Bash tool. Such a session
    /// resolves to its *parent's* TTY, so acting on it would mark the parent's tab "waiting"
    /// while the parent is actually busy. See docs/phase0-recon-findings.md.
    public var isNested: Bool { agentAncestors > 1 }

    public init(tty: String, sessionPid: Int32, agentAncestors: Int, nearestAgent: AgentKind?) {
        self.tty = tty
        self.sessionPid = sessionPid
        self.agentAncestors = agentAncestors
        self.nearestAgent = nearestAgent
    }
}

public struct TTYResolver: Sendable {
    private let table: ProcessTable
    private let matcher: ClaudeMatcher
    private let maxDepth: Int

    public init(table: ProcessTable = SysctlProcessTable(),
                matcher: ClaudeMatcher = ClaudeMatcher(),
                maxDepth: Int = 24) {
        self.table = table
        self.matcher = matcher
        self.maxDepth = maxDepth
    }

    /// Walks the ancestry from `startPid` toward the process-tree root, recording the first
    /// controlling TTY found and counting `claude` ancestors on the way.
    ///
    /// The walk continues past the first TTY rather than stopping there — counting *all*
    /// `claude` ancestors is what makes nested-session detection possible.
    public func resolve(from startPid: Int32) -> SessionIdentity? {
        var pid = startPid
        var depth = 0
        var visited = Set<Int32>()

        var tty = ""
        var firstTTYPid: Int32 = 0
        var nearestAgentPid: Int32 = 0
        var nearestKind: AgentKind? = nil
        var agentCount = 0

        while pid > 1, depth < maxDepth, !visited.contains(pid) {
            visited.insert(pid)
            guard let row = table.row(for: pid) else { break }

            if matcher.matches(row) {
                agentCount += 1
                if nearestAgentPid == 0 { nearestAgentPid = row.pid; nearestKind = .claude }
            }
            if tty.isEmpty, !row.tty.isEmpty {
                tty = row.tty
                firstTTYPid = row.pid
            }

            pid = row.ppid
            depth += 1
        }

        guard !tty.isEmpty else { return nil }

        // Prefer the claude process for liveness checks; fall back to whichever process
        // owns the TTY if claude wasn't recognisable (e.g. launched via a wrapper).
        let sessionPid = nearestAgentPid != 0 ? nearestAgentPid : firstTTYPid
        return SessionIdentity(tty: tty, sessionPid: sessionPid, agentAncestors: agentCount, nearestAgent: nearestKind)
    }
}

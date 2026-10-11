import Darwin
import Foundation

/// One row of the kernel process table, reduced to what ClaudeBar needs: who the
/// parent is, which terminal owns the process, and enough naming detail to recognise Claude
/// Code reliably.
public struct ProcessRow: Equatable, Sendable {
    public let pid: Int32
    public let ppid: Int32
    /// Absolute device path (e.g. "/dev/ttys003"), or "" when the process has no
    /// controlling terminal. Hook subprocesses always land in the "" case.
    public let tty: String
    /// `p_comm`, the kernel accounting name. Unreliable for spotting Claude Code: the
    /// binary is named after its version (".../claude/versions/2.1.220"), so this reads
    /// "2.1.220" rather than "claude" on a standard install.
    public let command: String
    /// `argv[0]` as the launcher set it — "claude" for Claude Code whatever the install
    /// layout. This is the dependable signal.
    public let argv0: String
    /// `argv[1]`. For a Node-based agent this is the script path, which is the only thing
    /// that identifies it: argv0 is just "node".
    public let argv1: String
    /// Absolute executable path, comparable against `CLAUDE_CODE_EXECPATH`.
    public let executablePath: String

    public init(pid: Int32,
                ppid: Int32,
                tty: String,
                command: String,
                argv0: String = "",
                argv1: String = "",
                executablePath: String = "") {
        self.pid = pid
        self.ppid = ppid
        self.tty = tty
        self.command = command
        self.argv0 = argv0
        self.argv1 = argv1
        self.executablePath = executablePath
    }

    public var argv0Basename: String {
        guard !argv0.isEmpty else { return "" }
        return (argv0 as NSString).lastPathComponent
    }
}

/// Abstracted so `TTYResolver` can be tested against a synthetic ancestry without
/// spawning real processes.
public protocol ProcessTable: Sendable {
    func row(for pid: Int32) -> ProcessRow?
}

/// Reads the process table via `sysctl`.
///
/// Deliberately not `ps`: the hook runs on every Claude Code event, and a fork/exec per
/// ancestry level was most of the 63-86ms measured during Phase 0 recon.
public struct SysctlProcessTable: ProcessTable {
    public init() {}

    public func row(for pid: Int32) -> ProcessRow? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride

        let rc = mib.withUnsafeMutableBufferPointer { buffer in
            sysctl(buffer.baseAddress, UInt32(buffer.count), &info, &size, nil, 0)
        }

        // sysctl reports success with size 0 for a pid that has exited, which would
        // otherwise yield a zeroed struct that looks like a real process.
        guard rc == 0, size > 0, info.kp_proc.p_pid == pid else { return nil }

        let command = withUnsafeBytes(of: info.kp_proc.p_comm) { raw -> String in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }

        var tty = ""
        let device = info.kp_eproc.e_tdev
        if device != -1, let name = devname(device, S_IFCHR) {
            tty = "/dev/" + String(cString: name)
        }

        let arguments = Self.arguments(for: pid, count: 2)
        return ProcessRow(pid: info.kp_proc.p_pid,
                          ppid: info.kp_eproc.e_ppid,
                          tty: tty,
                          command: command,
                          argv0: arguments.count > 0 ? arguments[0] : "",
                          argv1: arguments.count > 1 ? arguments[1] : "",
                          executablePath: Self.executablePath(for: pid))
    }

    /// The first `count` entries of argv from `KERN_PROCARGS2`. The buffer holds
    /// `[argc: Int32][exec path\0][\0 padding][argv0\0][argv1\0]...`; a 4KB buffer covers
    /// argv0 plus a script path and avoids allocating `KERN_ARGMAX` (1MB) per ancestry level.
    static func arguments(for pid: Int32, count wanted: Int) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var buffer = [UInt8](repeating: 0, count: 4096)
        var size = buffer.count

        let rc = mib.withUnsafeMutableBufferPointer { mibBuffer in
            sysctl(mibBuffer.baseAddress, UInt32(mibBuffer.count), &buffer, &size, nil, 0)
        }
        guard rc == 0, size > 4 else { return [] }

        let argc = Int(buffer[0]) | Int(buffer[1]) << 8 | Int(buffer[2]) << 16 | Int(buffer[3]) << 24
        var index = 4
        while index < size, buffer[index] != 0 { index += 1 }   // exec path
        while index < size, buffer[index] == 0 { index += 1 }   // alignment padding

        var result: [String] = []
        while result.count < min(wanted, max(argc, 0)), index < size {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            result.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return result
    }

    static func executablePath(for pid: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        return length > 0 ? String(cString: buffer) : ""
    }
}

/// In-memory table for tests.
public struct StubProcessTable: ProcessTable {
    private let rows: [Int32: ProcessRow]

    public init(_ rows: [ProcessRow]) {
        self.rows = Dictionary(uniqueKeysWithValues: rows.map { ($0.pid, $0) })
    }

    public func row(for pid: Int32) -> ProcessRow? { rows[pid] }
}

/// How to recognise an agent in the process table.
public struct AgentSignature: Sendable {
    /// What argv0 (or `p_comm`) reads when the agent is a native binary or a shim.
    public let binaryName: String
    /// For Node-based agents: substrings of the script path (argv1) that identify the package.
    /// Checked only when argv0 is a JavaScript runtime, so an unrelated `node server.js`
    /// never matches.
    public let scriptPathFragments: [String]

    public init(binaryName: String, scriptPathFragments: [String] = []) {
        self.binaryName = binaryName
        self.scriptPathFragments = scriptPathFragments
    }
}

public extension AgentKind {
    var signature: AgentSignature? {
        switch self {
        case .claude: return AgentSignature(binaryName: "claude")
        case .codex: return AgentSignature(binaryName: "codex")
        case .gemini: return AgentSignature(binaryName: "gemini",
                                            scriptPathFragments: ["/gemini-cli/"])
        case .copilot: return AgentSignature(binaryName: "copilot",
                                             scriptPathFragments: ["/@github/copilot/"])
        default: return nil
        }
    }
}

/// Decides whether a process is one of the known agents, and which.
///
/// Checks several signals because `p_comm` alone is wrong on a standard Claude install (the
/// binary is named after its version) and `argv0` alone is wrong for Node-based agents (it is
/// "node"). Ordered cheapest-and-most-portable first.
public struct AgentMatcher: Sendable {
    /// Exact executable paths from the environment, e.g. `CLAUDE_CODE_EXECPATH`.
    public let referenceExecutablePaths: [AgentKind: String]

    private static let javaScriptRuntimes: Set<String> = ["node", "bun", "deno"]

    public init(referenceExecutablePaths: [AgentKind: String]) {
        self.referenceExecutablePaths = referenceExecutablePaths
    }

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        var paths: [AgentKind: String] = [:]
        if let path = environment["CLAUDE_CODE_EXECPATH"], !path.isEmpty { paths[.claude] = path }
        referenceExecutablePaths = paths
    }

    public func match(_ row: ProcessRow) -> AgentKind? {
        for kind in AgentKind.known where matches(row, kind) { return kind }
        return nil
    }

    func matches(_ row: ProcessRow, _ kind: AgentKind) -> Bool {
        guard let signature = kind.signature else { return false }
        if row.argv0Basename == signature.binaryName { return true }
        if row.command == signature.binaryName { return true }
        if let reference = referenceExecutablePaths[kind], row.executablePath == reference { return true }
        if !signature.scriptPathFragments.isEmpty,
           Self.javaScriptRuntimes.contains(row.argv0Basename),
           signature.scriptPathFragments.contains(where: { row.argv1.contains($0) }) {
            return true
        }
        return false
    }
}

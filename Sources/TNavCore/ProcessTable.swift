import Darwin
import Foundation

/// One row of the kernel process table, reduced to what TerminalNavigator needs: who the
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
    /// Absolute executable path, comparable against `CLAUDE_CODE_EXECPATH`.
    public let executablePath: String

    public init(pid: Int32,
                ppid: Int32,
                tty: String,
                command: String,
                argv0: String = "",
                executablePath: String = "") {
        self.pid = pid
        self.ppid = ppid
        self.tty = tty
        self.command = command
        self.argv0 = argv0
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

        return ProcessRow(pid: info.kp_proc.p_pid,
                          ppid: info.kp_eproc.e_ppid,
                          tty: tty,
                          command: command,
                          argv0: Self.argv0(for: pid),
                          executablePath: Self.executablePath(for: pid))
    }

    /// `argv[0]` from `KERN_PROCARGS2`. The buffer holds
    /// `[argc: Int32][exec path\0][\0 padding][argv0\0][argv1\0]...`; only the first two
    /// strings are needed, so a 4KB buffer is plenty and avoids allocating `KERN_ARGMAX`
    /// (1MB) per ancestry level.
    static func argv0(for pid: Int32) -> String {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var buffer = [UInt8](repeating: 0, count: 4096)
        var size = buffer.count

        let rc = mib.withUnsafeMutableBufferPointer { mibBuffer in
            sysctl(mibBuffer.baseAddress, UInt32(mibBuffer.count), &buffer, &size, nil, 0)
        }
        guard rc == 0, size > 4 else { return "" }

        var index = 4
        while index < size, buffer[index] != 0 { index += 1 }   // exec path
        while index < size, buffer[index] == 0 { index += 1 }   // alignment padding
        guard index < size else { return "" }
        let start = index
        while index < size, buffer[index] != 0 { index += 1 }
        return String(decoding: buffer[start..<index], as: UTF8.self)
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

/// Decides whether a process is a Claude Code session.
///
/// Checks several signals because `p_comm` alone is wrong on a standard install — see
/// `ProcessRow.command`. Ordered cheapest-and-most-portable first.
public struct ClaudeMatcher: Sendable {
    public static let name = "claude"

    /// Taken from `CLAUDE_CODE_EXECPATH` when present: an exact match for the running install.
    public let referenceExecutablePath: String?

    public init(referenceExecutablePath: String?) {
        self.referenceExecutablePath = referenceExecutablePath
    }

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        let path = environment["CLAUDE_CODE_EXECPATH"]
        referenceExecutablePath = (path?.isEmpty ?? true) ? nil : path
    }

    public func matches(_ row: ProcessRow) -> Bool {
        if row.argv0Basename == Self.name { return true }
        if let reference = referenceExecutablePath, row.executablePath == reference { return true }
        // Installs where the binary really is called `claude`.
        if row.command == Self.name { return true }
        return false
    }
}

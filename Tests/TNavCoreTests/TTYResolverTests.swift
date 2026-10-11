import XCTest
@testable import TNavCore

final class TTYResolverTests: XCTestCase {
    /// The real chain captured in Phase 0 recon from a genuine top-level session
    /// (~/code/webapp on ttys002).
    private let topLevelChain = StubProcessTable([
        ProcessRow(pid: 19703, ppid: 12691, tty: "", command: "sh"),
        ProcessRow(pid: 12691, ppid: 1000, tty: "/dev/ttys002", command: "claude"),
        ProcessRow(pid: 1000, ppid: 991, tty: "/dev/ttys002", command: "-zsh"),
        ProcessRow(pid: 991, ppid: 645, tty: "/dev/ttys002", command: "login"),
        ProcessRow(pid: 645, ppid: 1, tty: "", command: "Terminal"),
    ])

    /// The real nested chain captured in Phase 0 recon: Claude Code spawning `claude -p`,
    /// which produces two `claude` ancestors and resolves to the *parent's* tty.
    private let nestedChain = StubProcessTable([
        ProcessRow(pid: 19594, ppid: 19575, tty: "", command: "sh"),
        ProcessRow(pid: 19575, ppid: 19571, tty: "", command: "claude"),
        ProcessRow(pid: 19571, ppid: 17544, tty: "", command: "zsh"),
        ProcessRow(pid: 17544, ppid: 16972, tty: "/dev/ttys003", command: "claude"),
        ProcessRow(pid: 16972, ppid: 16971, tty: "/dev/ttys003", command: "-zsh"),
        ProcessRow(pid: 16971, ppid: 645, tty: "/dev/ttys003", command: "login"),
        ProcessRow(pid: 645, ppid: 1, tty: "", command: "Terminal"),
    ])

    func testResolvesTopLevelSessionToItsOwnTTY() {
        let identity = TTYResolver(table: topLevelChain).resolve(from: 19703)
        XCTAssertEqual(identity?.tty, "/dev/ttys002")
        XCTAssertEqual(identity?.sessionPid, 12691, "should watch the claude process, not the shell")
        XCTAssertEqual(identity?.agentAncestors, 1)
        XCTAssertEqual(identity?.isNested, false)
    }

    func testDetectsNestedSessionRatherThanClaimingParentTab() {
        let identity = TTYResolver(table: nestedChain).resolve(from: 19594)
        // It still resolves a tty — the point is that it knows not to trust it.
        XCTAssertEqual(identity?.tty, "/dev/ttys003")
        XCTAssertEqual(identity?.agentAncestors, 2)
        XCTAssertEqual(identity?.isNested, true,
                       "two claude ancestors means the tty belongs to the parent session")
    }

    func testReturnsNilWhenNoControllingTerminalAnywhere() {
        let headless = StubProcessTable([
            ProcessRow(pid: 400, ppid: 300, tty: "", command: "sh"),
            ProcessRow(pid: 300, ppid: 1, tty: "", command: "claude"),
        ])
        XCTAssertNil(TTYResolver(table: headless).resolve(from: 400))
    }

    func testFallsBackToTTYOwnerWhenClaudeIsNotRecognisable() {
        // e.g. claude launched through a wrapper that renames the process.
        let wrapped = StubProcessTable([
            ProcessRow(pid: 500, ppid: 450, tty: "", command: "sh"),
            ProcessRow(pid: 450, ppid: 1, tty: "/dev/ttys009", command: "node"),
        ])
        let identity = TTYResolver(table: wrapped).resolve(from: 500)
        XCTAssertEqual(identity?.tty, "/dev/ttys009")
        XCTAssertEqual(identity?.sessionPid, 450)
        XCTAssertEqual(identity?.agentAncestors, 0)
        XCTAssertEqual(identity?.isNested, false)
    }

    func testSurvivesACycleInTheProcessTable() {
        let cyclic = StubProcessTable([
            ProcessRow(pid: 10, ppid: 20, tty: "", command: "a"),
            ProcessRow(pid: 20, ppid: 10, tty: "", command: "b"),
        ])
        // Must terminate rather than spin.
        XCTAssertNil(TTYResolver(table: cyclic).resolve(from: 10))
    }

    func testStopsAtMaxDepth() {
        var rows: [ProcessRow] = []
        for index in 1...50 {
            rows.append(ProcessRow(pid: Int32(index + 1), ppid: Int32(index + 2), tty: "", command: "sh"))
        }
        rows.append(ProcessRow(pid: 52, ppid: 1, tty: "/dev/ttys001", command: "claude"))
        let identity = TTYResolver(table: StubProcessTable(rows), maxDepth: 5).resolve(from: 2)
        XCTAssertNil(identity, "should give up rather than walk an unbounded chain")
    }

    // MARK: - Identifying claude when p_comm lies

    /// The real shape on this machine: the binary lives at .../claude/versions/2.1.220, so
    /// `p_comm` reads "2.1.220" and only argv0 / the exec path identify it.
    private let versionNamedChain = StubProcessTable([
        ProcessRow(pid: 900, ppid: 800, tty: "", command: "sh", argv0: "/bin/sh",
                   executablePath: "/bin/sh"),
        ProcessRow(pid: 800, ppid: 700, tty: "/dev/ttys003", command: "2.1.220", argv0: "claude",
                   executablePath: "/Users/you/.local/share/claude/versions/2.1.220"),
        ProcessRow(pid: 700, ppid: 1, tty: "/dev/ttys003", command: "-zsh", argv0: "-zsh",
                   executablePath: "/bin/zsh"),
    ])

    func testIdentifiesClaudeByArgv0WhenPCommIsTheVersionString() {
        let identity = TTYResolver(table: versionNamedChain).resolve(from: 900)
        XCTAssertEqual(identity?.agentAncestors, 1,
                       "p_comm is '2.1.220'; argv0 'claude' must still be recognised")
        XCTAssertEqual(identity?.sessionPid, 800)
        XCTAssertEqual(identity?.isNested, false)
    }

    func testIdentifiesClaudeByExecutablePathWhenArgv0IsUnhelpful() {
        let execPath = "/Users/you/.local/share/claude/versions/2.1.220"
        let chain = StubProcessTable([
            ProcessRow(pid: 900, ppid: 800, tty: "", command: "sh", argv0: "sh"),
            ProcessRow(pid: 800, ppid: 1, tty: "/dev/ttys003", command: "2.1.220",
                       argv0: "node", executablePath: execPath),
        ])
        let matcher = ClaudeMatcher(referenceExecutablePath: execPath)
        let identity = TTYResolver(table: chain, matcher: matcher).resolve(from: 900)
        XCTAssertEqual(identity?.agentAncestors, 1)
        XCTAssertEqual(identity?.sessionPid, 800)
    }

    func testDetectsNestingWhenBothClaudesAreVersionNamed() {
        let execPath = "/Users/you/.local/share/claude/versions/2.1.220"
        let chain = StubProcessTable([
            ProcessRow(pid: 950, ppid: 940, tty: "", command: "sh", argv0: "sh"),
            ProcessRow(pid: 940, ppid: 930, tty: "", command: "2.1.220", argv0: "claude",
                       executablePath: execPath),
            ProcessRow(pid: 930, ppid: 920, tty: "", command: "zsh", argv0: "zsh"),
            ProcessRow(pid: 920, ppid: 910, tty: "/dev/ttys003", command: "2.1.220",
                       argv0: "claude", executablePath: execPath),
            ProcessRow(pid: 910, ppid: 1, tty: "/dev/ttys003", command: "-zsh", argv0: "-zsh"),
        ])
        let identity = TTYResolver(table: chain).resolve(from: 950)
        XCTAssertEqual(identity?.agentAncestors, 2)
        XCTAssertEqual(identity?.isNested, true)
    }

    func testMatcherDoesNotFalsePositiveOnUnrelatedProcesses() {
        let matcher = ClaudeMatcher(referenceExecutablePath: "/opt/claude/versions/9")
        let unrelated = ProcessRow(pid: 1, ppid: 0, tty: "", command: "zsh",
                                   argv0: "-zsh", executablePath: "/bin/zsh")
        XCTAssertFalse(matcher.matches(unrelated))
        let claudeLike = ProcessRow(pid: 2, ppid: 1, tty: "", command: "node",
                                    argv0: "/usr/local/bin/claude", executablePath: "/usr/local/bin/node")
        XCTAssertTrue(matcher.matches(claudeLike), "argv0 basename should match through a full path")
    }

    // MARK: - Live process table

    func testLiveProcessTableIdentifiesTheRealClaudeProcess() throws {
        // Guards the exact regression this replaced: matching on p_comm silently failed
        // because the binary is named after the version.
        let environment = ProcessInfo.processInfo.environment
        guard let claudePid = environment["CLAUDE_PID"].flatMap(Int32.init) else {
            throw XCTSkip("not running under Claude Code")
        }
        let row = try XCTUnwrap(SysctlProcessTable().row(for: claudePid))
        XCTAssertEqual(row.argv0Basename, "claude")
        XCTAssertTrue(ClaudeMatcher(environment: environment).matches(row),
                      "p_comm was '\(row.command)'; matcher must still identify it")
        XCTAssertFalse(row.tty.isEmpty, "the session process owns the tab's tty")
    }

    func testLiveResolutionAgreesWithClaudePidAndIsNotNested() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let claudePid = environment["CLAUDE_PID"].flatMap(Int32.init) else {
            throw XCTSkip("not running under Claude Code")
        }
        let identity = try XCTUnwrap(TTYResolver().resolve(from: getpid()))
        XCTAssertEqual(identity.sessionPid, claudePid,
                       "the walk should land on the same process Claude Code advertises")
        XCTAssertGreaterThanOrEqual(identity.agentAncestors, 1)
    }

    func testLiveProcessTableReportsSelfWithoutATTY() {
        // The hook subprocess case from recon: sysctl works, tty is empty.
        let row = SysctlProcessTable().row(for: getpid())
        XCTAssertNotNil(row)
        XCTAssertEqual(row?.pid, getpid())
        XCTAssertFalse(row?.command.isEmpty ?? true)
    }

    func testLiveProcessTableReturnsNilForImpossiblePID() {
        XCTAssertNil(SysctlProcessTable().row(for: Int32.max))
    }
}

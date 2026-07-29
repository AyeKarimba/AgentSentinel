import XCTest
@testable import TNavCore

/// The menu bar badge is the part of the UI that's on screen all day, so what it counts and
/// which wait it reports are pinned down here rather than eyeballed.
final class StatusSummaryTests: XCTestCase {
    private func record(id: String,
                        state: SessionState = .waiting,
                        reason: WaitReason? = .turnComplete,
                        since: Double,
                        tty: String = "/dev/ttys003",
                        cwd: String = "/Users/you/proj") -> SessionRecord {
        SessionRecord(sessionId: id, tty: tty, pid: 100, cwd: cwd,
                      state: state, reason: reason, since: since)
    }

    func testIdleWhenNothingWaiting() {
        let summary = StatusSummary(records: [], config: Config(), now: 1000)
        XCTAssertEqual(summary.waitingCount, 0)
        XCTAssertNil(summary.badgeText)
        XCTAssertEqual(summary.tint, .idle)
        XCTAssertEqual(summary.accessibilityDescription, "No Claude sessions need you")
    }

    func testWorkingSessionsAreNotCounted() {
        let records = [record(id: "a", state: .working, reason: nil, since: 900)]
        let summary = StatusSummary(records: records, config: Config(), now: 1000)
        XCTAssertEqual(summary.waitingCount, 0)
        XCTAssertNil(summary.badgeText)
    }

    func testBadgeShowsCountAndLongestWait() {
        let records = [
            record(id: "a", since: 760, tty: "/dev/ttys001"),   // waited 240s = 4m
            record(id: "b", since: 953, tty: "/dev/ttys002"),   // waited 47s
        ]
        let summary = StatusSummary(records: records, config: Config(), now: 1000)
        XCTAssertEqual(summary.waitingCount, 2)
        XCTAssertEqual(summary.badgeText, "2 · 4m", "the timer reports the OLDEST wait")
        XCTAssertEqual(summary.tint, .waiting)
    }

    func testUrgentWinsTheTintEvenWhenItIsNotTheOldest() {
        let records = [
            record(id: "old", reason: .turnComplete, since: 700, tty: "/dev/ttys001"),
            record(id: "new", reason: .permission, since: 990, tty: "/dev/ttys002"),
        ]
        let summary = StatusSummary(records: records, config: Config(), now: 1000)
        XCTAssertEqual(summary.tint, .urgent)
        XCTAssertEqual(summary.badgeText, "2 · 5m", "tint and timer describe different sessions")
    }

    // MARK: - Mute interaction, the rule most likely to feel wrong

    func testMutedWaitingSessionsAreExcludedFromTheBadge() {
        let muted = record(id: "a", since: 700, tty: "/dev/ttys001", cwd: "/quiet")
        let audible = record(id: "b", since: 953, tty: "/dev/ttys002", cwd: "/loud")
        let config = Config(mutedTabs: [muted.tabMuteKey])
        let summary = StatusSummary(records: [muted, audible], config: config, now: 1000)

        XCTAssertEqual(summary.waitingCount, 1, "muting a tab should stop it nagging the badge")
        XCTAssertEqual(summary.badgeText, "1 · 47s",
                       "the timer must ignore the muted session's longer wait")
        XCTAssertEqual(summary.silencedWaitingCount, 1, "but it is still reported in the menu")
    }

    func testAllMutedStopsNaggingButStillLooksAlive() {
        let muted = record(id: "a", reason: .permission, since: 700)
        let config = Config(mutedTabs: [muted.tabMuteKey])
        let summary = StatusSummary(records: [muted], config: config, now: 1000)
        XCTAssertEqual(summary.tint, .working,
                       "muting silences a tab; it does not stop Claude running in it")
        XCTAssertNil(summary.badgeText)
        XCTAssertEqual(summary.silencedWaitingCount, 1)
    }

    func testPauseDropsTheAttentionColoursButNotToGrey() {
        let records = [record(id: "a", reason: .permission, since: 700)]
        let summary = StatusSummary(records: records, config: Config(paused: true), now: 1000)
        XCTAssertEqual(summary.tint, .working,
                       "paused should not glow red at you — but grey would claim nothing is "
                       + "running, which is worse than the nagging it replaced")
        XCTAssertEqual(summary.waitingCount, 1, "but the sessions are still waiting")
        XCTAssertEqual(summary.badgeText, "1 · 5m")
    }

    // MARK: - The icon's ladder

    /// Each rung is "more this concerns you" than the one below, and every step is verified
    /// here because the icon is the only part of the app visible without opening anything.
    func testIconColourClimbsWithHowMuchItConcernsYou() {
        func tint(_ records: [SessionRecord], _ visits: [String: Double] = [:]) -> StatusSummary.Tint {
            StatusSummary(records: records, config: Config(), visits: visits, now: 1000).tint
        }
        let busy = record(id: "w", state: .working, reason: nil, since: 900)
        let finished = record(id: "f", reason: .turnComplete, since: 900)
        let blocked = record(id: "b", reason: .permission, since: 900, tty: "/dev/ttys009")

        XCTAssertEqual(tint([]), .idle, "no sessions at all")
        XCTAssertEqual(tint([busy]), .working, "Claude is running, nothing wants you")
        XCTAssertEqual(tint([busy, finished]), .waiting, "one has finished and is waiting")
        XCTAssertEqual(tint([busy, finished, blocked]), .urgent, "one is blocked on permission")

        XCTAssertEqual(tint([busy, finished], ["f": 999]), .working,
                       "opening the finished one drops it back a rung, it does not go grey")
    }

    // MARK: - Redraw cadence

    func testRefreshIsPerSecondOnlyWhileTheLabelCountsInSeconds() {
        let fresh = [record(id: "a", since: 990)]
        XCTAssertEqual(StatusSummary(records: fresh, config: Config(), now: 1000).refreshInterval, 1)

        let old = [record(id: "a", since: 400)]
        XCTAssertEqual(StatusSummary(records: old, config: Config(), now: 1000).refreshInterval, 15,
                       "a '10m' label does not need a 1Hz timer")

        XCTAssertEqual(StatusSummary(records: [], config: Config(), now: 1000).refreshInterval, 30)
    }

    func testSingularAccessibilityWording() {
        let records = [record(id: "a", since: 953)]
        let summary = StatusSummary(records: records, config: Config(), now: 1000)
        XCTAssertEqual(summary.accessibilityDescription,
                       "1 Claude session needs you, longest 47s")
    }
}

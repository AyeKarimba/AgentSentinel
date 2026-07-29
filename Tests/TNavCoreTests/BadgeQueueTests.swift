import XCTest
@testable import TNavCore

/// The badge as a queue: it describes the tabs you have not dealt with yet, and checking one
/// hands it off to the next. When the queue empties the badge goes away entirely, even though
/// those sessions are all still waiting for a reply and still listed in the menu.
///
/// The distinction being pinned down here is "waiting" versus "waiting on *you*". They used to
/// be the same number, which meant the badge kept reporting work you had already looked at.
final class BadgeQueueTests: XCTestCase {
    private func record(_ id: String,
                        reason: WaitReason? = .turnComplete,
                        state: SessionState = .waiting,
                        since: Double,
                        reasonSince: Double? = nil) -> SessionRecord {
        SessionRecord(sessionId: id, tty: "/dev/tty\(id)", pid: 100, cwd: "/Users/you/\(id)",
                      state: state, reason: reason, since: since, reasonSince: reasonSince)
    }

    // MARK: - Walking the queue

    func testBadgeCountsOnlyTabsYouHaveNotChecked() {
        let records = [record("a", since: 760), record("b", since: 953)]
        let summary = StatusSummary(records: records, config: Config(),
                                    visits: [:], now: 1000)
        XCTAssertEqual(summary.badgeText, "2 · 4m")
        XCTAssertEqual(summary.tint, .waiting)
    }

    func testCheckingOneTabHandsTheBadgeToTheNext() {
        let records = [record("a", since: 760), record("b", since: 953)]
        // Opened the oldest one. The badge should stop describing it and move to the other.
        let summary = StatusSummary(records: records, config: Config(),
                                    visits: ["a": 999], now: 1000)
        XCTAssertEqual(summary.badgeText, "1 · 47s",
                       "the wait reported must be the next unchecked tab's, not the one just read")
    }

    func testCheckingEveryTabEmptiesTheQueueButNotTheBadge() {
        let records = [record("a", since: 760), record("b", since: 953)]
        let summary = StatusSummary(records: records, config: Config(),
                                    visits: ["a": 999, "b": 999], now: 1000)
        XCTAssertEqual(summary.badgeText, "2",
                       "no longer a queue of unread requests, but two tabs you opened and left "
                       + "unanswered — the badge stops counting down and starts counting those")
        XCTAssertEqual(summary.tint, .owed,
                       "out of the badge queue, but still unanswered — that is what owed is for")
        XCTAssertEqual(summary.needsAttentionCount, 0)
    }

    func testCheckedTabsAreStillWaitingEvenThoughTheBadgeIsQuiet() {
        let records = [record("a", since: 760)]
        let summary = StatusSummary(records: records, config: Config(),
                                    visits: ["a": 999], now: 1000)
        XCTAssertEqual(summary.needsAttentionCount, 0)
        XCTAssertEqual(summary.waitingCount, 1,
                       "the reply is still outstanding — the jump action has to keep reaching it")
    }

    func testTintFollowsTheUncheckedTabsNotTheCheckedOnes() {
        // Two finished turns, one already opened. The badge should describe only the other.
        let records = [record("read", since: 700), record("unread", since: 900)]
        let summary = StatusSummary(records: records, config: Config(),
                                    visits: ["read": 999], now: 1000)
        XCTAssertEqual(summary.tint, .waiting)
        XCTAssertEqual(summary.badgeText, "1 · 1m", "the opened one is teal now, not in the queue")
    }

    // MARK: - The dot, now reserved for what the badge cannot show

    func testDotFiresOnlyForSilencedTabs() {
        let target = record("a", reason: .permission, since: 700)
        let config = Config(mutedTabs: [target.tabMuteKey])
        let summary = StatusSummary(records: [target], config: config, visits: [:], now: 1000)
        XCTAssertNil(summary.badgeText, "silencing a tab takes it out of the badge by design")
        XCTAssertTrue(summary.showsUnseenDot,
                      "which is exactly why the dot has to cover it — nothing else can")
    }

    func testDotStaysQuietWhenTheBadgeAlreadySaysIt() {
        let summary = StatusSummary(records: [record("a", reason: .permission, since: 700)],
                                    config: Config(), visits: [:], now: 1000)
        XCTAssertEqual(summary.badgeText, "1 · 5m")
        XCTAssertFalse(summary.showsUnseenDot, "the badge is already red about this one")
    }

    func testDotClearsOnceTheSilencedTabIsOpened() {
        let target = record("a", reason: .permission, since: 700)
        let config = Config(mutedTabs: [target.tabMuteKey])
        let summary = StatusSummary(records: [target], config: config,
                                    visits: ["a": 999], now: 1000)
        XCTAssertFalse(summary.showsUnseenDot)
    }

    // MARK: - New information re-enters the queue

    func testAnEscalationAfterYourVisitCountsAsUnreadAgain() {
        // Claude finished, you looked, you left; a minute later it asked for permission. The
        // wait start is deliberately preserved so the elapsed label stays honest, which is
        // exactly why "have you seen this" cannot be measured from it.
        let escalated = record("a", reason: .permission, since: 700, reasonSince: 950)
        let summary = StatusSummary(records: [escalated], config: Config(),
                                    visits: ["a": 800], now: 1000)
        XCTAssertEqual(summary.needsAttentionCount, 1,
                       "an old visit cannot vouch for information that arrived after it")
        XCTAssertEqual(summary.badgeText, "1 · 5m",
                       "the wait reported is still the real one, measured from `since`")
    }

    func testOpeningABlockedTabDoesNotTakeItOutOfTheQueue() {
        // Everything else leaves the queue once seen. A permission request does not: Claude is
        // still stopped, and a badge that dropped it would be reporting your attention rather
        // than the session.
        let blocked = record("a", reason: .permission, since: 700)
        let summary = StatusSummary(records: [blocked], config: Config(),
                                    visits: ["a": 960], now: 1000)
        XCTAssertEqual(summary.needsAttentionCount, 1)
        XCTAssertEqual(summary.tint, .urgent, "opening it did not unblock it")
        XCTAssertEqual(summary.badgeText, "1 · 5m")
    }

    // MARK: - Redraw cadence

    func testCadenceFollowsTheYoungestWaitSoEverySecondsLabelStaysHonest() {
        // A row counting in seconds needs a 1Hz tick even when an hours-old wait sits above it.
        let records = [record("old", since: 100), record("new", since: 990)]
        let summary = StatusSummary(records: records, config: Config(), visits: [:], now: 1000)
        XCTAssertEqual(summary.refreshInterval, 1)
    }

    func testCheckedRowsStillTickWhileTheirLabelCountsInSeconds() {
        let records = [record("a", since: 990)]
        let summary = StatusSummary(records: records, config: Config(),
                                    visits: ["a": 999], now: 1000)
        XCTAssertEqual(summary.badgeText, "1", "out of the queue, counted as owed")
        XCTAssertEqual(summary.refreshInterval, 1, "and its row is on screen, still counting")
    }

    // MARK: - Wording

    func testAccessibilityDescribesTheQueueNotTheBacklog() {
        let records = [record("a", since: 760), record("b", since: 953)]
        let summary = StatusSummary(records: records, config: Config(), visits: ["a": 999],
                                    now: 1000)
        XCTAssertEqual(summary.accessibilityDescription,
                       "1 Claude session needs you, longest 47s · 1 already opened")
    }

    func testAccessibilityWhenEverythingHasBeenChecked() {
        let records = [record("a", since: 760)]
        let summary = StatusSummary(records: records, config: Config(), visits: ["a": 999],
                                    now: 1000)
        XCTAssertEqual(summary.accessibilityDescription,
                       "No Claude sessions need you · 1 already opened")
    }
}

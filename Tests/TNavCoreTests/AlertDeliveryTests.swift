import XCTest
@testable import TNavCore

/// Covers the part that decides whether an alert actually fires, now that `AlertPolicy` is
/// wired to something. The policy itself was always tested; what was missing was any record of
/// having alerted, which is what stops one request pinging forever.
///
/// That record lives outside the session file on purpose — the hook rewrites the whole record
/// on every event, so the app writing to it would race. It is keyed by the *wait* rather than
/// the session, so a new request re-arms without a flag to reset.
final class AlertDeliveryTests: XCTestCase {
    private var store: AlertStore!

    override func setUp() {
        super.setUp()
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tnav-alerts-\(UUID().uuidString).json")
        store = AlertStore(url: url)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: store.url)
        super.tearDown()
    }

    private func record(id: String = "s1",
                        reason: WaitReason? = .permission,
                        since: Double = 1000,
                        reasonSince: Double? = nil) -> SessionRecord {
        SessionRecord(sessionId: id, tty: "/dev/ttys003", pid: 100, cwd: "/Users/you/webapp",
                      state: .waiting, reason: reason, since: since, reasonSince: reasonSince)
    }

    /// What the app does: ask the store what it already sent, then let the existing policy rule.
    private func decide(_ record: SessionRecord,
                        config: Config = Config(),
                        frontmostTTY: String? = nil,
                        now: Double = 1000) -> AlertDecision {
        var view = record
        view.notified = store.hasNotified(record)
        view.escalated = store.hasEscalated(record)
        return AlertPolicy.decide(record: view, config: config,
                                  frontmostTTY: frontmostTTY, now: now)
    }

    // MARK: - Firing once

    func testAWaitAlertsOnceAndThenGoesQuiet() {
        let target = record()
        XCTAssertEqual(decide(target), .notify(.urgent))
        store.markNotified(target)
        XCTAssertEqual(decide(target), .suppressAlreadyNotified,
                       "the same request must not ping on every reload")
    }

    func testANewRequestInTheSameTabAlertsAgain() {
        let first = record(since: 1000)
        store.markNotified(first)
        // The user answered, Claude worked, and a new request arrived: same session, later wait.
        let second = record(since: 2000)
        XCTAssertEqual(decide(second, now: 2000), .notify(.urgent),
                       "a later wait is a different thing to be told about")
    }

    func testAnEscalationRearmsTheAlertToo() {
        // Turn completion, alerted, then it became a permission request a minute later.
        let finished = record(reason: .turnComplete, since: 1000)
        store.markNotified(finished)
        let escalated = record(reason: .permission, since: 1000, reasonSince: 1060)
        XCTAssertEqual(decide(escalated, now: 1100), .notify(.urgent),
                       "the reason changed under the user; the earlier ping did not cover it")
    }

    // MARK: - Escalation

    func testALongIgnoredRequestEscalatesExactlyOnce() {
        let target = record(since: 1000)
        store.markNotified(target)
        XCTAssertEqual(decide(target, now: 1200), .suppressAlreadyNotified,
                       "not yet — the escalation threshold is 300s")
        XCTAssertEqual(decide(target, now: 1300), .escalate)
        store.markEscalated(target)
        XCTAssertEqual(decide(target, now: 1400), .suppressAlreadyNotified,
                       "escalation is a single louder reminder, not a repeating alarm")
    }

    // MARK: - Reminders never banner

    func testAnIdleReminderNeverAlertsEvenIfTheFinishWasSuppressed() {
        // The Stop's banner can be suppressed while the user is reading that very tab. The
        // idle_prompt echo a minute later must not deliver it late — a banner about a tab
        // the user already read is noise, not news.
        let reminder = record(reason: .idlePrompt, since: 1000)
        XCTAssertEqual(decide(reminder), .suppressReminder)
    }

    func testAnIdleReminderDoesNotEscalateLateEither() {
        let reminder = record(reason: .idlePrompt, since: 1000)
        store.markNotified(reminder)
        XCTAssertEqual(decide(reminder, now: 1400), .suppressReminder)
    }

    func testAFinishedTurnNeverEscalates() {
        // Escalation is for blocked sessions. A finished turn said everything at the finish;
        // a louder reminder five minutes later is exactly the late banner being removed.
        let finished = record(reason: .turnComplete, since: 1000)
        store.markNotified(finished)
        XCTAssertEqual(decide(finished, now: 1400), .suppressAlreadyNotified)
    }

    // MARK: - Silence still wins

    func testAnythingTheUserSilencedNeverAlerts() {
        let target = record()
        let muted = Config(mutedTabs: [target.tabMuteKey])
        XCTAssertEqual(decide(target, config: muted), .suppressMuted)
        XCTAssertEqual(decide(target, config: Config(paused: true)), .suppressPaused)
        XCTAssertEqual(decide(target, config: Config(snoozedUntil: [target.tabMuteKey: 2000])),
                       .suppressSnoozed)
    }

    func testTheTabYouAreLookingAtDoesNotInterruptYou() {
        let target = record()
        XCTAssertEqual(decide(target, frontmostTTY: target.tty), .suppressAlreadyFocused)
    }

    // MARK: - Settings

    func testSlidersAreClampedWhenTheFileIsHandEdited() throws {
        let json = """
        {"soundVolume": 4.5, "pulseDepth": -2, "bannerSeconds": 9000}
        """.data(using: .utf8)!
        let settings = try JSONDecoder().decode(AlertSettings.self, from: json)
        XCTAssertEqual(settings.soundVolume, 1, "a volume above 1 would be silently ignored by AppKit")
        XCTAssertEqual(settings.pulseDepth, 0.1, "a depth of 0 would make the icon vanish entirely")
        XCTAssertEqual(settings.bannerSeconds, 30, "a banner that never leaves is a stuck window")
    }

    func testSettingsFromAnOlderBuildStillLoad() throws {
        // A config written before alerting existed has no `alerts` key at all.
        let json = #"{"paused": false, "mutedTabs": ["a|b"]}"#.data(using: .utf8)!
        let config = try JSONDecoder().decode(Config.self, from: json)
        XCTAssertEqual(config.mutedTabs, ["a|b"])
        XCTAssertEqual(config.alerts, AlertSettings(), "missing settings fall back to defaults")
    }

    // MARK: - Launch

    func testAnAlreadyOldWaitIsAdoptedSilentlyOnLaunch() {
        // Launching with sessions that have been waiting for ages must not fire anything: the
        // user has been living with them, they are not news.
        let old = record(since: 1000)
        store.adopt(old, escalateAfterSeconds: 300, now: 5000)
        XCTAssertEqual(decide(old, now: 5000), .suppressAlreadyNotified,
                       "and not one tick later either — adopting only the first tier would let "
                       + "every long wait escalate immediately, which is the same burst")
    }

    func testAYoungWaitAdoptedOnLaunchStillEscalatesLater() {
        let fresh = record(since: 1000)
        store.adopt(fresh, escalateAfterSeconds: 300, now: 1010)
        XCTAssertEqual(decide(fresh, now: 1100), .suppressAlreadyNotified, "not yet")
        XCTAssertEqual(decide(fresh, now: 1400), .escalate,
                       "it was young when adopted, so its escalation is still ahead of it")
    }

    func testAlertStatePrunesWithTheSessions() {
        let target = record(id: "gone")
        store.markNotified(target)
        XCTAssertTrue(store.hasNotified(target))
        store.prune(keeping: ["still-here"])
        XCTAssertFalse(store.hasNotified(target))
    }
}

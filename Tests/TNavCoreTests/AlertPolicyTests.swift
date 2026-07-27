import XCTest
@testable import TNavCore

/// The suppression rule set as a table. This is the behaviour the user will feel most
/// directly — a false alert or a missed alert both live here.
final class AlertPolicyTests: XCTestCase {
    private func record(state: SessionState = .waiting,
                        reason: WaitReason? = .turnComplete,
                        since: Double = 1000,
                        notified: Bool = false,
                        escalated: Bool = false,
                        tty: String = "/dev/ttys003",
                        cwd: String = "/Users/you/proj") -> SessionRecord {
        SessionRecord(sessionId: "s1", tty: tty, pid: 100, cwd: cwd,
                      state: state, reason: reason, since: since,
                      notified: notified, escalated: escalated)
    }

    func testNotifiesNormalTierForTurnComplete() {
        let decision = AlertPolicy.decide(record: record(reason: .turnComplete),
                                          config: Config(),
                                          frontmostTTY: nil,
                                          now: 1000)
        XCTAssertEqual(decision, .notify(.normal))
    }

    func testNotifiesUrgentTierForPermission() {
        let decision = AlertPolicy.decide(record: record(reason: .permission),
                                          config: Config(),
                                          frontmostTTY: nil,
                                          now: 1000)
        XCTAssertEqual(decision, .notify(.urgent))
    }

    func testWorkingSessionNeverAlerts() {
        let decision = AlertPolicy.decide(record: record(state: .working, reason: nil),
                                          config: Config(),
                                          frontmostTTY: nil,
                                          now: 1000)
        XCTAssertEqual(decision, .suppressNotWaiting)
    }

    func testTabMuteSuppresses() {
        let target = record()
        let config = Config(mutedTabs: [target.tabMuteKey])
        XCTAssertEqual(AlertPolicy.decide(record: target, config: config, frontmostTTY: nil, now: 1000),
                       .suppressMuted)
    }

    func testTabMuteIsScopedToThatTabOnly() {
        let muted = record(tty: "/dev/ttys003")
        let other = record(tty: "/dev/ttys009")
        let config = Config(mutedTabs: [muted.tabMuteKey])
        XCTAssertEqual(AlertPolicy.decide(record: other, config: config, frontmostTTY: nil, now: 1000),
                       .notify(.normal))
    }

    func testTabMuteSurvivesADifferentSessionInTheSameTabAndDirectory() {
        var restarted = record()
        restarted.sessionId = "a-brand-new-session-id"
        let config = Config(mutedTabs: [record().tabMuteKey])
        XCTAssertEqual(AlertPolicy.decide(record: restarted, config: config, frontmostTTY: nil, now: 1000),
                       .suppressMuted,
                       "tab-scoped mute should outlive the session that set it")
    }

    func testSessionMuteSuppressesOnlyThatSession() {
        let target = record()
        let config = Config(mutedSessions: ["s1"])
        XCTAssertEqual(AlertPolicy.decide(record: target, config: config, frontmostTTY: nil, now: 1000),
                       .suppressMuted)
    }

    func testGlobalPauseSuppresses() {
        XCTAssertEqual(AlertPolicy.decide(record: record(), config: Config(paused: true),
                                          frontmostTTY: nil, now: 1000),
                       .suppressPaused)
    }

    func testAlreadyLookingAtThatTabSuppresses() {
        XCTAssertEqual(AlertPolicy.decide(record: record(tty: "/dev/ttys003"),
                                          config: Config(),
                                          frontmostTTY: "/dev/ttys003",
                                          now: 1000),
                       .suppressAlreadyFocused)
    }

    func testLookingAtADifferentTabStillNotifies() {
        XCTAssertEqual(AlertPolicy.decide(record: record(tty: "/dev/ttys003"),
                                          config: Config(),
                                          frontmostTTY: "/dev/ttys009",
                                          now: 1000),
                       .notify(.normal))
    }

    func testTerminalNotFrontmostStillNotifies() {
        XCTAssertEqual(AlertPolicy.decide(record: record(), config: Config(),
                                          frontmostTTY: nil, now: 1000),
                       .notify(.normal))
    }

    func testAlreadyNotifiedStaysQuietBeforeEscalationWindow() {
        XCTAssertEqual(AlertPolicy.decide(record: record(since: 1000, notified: true),
                                          config: Config(escalateAfterSeconds: 300),
                                          frontmostTTY: nil,
                                          now: 1200),
                       .suppressAlreadyNotified)
    }

    func testEscalatesOnceAfterTheWindow() {
        XCTAssertEqual(AlertPolicy.decide(record: record(since: 1000, notified: true),
                                          config: Config(escalateAfterSeconds: 300),
                                          frontmostTTY: nil,
                                          now: 1301),
                       .escalate)
    }

    func testDoesNotEscalateTwice() {
        XCTAssertEqual(AlertPolicy.decide(record: record(since: 1000, notified: true, escalated: true),
                                          config: Config(escalateAfterSeconds: 300),
                                          frontmostTTY: nil,
                                          now: 5000),
                       .suppressAlreadyNotified)
    }

    func testMuteBeatsEscalation() {
        let target = record(since: 1000, notified: true)
        let config = Config(escalateAfterSeconds: 300, mutedTabs: [target.tabMuteKey])
        XCTAssertEqual(AlertPolicy.decide(record: target, config: config, frontmostTTY: nil, now: 9000),
                       .suppressMuted,
                       "a deliberately parked tab must stop nagging")
    }

    func testFocusBeatsEscalation() {
        XCTAssertEqual(AlertPolicy.decide(record: record(since: 1000, notified: true),
                                          config: Config(escalateAfterSeconds: 300),
                                          frontmostTTY: "/dev/ttys003",
                                          now: 9000),
                       .suppressAlreadyFocused)
    }

    // MARK: - Label formatting

    func testSummaryReadsAsSpecified() {
        let target = record(reason: .permission, since: 1000)
        XCTAssertEqual(target.summary(now: 1012), "proj — needs permission · 12s")
    }

    func testElapsedFormatting() {
        XCTAssertEqual(Elapsed.short(0), "0s")
        XCTAssertEqual(Elapsed.short(8.4), "8s")
        XCTAssertEqual(Elapsed.short(59), "59s")
        XCTAssertEqual(Elapsed.short(60), "1m")
        XCTAssertEqual(Elapsed.short(3599), "59m", "truncates rather than rounding up to a bogus 60m")
        XCTAssertEqual(Elapsed.short(3600), "1h")
        XCTAssertEqual(Elapsed.short(3840), "1h04m")
        XCTAssertEqual(Elapsed.short(-5), "0s", "clock skew must not print negative waits")
    }
}

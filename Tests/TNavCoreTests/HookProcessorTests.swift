import XCTest
@testable import TNavCore

final class HookProcessorTests: XCTestCase {
    private let id = "9cf7abf1-94cb-4db1-912a-38247f0898b6"
    private let cwd = "/Users/you/code/MacTerminalNavigator"
    private let identity = SessionIdentity(tty: "/dev/ttys003", sessionPid: 17544,
                                           agentAncestors: 1, nearestAgent: .claude)
    private let nested = SessionIdentity(tty: "/dev/ttys003", sessionPid: 17544,
                                         agentAncestors: 2, nearestAgent: .claude)

    private func hook(_ event: AgentEvent?, raw: String = "X", model: String? = nil) -> DecodedHook {
        DecodedHook(sessionId: id, cwd: cwd, model: model, rawEventName: raw, event: event)
    }

    private func apply(_ event: AgentEvent?, raw: String = "X", agent: AgentKind = .claude,
                       model: String? = nil, existing: SessionRecord? = nil,
                       identity: SessionIdentity? = nil, now: Double) -> HookOutcome {
        HookProcessor.apply(agent: agent, hook: hook(event, raw: raw, model: model),
                            identity: identity ?? self.identity, existing: existing, now: now)
    }

    private func waiting(reason: WaitReason, since: Double, notified: Bool, escalated: Bool = false) -> SessionRecord {
        SessionRecord(sessionId: id, tty: "/dev/ttys003", pid: 17544, cwd: cwd,
                      state: .waiting, reason: reason, since: since,
                      notified: notified, escalated: escalated)
    }

    private func working(since: Double) -> SessionRecord {
        SessionRecord(sessionId: id, tty: "/dev/ttys003", pid: 17544, cwd: "/tmp/x",
                      state: .working, since: since)
    }

    // MARK: - Nested and unknown

    func testIgnoresNestedSessionEntirely() {
        XCTAssertEqual(apply(.turnComplete(lastMessage: nil), identity: nested, now: 1000), .ignoredNested)
    }

    func testUnknownEventIsIgnoredByName() {
        XCTAssertEqual(apply(nil, raw: "SubagentStop", now: 1000), .ignoredUnknownEvent("SubagentStop"))
    }

    // MARK: - Agent and model land on the record

    func testRecordCarriesAgentAndModel() {
        let outcome = apply(.sessionStart, agent: .codex, model: "gpt-6-astra", now: 1000)
        guard case .updated(let record) = outcome else { return XCTFail("expected update") }
        XCTAssertEqual(record.agent, .codex)
        XCTAssertEqual(record.model, "gpt-6-astra")
    }

    func testModelPersistsWhenALaterEventOmitsIt() {
        var existing = working(since: 500)
        existing.agent = .codex
        existing.model = "gpt-6-astra"
        let outcome = apply(.turnComplete(lastMessage: "done"), agent: .codex, existing: existing, now: 1000)
        guard case .updated(let record) = outcome else { return XCTFail("expected update") }
        XCTAssertEqual(record.model, "gpt-6-astra")
    }

    func testSessionEndRemovesRecordForThatAgent() {
        XCTAssertEqual(apply(.sessionEnd, agent: .gemini, now: 1000),
                       .removed(agent: .gemini, sessionId: id))
    }

    // MARK: - Reason mapping

    func testTurnCompleteIsNormalUrgency() {
        let outcome = apply(.turnComplete(lastMessage: "pong"), now: 1000)
        guard case .updated(let record) = outcome else { return XCTFail("expected update") }
        XCTAssertEqual(record.state, .waiting)
        XCTAssertEqual(record.reason, .turnComplete)
        XCTAssertEqual(record.urgency, .normal)
        XCTAssertEqual(record.since, 1000)
        XCTAssertFalse(record.notified)
        XCTAssertEqual(record.lastAssistantMessage, "pong")
        XCTAssertEqual(record.tty, "/dev/ttys003")
        XCTAssertEqual(record.project, "MacTerminalNavigator")
    }

    func testIdlePromptIsNotUrgent() {
        let outcome = apply(.idlePrompt, now: 1000)
        guard case .updated(let record) = outcome else { return XCTFail("expected update") }
        XCTAssertEqual(record.reason, .idlePrompt)
        XCTAssertEqual(record.urgency, .normal)
    }

    func testNeedsPermissionIsUrgentAndCarriesItsMessage() {
        let outcome = apply(.needsPermission(message: "Allow Bash?"), now: 1000)
        guard case .updated(let record) = outcome else { return XCTFail("expected update") }
        XCTAssertEqual(record.reason, .permission)
        XCTAssertEqual(record.urgency, .urgent)
        XCTAssertEqual(record.lastAssistantMessage, "Allow Bash?")
    }

    // MARK: - The user acting clears the alert

    func testPromptSubmittedClearsPendingAlert() {
        let existing = waiting(reason: .permission, since: 500, notified: true, escalated: true)
        let outcome = apply(.promptSubmitted, existing: existing, now: 1000)
        guard case .updated(let record) = outcome else { return XCTFail("expected update") }
        XCTAssertEqual(record.state, .working)
        XCTAssertNil(record.reason)
        XCTAssertFalse(record.notified)
        XCTAssertFalse(record.escalated)
    }

    // MARK: - `since` preservation and notification re-arming

    func testRepeatedTurnCompletePreservesOriginalWaitStart() {
        let existing = waiting(reason: .turnComplete, since: 500, notified: true)
        let outcome = apply(.turnComplete(lastMessage: nil), existing: existing, now: 1000)
        guard case .updated(let record) = outcome else { return XCTFail("expected update") }
        XCTAssertEqual(record.since, 500, "elapsed time must measure the real wait")
        XCTAssertTrue(record.notified, "same urgency should not re-notify")
    }

    func testIdlePromptAfterTurnCompleteDoesNotReArmTheAlert() {
        let existing = waiting(reason: .turnComplete, since: 500, notified: true, escalated: true)
        let outcome = apply(.idlePrompt, existing: existing, now: 560)
        guard case .updated(let record) = outcome else { return XCTFail("expected update") }
        XCTAssertEqual(record.reason, .idlePrompt)
        XCTAssertEqual(record.since, 500)
        XCTAssertTrue(record.notified)
        XCTAssertTrue(record.escalated)
    }

    func testPermissionAfterTurnCompleteReArmsTheAlert() {
        let existing = waiting(reason: .turnComplete, since: 500, notified: true, escalated: true)
        let outcome = apply(.needsPermission(message: nil), existing: existing, now: 560)
        guard case .updated(let record) = outcome else { return XCTFail("expected update") }
        XCTAssertEqual(record.reason, .permission)
        XCTAssertFalse(record.notified, "climbing to urgent should ping again")
        XCTAssertFalse(record.escalated)
        XCTAssertEqual(record.since, 500)
        XCTAssertEqual(record.reasonSince, 560, "new information restarts the seen clock")
    }

    func testRepeatedIdlePromptDoesNotReArm() {
        let existing = waiting(reason: .idlePrompt, since: 500, notified: true)
        let outcome = apply(.idlePrompt, existing: existing, now: 600)
        guard case .updated(let record) = outcome else { return XCTFail("expected update") }
        XCTAssertTrue(record.notified)
    }

    func testTurnCompleteAfterWorkingStartsFreshWait() {
        let outcome = apply(.turnComplete(lastMessage: nil), existing: working(since: 500), now: 1000)
        guard case .updated(let record) = outcome else { return XCTFail("expected update") }
        XCTAssertEqual(record.since, 1000)
    }

    // MARK: - Tool activity

    func testToolStartingMarksAWaitingSessionWorking() {
        let existing = waiting(reason: .permission, since: 500, notified: true, escalated: true)
        let outcome = apply(.toolStarting, existing: existing, now: 1000)
        guard case .updated(let record) = outcome else { return XCTFail("expected update") }
        XCTAssertEqual(record.state, .working)
        XCTAssertNil(record.reason)
        XCTAssertEqual(record.since, 1000, "the approval starts a fresh work period")
        XCTAssertFalse(record.notified)
    }

    func testToolStartingWhileAlreadyWorkingPreservesTheWorkStart() {
        let outcome = apply(.toolStarting, existing: working(since: 500), now: 1000)
        guard case .updated(let record) = outcome else { return XCTFail("expected update") }
        XCTAssertEqual(record.since, 500, "every tool call fires this; the clock must not restart per tool")
    }

    func testWaitPreservesEarlierMessageWhenEventOmitsIt() {
        var existing = waiting(reason: .turnComplete, since: 500, notified: true)
        existing.lastAssistantMessage = "earlier answer"
        let outcome = apply(.idlePrompt, existing: existing, now: 600)
        guard case .updated(let record) = outcome else { return XCTFail("expected update") }
        XCTAssertEqual(record.lastAssistantMessage, "earlier answer")
    }
}

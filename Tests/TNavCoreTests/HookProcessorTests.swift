import XCTest
@testable import TNavCore

final class HookProcessorTests: XCTestCase {
    private let identity = SessionIdentity(tty: "/dev/ttys003", sessionPid: 17544, claudeAncestors: 1)
    private let nested = SessionIdentity(tty: "/dev/ttys003", sessionPid: 17544, claudeAncestors: 2)

    private func payload(_ event: String,
                         notificationType: String? = nil,
                         lastMessage: String? = nil,
                         cwd: String = "/Users/you/code/MacTerminalNavigator") throws -> HookPayload {
        var object: [String: Any] = [
            "session_id": "9cf7abf1-94cb-4db1-912a-38247f0898b6",
            "cwd": cwd,
            "hook_event_name": event,
        ]
        if let notificationType { object["notification_type"] = notificationType }
        if let lastMessage { object["last_assistant_message"] = lastMessage }
        let data = try JSONSerialization.data(withJSONObject: object)
        return try HookPayload.decode(data)
    }

    private func waiting(reason: WaitReason, since: Double, notified: Bool, escalated: Bool = false) -> SessionRecord {
        SessionRecord(sessionId: "9cf7abf1-94cb-4db1-912a-38247f0898b6",
                      tty: "/dev/ttys003",
                      pid: 17544,
                      cwd: "/Users/you/code/MacTerminalNavigator",
                      state: .waiting,
                      reason: reason,
                      since: since,
                      notified: notified,
                      escalated: escalated)
    }

    // MARK: - Payload decoding, against the shapes captured in Phase 0

    func testDecodesRealStopPayload() throws {
        let raw = """
        {"session_id":"9cf7abf1","transcript_path":"/tmp/t.jsonl",\
        "cwd":"/Users/you/code/MacTerminalNavigator","prompt_id":"bf47",\
        "permission_mode":"default","hook_event_name":"Stop","stop_hook_active":false,\
        "last_assistant_message":"pong","background_tasks":[],"session_crons":[]}
        """
        let decoded = try HookPayload.decode(Data(raw.utf8))
        XCTAssertEqual(decoded.sessionId, "9cf7abf1")
        XCTAssertEqual(decoded.hookEventName, "Stop")
        XCTAssertEqual(decoded.lastAssistantMessage, "pong")
    }

    func testDecodesRealNotificationPayload() throws {
        let raw = """
        {"session_id":"20aae48f","transcript_path":"/tmp/t.jsonl",\
        "cwd":"/Users/you/code/webapp","prompt_id":"5b04",\
        "hook_event_name":"Notification","message":"Claude is waiting for your input",\
        "notification_type":"idle_prompt"}
        """
        let decoded = try HookPayload.decode(Data(raw.utf8))
        XCTAssertEqual(decoded.notificationType, "idle_prompt")
        XCTAssertEqual(decoded.message, "Claude is waiting for your input")
    }

    // MARK: - Nested sessions

    func testIgnoresNestedSessionEntirely() throws {
        let outcome = HookProcessor.apply(payload: try payload("Stop"),
                                         identity: nested,
                                         existing: nil,
                                         now: 1000)
        XCTAssertEqual(outcome, .ignoredNested)
    }

    // MARK: - Reason mapping

    func testIdlePromptMapsToIdleReasonAndIsNotUrgent() {
        XCTAssertEqual(HookProcessor.waitReason(forNotificationType: "idle_prompt"), .idlePrompt)
        XCTAssertEqual(WaitReason.idlePrompt.urgency, .normal,
                       "it is a reminder that Claude is waiting, not a new thing blocking it — "
                       + "only a permission request stops Claude from proceeding")
        XCTAssertEqual(WaitReason.permission.urgency, .urgent)
    }

    func testUnknownNotificationTypeIsTreatedAsUrgentNotIgnored() {
        // The permission-request type was never observed in recon; unknown must not be dropped.
        XCTAssertEqual(HookProcessor.waitReason(forNotificationType: "some_future_type"), .permission)
        XCTAssertEqual(HookProcessor.waitReason(forNotificationType: nil), .permission)
        XCTAssertEqual(WaitReason.permission.urgency, .urgent)
    }

    func testStopIsNormalUrgency() {
        XCTAssertEqual(WaitReason.turnComplete.urgency, .normal)
    }

    // MARK: - State transitions

    func testStopMarksSessionWaitingAndCarriesLastMessage() throws {
        let outcome = HookProcessor.apply(payload: try payload("Stop", lastMessage: "pong"),
                                         identity: identity,
                                         existing: nil,
                                         now: 1000)
        guard case .updated(let record) = outcome else { return XCTFail("expected update") }
        XCTAssertEqual(record.state, .waiting)
        XCTAssertEqual(record.reason, .turnComplete)
        XCTAssertEqual(record.since, 1000)
        XCTAssertFalse(record.notified)
        XCTAssertEqual(record.lastAssistantMessage, "pong")
        XCTAssertEqual(record.tty, "/dev/ttys003")
        XCTAssertEqual(record.project, "MacTerminalNavigator")
    }

    func testUserPromptSubmitClearsPendingAlert() throws {
        let existing = waiting(reason: .permission, since: 500, notified: true, escalated: true)
        let outcome = HookProcessor.apply(payload: try payload("UserPromptSubmit"),
                                         identity: identity,
                                         existing: existing,
                                         now: 1000)
        guard case .updated(let record) = outcome else { return XCTFail("expected update") }
        XCTAssertEqual(record.state, .working)
        XCTAssertNil(record.reason)
        XCTAssertFalse(record.notified)
        XCTAssertFalse(record.escalated)
    }

    func testSessionEndRemovesRecord() throws {
        let outcome = HookProcessor.apply(payload: try payload("SessionEnd"),
                                         identity: identity,
                                         existing: waiting(reason: .turnComplete, since: 500, notified: true),
                                         now: 1000)
        XCTAssertEqual(outcome, .removed(sessionId: "9cf7abf1-94cb-4db1-912a-38247f0898b6"))
    }

    func testUnknownEventIsIgnored() throws {
        let outcome = HookProcessor.apply(payload: try payload("PreToolUse"),
                                         identity: identity,
                                         existing: nil,
                                         now: 1000)
        XCTAssertEqual(outcome, .ignoredUnknownEvent("PreToolUse"))
    }

    // MARK: - `since` preservation and notification re-arming

    func testRepeatedStopPreservesOriginalWaitStart() throws {
        let existing = waiting(reason: .turnComplete, since: 500, notified: true)
        let outcome = HookProcessor.apply(payload: try payload("Stop"),
                                         identity: identity,
                                         existing: existing,
                                         now: 1000)
        guard case .updated(let record) = outcome else { return XCTFail("expected update") }
        XCTAssertEqual(record.since, 500, "elapsed time must measure the real wait")
        XCTAssertTrue(record.notified, "same urgency should not re-notify")
    }

    func testTheIdleReminderDoesNotReArmTheNotification() throws {
        // Real sequence: Stop fires, then 60s later Claude Code emits the idle notification.
        // Same state, only older — so it must not ping again.
        let existing = waiting(reason: .turnComplete, since: 500, notified: true, escalated: true)
        let outcome = HookProcessor.apply(payload: try payload("Notification", notificationType: "idle_prompt"),
                                         identity: identity,
                                         existing: existing,
                                         now: 560)
        guard case .updated(let record) = outcome else { return XCTFail("expected update") }
        XCTAssertEqual(record.reason, .idlePrompt)
        XCTAssertEqual(record.since, 500, "wait started at the Stop, not the reminder")
        XCTAssertTrue(record.notified, "no urgency climb, so nothing to announce again")
    }

    func testBecomingBlockedDoesReArmTheNotification() throws {
        // A real climb: finished, then Claude hit something it needs permission for.
        let existing = waiting(reason: .turnComplete, since: 500, notified: true, escalated: true)
        let outcome = HookProcessor.apply(payload: try payload("Notification", notificationType: "permission_prompt"),
                                         identity: identity,
                                         existing: existing,
                                         now: 560)
        guard case .updated(let record) = outcome else { return XCTFail("expected update") }
        XCTAssertEqual(record.reason, .permission)
        XCTAssertFalse(record.notified, "it is blocked now; that is worth saying again")
        XCTAssertFalse(record.escalated)
    }

    func testUrgentToUrgentDoesNotReArm() throws {
        let existing = waiting(reason: .idlePrompt, since: 500, notified: true)
        let outcome = HookProcessor.apply(payload: try payload("Notification", notificationType: "idle_prompt"),
                                         identity: identity,
                                         existing: existing,
                                         now: 600)
        guard case .updated(let record) = outcome else { return XCTFail("expected update") }
        XCTAssertTrue(record.notified)
    }

    func testStopAfterWorkingStartsFreshWait() throws {
        let working = SessionRecord(sessionId: "9cf7abf1-94cb-4db1-912a-38247f0898b6",
                                   tty: "/dev/ttys003", pid: 17544,
                                   cwd: "/tmp/x", state: .working, since: 500)
        let outcome = HookProcessor.apply(payload: try payload("Stop"),
                                         identity: identity,
                                         existing: working,
                                         now: 1000)
        guard case .updated(let record) = outcome else { return XCTFail("expected update") }
        XCTAssertEqual(record.since, 1000)
    }

    func testStopPreservesEarlierMessageWhenPayloadOmitsIt() throws {
        var existing = waiting(reason: .turnComplete, since: 500, notified: true)
        existing.lastAssistantMessage = "earlier answer"
        let outcome = HookProcessor.apply(payload: try payload("Notification", notificationType: "idle_prompt"),
                                         identity: identity,
                                         existing: existing,
                                         now: 600)
        guard case .updated(let record) = outcome else { return XCTFail("expected update") }
        XCTAssertEqual(record.lastAssistantMessage, "earlier answer")
    }
}

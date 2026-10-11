import XCTest
@testable import TNavCore

final class ClaudeAdapterTests: XCTestCase {
    private let adapter = ClaudeAdapter()

    private func decode(_ json: String) throws -> DecodedHook {
        try adapter.decode(Data(json.utf8), eventHint: nil)
    }

    // Shapes captured live in Phase 0 (docs/phase0-recon-findings.md).

    func testStopCarriesLastMessage() throws {
        let hook = try decode("""
        {"session_id":"9cf7abf1","transcript_path":"/tmp/t.jsonl","cwd":"/Users/you/code/webapp",\
        "prompt_id":"bf47","permission_mode":"default","hook_event_name":"Stop",\
        "stop_hook_active":false,"last_assistant_message":"pong","background_tasks":[],"session_crons":[]}
        """)
        XCTAssertEqual(hook.sessionId, "9cf7abf1")
        XCTAssertEqual(hook.cwd, "/Users/you/code/webapp")
        XCTAssertNil(hook.model)
        XCTAssertEqual(hook.rawEventName, "Stop")
        XCTAssertEqual(hook.event, .turnComplete(lastMessage: "pong"))
    }

    func testIdlePromptNotificationIsTheSoftReminder() throws {
        let hook = try decode("""
        {"session_id":"20aae48f","cwd":"/Users/you/code/webapp","hook_event_name":"Notification",\
        "message":"Claude is waiting for your input","notification_type":"idle_prompt"}
        """)
        XCTAssertEqual(hook.event, .idlePrompt)
    }

    func testAnyOtherNotificationTypeNeedsPermission() throws {
        // The permission type was never observed in recon; unknown must be urgent, not dropped.
        let hook = try decode("""
        {"session_id":"a","cwd":"/p","hook_event_name":"Notification",\
        "message":"Claude needs your permission","notification_type":"tool_permission_v9"}
        """)
        XCTAssertEqual(hook.event, .needsPermission(message: "Claude needs your permission"))
        let untyped = try decode(#"{"session_id":"a","cwd":"/p","hook_event_name":"Notification"}"#)
        XCTAssertEqual(untyped.event, .needsPermission(message: nil))
    }

    func testLifecycleEvents() throws {
        XCTAssertEqual(try decode(#"{"session_id":"a","cwd":"/p","hook_event_name":"SessionStart","source":"startup"}"#).event, .sessionStart)
        XCTAssertEqual(try decode(#"{"session_id":"a","cwd":"/p","hook_event_name":"UserPromptSubmit","prompt":"go"}"#).event, .promptSubmitted)
        XCTAssertEqual(try decode(#"{"session_id":"a","cwd":"/p","hook_event_name":"PreToolUse","tool_name":"Bash"}"#).event, .toolStarting)
        XCTAssertEqual(try decode(#"{"session_id":"a","cwd":"/p","hook_event_name":"SessionEnd","reason":"other"}"#).event, .sessionEnd)
    }

    func testUnknownEventDecodesWithNilEventAndKeepsItsName() throws {
        let hook = try decode(#"{"session_id":"a","cwd":"/p","hook_event_name":"SubagentStop"}"#)
        XCTAssertNil(hook.event)
        XCTAssertEqual(hook.rawEventName, "SubagentStop")
    }

    func testMissingSessionIdThrows() {
        XCTAssertThrowsError(try decode(#"{"cwd":"/p","hook_event_name":"Stop"}"#))
    }

    func testNonObjectThrows() {
        XCTAssertThrowsError(try decode("[1,2,3]"))
        XCTAssertThrowsError(try decode("not json"))
    }

    func testRegistryKnowsClaude() {
        XCTAssertEqual(AgentRegistry.adapter(for: .claude)?.kind, .claude)
        XCTAssertNil(AgentRegistry.adapter(for: AgentKind(rawValue: "nope")))
    }
}

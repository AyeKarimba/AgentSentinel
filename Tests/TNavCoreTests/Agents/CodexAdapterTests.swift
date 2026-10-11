import XCTest
@testable import TNavCore

final class CodexAdapterTests: XCTestCase {
    private let adapter = CodexAdapter()

    private func decode(_ json: String) throws -> DecodedHook {
        try adapter.decode(Data(json.utf8), eventHint: nil)
    }

    // Captured live from Codex CLI 0.155.0 on 2026-10-10 (see the probe notes in the plan).

    func testSessionStartCarriesModel() throws {
        let hook = try decode("""
        {"session_id":"01a128e2-f361-7890-89ba-fcc27bcb271a","transcript_path":"/x/rollout.jsonl",\
        "cwd":"/Users/you/code/webapp","hook_event_name":"SessionStart","model":"gpt-5",\
        "permission_mode":"bypassPermissions","source":"startup"}
        """)
        XCTAssertEqual(hook.sessionId, "01a128e2-f361-7890-89ba-fcc27bcb271a")
        XCTAssertEqual(hook.cwd, "/Users/you/code/webapp")
        XCTAssertEqual(hook.model, "gpt-5")
        XCTAssertEqual(hook.event, .sessionStart)
    }

    func testUserPromptSubmit() throws {
        let hook = try decode("""
        {"session_id":"01a128e2","turn_id":"01a128e2-f380","transcript_path":"/x.jsonl",\
        "cwd":"/p","hook_event_name":"UserPromptSubmit","model":"gpt-5",\
        "permission_mode":"bypassPermissions","prompt":"say hi"}
        """)
        XCTAssertEqual(hook.event, .promptSubmitted)
    }

    // Documented shapes (learn.chatgpt.com/docs/hooks); not yet captured live.

    func testStopCarriesLastAssistantMessage() throws {
        let hook = try decode("""
        {"session_id":"a","cwd":"/p","hook_event_name":"Stop","model":"gpt-5",\
        "stop_hook_active":false,"last_assistant_message":"Done. Want tests?"}
        """)
        XCTAssertEqual(hook.event, .turnComplete(lastMessage: "Done. Want tests?"))
    }

    func testStopWithNullMessage() throws {
        let hook = try decode(#"{"session_id":"a","cwd":"/p","hook_event_name":"Stop","last_assistant_message":null}"#)
        XCTAssertEqual(hook.event, .turnComplete(lastMessage: nil))
    }

    func testPermissionRequestNeedsPermissionWithToolDescription() throws {
        let hook = try decode("""
        {"session_id":"a","cwd":"/p","hook_event_name":"PermissionRequest","tool_name":"Bash",\
        "tool_input":{"command":"rm -rf build","description":"Remove the build directory"}}
        """)
        XCTAssertEqual(hook.event, .needsPermission(message: "Remove the build directory"))
    }

    func testPermissionRequestWithoutDescriptionFallsBackToToolName() throws {
        let hook = try decode("""
        {"session_id":"a","cwd":"/p","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"ls"}}
        """)
        XCTAssertEqual(hook.event, .needsPermission(message: "Bash"))
    }

    func testOtherLifecycleEvents() throws {
        XCTAssertEqual(try decode(#"{"session_id":"a","cwd":"/p","hook_event_name":"PreToolUse","tool_name":"Bash"}"#).event, .toolStarting)
        XCTAssertEqual(try decode(#"{"session_id":"a","cwd":"/p","hook_event_name":"SessionEnd","reason":"other"}"#).event, .sessionEnd)
    }

    func testUnmappedEventsAreNil() throws {
        for name in ["PostToolUse", "PreCompact", "PostCompact", "SubagentStop", "SubagentStart", "Interrupt"] {
            let hook = try decode(#"{"session_id":"a","cwd":"/p","hook_event_name":"\#(name)"}"#)
            XCTAssertNil(hook.event, name)
            XCTAssertEqual(hook.rawEventName, name)
        }
    }

    func testRegistryKnowsCodex() {
        XCTAssertEqual(AgentRegistry.adapter(for: .codex)?.kind, .codex)
    }
}

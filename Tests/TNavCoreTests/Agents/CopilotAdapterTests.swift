import XCTest
@testable import TNavCore

/// Fixtures follow the Copilot CLI hooks reference
/// (docs.github.com/en/copilot/reference/copilot-cli-reference/cli-hooks-reference): camelCase
/// `sessionId`, `cwd`, `timestamp` in Unix ms, and — crucially — no field naming the event.
/// The event comes from the `--event` argument the hook was registered with.
final class CopilotAdapterTests: XCTestCase {
    private let adapter = CopilotAdapter()

    private func decode(_ json: String, hint: String?) throws -> DecodedHook {
        try adapter.decode(Data(json.utf8), eventHint: hint)
    }

    private let common = #""sessionId":"cp-1","timestamp":1789730418873,"cwd":"/Users/you/code/webapp""#

    func testUsesEventHintWhenPayloadHasNoEventName() throws {
        let hook = try decode("{\(common),\"transcriptPath\":\"/t\",\"stopReason\":\"end_turn\"}", hint: "agentStop")
        XCTAssertEqual(hook.sessionId, "cp-1")
        XCTAssertEqual(hook.cwd, "/Users/you/code/webapp")
        XCTAssertEqual(hook.rawEventName, "agentStop")
        XCTAssertEqual(hook.event, .turnComplete(lastMessage: nil))
    }

    func testPayloadEventNameWinsOverHintWhenPresent() throws {
        // The VS Code-format payload does carry hook_event_name; prefer the payload's word.
        let hook = try decode(#"{"session_id":"cp-2","cwd":"/p","hook_event_name":"sessionStart","timestamp":"2026-10-10T00:00:00Z"}"#, hint: "agentStop")
        XCTAssertEqual(hook.sessionId, "cp-2")
        XCTAssertEqual(hook.event, .sessionStart)
    }

    func testMissingHintYieldsNoEvent() throws {
        let hook = try decode("{\(common)}", hint: nil)
        XCTAssertNil(hook.event)
        XCTAssertEqual(hook.rawEventName, "")
    }

    func testLifecycle() throws {
        XCTAssertEqual(try decode("{\(common),\"source\":\"new\"}", hint: "sessionStart").event, .sessionStart)
        XCTAssertEqual(try decode("{\(common),\"prompt\":\"go\"}", hint: "userPromptSubmitted").event, .promptSubmitted)
        XCTAssertEqual(try decode("{\(common),\"toolName\":\"bash\",\"toolArgs\":{}}", hint: "preToolUse").event, .toolStarting)
        XCTAssertEqual(try decode("{\(common),\"reason\":\"exit\"}", hint: "sessionEnd").event, .sessionEnd)
    }

    func testPermissionRequestNeedsPermissionWithToolName() throws {
        let hook = try decode("{\(common),\"toolName\":\"bash\",\"toolArgs\":{\"command\":\"ls\"}}", hint: "permissionRequest")
        XCTAssertEqual(hook.event, .needsPermission(message: "bash"))
    }

    func testPermissionPromptNotificationNeedsPermissionWithMessage() throws {
        let hook = try decode("{\(common),\"message\":\"Copilot wants to run bash\",\"notification_type\":\"permission_prompt\"}", hint: "notification")
        XCTAssertEqual(hook.event, .needsPermission(message: "Copilot wants to run bash"))
    }

    func testPascalCaseEventNameInPayloadStillMaps() throws {
        let hook = try decode(#"{"session_id":"cp-3","cwd":"/p","hook_event_name":"Notification","notification_type":"permission_prompt","message":"m"}"#, hint: nil)
        XCTAssertEqual(hook.event, .needsPermission(message: "m"))
    }

    func testOtherNotificationTypesAreIgnored() throws {
        // `agent_idle` is about a background agent, not the main session; not our business.
        let hook = try decode("{\(common),\"message\":\"idle\",\"notification_type\":\"agent_idle\"}", hint: "notification")
        XCTAssertNil(hook.event)
    }

    func testSubagentAndErrorEventsAreUnmapped() throws {
        for name in ["subagentStart", "subagentStop", "errorOccurred", "preCompact", "postToolUse", "postToolUseFailure", "userPromptTransformed"] {
            XCTAssertNil(try decode("{\(common)}", hint: name).event, name)
        }
    }

    func testRegistryKnowsCopilot() {
        XCTAssertEqual(AgentRegistry.adapter(for: .copilot)?.kind, .copilot)
    }
}

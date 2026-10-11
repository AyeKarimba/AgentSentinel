import XCTest
@testable import TNavCore

/// Fixtures are built from the field names in the Gemini CLI hooks reference
/// (geminicli.com/docs/hooks/reference), not captured live. If a live payload disagrees,
/// fix the fixture here and the adapter together.
final class GeminiAdapterTests: XCTestCase {
    private let adapter = GeminiAdapter()

    private func decode(_ json: String) throws -> DecodedHook {
        try adapter.decode(Data(json.utf8), eventHint: nil)
    }

    private let common = #""session_id":"g-1","transcript_path":"/t.json","cwd":"/Users/you/code/webapp","timestamp":"2026-10-10T12:00:00Z""#

    func testSessionStartAndEnd() throws {
        XCTAssertEqual(try decode("{\(common),\"hook_event_name\":\"SessionStart\",\"source\":\"startup\"}").event, .sessionStart)
        XCTAssertEqual(try decode("{\(common),\"hook_event_name\":\"SessionEnd\",\"reason\":\"exit\"}").event, .sessionEnd)
    }

    func testBeforeAgentIsThePromptBeingSubmitted() throws {
        let hook = try decode("{\(common),\"hook_event_name\":\"BeforeAgent\",\"prompt\":\"fix the tests\"}")
        XCTAssertEqual(hook.event, .promptSubmitted)
        XCTAssertEqual(hook.cwd, "/Users/you/code/webapp")
        XCTAssertNil(hook.model)
    }

    func testBeforeToolIsToolStarting() throws {
        XCTAssertEqual(try decode("{\(common),\"hook_event_name\":\"BeforeTool\",\"tool_name\":\"write_file\",\"tool_input\":{}}").event, .toolStarting)
    }

    func testAfterAgentCarriesTheResponse() throws {
        let hook = try decode("{\(common),\"hook_event_name\":\"AfterAgent\",\"prompt\":\"fix\",\"prompt_response\":\"All green.\",\"stop_hook_active\":false}")
        XCTAssertEqual(hook.event, .turnComplete(lastMessage: "All green."))
    }

    func testToolPermissionNotificationNeedsPermission() throws {
        let hook = try decode("{\(common),\"hook_event_name\":\"Notification\",\"notification_type\":\"ToolPermission\",\"message\":\"Allow write_file?\",\"details\":{\"tool\":\"write_file\"}}")
        XCTAssertEqual(hook.event, .needsPermission(message: "Allow write_file?"))
    }

    func testUnknownNotificationTypeIsStillUrgent() throws {
        let hook = try decode("{\(common),\"hook_event_name\":\"Notification\",\"notification_type\":\"SomethingNew\",\"message\":\"m\"}")
        XCTAssertEqual(hook.event, .needsPermission(message: "m"))
    }

    func testModelEventsAreUnmapped() throws {
        for name in ["BeforeModel", "AfterModel", "BeforeToolSelection", "AfterTool", "PreCompress"] {
            XCTAssertNil(try decode("{\(common),\"hook_event_name\":\"\(name)\"}").event, name)
        }
    }

    func testRegistryKnowsGemini() {
        XCTAssertEqual(AgentRegistry.adapter(for: .gemini)?.kind, .gemini)
    }
}

import Foundation

/// Google Gemini CLI. Field names from the hooks reference (geminicli.com/docs/hooks/reference):
/// every hook gets `session_id`, `transcript_path`, `cwd`, `hook_event_name`, `timestamp`.
/// Not yet verified against a live payload; the adapter tests say so.
public struct GeminiAdapter: AgentAdapter {
    public let kind: AgentKind = .gemini

    public init() {}

    public func decode(_ data: Data, eventHint: String?) throws -> DecodedHook {
        let object = try HookJSON.object(data)
        let name = try HookJSON.required(object, "hook_event_name")
        let event: AgentEvent?
        switch name {
        case "SessionStart": event = .sessionStart
        // Fires once per user turn, before the agent loop — the closest thing to "the user
        // just said something".
        case "BeforeAgent": event = .promptSubmitted
        case "BeforeTool": event = .toolStarting
        case "AfterAgent": event = .turnComplete(lastMessage: HookJSON.string(object, "prompt_response"))
        // Observability-only alert. Only `ToolPermission` is documented; anything else is
        // treated as urgent rather than dropped, as with Claude.
        case "Notification": event = .needsPermission(message: HookJSON.string(object, "message"))
        case "SessionEnd": event = .sessionEnd
        default: event = nil
        }
        return DecodedHook(sessionId: try HookJSON.required(object, "session_id"),
                           cwd: try HookJSON.required(object, "cwd"),
                           model: nil,
                           rawEventName: name,
                           event: event)
    }
}

import Foundation

/// OpenAI Codex CLI. Its hook payload is deliberately Claude-shaped (`session_id`, `cwd`,
/// `hook_event_name`, `Stop`, `PreToolUse`), plus `model`. The one real difference: a
/// permission prompt arrives as `PermissionRequest`, not `Notification`.
///
/// `PermissionRequest` is a hook that *can answer the prompt* through stdout. This adapter
/// only observes; the hook command prints nothing, ever.
public struct CodexAdapter: AgentAdapter {
    public let kind: AgentKind = .codex

    public init() {}

    public func decode(_ data: Data, eventHint: String?) throws -> DecodedHook {
        let object = try HookJSON.object(data)
        let name = try HookJSON.required(object, "hook_event_name")
        let event: AgentEvent?
        switch name {
        case "SessionStart": event = .sessionStart
        case "UserPromptSubmit": event = .promptSubmitted
        case "PreToolUse": event = .toolStarting
        case "Stop": event = .turnComplete(lastMessage: HookJSON.string(object, "last_assistant_message"))
        case "PermissionRequest":
            // The description is what the user sees in Codex's own prompt; the tool name is a
            // poorer but never-empty fallback.
            event = .needsPermission(message: HookJSON.string(object, "tool_input", "description")
                                                ?? HookJSON.string(object, "tool_name"))
        case "SessionEnd": event = .sessionEnd
        default: event = nil
        }
        return DecodedHook(sessionId: try HookJSON.required(object, "session_id"),
                           cwd: try HookJSON.required(object, "cwd"),
                           model: HookJSON.string(object, "model"),
                           rawEventName: name,
                           event: event)
    }
}

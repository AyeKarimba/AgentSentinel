import Foundation

/// Claude Code. Field names verified against live payloads in Phase 0 —
/// see docs/phase0-recon-findings.md.
public struct ClaudeAdapter: AgentAdapter {
    public let kind: AgentKind = .claude

    /// The one notification type observed in recon. Anything else is treated as a
    /// permission request rather than guessed at: unknown means urgent, not ignored.
    public static let idlePromptType = "idle_prompt"

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
        case "Notification":
            event = HookJSON.string(object, "notification_type") == Self.idlePromptType
                ? .idlePrompt
                : .needsPermission(message: HookJSON.string(object, "message"))
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

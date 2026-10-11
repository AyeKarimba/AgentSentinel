import Foundation

/// GitHub Copilot CLI. Its native payload is camelCase (`sessionId`, `cwd`, `timestamp` in
/// Unix ms) and does not say which event fired; the registrar therefore passes the event on
/// the command line (`--event agentStop`) and this adapter reads it from `eventHint`. The
/// alternative VS Code-format payload carries `session_id` and `hook_event_name`; both are
/// accepted, and the payload's own event name wins when present.
public struct CopilotAdapter: AgentAdapter {
    public let kind: AgentKind = .copilot

    public init() {}

    /// VS Code-format payloads spell events PascalCase ("Notification"); Copilot's are camelCase.
    private static func lowercasingFirst(_ text: String) -> String {
        text.prefix(1).lowercased() + text.dropFirst()
    }

    public func decode(_ data: Data, eventHint: String?) throws -> DecodedHook {
        let object = try HookJSON.object(data)
        let name = HookJSON.string(object, "hook_event_name").map(Self.lowercasingFirst) ?? eventHint ?? ""
        let event: AgentEvent?
        switch name {
        case "sessionStart": event = .sessionStart
        case "userPromptSubmitted": event = .promptSubmitted
        case "preToolUse": event = .toolStarting
        // Copilot's payload has no final-message field, and the transcript is off limits.
        case "agentStop": event = .turnComplete(lastMessage: nil)
        case "permissionRequest": event = .needsPermission(message: HookJSON.string(object, "toolName"))
        case "notification":
            event = HookJSON.string(object, "notification_type") == "permission_prompt"
                ? .needsPermission(message: HookJSON.string(object, "message"))
                : nil
        case "sessionEnd": event = .sessionEnd
        default: event = nil
        }
        guard let sessionId = HookJSON.string(object, "sessionId") ?? HookJSON.string(object, "session_id") else {
            throw HookDecodeError.missingField("sessionId")
        }
        return DecodedHook(sessionId: sessionId,
                           cwd: try HookJSON.required(object, "cwd"),
                           model: nil,
                           rawEventName: name,
                           event: event)
    }
}

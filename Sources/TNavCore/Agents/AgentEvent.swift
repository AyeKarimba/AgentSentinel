import Foundation

/// What a hook event means, independent of which agent sent it. This is the whole vocabulary
/// the state machine in `HookProcessor` understands; each adapter's job is to translate its
/// agent's event names into these.
public enum AgentEvent: Equatable, Sendable {
    case sessionStart
    case promptSubmitted
    case toolStarting
    /// The agent finished its turn and is waiting for the user to say something.
    case turnComplete(lastMessage: String?)
    /// Claude Code's soft reminder about a minute after a turn ends. No other agent has an
    /// equivalent, and it is deliberately not urgent — see `WaitReason.idlePrompt`.
    case idlePrompt
    /// The agent is blocked on a permission prompt.
    case needsPermission(message: String?)
    case sessionEnd
}

/// An agent's hook payload, reduced to what the state machine needs.
public struct DecodedHook: Equatable, Sendable {
    public let sessionId: String
    public let cwd: String
    /// Stated by the payload when the agent includes it (Codex does), nil otherwise.
    public let model: String?
    /// The agent's own event name, for logging the ones that are not mapped.
    public let rawEventName: String
    /// Nil when the agent sent an event this adapter does not map. Logged and ignored.
    public let event: AgentEvent?

    public init(sessionId: String, cwd: String, model: String?, rawEventName: String, event: AgentEvent?) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.model = model
        self.rawEventName = rawEventName
        self.event = event
    }
}

public enum HookDecodeError: Error, Equatable, CustomStringConvertible {
    case notAnObject
    case missingField(String)

    public var description: String {
        switch self {
        case .notAnObject: return "payload is not a JSON object"
        case .missingField(let name): return "payload lacks \(name)"
        }
    }
}

/// One conformance per agent. Decoding is the only agent-specific step in the hook path;
/// everything after it works on `DecodedHook`.
public protocol AgentAdapter: Sendable {
    var kind: AgentKind { get }
    /// - Parameter eventHint: the `--event` argument the hook was registered with. Adapters
    ///   whose payload names the event ignore it; Copilot's does not, so it needs it.
    func decode(_ data: Data, eventHint: String?) throws -> DecodedHook
}

public enum AgentRegistry {
    public static func adapter(for kind: AgentKind) -> AgentAdapter? {
        switch kind {
        case .claude: return ClaudeAdapter()
        case .codex: return CodexAdapter()
        case .gemini: return GeminiAdapter()
        default: return nil
        }
    }
}

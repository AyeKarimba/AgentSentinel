import Foundation

/// Which CLI coding agent a session belongs to.
///
/// A struct rather than an enum so that any raw string decodes: a record written by a newer
/// build with an agent this build does not know still loads and renders, showing its raw
/// value as the tag. The known kinds are the ones with adapters and registrars.
public struct AgentKind: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let claude = AgentKind(rawValue: "claude")
    public static let codex = AgentKind(rawValue: "codex")
    public static let gemini = AgentKind(rawValue: "gemini")
    public static let copilot = AgentKind(rawValue: "copilot")

    /// Every kind this build ships an adapter for, in display order.
    public static let known: [AgentKind] = [.claude, .codex, .gemini, .copilot]

    public var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .gemini: return "Gemini CLI"
        case .copilot: return "Copilot CLI"
        default: return rawValue
        }
    }

    /// The agent's name as shown after the project on each row: short enough to sit beside
    /// it, plain enough to need no legend. Unknown kinds use their raw value, capitalised,
    /// so a record from a newer build still says what it is.
    public var shortName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .gemini: return "Gemini"
        case .copilot: return "Copilot"
        default: return rawValue.prefix(1).uppercased() + rawValue.dropFirst()
        }
    }

    /// Directory under `$HOME` whose presence means "this agent is installed". Nil for kinds
    /// this build cannot register hooks for.
    public var configDirectoryName: String? {
        switch self {
        case .claude: return ".claude"
        case .codex: return ".codex"
        case .gemini: return ".gemini"
        case .copilot: return ".copilot"
        default: return nil
        }
    }
}

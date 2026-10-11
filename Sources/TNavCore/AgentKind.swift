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

    /// Two-letter label shown on each row. Unknown kinds use the first two letters of
    /// their raw value, uppercased, so they still read as *something*.
    public var tag: String {
        switch self {
        case .claude: return "CC"
        case .codex: return "CX"
        case .gemini: return "GM"
        case .copilot: return "CP"
        default: return String(rawValue.prefix(2)).uppercased()
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

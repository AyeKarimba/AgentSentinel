import Foundation

/// Answers "is this agent installed, and are our hooks in its config" by reading the same
/// files the Python registrars write. A hook that isn't registered fails silently and
/// invisibly, so Diagnostics states it plainly.
public enum HookRegistration {
    public struct Status: Equatable, Sendable {
        public let kind: AgentKind
        public let installed: Bool
        public let registered: Bool
    }

    public static func configFile(for kind: AgentKind, home: URL) -> URL? {
        switch kind {
        case .claude: return home.appendingPathComponent(".claude/settings.json")
        case .codex: return home.appendingPathComponent(".codex/hooks.json")
        case .gemini: return home.appendingPathComponent(".gemini/settings.json")
        case .copilot: return home.appendingPathComponent(".copilot/hooks/agentsentinel.json")
        default: return nil
        }
    }

    /// The events whose absence means the app cannot do its job for that agent: the one that
    /// says "turn finished" and the one that says "needs permission".
    public static func requiredEvents(for kind: AgentKind) -> [String] {
        switch kind {
        case .claude: return ["Stop", "Notification"]
        case .codex: return ["Stop", "PermissionRequest"]
        case .gemini: return ["AfterAgent", "Notification"]
        case .copilot: return ["agentStop", "permissionRequest"]
        default: return []
        }
    }

    public static func isInstalled(_ kind: AgentKind, home: URL) -> Bool {
        guard let directory = kind.configDirectoryName else { return false }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: home.appendingPathComponent(directory).path,
                                              isDirectory: &isDirectory) && isDirectory.boolValue
    }

    public static func isRegistered(_ kind: AgentKind, home: URL) -> Bool {
        guard let file = configFile(for: kind, home: home),
              let data = try? Data(contentsOf: file),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = root["hooks"] as? [String: Any]
        else { return false }

        var markers = ["tnav hook --agent \(kind.rawValue)"]
        if kind == .claude { markers.append("tnav hook") }   // 1.0.x registrations

        for event in requiredEvents(for: kind) {
            guard let entry = hooks[event] else { return false }
            let strings = allStrings(in: entry)
            // The bare "tnav hook" marker must not match another agent's "tnav hook --agent x".
            let hit = strings.contains { s in
                markers.contains { marker in
                    marker == "tnav hook"
                        ? (s.contains("tnav hook") && !s.contains("--agent"))
                        : s.contains(marker)
                }
            }
            if !hit { return false }
        }
        return true
    }

    public static func statuses(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [Status] {
        AgentKind.known.map { kind in
            let installed = isInstalled(kind, home: home)
            return Status(kind: kind, installed: installed,
                          registered: installed && isRegistered(kind, home: home))
        }
    }

    /// Every string value anywhere under a JSON fragment. The four agents nest their command
    /// strings differently (`command` vs `bash`, with or without matcher groups); flattening
    /// sidesteps all of that.
    static func allStrings(in value: Any) -> [String] {
        if let s = value as? String { return [s] }
        if let array = value as? [Any] { return array.flatMap(allStrings) }
        if let object = value as? [String: Any] { return object.values.flatMap(allStrings) }
        return []
    }
}

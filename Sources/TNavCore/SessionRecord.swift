import Foundation

public enum Urgency: String, Codable, Sendable {
    case normal
    case urgent
}

/// Why a session is waiting on the user. Drives both notification tier and label text.
public enum WaitReason: String, Codable, Sendable {
    /// From the `Stop` hook — Claude finished its turn.
    case turnComplete = "turn_complete"
    /// From `Notification` with `notification_type == "idle_prompt"`.
    case idlePrompt = "idle_prompt"
    /// From `Notification` with any other type. Permission requests land here, and so do
    /// notification types Claude Code may add later — unknown means urgent, not ignored.
    case permission = "permission"

    /// Only a permission request is urgent. Claude Code emits `idle_prompt` about a minute
    /// after every turn ends, so treating it as urgent turned every finished tab red and
    /// fired a second, louder alert for a turn the user had already been pinged about.
    /// Unknown notification types decode as `permission`, so they stay urgent rather than
    /// silently soft.
    public var urgency: Urgency {
        self == .permission ? .urgent : .normal
    }

    public var label: String {
        switch self {
        case .turnComplete: return "finished"
        case .idlePrompt: return "waiting for input"
        case .permission: return "needs permission"
        }
    }
}

public enum SessionState: String, Codable, Sendable {
    case working
    case waiting
}

public struct SessionRecord: Codable, Equatable, Sendable {
    public var sessionId: String
    /// Which agent this session belongs to. Absent in records written before 1.1, which
    /// were all Claude's.
    public var agent: AgentKind
    /// Model name when the agent's payload states it (Codex does); nil otherwise.
    public var model: String?
    public var tty: String
    public var pid: Int32
    public var cwd: String
    public var state: SessionState
    public var reason: WaitReason?
    /// Unix time the session entered its current state. Preserved across reason upgrades so
    /// "waiting 4m" and the escalation timer both measure from the original wait.
    public var since: Double
    /// Unix time the current `reason` was set, when that is later than `since`.
    ///
    /// Exists because preserving `since` across an upgrade — right for the elapsed label — is
    /// wrong for "have you seen this". A turn completion you glanced at and left can become a
    /// permission request a minute later; measured from `since`, your earlier visit would
    /// vouch for information that did not exist when you made it, and the tab would drop out
    /// of the badge while genuinely blocked. Optional so records from an older build decode.
    public var reasonSince: Double?
    public var notified: Bool
    public var escalated: Bool
    /// `Stop` ships this inline, so the richer label costs nothing to support.
    public var lastAssistantMessage: String?

    public init(sessionId: String,
                agent: AgentKind = .claude,
                model: String? = nil,
                tty: String,
                pid: Int32,
                cwd: String,
                state: SessionState,
                reason: WaitReason? = nil,
                since: Double,
                reasonSince: Double? = nil,
                notified: Bool = false,
                escalated: Bool = false,
                lastAssistantMessage: String? = nil) {
        self.sessionId = sessionId
        self.agent = agent
        self.model = model
        self.tty = tty
        self.pid = pid
        self.cwd = cwd
        self.state = state
        self.reason = reason
        self.since = since
        self.reasonSince = reasonSince
        self.notified = notified
        self.escalated = escalated
        self.lastAssistantMessage = lastAssistantMessage
    }

    // Decoded by hand so a record from the 1.0.x build — no `agent`, no `model` — still loads
    // as the Claude session it was, instead of failing and vanishing from the menu.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try c.decode(String.self, forKey: .sessionId)
        agent = try c.decodeIfPresent(AgentKind.self, forKey: .agent) ?? .claude
        model = try c.decodeIfPresent(String.self, forKey: .model)
        tty = try c.decode(String.self, forKey: .tty)
        pid = try c.decode(Int32.self, forKey: .pid)
        cwd = try c.decode(String.self, forKey: .cwd)
        state = try c.decode(SessionState.self, forKey: .state)
        reason = try c.decodeIfPresent(WaitReason.self, forKey: .reason)
        since = try c.decode(Double.self, forKey: .since)
        reasonSince = try c.decodeIfPresent(Double.self, forKey: .reasonSince)
        notified = try c.decodeIfPresent(Bool.self, forKey: .notified) ?? false
        escalated = try c.decodeIfPresent(Bool.self, forKey: .escalated) ?? false
        lastAssistantMessage = try c.decodeIfPresent(String.self, forKey: .lastAssistantMessage)
    }

    /// Filename stem for this record: `<agent>-<sessionId>`. Two agents can in principle hand
    /// out the same id, and the prefix also makes a directory listing readable.
    public var storageKey: String { "\(agent.rawValue)-\(sessionId)" }

    /// Derived rather than stored, so it can never drift from `cwd`.
    public var project: String {
        let name = URL(fileURLWithPath: cwd).lastPathComponent
        return name.isEmpty ? cwd : name
    }

    public var urgency: Urgency { reason?.urgency ?? .normal }

    /// The moment this tab last had something new to say — the wait start, or the later moment
    /// its reason changed. What "have you looked at it" is measured against; `since` is what
    /// the elapsed label is measured against, and the two deliberately differ after an upgrade.
    public var attentionSince: Double { max(since, reasonSince ?? since) }

    public func elapsed(now: Double) -> Double { max(0, now - since) }

    /// "MacTerminalNavigator (Codex) — needs permission · 12s"
    public func summary(now: Double) -> String {
        let detail = reason?.label ?? "working"
        return "\(project) (\(agent.displayName)) — \(detail) · \(Elapsed.short(elapsed(now: now)))"
    }

    /// Key used for tab-scoped mute: survives restarting Claude in the same tab and
    /// directory, which is the behaviour "mute this terminal" implies.
    public var tabMuteKey: String { "\(tty)|\(cwd)" }
}

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

    /// Only a permission request is urgent: it is the one state where Claude is *blocked* and
    /// cannot proceed without an answer.
    ///
    /// `idlePrompt` used to count as urgent, which quietly wrecked the whole colour scheme.
    /// Claude Code emits it about a minute after a turn ends, as a reminder that it is waiting
    /// — so every finished turn started amber and turned red sixty seconds later, and amber
    /// effectively did not exist. It is the same state as `turnComplete`, only older.
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

    /// Derived rather than stored, so it can never drift from `cwd`.
    public var project: String {
        let name = URL(fileURLWithPath: cwd).lastPathComponent
        return name.isEmpty ? cwd : name
    }

    public var urgency: Urgency { reason?.urgency ?? .normal }

    /// Whether Claude's closing message looks like it hands the next move back to the user.
    ///
    /// This is the only guess in the colour system, and it exists because the hook cannot tell
    /// these apart: "I've committed the changes." and "Committed — shall I update the tests?"
    /// arrive as the identical event, `Stop` with `turn_complete`. The message text is the only
    /// thing left to read.
    ///
    /// It will be wrong sometimes. A courteous "Anything else?" reads as a request when nothing
    /// is really needed, and "Next I'd suggest running the migration" reads as inert when it is
    /// not. The bias is deliberate: **anything unclear counts as inviting a reply**, because a
    /// tab wrongly coloured orange costs a glance, while a tab wrongly greyed is one you never
    /// come back to.
    var invitesReply: Bool {
        // A blocking request always wants something, whatever the text says.
        guard reason != .permission else { return true }
        guard let message = lastAssistantMessage?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !message.isEmpty
        else { return true }   // nothing to read: assume it wants you

        if message.hasSuffix("?") { return true }
        let lowered = message.lowercased()
        return Self.replyInvitations.contains { lowered.contains($0) }
    }

    /// Phrases that hand the decision back without necessarily ending in a question mark.
    /// Deliberately short: every addition is another way to be confidently wrong.
    private static let replyInvitations = [
        "should i", "shall i", "want me to", "would you like", "do you want",
        "let me know", "your call", "up to you", "or should", "which would",
    ]

    /// The moment this tab last had something new to say — the wait start, or the later moment
    /// its reason changed. What "have you looked at it" is measured against; `since` is what
    /// the elapsed label is measured against, and the two deliberately differ after an upgrade.
    public var attentionSince: Double { max(since, reasonSince ?? since) }

    public func elapsed(now: Double) -> Double { max(0, now - since) }

    /// "MacTerminalNavigator — needs permission · 12s"
    public func summary(now: Double) -> String {
        let detail = reason?.label ?? "working"
        return "\(project) — \(detail) · \(Elapsed.short(elapsed(now: now)))"
    }

    /// Key used for tab-scoped mute: survives restarting Claude in the same tab and
    /// directory, which is the behaviour "mute this terminal" implies.
    public var tabMuteKey: String { "\(tty)|\(cwd)" }
}

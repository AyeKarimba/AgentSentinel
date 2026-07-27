import Foundation

/// Claude Code hook payload. Field names verified against live payloads in Phase 0 —
/// see docs/phase0-recon-findings.md for the full observed shapes.
public struct HookPayload: Decodable, Sendable {
    public let sessionId: String
    public let cwd: String
    public let hookEventName: String
    public let transcriptPath: String?
    public let message: String?
    public let notificationType: String?
    public let lastAssistantMessage: String?

    public static func decode(_ data: Data) throws -> HookPayload {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(HookPayload.self, from: data)
    }
}

public enum HookEventKind: String, Sendable {
    case sessionStart = "SessionStart"
    case userPromptSubmit = "UserPromptSubmit"
    case stop = "Stop"
    case notification = "Notification"
    case sessionEnd = "SessionEnd"
}

public enum HookOutcome: Equatable, Sendable {
    case updated(SessionRecord)
    case removed(sessionId: String)
    case ignoredNested
    case ignoredUnknownEvent(String)
}

/// Pure state transitions, kept free of disk and AppleScript so the interesting behaviour
/// (what preserves `since`, what re-arms a notification) is unit-testable.
public enum HookProcessor {
    /// The one notification type observed in recon. Anything else is treated as urgent
    /// rather than guessed at.
    public static let idlePromptType = "idle_prompt"

    public static func waitReason(forNotificationType type: String?) -> WaitReason {
        type == idlePromptType ? .idlePrompt : .permission
    }

    public static func apply(payload: HookPayload,
                             identity: SessionIdentity,
                             existing: SessionRecord?,
                             now: Double) -> HookOutcome {
        guard !identity.isNested else { return .ignoredNested }
        guard let kind = HookEventKind(rawValue: payload.hookEventName) else {
            return .ignoredUnknownEvent(payload.hookEventName)
        }

        switch kind {
        case .sessionEnd:
            return .removed(sessionId: payload.sessionId)

        case .sessionStart, .userPromptSubmit:
            // The user just acted, so any pending alert is answered by definition.
            return .updated(SessionRecord(sessionId: payload.sessionId,
                                          tty: identity.tty,
                                          pid: identity.sessionPid,
                                          cwd: payload.cwd,
                                          state: .working,
                                          reason: nil,
                                          since: now,
                                          notified: false,
                                          escalated: false,
                                          lastAssistantMessage: nil))

        case .stop, .notification:
            let reason: WaitReason = kind == .stop
                ? .turnComplete
                : waitReason(forNotificationType: payload.notificationType)

            let wasWaiting = existing?.state == .waiting

            // Keep the original wait start so elapsed time and escalation measure the real
            // wait, not the most recent event.
            let since = wasWaiting ? (existing?.since ?? now) : now

            // A changed reason is new information the user cannot have seen, so it restarts
            // the "have you looked at it" clock even though the wait clock keeps running. A
            // repeat of the same reason does not: the user having decided to leave a request
            // sitting is not grounds for the badge to keep re-flagging it at them.
            let reasonChanged = !wasWaiting || existing?.reason != reason
            let reasonSince = reasonChanged ? now : (existing?.reasonSince ?? since)

            // Re-arm notification when urgency climbs: a soft "finished" ping followed 60s
            // later by an urgent idle_prompt should sound again, at the higher tier.
            let urgencyClimbed = wasWaiting
                && existing?.urgency == .normal
                && reason.urgency == .urgent
            let notified = wasWaiting && !urgencyClimbed ? (existing?.notified ?? false) : false
            let escalated = wasWaiting && !urgencyClimbed ? (existing?.escalated ?? false) : false

            let message = payload.lastAssistantMessage ?? existing?.lastAssistantMessage

            return .updated(SessionRecord(sessionId: payload.sessionId,
                                          tty: identity.tty,
                                          pid: identity.sessionPid,
                                          cwd: payload.cwd,
                                          state: .waiting,
                                          reason: reason,
                                          since: since,
                                          reasonSince: reasonSince,
                                          notified: notified,
                                          escalated: escalated,
                                          lastAssistantMessage: message))
        }
    }
}

import Foundation

public enum HookOutcome: Equatable, Sendable {
    case updated(SessionRecord)
    case removed(agent: AgentKind, sessionId: String)
    case ignoredNested
    case ignoredUnknownEvent(String)
}

/// Pure state transitions, kept free of disk and AppleScript so the interesting behaviour
/// (what preserves `since`, what re-arms a notification) is unit-testable. Knows nothing about
/// any particular agent: the adapters have already translated the payload into `AgentEvent`.
public enum HookProcessor {
    public static func apply(agent: AgentKind,
                             hook: DecodedHook,
                             identity: SessionIdentity,
                             existing: SessionRecord?,
                             now: Double) -> HookOutcome {
        guard !identity.isNested else { return .ignoredNested }
        guard let event = hook.event else { return .ignoredUnknownEvent(hook.rawEventName) }

        // A payload that states the model wins; otherwise keep whatever an earlier event said.
        let model = hook.model ?? existing?.model

        switch event {
        case .sessionEnd:
            return .removed(agent: agent, sessionId: hook.sessionId)

        case .sessionStart, .promptSubmitted:
            // The user just acted, so any pending alert is answered by definition.
            return .updated(SessionRecord(sessionId: hook.sessionId,
                                          agent: agent,
                                          model: model,
                                          tty: identity.tty,
                                          pid: identity.sessionPid,
                                          cwd: hook.cwd,
                                          state: .working,
                                          reason: nil,
                                          since: now,
                                          notified: false,
                                          escalated: false,
                                          lastAssistantMessage: nil))

        case .toolStarting:
            // The only signal that exists for "the user answered the permission prompt":
            // approving one fires no hook of its own, but the approved tool starts executing
            // immediately, and that is observable. It also fires on every tool call mid-turn,
            // so an already-working session keeps its original work start — the clock must
            // not restart per tool.
            let since = existing?.state == .working ? (existing?.since ?? now) : now
            return .updated(SessionRecord(sessionId: hook.sessionId,
                                          agent: agent,
                                          model: model,
                                          tty: identity.tty,
                                          pid: identity.sessionPid,
                                          cwd: hook.cwd,
                                          state: .working,
                                          reason: nil,
                                          since: since,
                                          notified: false,
                                          escalated: false,
                                          lastAssistantMessage: nil))

        case .turnComplete(let last):
            return waiting(agent: agent, hook: hook, identity: identity, existing: existing,
                           model: model, reason: .turnComplete, message: last, now: now)

        case .idlePrompt:
            return waiting(agent: agent, hook: hook, identity: identity, existing: existing,
                           model: model, reason: .idlePrompt, message: nil, now: now)

        case .needsPermission(let text):
            return waiting(agent: agent, hook: hook, identity: identity, existing: existing,
                           model: model, reason: .permission, message: text, now: now)
        }
    }

    private static func waiting(agent: AgentKind,
                                hook: DecodedHook,
                                identity: SessionIdentity,
                                existing: SessionRecord?,
                                model: String?,
                                reason: WaitReason,
                                message: String?,
                                now: Double) -> HookOutcome {
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

        // Re-arm notification when urgency climbs: a soft "finished" ping followed by a
        // permission request should sound again, at the higher tier.
        let urgencyClimbed = wasWaiting
            && existing?.urgency == .normal
            && reason.urgency == .urgent
        let notified = wasWaiting && !urgencyClimbed ? (existing?.notified ?? false) : false
        let escalated = wasWaiting && !urgencyClimbed ? (existing?.escalated ?? false) : false

        return .updated(SessionRecord(sessionId: hook.sessionId,
                                      agent: agent,
                                      model: model,
                                      tty: identity.tty,
                                      pid: identity.sessionPid,
                                      cwd: hook.cwd,
                                      state: .waiting,
                                      reason: reason,
                                      since: since,
                                      reasonSince: reasonSince,
                                      notified: notified,
                                      escalated: escalated,
                                      lastAssistantMessage: message ?? existing?.lastAssistantMessage))
    }
}

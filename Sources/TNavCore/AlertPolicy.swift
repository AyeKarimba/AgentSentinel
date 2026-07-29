import Foundation

public enum AlertDecision: Equatable, Sendable {
    case notify(Urgency)
    case escalate
    case suppressNotWaiting
    case suppressMuted
    case suppressSnoozed
    case suppressPaused
    /// Blocking-only mode is on and this is a plain turn-completion.
    case suppressNonBlocking
    /// You are already looking at this tab, so there is nothing to route you to.
    case suppressAlreadyFocused
    /// You have been in this tab since it started waiting, so you already know.
    case suppressAlreadySeen
    case suppressAlreadyNotified

    public var shouldAlert: Bool {
        switch self {
        case .notify, .escalate: return true
        default: return false
        }
    }
}

/// Pure decision function for "should this session ping the user right now".
///
/// Kept separate from the notification machinery so the whole rule set can be unit-tested as a
/// table, without AppleScript or UserNotifications in the loop. Order matters: the deliberate
/// silences (mute, snooze, pause) come first, so nothing — not even escalation — can talk over
/// a tab the user has explicitly parked.
public enum AlertPolicy {
    /// - Parameters:
    ///   - frontmostTTY: TTY of the tab the user is currently looking at, or nil when the
    ///     terminal app isn't frontmost.
    ///   - lastVisit: when the user was last in this tab, or nil if never.
    public static func decide(record: SessionRecord,
                              config: Config,
                              frontmostTTY: String?,
                              lastVisit: Double? = nil,
                              now: Double) -> AlertDecision {
        guard record.state == .waiting else { return .suppressNotWaiting }
        if config.isMuted(record) { return .suppressMuted }
        if config.isSnoozed(record, now: now) { return .suppressSnoozed }
        if config.paused { return .suppressPaused }

        // Blocking-only silences turn-completions but leaves them counted and listed; the
        // badge still tells you they are there, they just stop interrupting.
        if config.blockingOnly, record.reason != .permission { return .suppressNonBlocking }

        if let frontmostTTY, frontmostTTY == record.tty { return .suppressAlreadyFocused }

        // Knowing which tab is frontmost costs an Apple Event, so it is sampled rather than
        // continuous and is stale exactly when it matters most — the instant you switch into a
        // tab. Visits are recorded from that same sampling but persist, so "have you been in
        // here since it started waiting" answers the same question without the race.
        //
        // This is also what draws the line between the two signals: an alert is for something
        // you have not seen. A tab you have seen and not finished is the row colour's problem,
        // not something to interrupt you about again.
        if !record.isUnseen(lastVisit: lastVisit) { return .suppressAlreadySeen }

        if !record.notified { return .notify(record.urgency) }

        // Already pinged once. The only remaining reason to speak up is a wait that has run
        // long enough to deserve a single louder reminder.
        if !record.escalated, record.elapsed(now: now) >= config.escalateAfterSeconds {
            return .escalate
        }
        return .suppressAlreadyNotified
    }
}

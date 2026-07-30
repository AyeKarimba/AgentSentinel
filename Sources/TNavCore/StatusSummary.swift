import Foundation

/// What the menu bar item should say, derived from the current session set.
///
/// Pure and AppKit-free so the badge rules — what counts, what a mute suppresses, which wait
/// the timer reports — can be tested as a table rather than eyeballed in the menu bar.
public struct StatusSummary: Equatable, Sendable {
    /// What the menu bar icon is coloured, in ascending order of "this concerns you".
    ///
    /// Grey means there is nothing to track at all, so the icon reads as genuinely off rather
    /// than merely quiet — which is what makes purple worth having: sessions are running, and
    /// none of them wants anything from you.
    public enum Tint: String, Equatable, Sendable {
        /// No Claude sessions at all.
        case idle
        /// Sessions are running, and nothing is waiting on the user.
        case working
        /// Something is waiting, nothing is blocking.
        case waiting
        /// A permission request is blocking a session.
        case urgent
    }

    /// Sessions waiting on the user that they have not opened yet, excluding silenced ones.
    ///
    /// This is the queue the badge walks. Opening a tab drops it out and the badge moves to
    /// the next; empty the queue and the badge disappears, even though those sessions are all
    /// still waiting for a reply and still listed in the menu. "Waiting" and "waiting on you"
    /// were one number once, which is why the badge kept reporting work already dealt with.
    public let needsAttentionCount: Int
    /// Sessions waiting on the user and not silenced, opened or not — everything the jump
    /// action can still reach. Deliberately wider than `needsAttentionCount`.
    public let waitingCount: Int
    /// Seconds the longest wait among `needsAttentionCount` has been running; nil when the
    /// queue is empty. The same session `Jump to oldest waiting` targets, so the number in the
    /// menu bar always describes where that action will take you.
    public let oldestWait: Double?
    public let tint: Tint
    /// Waiting sessions hidden from the badge because their tab is muted or snoozed.
    public let silencedWaitingCount: Int
    /// Waiting sessions the user has already opened. They stay in the menu; they have just
    /// stopped asking for anything.
    public let attendedWaitingCount: Int
    /// Sessions Claude is actively running in. What the badge reports when nothing wants you —
    /// the colour says the machine is alive, this says how much of it is.
    public let workingCount: Int
    /// Blocking requests the user has not yet been present for, anywhere.
    public let unseenUrgentCount: Int
    /// The subset of those sitting in a silenced tab — the one thing the badge structurally
    /// cannot report, since silencing removes a tab from it by design. Drives the dot.
    public let silencedUnseenUrgentCount: Int

    /// Seconds since the most recently started wait, across every waiting session including
    /// silenced and already-opened ones. Those rows are on screen too and their labels still
    /// count in seconds, so the redraw cadence has to follow the youngest of them.
    private let youngestWait: Double?

    public init(records: [SessionRecord],
                config: Config,
                visits: [String: Double] = [:],
                now: Double) {
        let waiting = records.filter { $0.state == .waiting }
        let audible = waiting.filter { !config.isSilenced($0, now: now) }

        // Derived from the row tints rather than recomputed, so the icon can never disagree
        // with the list it is summarising. That divergence is how "everything is red" happened.
        let tinted = audible.map { ($0, $0.tint(lastVisit: visits[$0.sessionId])) }
        let pressing = tinted.filter { $0.1 == .urgent || $0.1 == .waiting }.map(\.0)
        needsAttentionCount = pressing.count
        waitingCount = audible.count
        attendedWaitingCount = audible.count - pressing.count
        workingCount = records.filter { $0.state == .working }.count
        silencedWaitingCount = waiting.count - audible.count
        oldestWait = pressing.map { $0.elapsed(now: now) }.max()
        youngestWait = waiting.map { $0.elapsed(now: now) }.min()

        // Counted across all waiting sessions: silencing a tab stops the nagging, but a
        // blocking request you have never looked at is still unseen.
        let unseenUrgent = waiting.filter { $0.isUnseenUrgent(lastVisit: visits[$0.sessionId]) }
        unseenUrgentCount = unseenUrgent.count
        silencedUnseenUrgentCount = unseenUrgent.filter { config.isSilenced($0, now: now) }.count

        // Paused drops out of the two attention colours but not down to grey: grey now claims
        // there is nothing running at all, and a paused machine full of sessions would be a
        // lie. Pausing stops the nagging; it does not make the work disappear.
        if !config.paused, pressing.contains(where: { $0.urgency == .urgent }) {
            tint = .urgent
        } else if !config.paused, !pressing.isEmpty {
            tint = .waiting
        } else if !records.isEmpty {
            tint = .working
        } else {
            tint = .idle
        }
    }

    /// The text beside the glyph, e.g. "2 · 4m" — how many tabs are still asking for you and
    /// how long the oldest of them has been. Nil once the queue empties, which is how the item
    /// renders as a bare dimmed glyph with no timestamp at all.
    public var badgeText: String? {
        if needsAttentionCount > 0, let oldestWait {
            return "\(needsAttentionCount) · \(Elapsed.short(oldestWait))"
        }
        // Nothing wants you, so report what is running instead. The colour already says the
        // machine is alive; this says how much of it is.
        return workingCount > 0 ? "\(workingCount)" : nil
    }

    /// Whether to draw the dot beside the glyph.
    ///
    /// Reserved for unopened blocking requests in silenced tabs. Anything audible is already
    /// in the badge, in colour; a dot there would just say the same thing twice.
    public var showsUnseenDot: Bool { silencedUnseenUrgentCount > 0 }

    /// Accessibility / tooltip description.
    public var accessibilityDescription: String {
        var parts: [String] = []
        if needsAttentionCount > 0, let oldestWait {
            let verb = needsAttentionCount == 1 ? "session needs" : "sessions need"
            parts.append("\(needsAttentionCount) Claude \(verb) you, longest \(Elapsed.short(oldestWait))")
        } else {
            parts.append("No Claude sessions need you")
        }
        if attendedWaitingCount > 0 {
            parts.append("\(attendedWaitingCount) already opened")
        }
        if silencedUnseenUrgentCount > 0 {
            let plural = silencedUnseenUrgentCount == 1 ? "request" : "requests"
            parts.append("\(silencedUnseenUrgentCount) unopened \(plural) in a silenced tab")
        }
        if silencedWaitingCount > 0 {
            parts.append("\(silencedWaitingCount) silenced")
        }
        return parts.joined(separator: " · ")
    }

    /// How often the menu needs redrawing: once a second while any label is still counting in
    /// seconds, then far less often. Avoids a 1Hz timer running all day for a "2h" label.
    ///
    /// Measured from the *youngest* wait, not the badge's. A row that has been waiting eight
    /// seconds needs a 1Hz tick whether or not it is the one the badge is describing, and it
    /// keeps needing one after you open it — the row stays on screen, still counting.
    public var refreshInterval: TimeInterval {
        guard let youngestWait else { return 30 }
        return youngestWait < 60 ? 1 : 15
    }
}

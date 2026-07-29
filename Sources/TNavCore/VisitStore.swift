import Foundation

/// Records when the user was last actually *in* a session's tab.
///
/// Kept in its own file rather than on `SessionRecord` because the hook rewrites the whole
/// record on every event while the app writes visits — sharing one file would make the two
/// writers race and lose updates.
///
/// The distinction this enables: "still waiting for a reply" is not the same as "you haven't
/// even looked at it". Opening the menu tells you a request exists; it doesn't mean you dealt
/// with it, so only genuinely reaching the tab clears the marker.
public final class VisitStore {
    public let url: URL
    private let lock = NSLock()
    private var cache: [String: Double]?

    public init(url: URL = Paths.visitsFile) {
        self.url = url
    }

    public func all() -> [String: Double] {
        lock.lock()
        defer { lock.unlock() }
        if let cache { return cache }
        let loaded = (try? Data(contentsOf: url))
            .flatMap { try? JSONDecoder().decode([String: Double].self, from: $0) } ?? [:]
        cache = loaded
        return loaded
    }

    public func lastVisit(sessionId: String) -> Double? {
        all()[sessionId]
    }

    public func markVisited(sessionId: String, at time: Double = Date().timeIntervalSince1970) {
        lock.lock()
        var visits = cache ?? (try? Data(contentsOf: url))
            .flatMap { try? JSONDecoder().decode([String: Double].self, from: $0) } ?? [:]
        visits[sessionId] = time
        cache = visits
        lock.unlock()
        persist(visits)
    }

    /// Drops entries for sessions that no longer exist.
    public func prune(keeping sessionIds: Set<String>) {
        lock.lock()
        let visits = (cache ?? [:]).filter { sessionIds.contains($0.key) }
        guard visits.count != (cache?.count ?? 0) else { lock.unlock(); return }
        cache = visits
        lock.unlock()
        persist(visits)
    }

    private func persist(_ visits: [String: Double]) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try? encoder.encode(visits).write(to: url, options: .atomic)
    }
}

/// How a session row's timestamp and status dot should read.
///
/// Colour here answers "have you dealt with this yet", not "what state is the session in" —
/// the dot glyph and the detail text already say the latter. A row you have opened settles to
/// grey even though it is still waiting for a reply, which is what makes a menu full of
/// waiting sessions scannable.
public enum RowTint: String, Equatable, Sendable {
    /// Finished, and not asking for anything. Nothing is owed and nothing is happening.
    case settled
    /// Claude is running in this tab. Nothing is required of the user.
    case working
    /// Asked you something, and you have opened it without answering.
    ///
    /// The tab you looked at, meant to reply to, and left — usually because something louder
    /// pulled you away. It has stopped alerting, because you have seen it, so this colour is
    /// the only thing still holding it.
    case owed
    /// Asked you something you have not looked at yet.
    case waiting
    /// Blocked on a permission request. The only state where Claude cannot proceed at all.
    case urgent
}

public extension SessionRecord {
    /// Waiting on the user, with no visit to the tab since that wait began.
    ///
    /// Glancing at the menu leaves this set — only genuinely reaching the tab clears it — and
    /// it clears there even though the session still needs a reply.
    func isUnseen(lastVisit: Double?) -> Bool {
        guard state == .waiting else { return false }
        return (lastVisit ?? 0) < attentionSince
    }

    /// A blocking request the user has not yet been present for.
    ///
    /// Deliberately narrower than `isUnseen`: this one drives the menu bar dot, which has to
    /// keep meaning "something is actually stuck" rather than "there is unread output".
    func isUnseenUrgent(lastVisit: Double?) -> Bool {
        urgency == .urgent && isUnseen(lastVisit: lastVisit)
    }

    /// Red -> orange -> teal -> grey -> purple, in descending order of what it wants from you.
    ///
    /// Red does not decay when opened. A permission request is blocked whether or not you have
    /// looked at it, and a colour that softened on being read would be describing your
    /// attention rather than the session's state — it stays red until you answer it.
    func tint(lastVisit: Double?) -> RowTint {
        guard state == .waiting else { return .working }
        if reason == .permission { return .urgent }
        guard invitesReply else { return .settled }
        return isUnseen(lastVisit: lastVisit) ? .waiting : .owed
    }
}

import Foundation

/// Remembers which waits have already been alerted for.
///
/// `SessionRecord` carries `notified` and `escalated`, but the app must not be the one to write
/// them: the hook rewrites the whole record on every event, so two writers on one file would
/// race and lose updates. This is the same reason `VisitStore` exists.
///
/// Keyed by the wait rather than the session. A record's `attentionSince` moves when a new wait
/// begins or the reason changes under the user, so comparing against it re-arms the alert
/// automatically — no flag to reset, and no way for a stale entry to silence a genuinely new
/// request.
public final class AlertStore {
    public struct State: Codable, Equatable, Sendable {
        /// The `attentionSince` this alert was raised for.
        public var wait: Double
        /// How many reminders this wait has already produced.
        ///
        /// Replaces the old `escalated` flag; an old alerts.json fails to decode wholesale,
        /// which is safe — the un-primed first pass adopts every in-progress wait quietly.
        public var escalations: Int

        public init(wait: Double, escalations: Int = 0) {
            self.wait = wait
            self.escalations = escalations
        }
    }

    public let url: URL
    private let lock = NSLock()
    private var cache: [String: State]?

    public init(url: URL = Paths.alertsFile) {
        self.url = url
    }

    public func all() -> [String: State] {
        lock.lock()
        defer { lock.unlock() }
        if let cache { return cache }
        let loaded = (try? Data(contentsOf: url))
            .flatMap { try? JSONDecoder().decode([String: State].self, from: $0) } ?? [:]
        cache = loaded
        return loaded
    }

    /// Whether this exact wait has already produced its first alert.
    public func hasNotified(_ record: SessionRecord) -> Bool {
        guard let state = all()[record.sessionId] else { return false }
        return state.wait == record.attentionSince
    }

    /// How many reminders this exact wait has already produced; a different wait counts from zero.
    public func escalations(_ record: SessionRecord) -> Int {
        guard let state = all()[record.sessionId], state.wait == record.attentionSince else { return 0 }
        return state.escalations
    }

    public func markNotified(_ record: SessionRecord) {
        mutate { $0[record.sessionId] = State(wait: record.attentionSince) }
    }

    public func markEscalated(_ record: SessionRecord) {
        mutate { states in
            let sent = states[record.sessionId]?.wait == record.attentionSince
                ? states[record.sessionId]?.escalations ?? 0
                : 0
            states[record.sessionId] = State(wait: record.attentionSince, escalations: sent + 1)
        }
    }

    /// Records a wait that was already in progress before this app started as already handled.
    ///
    /// Marking it merely notified is not enough: a session that has been waiting longer than the
    /// escalation threshold — which most of them have, if the app was just launched — becomes
    /// eligible to escalate on the very next pass, producing the same burst of alerts that
    /// adopting it was meant to avoid, one tick later. So anything already past the threshold
    /// adopts the escalated state too, while a young wait keeps its escalation ahead of it.
    public func adopt(_ record: SessionRecord, escalateAfterSeconds: Double, now: Double) {
        if record.elapsed(now: now) >= escalateAfterSeconds {
            mutate { $0[record.sessionId] = State(wait: record.attentionSince,
                                                  escalations: AlertPolicy.maxEscalations) }
        } else {
            markNotified(record)
        }
    }

    public func prune(keeping sessionIds: Set<String>) {
        mutate { states in
            states = states.filter { sessionIds.contains($0.key) }
        }
    }

    private func mutate(_ body: (inout [String: State]) -> Void) {
        lock.lock()
        var states = cache ?? (try? Data(contentsOf: url))
            .flatMap { try? JSONDecoder().decode([String: State].self, from: $0) } ?? [:]
        let before = states
        body(&states)
        guard states != before else { lock.unlock(); return }
        cache = states
        lock.unlock()
        persist(states)
    }

    private func persist(_ states: [String: State]) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try? encoder.encode(states).write(to: url, options: .atomic)
    }
}

import Foundation
import TNavCore

enum ListCommand {
    static func run(_ arguments: [String]) -> Int32 {
        let store = SessionStore()
        if !arguments.contains("--no-prune") { store.prune() }

        let config = ConfigStore().load()
        let visits = VisitStore().all()
        let now = Date().timeIntervalSince1970
        let records = store.all().sorted { lhs, rhs in
            if lhs.state != rhs.state { return lhs.state == .waiting }
            return lhs.since < rhs.since
        }

        guard !records.isEmpty else {
            print("no tracked sessions")
            return 0
        }

        let frontmost = try? AdaptiveTabController().frontmostTTY()

        for record in records {
            let marker = record.state == .waiting ? "●" : "○"
            let unseen = record.isUnseenUrgent(lastVisit: visits[record.sessionId]) ? " ◉" : ""
            let decision = AlertPolicy.decide(record: record,
                                              config: config,
                                              frontmostTTY: frontmost,
                                              now: now)
            var notes: [String] = []
            if let remaining = config.snoozeRemaining(record, now: now) {
                notes.append("snoozed \(Elapsed.short(remaining))")
            }
            // Report why a session is quiet rather than lumping every reason under one label —
            // "muted" and "filtered by blocking-only" call for very different responses.
            if let reason = describe(decision) { notes.append(reason) }

            let suffix = notes.isEmpty ? "" : "  [\(notes.joined(separator: ", "))]"
            print("\(marker)\(unseen) \(record.tty)  \(record.summary(now: now))\(suffix)")
        }
        return 0
    }

    private static func describe(_ decision: AlertDecision) -> String? {
        switch decision {
        case .notify, .escalate, .suppressNotWaiting: return nil
        case .suppressMuted: return "muted"
        case .suppressSnoozed: return nil   // already reported with its remaining time
        case .suppressPaused: return "paused"
        case .suppressNonBlocking: return "not blocking"
        case .suppressAlreadyFocused: return "you're here"
        case .suppressAlreadyNotified: return "already alerted"
        }
    }
}

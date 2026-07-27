import Foundation
import TNavCore

enum JumpCommand {
    static func run(_ arguments: [String]) -> Int32 {
        let store = SessionStore()
        let controller = AdaptiveTabController()

        let target: String
        switch arguments.first {
        case nil, "--oldest":
            store.prune()
            guard let oldest = store.waiting().first else {
                print("no sessions waiting")
                return 0
            }
            target = oldest.tty
            print("→ \(oldest.summary(now: Date().timeIntervalSince1970))")
        case let value?:
            target = value
        }

        do {
            switch try controller.focus(tty: target) {
            case .focused:
                return 0
            case .notFound:
                printErr("no Terminal tab owns \(target) — the tab was probably closed")
                // Only drop records once Terminal independently confirms the tty is gone.
                // Deleting state on the strength of a single failed lookup loses good
                // records whenever a scripting call misbehaves.
                let live = (try? controller.knownTTYs()) ?? []
                if !live.isEmpty, !live.contains(target) {
                    for record in store.all() where record.tty == target {
                        store.remove(record.sessionId)
                    }
                }
                return 1
            }
        } catch {
            printErr("\(error)")
            return 1
        }
    }
}

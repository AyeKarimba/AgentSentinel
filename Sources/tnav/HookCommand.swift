import Darwin
import Foundation
import TNavCore

/// Runs on every Claude Code hook event.
///
/// Two hard rules:
///  1. Always exit 0. A nonzero exit from a hook can block or disturb the session; a bug in
///     ClaudeBar must never break the user's Claude Code.
///  2. Stay fast. Everything here is syscalls and one small file write — no subprocesses.
enum HookCommand {
    static func run() -> Int32 {
        do {
            try process()
        } catch {
            EventLog.append("hook error: \(error)")
        }
        return 0
    }

    private static func process() throws {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard !data.isEmpty else {
            EventLog.append("hook: empty stdin")
            return
        }

        let payload: HookPayload
        do {
            payload = try HookPayload.decode(data)
        } catch {
            EventLog.append("hook: undecodable payload: \(error)")
            return
        }

        guard let identity = TTYResolver().resolve(from: getpid()) else {
            // Expected when Claude Code runs somewhere without a controlling terminal
            // (CI, an editor pane, a detached agent). Nothing to navigate to.
            EventLog.append("hook: no tty for session \(payload.sessionId) (\(payload.hookEventName))")
            return
        }

        let store = SessionStore()
        let existing = store.load(agent: .claude, sessionId: payload.sessionId)
        let outcome = HookProcessor.apply(payload: payload,
                                         identity: identity,
                                         existing: existing,
                                         now: Date().timeIntervalSince1970)

        switch outcome {
        case .updated(let record):
            try store.save(record)
            logUnknownNotificationType(payload)
        case .removed(let sessionId):
            store.remove(agent: .claude, sessionId: sessionId)
        case .ignoredNested:
            // Nested `claude` resolves to its parent's tab; acting on it would raise a
            // phantom alert for a tab that is actually busy.
            break
        case .ignoredUnknownEvent(let name):
            EventLog.append("hook: unhandled event \(name)")
        }

        Signals.postStateChanged()
    }

    /// Phase 0 only ever observed "idle_prompt". Record anything else so the real permission
    /// notification type documents itself rather than staying a guess.
    private static func logUnknownNotificationType(_ payload: HookPayload) {
        guard payload.hookEventName == HookEventKind.notification.rawValue,
              let type = payload.notificationType,
              type != HookProcessor.idlePromptType
        else { return }
        EventLog.append("notification_type=\(type) message=\(payload.message ?? "")")
    }
}

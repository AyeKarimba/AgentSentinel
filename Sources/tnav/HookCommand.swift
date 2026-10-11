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

        let adapter = ClaudeAdapter()
        let hook: DecodedHook
        do {
            hook = try adapter.decode(data, eventHint: nil)
        } catch {
            EventLog.append("hook: undecodable payload: \(error)")
            return
        }

        guard let identity = TTYResolver().resolve(from: getpid()) else {
            EventLog.append("hook: no tty for session \(hook.sessionId) (\(hook.rawEventName))")
            return
        }

        let store = SessionStore()
        let existing = store.load(agent: .claude, sessionId: hook.sessionId)
        let outcome = HookProcessor.apply(agent: .claude,
                                         hook: hook,
                                         identity: identity,
                                         existing: existing,
                                         now: Date().timeIntervalSince1970)

        switch outcome {
        case .updated(let record):
            try store.save(record)
        case .removed(let agent, let sessionId):
            store.remove(agent: agent, sessionId: sessionId)
        case .ignoredNested:
            break
        case .ignoredUnknownEvent(let name):
            EventLog.append("hook: unhandled event \(name)")
        }

        Signals.postStateChanged()
    }
}

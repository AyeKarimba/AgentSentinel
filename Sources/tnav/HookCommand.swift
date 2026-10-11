import Darwin
import Foundation
import TNavCore

/// Runs on every hook event, for every agent.
///
/// Two hard rules:
///  1. Always exit 0 and print nothing. A nonzero exit or stray stdout from a hook can block
///     or disturb the session — Codex and Copilot read a permission hook's stdout as a
///     decision — so a bug here must never break the user's agent.
///  2. Stay fast. Everything here is syscalls and one small file write — no subprocesses.
///
/// The agent is named on the command line at registration time (`--agent codex`), never
/// guessed from the payload: Codex's payload is deliberately Claude-shaped. `--event` exists
/// for Copilot, whose payload does not name the event that fired.
enum HookCommand {
    /// Environment variable that, when set to `1`, makes the hook proceed despite an
    /// ancestry/registration agent mismatch. It exists for the integration test, which runs
    /// its canned payloads from inside another agent's process tree.
    static let ignoreAncestryMismatchVariable = "TNAV_HOOK_IGNORE_ANCESTRY_MISMATCH"

    static func run(_ arguments: [String]) -> Int32 {
        do {
            try process(arguments)
        } catch {
            EventLog.append("hook error: \(error)")
        }
        return 0
    }

    /// `--agent X` defaults to claude so hooks registered by the 1.0.x build keep working
    /// until the user reinstalls.
    static func parse(_ arguments: [String]) -> (agent: AgentKind, event: String?) {
        var agent = AgentKind.claude
        var event: String?
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--agent" where index + 1 < arguments.count:
                agent = AgentKind(rawValue: arguments[index + 1]); index += 2
            case "--event" where index + 1 < arguments.count:
                event = arguments[index + 1]; index += 2
            default:
                index += 1
            }
        }
        return (agent, event)
    }

    private static func process(_ arguments: [String]) throws {
        let (agent, eventHint) = parse(arguments)
        // Read stdin first, even for an unknown agent, so a writer never sees EPIPE.
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard let adapter = AgentRegistry.adapter(for: agent) else {
            EventLog.append("hook: no adapter for agent '\(agent.rawValue)'")
            return
        }

        guard !data.isEmpty else {
            EventLog.append("hook(\(agent.rawValue)): empty stdin")
            return
        }

        let hook: DecodedHook
        do {
            hook = try adapter.decode(data, eventHint: eventHint)
        } catch {
            EventLog.append("hook(\(agent.rawValue)): undecodable payload: \(error)")
            return
        }

        guard let identity = TTYResolver().resolve(from: getpid()) else {
            // Expected when the agent runs somewhere without a controlling terminal (CI, an
            // editor pane, a detached agent). Nothing to navigate to.
            EventLog.append("hook(\(agent.rawValue)): no tty for session \(hook.sessionId) (\(hook.rawEventName))")
            return
        }

        if let nearest = identity.nearestAgent, nearest != agent {
            // The process tree says one agent, the registration says another. Happens when
            // agent A's hook config is inherited by a subprocess that is really agent B; the
            // ancestry is the more trustworthy of the two, so log it and treat as nested.
            let message = "hook(\(agent.rawValue)): nearest agent in ancestry is \(nearest.rawValue)"
            if ProcessInfo.processInfo.environment[ignoreAncestryMismatchVariable] == "1" {
                EventLog.append(message + "; proceeding (override)")
            } else {
                EventLog.append(message + "; ignoring")
                return
            }
        }

        let store = SessionStore()
        let existing = store.load(agent: agent, sessionId: hook.sessionId)
        let outcome = HookProcessor.apply(agent: agent,
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
            // Nested agents resolve to their parent's tab; acting on them would raise a
            // phantom alert for a tab that is actually busy.
            break
        case .ignoredUnknownEvent(let name):
            EventLog.append("hook(\(agent.rawValue)): unhandled event \(name)")
        }

        Signals.postStateChanged()
    }
}

import Foundation

/// Copies the 1.0.x state directory (`~/.claude/tnav`) into the new one, once.
///
/// Copy rather than move, and never overwrite: a hook from an already-running session may
/// have written to the new directory before the app first launched, and that newer record
/// must win. The old directory is left for `uninstall.sh --purge` to deal with, so a user
/// who downgrades loses nothing.
public enum StateMigration {
    static let files = ["config.json", "visits.json", "alerts.json", "events.log"]

    /// Returns the relative paths that were copied.
    @discardableResult
    public static func run(from old: URL, to new: URL) -> [String] {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: old.path, isDirectory: &isDirectory), isDirectory.boolValue else { return [] }

        var copied: [String] = []
        var candidates = files
        let oldSessions = old.appendingPathComponent("sessions")
        if let names = try? fm.contentsOfDirectory(atPath: oldSessions.path) {
            candidates += names.filter { $0.hasSuffix(".json") }.map { "sessions/\($0)" }
        }

        for relative in candidates {
            let source = old.appendingPathComponent(relative)
            let target = new.appendingPathComponent(relative)
            guard fm.fileExists(atPath: source.path), !fm.fileExists(atPath: target.path) else { continue }
            do {
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: source, to: target)
                copied.append(relative)
            } catch {
                EventLog.append("migration: could not copy \(relative): \(error)")
            }
        }
        return copied
    }

    /// The app calls this at launch. A no-op when `TNAV_STATE_DIR` points somewhere else, so
    /// tests and scratch runs never touch the real legacy directory.
    public static func runIfNeeded() {
        guard ProcessInfo.processInfo.environment[Paths.stateDirectoryVariable] == nil else { return }
        let copied = run(from: Paths.legacyRoot, to: Paths.root)
        if !copied.isEmpty {
            EventLog.append("migration: copied \(copied.count) file(s) from \(Paths.legacyRoot.path)")
        }
    }
}

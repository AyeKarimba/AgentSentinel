import Foundation

/// Default on-disk locations. Every type that touches disk takes its directory as an
/// injectable parameter defaulting to one of these, so tests can run against a temp dir.
public enum Paths {
    /// Overrides the state directory wholesale. Every type here already takes an injectable
    /// directory, but the app wires its own stores from these defaults, so end-to-end checks —
    /// what the menu actually renders for a given set of records — had no way in. `$HOME` is
    /// not that way in: `homeDirectoryForCurrentUser` reads the password database, not the
    /// environment, so a test that sets it silently exercises the real state instead.
    public static let stateDirectoryVariable = "TNAV_STATE_DIR"

    public static let root: URL = {
        let override = ProcessInfo.processInfo.environment[stateDirectoryVariable]
        if let override, !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath,
                       isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("tnav", isDirectory: true)
    }()

    public static let sessions: URL = root.appendingPathComponent("sessions", isDirectory: true)
    public static let configFile: URL = root.appendingPathComponent("config.json")
    public static let eventLog: URL = root.appendingPathComponent("events.log")
    public static let visitsFile: URL = root.appendingPathComponent("visits.json")

    public static func ensureRoot() throws {
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    }
}

public enum Elapsed {
    /// Compact human duration: "8s", "3m", "1h", "1h04m".
    public static func short(_ seconds: Double) -> String {
        let total = Int(max(0, seconds).rounded())
        if total < 60 { return "\(total)s" }
        let minutes = total / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder == 0 ? "\(hours)h" : String(format: "%dh%02dm", hours, remainder)
    }
}

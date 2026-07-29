import Darwin
import Foundation

/// One JSON file per session under `sessions/`. Files are the whole contract between the
/// hook binary and the menu bar app; the app can be down without state going wrong.
public final class SessionStore {
    public let directory: URL
    private let table: ProcessTable
    private let fileManager = FileManager.default

    public init(directory: URL = Paths.sessions, table: ProcessTable = SysctlProcessTable()) {
        self.directory = directory
        self.table = table
    }

    public func ensureDirectory() throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Session ids are UUIDs, but never trust an id straight from a payload with a path.
    static func sanitize(_ sessionId: String) -> String? {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        guard !sessionId.isEmpty,
              sessionId.count <= 128,
              sessionId != ".",
              sessionId != "..",
              sessionId.allSatisfy({ allowed.contains($0) })
        else { return nil }
        return sessionId
    }

    public func url(for sessionId: String) -> URL? {
        guard let safe = Self.sanitize(sessionId) else { return nil }
        return directory.appendingPathComponent("\(safe).json")
    }

    public func load(_ sessionId: String) -> SessionRecord? {
        guard let url = url(for: sessionId), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SessionRecord.self, from: data)
    }

    /// Atomic: `.atomic` writes a temp file and renames, so a concurrent reader in the app
    /// never observes a partially written record.
    public func save(_ record: SessionRecord) throws {
        guard let url = url(for: record.sessionId) else {
            throw StoreError.invalidSessionId(record.sessionId)
        }
        try ensureDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(record).write(to: url, options: .atomic)
    }

    public func remove(_ sessionId: String) {
        guard let url = url(for: sessionId) else { return }
        try? fileManager.removeItem(at: url)
    }

    public func all() -> [SessionRecord] {
        let entries = (try? fileManager.contentsOfDirectory(at: directory,
                                                           includingPropertiesForKeys: nil)) ?? []
        return entries
            .filter { $0.pathExtension == "json" }
            .compactMap { try? Data(contentsOf: $0) }
            .compactMap { try? JSONDecoder().decode(SessionRecord.self, from: $0) }
    }

    /// Waiting sessions, oldest wait first — the order the jump hotkey cycles through.
    public func waiting() -> [SessionRecord] {
        all().filter { $0.state == .waiting }.sorted { $0.since < $1.since }
    }

    /// A record is stale when its process is gone, or when the pid has been recycled by an
    /// unrelated process (detected by the TTY no longer matching).
    public func isAlive(_ record: SessionRecord) -> Bool {
        guard let row = table.row(for: record.pid) else { return false }
        return row.tty == record.tty
    }

    @discardableResult
    public func prune() -> [String] {
        let loaded = all()
        let survivors = Set(prune(loaded).map(\.sessionId))
        return loaded.map(\.sessionId).filter { !survivors.contains($0) }
    }

    /// Prunes an already-loaded snapshot and hands back the survivors, so a caller that wants
    /// the records anyway doesn't pay for a second directory scan and round of JSON decoding.
    /// The menu bar app reloads on a timer, which made that duplication a per-second cost.
    @discardableResult
    public func prune(_ records: [SessionRecord]) -> [SessionRecord] {
        var alive: [SessionRecord] = []
        for record in records {
            if isAlive(record) {
                alive.append(record)
            } else {
                remove(record.sessionId)
            }
        }
        return dropStaleDuplicates(alive)
    }

    /// Drops records that share a pid with a newer one.
    ///
    /// `isAlive` cannot catch these. One `claude` process serves one session, so two records
    /// claiming the same pid means at least one is stale — but the pid *is* alive and its tty
    /// *does* match, so the liveness check passes and the stale one sits in the menu forever.
    /// It cannot be jumped to, because the tab it names belongs to the other session, and until
    /// now there was no way to get rid of it.
    ///
    /// Ties break on `since`, keeping the most recently active. That can pick wrong when a real
    /// session has been waiting longer than the stale record has existed — which is acceptable
    /// because it self-corrects: a live session rewrites its record on its next hook event,
    /// while a stale one never comes back.
    private func dropStaleDuplicates(_ records: [SessionRecord]) -> [SessionRecord] {
        var newestByPID: [Int32: SessionRecord] = [:]
        for record in records {
            if let existing = newestByPID[record.pid], existing.since >= record.since { continue }
            newestByPID[record.pid] = record
        }
        let keep = Set(newestByPID.values.map(\.sessionId))
        for record in records where !keep.contains(record.sessionId) {
            EventLog.append("pruned \(record.sessionId): pid \(record.pid) belongs to another session")
            remove(record.sessionId)
        }
        return records.filter { keep.contains($0.sessionId) }
    }

    public enum StoreError: Error, CustomStringConvertible {
        case invalidSessionId(String)

        public var description: String {
            switch self {
            case .invalidSessionId(let id): return "invalid session id: \(id)"
            }
        }
    }
}

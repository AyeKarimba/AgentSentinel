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

    /// Sanitised filename stem for a record, or nil when the id is not safe as a filename.
    static func stem(agent: AgentKind, sessionId: String) -> String? {
        guard let safe = sanitize(sessionId), sanitize(agent.rawValue) != nil else { return nil }
        return "\(agent.rawValue)-\(safe)"
    }

    public func url(agent: AgentKind, sessionId: String) -> URL? {
        guard let stem = Self.stem(agent: agent, sessionId: sessionId) else { return nil }
        return directory.appendingPathComponent("\(stem).json")
    }

    /// Where the 1.0.x build kept the same record: a bare `<sessionId>.json`. Only Claude
    /// sessions ever lived there.
    func legacyURL(sessionId: String) -> URL? {
        guard let safe = Self.sanitize(sessionId) else { return nil }
        return directory.appendingPathComponent("\(safe).json")
    }

    public func load(agent: AgentKind, sessionId: String) -> SessionRecord? {
        if let url = url(agent: agent, sessionId: sessionId),
           let data = try? Data(contentsOf: url),
           let record = try? JSONDecoder().decode(SessionRecord.self, from: data) {
            return record
        }
        guard agent == .claude,
              let legacy = legacyURL(sessionId: sessionId),
              let data = try? Data(contentsOf: legacy),
              let record = try? JSONDecoder().decode(SessionRecord.self, from: data)
        else { return nil }
        return record
    }

    /// Atomic: `.atomic` writes a temp file and renames, so a concurrent reader in the app
    /// never observes a partially written record. Also retires the pre-1.1 bare filename for
    /// the same session, so an upgraded install does not list it twice.
    public func save(_ record: SessionRecord) throws {
        guard let url = url(agent: record.agent, sessionId: record.sessionId) else {
            throw StoreError.invalidSessionId(record.sessionId)
        }
        try ensureDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(record).write(to: url, options: .atomic)
        if record.agent == .claude, let legacy = legacyURL(sessionId: record.sessionId) {
            try? fileManager.removeItem(at: legacy)
        }
    }

    public func remove(agent: AgentKind, sessionId: String) {
        if let url = url(agent: agent, sessionId: sessionId) {
            try? fileManager.removeItem(at: url)
        }
        if agent == .claude, let legacy = legacyURL(sessionId: sessionId) {
            try? fileManager.removeItem(at: legacy)
        }
    }

    public func remove(_ record: SessionRecord) {
        remove(agent: record.agent, sessionId: record.sessionId)
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
                remove(record)
            }
        }
        return alive
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

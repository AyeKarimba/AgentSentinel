import Foundation

public struct Config: Codable, Equatable, Sendable {
    public var paused: Bool
    public var escalateAfterSeconds: Double
    /// When true, rows and notifications show Claude's closing message instead of the generic
    /// reason. Free to support: `Stop` ships `last_assistant_message` inline (Phase 0, Finding 1).
    public var showLastMessage: Bool
    /// Only alert for requests that are actually blocking a session. Turn-completions stay
    /// visible in the menu and the badge, they just stop making noise.
    public var blockingOnly: Bool
    /// Tab-scoped mutes, keyed by `SessionRecord.tabMuteKey` ("tty|cwd"). Survives restarting
    /// Claude in the same tab.
    public var mutedTabs: [String]
    /// Session-scoped mutes, cleared when that session ends.
    public var mutedSessions: [String]
    /// Tab-scoped snoozes: `tabMuteKey` → unix time the snooze expires.
    ///
    /// Distinct from mute on purpose. Mute is permanent until undone, which is the wrong tool
    /// for "I'll get to it in ten minutes" — and a tab muted in that spirit is how a session
    /// goes silently forgotten.
    public var snoozedUntil: [String: Double]

    public init(paused: Bool = false,
                escalateAfterSeconds: Double = 300,
                showLastMessage: Bool = true,
                blockingOnly: Bool = false,
                mutedTabs: [String] = [],
                mutedSessions: [String] = [],
                snoozedUntil: [String: Double] = [:]) {
        self.paused = paused
        self.escalateAfterSeconds = escalateAfterSeconds
        self.showLastMessage = showLastMessage
        self.blockingOnly = blockingOnly
        self.mutedTabs = mutedTabs
        self.mutedSessions = mutedSessions
        self.snoozedUntil = snoozedUntil
    }

    public func isMuted(_ record: SessionRecord) -> Bool {
        mutedTabs.contains(record.tabMuteKey) || mutedSessions.contains(record.sessionId)
    }

    public func isSnoozed(_ record: SessionRecord, now: Double) -> Bool {
        (snoozedUntil[record.tabMuteKey] ?? 0) > now
    }

    /// Seconds left on an active snooze, or nil when there isn't one.
    public func snoozeRemaining(_ record: SessionRecord, now: Double) -> Double? {
        guard let until = snoozedUntil[record.tabMuteKey], until > now else { return nil }
        return until - now
    }

    /// Silenced one way or another — what the badge and alerts should skip.
    public func isSilenced(_ record: SessionRecord, now: Double) -> Bool {
        isMuted(record) || isSnoozed(record, now: now)
    }

    /// Drops snoozes that have already elapsed, so the file doesn't accumulate dead keys.
    public mutating func pruneExpiredSnoozes(now: Double) {
        snoozedUntil = snoozedUntil.filter { $0.value > now }
    }

    // Decoded leniently so a config written by an older build (or hand-edited with a key
    // missing) still loads instead of resetting everything to defaults.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Config()
        paused = try container.decodeIfPresent(Bool.self, forKey: .paused) ?? defaults.paused
        escalateAfterSeconds = try container.decodeIfPresent(Double.self, forKey: .escalateAfterSeconds)
            ?? defaults.escalateAfterSeconds
        showLastMessage = try container.decodeIfPresent(Bool.self, forKey: .showLastMessage)
            ?? defaults.showLastMessage
        blockingOnly = try container.decodeIfPresent(Bool.self, forKey: .blockingOnly)
            ?? defaults.blockingOnly
        mutedTabs = try container.decodeIfPresent([String].self, forKey: .mutedTabs) ?? []
        mutedSessions = try container.decodeIfPresent([String].self, forKey: .mutedSessions) ?? []
        snoozedUntil = try container.decodeIfPresent([String: Double].self, forKey: .snoozedUntil) ?? [:]
    }
}

public final class ConfigStore {
    public let url: URL
    private let lock = NSLock()

    public init(url: URL = Paths.configFile) {
        self.url = url
    }

    public func load() -> Config {
        guard let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(Config.self, from: data)
        else { return Config() }
        return config
    }

    public func save(_ config: Config) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                               withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(config).write(to: url, options: .atomic)
    }

    /// Read-modify-write under a lock. Serialises the menu bar app and concurrent `tnav mute`
    /// invocations from different tabs.
    @discardableResult
    public func mutate(_ body: (inout Config) -> Void) throws -> Config {
        lock.lock()
        defer { lock.unlock() }
        var config = load()
        body(&config)
        try save(config)
        return config
    }
}

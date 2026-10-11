import AppKit
import Foundation
import TNavCore

/// Keeps an in-memory view of the session files fresh.
///
/// Four wake-up sources, deliberately overlapping:
///  - `notify_post` from the hook: instant, the normal path.
///  - a directory watch: covers edits that arrive without a signal (manual `tnav` runs).
///  - application activation: the instant the user moves into or out of the terminal.
///  - a periodic reload: covers everything none of the above can see — a tab switched by
///    hand, a tab closed, a config edit from another process — and ticks the elapsed labels.
///
/// That last one has to be a genuine reload rather than a redraw. It used to only re-render
/// the existing snapshot, which meant the three changes listed above waited on a hook event
/// from a session that, being waiting, was never going to produce one.
final class SessionMonitor {
    private let store: SessionStore
    private let configStore: ConfigStore
    private let visitStore: VisitStore
    private let tabs: AdaptiveTabController
    private var notifyToken: Int32?
    private var directorySource: DispatchSourceFileSystemObject?
    private var directoryDescriptor: CInt = -1
    private var refreshTimer: Timer?
    private var activationObserver: NSObjectProtocol?

    private(set) var records: [SessionRecord] = []
    private(set) var config: Config = Config()
    private(set) var visits: [String: Double] = [:]
    /// TTY of the tab the user is looking at, or nil when Terminal isn't frontmost.
    private(set) var frontmostTTY: String?

    /// Called on the main queue whenever the visible state may have changed.
    var onChange: (() -> Void)?

    init(store: SessionStore = SessionStore(),
         configStore: ConfigStore = ConfigStore(),
         visitStore: VisitStore = VisitStore(),
         tabs: AdaptiveTabController = AdaptiveTabController()) {
        self.store = store
        self.configStore = configStore
        self.visitStore = visitStore
        self.tabs = tabs
    }

    func start() {
        try? store.ensureDirectory()
        notifyToken = Signals.observeStateChanged(queue: .main) { [weak self] in
            self?.reload()
        }
        if notifyToken == nil {
            // Without it the app still works, but only at the periodic cadence — worth saying
            // rather than silently feeling sluggish.
            EventLog.append("app: notify registration failed; updates fall back to polling")
        }
        startDirectoryWatch()
        startActivationWatch()
        reload()
    }

    func stop() {
        if let notifyToken { Signals.cancel(notifyToken) }
        notifyToken = nil
        directorySource?.cancel()
        directorySource = nil
        refreshTimer?.invalidate()
        refreshTimer = nil
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        activationObserver = nil
    }

    func reload() {
        config = configStore.load()
        // One directory scan for the whole pass: pruning, the visit check and the display list
        // all used to load the records separately, which was affordable at the old cadence and
        // is not at one reload a second.
        let live = store.prune(store.all())

        // Paint what is already known before doing anything that can block. The visit poll
        // below costs an Apple Event to Terminal — a few milliseconds usually, but tens when
        // Terminal is busy, and a state change that has already arrived from the hook has no
        // reason to queue behind it.
        apply(live)

        let policy = RefreshPolicy(records: live,
                                   visits: visits,
                                   summary: summary(),
                                   terminalIsFrontmost: terminalIsFrontmost)
        if recordCurrentVisit(in: live, polling: policy.pollsFrontmostTab) {
            // The poll moved a row from unread to opened, which changes both its colour and
            // its place in the order — cheap to redo, and only when something actually moved.
            apply(live)
        }
        scheduleRefresh(after: policy.interval)
    }

    /// Sorts by the colour hierarchy the legend describes and hands the result to the UI.
    ///
    /// Red (unread blocking request) first, then amber (unread turn completion), then grey
    /// (opened but still unanswered), then purple (Claude still working) — so the rows that
    /// want something are always above the rows that do not.
    ///
    /// Within one colour, silenced tabs sink: muting is a request to stop competing for
    /// attention, and a muted tab outranking an audible one of the same colour would undo
    /// that. Then waits sort longest-first, and working sessions most-recently-started first.
    private func apply(_ live: [SessionRecord]) {
        visits = visitStore.all()
        let now = Date().timeIntervalSince1970
        records = live.sorted { lhs, rhs in
            let (left, right) = (rank(lhs), rank(rhs))
            if left != right { return left < right }

            let (leftSilenced, rightSilenced) = (config.isSilenced(lhs, now: now),
                                                 config.isSilenced(rhs, now: now))
            if leftSilenced != rightSilenced { return !leftSilenced }

            return lhs.state == .waiting ? lhs.since < rhs.since : lhs.since > rhs.since
        }
        visitStore.prune(keeping: Set(records.map(\.sessionId)))
        onChange?()
    }

    private func rank(_ record: SessionRecord) -> Int {
        switch record.tint(lastVisit: visits[record.sessionId]) {
        case .urgent: return 0
        case .waiting: return 1
        case .settled: return 2
        case .working: return 3
        }
    }

    func summary(now: Date = Date()) -> StatusSummary {
        StatusSummary(records: records, config: config, visits: visits,
                      now: now.timeIntervalSince1970)
    }

    /// Whether the user is in the terminal at all. Reads state the window server already
    /// publishes, so unlike `frontmostTTY()` it sends no Apple Event and is free to ask on
    /// every pass — which is the point, since it gates the call that isn't free.
    private var terminalIsFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == tabs.applicationBundleIdentifier
    }

    /// Notes that the user is presently in a tab, whether they got there through this app or
    /// by their own ⌘` — the "haven't looked at it" marker has to clear either way, otherwise
    /// it would keep flagging requests the user has already read.
    ///
    /// Switching tabs inside the terminal writes no file and posts no signal, so asking is the
    /// only way to find out; `RefreshPolicy` decides how often that question is worth an Apple
    /// Event. A nil `frontmostTTY` therefore means "not in the terminal", never "didn't ask".
    ///
    /// Returns whether anything actually moved from unread to opened, so the caller can skip a
    /// second pass over the rows on the many polls that learn nothing new.
    private func recordCurrentVisit(in records: [SessionRecord], polling: Bool) -> Bool {
        guard polling else {
            frontmostTTY = nil
            return false
        }
        frontmostTTY = try? tabs.frontmostTTY()
        guard let frontmostTTY else { return false }

        let here = records.filter { $0.tty == frontmostTTY }
        let changed = here.contains { $0.isUnseen(lastVisit: visits[$0.sessionId]) }
        for record in here {
            visitStore.markVisited(sessionId: record.sessionId)
        }
        return changed
    }

    /// Drops a record from the menu.
    ///
    /// Safe by construction rather than by care: a session that is genuinely alive rewrites its
    /// record on its next hook event, so forgetting one is at worst temporary. Only a record
    /// with nothing behind it stays gone — which is precisely the one the user is trying to
    /// remove, and the case that had no remedy at all before.
    func forget(_ record: SessionRecord) {
        EventLog.append("forget: \(record.project) (\(record.tty), \(record.sessionId)) dismissed by hand")
        store.remove(record)
        reload()
    }

    func snooze(_ record: SessionRecord, seconds: Double) {
        let key = record.tabMuteKey
        let until = Date().timeIntervalSince1970 + seconds
        mutate { config in
            config.pruneExpiredSnoozes(now: Date().timeIntervalSince1970)
            config.snoozedUntil[key] = until
        }
    }

    func cancelSnooze(_ record: SessionRecord) {
        let key = record.tabMuteKey
        mutate { $0.snoozedUntil.removeValue(forKey: key) }
    }

    func mutate(_ body: (inout Config) -> Void) {
        _ = try? configStore.mutate(body)
        reload()
    }

    // MARK: - Wake-up sources

    private func startDirectoryWatch() {
        directoryDescriptor = open(store.directory.path, O_EVTONLY)
        guard directoryDescriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: directoryDescriptor,
                                                              eventMask: [.write, .delete, .rename],
                                                              queue: .main)
        source.setEventHandler { [weak self] in self?.reload() }
        source.setCancelHandler { [weak self] in
            guard let self, self.directoryDescriptor >= 0 else { return }
            close(self.directoryDescriptor)
            self.directoryDescriptor = -1
        }
        source.resume()
        directorySource = source
    }

    /// Moving into the terminal is the moment a tab switch becomes possible, and moving out is
    /// the moment polling for one stops being worth anything. The workspace tells us both for
    /// free, so neither has to wait for the next tick.
    private func startActivationWatch() {
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reload()
        }
    }

    /// A full reload, not a redraw: a visited tab, a closed tab and a config edit from another
    /// process all change what the menu should say without touching anything this app watches,
    /// so this pass is the only thing that can pick them up. `RefreshPolicy` sets the rate —
    /// once a second while the user is in the terminal with something unread, and no faster
    /// than the elapsed labels need otherwise.
    private func scheduleRefresh(after interval: TimeInterval) {
        refreshTimer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            self?.reload()
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }
}

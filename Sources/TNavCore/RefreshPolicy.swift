import Foundation

/// How long until the app should re-read the world, and whether that pass should ask the
/// terminal which tab is selected.
///
/// The app has three instant wake-up sources — a `notify_post` from the hook, a watch on the
/// sessions directory, and application-activation notices — and all three are driven by
/// *something else* acting. Three of the changes that matter are invisible to every one of
/// them:
///
///  - the user switching tabs inside the terminal, which writes no file and posts no signal;
///  - a tab being closed, whose session ends with the process and so never reports it;
///  - a config edit from a `tnav` invocation in another tab.
///
/// A waiting session produces no further hook events by definition, so those three can wait
/// indefinitely unless the periodic pass does a real reload. This type sets that pass's rate.
///
/// The one genuinely expensive input is the selected tab, which costs an Apple Event to the
/// terminal. That is why the fast cadence is conditional: the only thing it buys is noticing
/// a tab switch, which is only worth a poll per second when the user is actually in the
/// terminal *and* something is still unread.
public struct RefreshPolicy: Equatable, Sendable {
    /// Fast enough that a row settles while the user is still looking at the tab.
    public static let activeInterval: TimeInterval = 1
    /// Ceiling between reloads. `StatusSummary.refreshInterval` is allowed to ask for less
    /// often than this when only a label is at stake, but pruning a dead session and picking
    /// up an external config edit both ride on this pass, so it cannot go quiet for 30s.
    public static let maximumInterval: TimeInterval = 5

    /// Whether to spend an Apple Event asking the terminal which tab is selected.
    public let pollsFrontmostTab: Bool
    /// Seconds until the next reload.
    public let interval: TimeInterval

    public init(records: [SessionRecord],
                visits: [String: Double],
                summary: StatusSummary,
                terminalIsFrontmost: Bool) {
        // Nothing to learn from an app the user is not in: they cannot be switching tabs in it.
        pollsFrontmostTab = terminalIsFrontmost

        let hasUnread = records.contains { $0.isUnseen(lastVisit: visits[$0.sessionId]) }
        interval = terminalIsFrontmost && hasUnread
            ? Self.activeInterval
            : min(summary.refreshInterval, Self.maximumInterval)
    }
}

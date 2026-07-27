import CNotify
import Darwin
import Foundation

/// Hook → app wake-up, via a payload-free Darwin notification.
///
/// Chosen over a Unix socket because there is no connection state to manage and no failure
/// mode when the app isn't running: the hook has already written the session file, so state
/// stays correct and the app reconciles from disk on next launch. The signal is only a nudge.
public enum Signals {
    public static let stateChanged = "com.kailash.tnav.state-changed"

    public static func postStateChanged() {
        notify_post(stateChanged)
    }

    /// Registers `handler` to run on `queue` whenever any process posts the signal.
    /// Returns a token to pass to `cancel`, or nil if registration failed.
    public static func observeStateChanged(queue: DispatchQueue = .main,
                                           handler: @escaping () -> Void) -> Int32? {
        var token: Int32 = 0
        let status = notify_register_dispatch(stateChanged, &token, queue) { _ in handler() }
        guard status == UInt32(NOTIFY_STATUS_OK) else { return nil }
        return token
    }

    public static func cancel(_ token: Int32) {
        notify_cancel(token)
    }
}

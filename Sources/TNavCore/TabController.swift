import Foundation

public enum FocusOutcome: String, Sendable {
    case focused
    /// No tab with that TTY exists any more — the tab was closed. Caller should prune.
    case notFound
}

public enum TabControlError: Error, CustomStringConvertible, Equatable {
    /// Automation (Apple Events) permission has not been granted for the terminal app.
    case notPermitted
    /// Accessibility permission is missing, so cross-Space focus is unavailable.
    case accessibilityNotPermitted
    case terminalNotRunning
    case invalidTTY(String)
    case scriptFailed(code: Int, message: String)

    public var description: String {
        switch self {
        case .notPermitted:
            return """
                Automation permission denied. Grant it in System Settings → Privacy & \
                Security → Automation, then retry.
                """
        case .accessibilityNotPermitted:
            return """
                Accessibility permission denied, so windows on other Spaces cannot be \
                raised. Grant it in System Settings → Privacy & Security → Accessibility.
                """
        case .terminalNotRunning:
            return "Terminal is not running."
        case .invalidTTY(let tty):
            return "refusing to use suspicious tty: \(tty)"
        case .scriptFailed(let code, let message):
            return "AppleScript error \(code): \(message)"
        }
    }
}

/// The only terminal-specific surface in the system. Terminal.app is the sole
/// implementation today; iTerm2/Ghostty/VS Code can be added behind this protocol without
/// the hook or state layers changing.
public protocol TabController {
    /// Bundle identifier of the terminal application this controller drives.
    ///
    /// Lets a caller ask "is the user in the terminal right now" through `NSWorkspace`, which
    /// reads state the system already publishes, instead of through `frontmostTTY()`, which
    /// costs an Apple Event round trip to the terminal itself.
    var applicationBundleIdentifier: String { get }

    func focus(tty: String) throws -> FocusOutcome
    /// TTY of the selected tab of the frontmost window, or nil when the terminal app is not
    /// the frontmost application. Used to suppress alerts for a tab you're already viewing.
    func frontmostTTY() throws -> String?
    func knownTTYs() throws -> [String]
    /// Pass nil to restore the tab's default title.
    func setTitle(_ title: String?, tty: String) throws
}

/// Rejects anything that isn't a plain tty device path, which removes any question of
/// string interpolation into AppleScript source being injectable.
public func validateTTY(_ tty: String) throws {
    let prefix = "/dev/tty"
    guard tty.hasPrefix(prefix) else { throw TabControlError.invalidTTY(tty) }
    let suffix = tty.dropFirst(prefix.count)
    guard !suffix.isEmpty, suffix.count <= 16,
          suffix.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) })
    else { throw TabControlError.invalidTTY(tty) }
}

/// AppleScript string literal escaping for values that aren't TTYs (window titles).
func appleScriptLiteral(_ value: String) -> String {
    var escaped = ""
    for character in value {
        switch character {
        case "\\": escaped += "\\\\"
        case "\"": escaped += "\\\""
        case "\n", "\r": escaped += " "
        default: escaped.append(character)
        }
    }
    return "\"\(escaped)\""
}

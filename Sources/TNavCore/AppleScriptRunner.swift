import Foundation

#if canImport(AppKit)
import AppKit

/// Shared `NSAppleScript` execution. In-process (~5ms) rather than shelling out to
/// `osascript` (~60ms), because focus runs on a notification click and should feel instant.
public struct AppleScriptRunner: Sendable {
    /// errAEEventNotPermitted — TCC has denied Apple Events to the target app.
    static let errAEEventNotPermitted = -1743
    /// Raised when the target application isn't running.
    static let procNotFound = -600

    public init() {}

    /// NSAppleScript is not thread-safe and must be driven from the main thread.
    public func run(_ source: String) throws -> String {
        if !Thread.isMainThread {
            return try DispatchQueue.main.sync { try self.execute(source) }
        }
        return try execute(source)
    }

    private func execute(_ source: String) throws -> String {
        guard let script = NSAppleScript(source: source) else {
            throw TabControlError.scriptFailed(code: 0, message: "could not compile script")
        }
        var errorInfo: NSDictionary?
        let descriptor = script.executeAndReturnError(&errorInfo)

        if let errorInfo {
            let code = errorInfo[NSAppleScript.errorNumber] as? Int ?? 0
            let message = errorInfo[NSAppleScript.errorMessage] as? String ?? "unknown error"
            switch code {
            case Self.errAEEventNotPermitted: throw TabControlError.notPermitted
            case Self.procNotFound: throw TabControlError.terminalNotRunning
            default: throw TabControlError.scriptFailed(code: code, message: message)
            }
        }
        return descriptor.stringValue ?? ""
    }
}

/// What Terminal.app knows about the tab owning a given TTY.
public struct TerminalWindowInfo: Equatable, Sendable {
    /// Terminal's AppleScript window id, which is also the CGWindowID.
    public let windowID: UInt32
    /// The window's displayed title — the same string Terminal puts in its Window menu.
    public let title: String

    public init(windowID: UInt32, title: String) {
        self.windowID = windowID
        self.title = title
    }
}

/// Terminal.app queries shared by both focus backends.
public struct TerminalQueries: Sendable {
    private let runner: AppleScriptRunner

    public init(runner: AppleScriptRunner = AppleScriptRunner()) {
        self.runner = runner
    }

    /// Every walk over Terminal's tabs opens with this, never with a bare `tabs of aWindow`.
    ///
    /// Terminal's `windows` element is not only terminal windows. Once Shell ▸ New Command…
    /// (⇧⌘N) has been opened, its panel is listed too, and stays listed after it is dismissed
    /// (Terminal 2.15, macOS 26.5). Every property of that element reads `missing value` and
    /// `tabs of` it raises -1728 — so an unguarded walk died on the panel and took the jump
    /// with it, even though the wanted tab sat in the very next window. The guard hands such a
    /// window an empty tab list and the walk moves on.
    ///
    /// Filtering `windows` up front is the tempting alternative and the wrong one: `whose
    /// visible is true` also drops miniaturised windows, whose tabs must stay reachable.
    static let guardedTabWalk = """
                repeat with aWindow in windows
                    set windowTabs to {}
                    try
                        set windowTabs to tabs of aWindow
                    end try
                    repeat with aTab in windowTabs
        """

    /// Returns nil only when no tab owns `tty`; throws if the reply can't be parsed, so a
    /// scripting quirk is never mistaken for "the tab was closed" (which would prune records).
    public func windowInfo(forTTY tty: String) throws -> TerminalWindowInfo? {
        try validateTTY(tty)
        let raw = try runner.run(Self.windowInfoScript(tty: tty))
        return try Self.parseWindowInfo(raw)
    }

    static func windowInfoScript(tty: String) -> String {
        // `linefeed`, not `tab`: inside a `tell application "Terminal"` block Terminal's `tab`
        // class shadows the tab-character constant, and the concatenation yields the literal
        // text "tab" ("85tabwebapp — …"). Window titles cannot contain a newline.
        """
        tell application "Terminal"
        \(guardedTabWalk)
                    if tty of aTab is "\(tty)" then
                        return ((id of aWindow) as text) & linefeed & (name of aWindow)
                    end if
                end repeat
            end repeat
            return ""
        end tell
        """
    }

    /// Split out as a pure function so the failure that motivated it stays covered: the reply
    /// used to be joined with `tab`, which Terminal's `tab` class turned into the literal text
    /// "tab" ("85tabwebapp — …"). That parsed as "not found", and "not found" pruned
    /// session records — a scripting quirk silently destroying good state.
    static func parseWindowInfo(_ raw: String) throws -> TerminalWindowInfo? {
        if raw.isEmpty { return nil }

        let parts = raw.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            .map(String.init)
        guard parts.count == 2, let identifier = UInt32(parts[0]), !parts[1].isEmpty else {
            throw TabControlError.scriptFailed(code: 0,
                                              message: "unparseable window info: \(raw)")
        }
        return TerminalWindowInfo(windowID: identifier, title: parts[1])
    }

    /// Selects the tab inside its own window without touching window ordering. Safe to call
    /// before raising, so the correct tab is already showing when the window appears.
    public func selectTab(tty: String) throws {
        try validateTTY(tty)
        _ = try runner.run(Self.selectTabScript(tty: tty))
    }

    static func selectTabScript(tty: String) -> String {
        """
        tell application "Terminal"
        \(guardedTabWalk)
                    if tty of aTab is "\(tty)" then
                        set selected of aTab to true
                        return "ok"
                    end if
                end repeat
            end repeat
            return "notFound"
        end tell
        """
    }

    public func frontmostTTY() throws -> String? {
        // `frontmost` is a property of the application itself, so this needs no System
        // Events access and therefore no Accessibility permission.
        let result = try runner.run("""
        tell application "Terminal"
            if not frontmost then return ""
            if (count of windows) is 0 then return ""
            try
                return tty of selected tab of window 1
            on error
                return ""
            end try
        end tell
        """)
        return result.isEmpty ? nil : result
    }

    public func knownTTYs() throws -> [String] {
        let result = try runner.run(Self.knownTTYsScript)
        return result.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    static let knownTTYsScript = """
        tell application "Terminal"
            set found to {}
        \(guardedTabWalk)
                    set end of found to tty of aTab
                end repeat
            end repeat
            set AppleScript's text item delimiters to linefeed
            return found as text
        end tell
        """

    public func setTitle(_ title: String?, tty: String) throws {
        try validateTTY(tty)
        _ = try runner.run(Self.setTitleScript(title, tty: tty))
    }

    static func setTitleScript(_ title: String?, tty: String) -> String {
        // `custom title` is inert unless `title displays custom title` is also on.
        let body: String
        if let title {
            body = """
                            set custom title of aTab to \(appleScriptLiteral(title))
                            set title displays custom title of aTab to true
            """
        } else {
            body = """
                            set title displays custom title of aTab to false
                            set custom title of aTab to ""
            """
        }
        return """
        tell application "Terminal"
        \(guardedTabWalk)
                    if tty of aTab is "\(tty)" then
        \(body)
                        return "ok"
                    end if
                end repeat
            end repeat
            return "notFound"
        end tell
        """
    }
}
#endif

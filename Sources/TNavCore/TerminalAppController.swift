import Foundation

#if canImport(AppKit)
import AppKit

/// Pure-AppleScript Terminal.app driver.
///
/// Focus works only when the target window is on the Space the user is currently viewing:
/// `set index` and `set frontmost` return no error but have no effect across Spaces. This is
/// therefore the fallback backend, used when Accessibility permission is unavailable — see
/// `AXWindowMenuController` for the cross-Space route and docs/phase1-spaces-finding.md.
///
/// Scripting surface verified against Terminal.app's sdef: `tab.tty` (read), `tab.selected`,
/// `tab.custom title`, `tab.title displays custom title`, `window.frontmost`, `window.index`,
/// `window.miniaturized` (settable), and `selected tab` as a window contents element.
public final class TerminalAppController: TabController {
    private let runner: AppleScriptRunner
    private let queries: TerminalQueries

    public let applicationBundleIdentifier = "com.apple.Terminal"

    public init(runner: AppleScriptRunner = AppleScriptRunner()) {
        self.runner = runner
        self.queries = TerminalQueries(runner: runner)
    }

    public func focus(tty: String) throws -> FocusOutcome {
        try validateTTY(tty)
        // Resolve to a `window id` before mutating anything. `repeat with aWindow in windows`
        // hands back index-based references ("window 3 of ..."), and `set index to 1`
        // reorders the window list — so a held reference silently starts pointing at a
        // different window and the focus lands on the wrong one. `window id` is stable.
        let source = """
        tell application "Terminal"
            set targetWindowId to missing value
            set targetTabIndex to 0
            repeat with aWindow in windows
                if targetWindowId is not missing value then exit repeat
                set tabIndex to 0
                repeat with aTab in tabs of aWindow
                    set tabIndex to tabIndex + 1
                    if tty of aTab is "\(tty)" then
                        set targetWindowId to id of aWindow
                        set targetTabIndex to tabIndex
                        exit repeat
                    end if
                end repeat
            end repeat
            if targetWindowId is missing value then return "notFound"
            set theWindow to window id targetWindowId
            try
                if miniaturized of theWindow then set miniaturized of theWindow to false
            end try
            try
                set selected of tab targetTabIndex of theWindow to true
            end try
            try
                set index of theWindow to 1
            end try
            try
                set frontmost of theWindow to true
            end try
            activate
            return "focused"
        end tell
        """
        let result = try runner.run(source)
        return FocusOutcome(rawValue: result) ?? .notFound
    }

    public func frontmostTTY() throws -> String? { try queries.frontmostTTY() }
    public func knownTTYs() throws -> [String] { try queries.knownTTYs() }
    public func setTitle(_ title: String?, tty: String) throws { try queries.setTitle(title, tty: tty) }
}
#endif

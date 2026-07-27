import Foundation

#if canImport(AppKit)
import AppKit
import ApplicationServices
import CoreGraphics

/// Tab focus that can reach a window on any desktop, driven through Terminal's own Window menu.
///
/// Why this route rather than the obvious ones:
///  - `set index` / `set frontmost` via AppleScript silently no-op for a window on another
///    Space (no error, no effect).
///  - `AXUIElementCopyAttributeValue(kAXWindows)` only enumerates windows on the *current*
///    Space, so `AXRaise` cannot even find an off-Space window.
///  - Terminal's Window menu lists every window across every Space, and `AXPress` on an item
///    reaches the target wherever it is.
///
/// KNOWN BEHAVIOUR: for a window on another desktop, macOS satisfies the press by bringing the
/// window to the desktop you are on, rather than taking you to it. That is macOS's own response
/// to that menu item — pressing it by hand does the same — and the window is left somewhere the
/// user can see and move. It is a nuisance, not a fault; the measurements are in the correction
/// at the top of docs/phase1-spaces-finding.md.
///
/// What is deliberately *not* here is the private window-server call that switches desktops
/// properly. It works only with SIP disabled, and with SIP on it silently desynchronises the
/// system's record of the current desktop — breaking Mission Control and Stage Manager
/// machine-wide. A nuisance is recoverable; that is not. See the same document.
///
/// Requires Accessibility permission. `TerminalAppController` is the same-Space fallback when
/// it isn't granted.
public final class AXWindowMenuController: TabController {
    private let queries: TerminalQueries
    public let applicationBundleIdentifier = "com.apple.Terminal"

    public init(queries: TerminalQueries = TerminalQueries()) {
        self.queries = queries
    }

    public static var isPermitted: Bool { AXIsProcessTrusted() }

    public func focus(tty: String) throws -> FocusOutcome {
        guard Self.isPermitted else { throw TabControlError.accessibilityNotPermitted }
        guard let info = try queries.windowInfo(forTTY: tty) else { return .notFound }
        guard let terminal = runningTerminal() else { throw TabControlError.terminalNotRunning }

        // Select the tab first, so the right one is showing the moment the window appears.
        try? queries.selectTab(tty: tty)

        let items = try windowMenuItems(for: terminal)
        let matching = items.filter { $0.title == info.title }

        // Window titles are not unique — two windows can differ only by size, e.g.
        // "webapp — claude — 160×41" vs "… — 178×46". When ambiguous, stamp a
        // one-off custom title on the target tab so exactly one menu item can match.
        if matching.count == 1 {
            try press(matching[0].element)
            terminal.activate()
            return .focused
        }

        return try focusByTemporaryTitle(tty: tty, terminal: terminal)
    }

    /// Disambiguates by giving the tab a unique title, pressing the now-unique menu item, then
    /// restoring whatever title it had.
    private func focusByTemporaryTitle(tty: String,
                                       terminal: NSRunningApplication) throws -> FocusOutcome {
        let marker = "tnav:\(UUID().uuidString.prefix(8))"
        try queries.setTitle(marker, tty: tty)
        defer { try? queries.setTitle(nil, tty: tty) }

        // The menu is rebuilt from live window titles, so re-read after renaming.
        let items = try windowMenuItems(for: terminal)
        guard let match = items.first(where: { $0.title.contains(marker) }) else {
            return .notFound
        }
        try press(match.element)
        terminal.activate()
        return .focused
    }

    private func press(_ element: AXUIElement) throws {
        let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
        guard result == .success else {
            throw TabControlError.scriptFailed(code: Int(result.rawValue),
                                              message: "AXPress on Window menu item failed")
        }
    }

    private func runningTerminal() -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: applicationBundleIdentifier).first
    }

    private struct MenuItem {
        let title: String
        let element: AXUIElement
    }

    private func windowMenuItems(for terminal: NSRunningApplication) throws -> [MenuItem] {
        let axApp = AXUIElementCreateApplication(terminal.processIdentifier)

        guard let menuBar = Self.attribute(axApp, kAXMenuBarAttribute, as: AXUIElement.self) else {
            throw TabControlError.accessibilityNotPermitted
        }
        guard let menus = Self.attribute(menuBar, kAXChildrenAttribute, as: [AXUIElement].self) else {
            throw TabControlError.scriptFailed(code: 0, message: "could not read Terminal's menu bar")
        }

        // Locate the Window menu by title rather than index, so a menu-bar change doesn't
        // silently point this at the wrong menu. Note the menu also contains commands such as
        // "Bring All to Front"; matching window titles exactly is what keeps those unreachable.
        let windowMenu = menus.first { Self.attribute($0, kAXTitleAttribute, as: String.self) == "Window" }
        guard let windowMenu,
              let container = Self.attribute(windowMenu, kAXChildrenAttribute, as: [AXUIElement].self)?.first,
              let items = Self.attribute(container, kAXChildrenAttribute, as: [AXUIElement].self)
        else {
            throw TabControlError.scriptFailed(code: 0, message: "could not read Terminal's Window menu")
        }

        return items.compactMap { item in
            guard let title = Self.attribute(item, kAXTitleAttribute, as: String.self),
                  !title.isEmpty else { return nil }
            return MenuItem(title: title, element: item)
        }
    }

    private static func attribute<T>(_ element: AXUIElement, _ name: String, as type: T.Type) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return nil
        }
        return value as? T
    }

    // Queries that need no Accessibility permission are delegated straight through.
    public func frontmostTTY() throws -> String? { try queries.frontmostTTY() }
    public func knownTTYs() throws -> [String] { try queries.knownTTYs() }
    public func setTitle(_ title: String?, tty: String) throws { try queries.setTitle(title, tty: tty) }

    public func windowInfo(forTTY tty: String) throws -> TerminalWindowInfo? {
        try queries.windowInfo(forTTY: tty)
    }

    /// True when the window owning `tty` is on the Space the user is currently looking at.
    /// `kCGWindowIsOnscreen` is only set for windows on the active Space.
    public func isOnCurrentSpace(tty: String) throws -> Bool? {
        guard let info = try queries.windowInfo(forTTY: tty) else { return nil }
        return Self.windowsOnCurrentSpace().contains(info.windowID)
    }

    public static func windowsOnCurrentSpace() -> Set<UInt32> {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                   kCGNullWindowID) as? [[String: Any]] else { return [] }
        return Set(list.compactMap { $0[kCGWindowNumber as String] as? UInt32 })
    }

    /// On-screen *application* windows only — a fingerprint of which desktop is showing.
    ///
    /// Layer 0 is ordinary app windows. The menu bar, Dock and Stage Manager live on other
    /// layers and are present on every Space, so including them makes two entirely different
    /// desktops look nearly identical — which is precisely the comparison this exists for.
    public static func applicationWindowsOnCurrentSpace() -> Set<UInt32> {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                   kCGNullWindowID) as? [[String: Any]] else { return [] }
        return Set(list.compactMap { window in
            guard window[kCGWindowLayer as String] as? Int == 0 else { return nil }
            return window[kCGWindowNumber as String] as? UInt32
        })
    }
}

/// Picks the best available backend at call time: the Window-menu route when Accessibility is
/// granted, otherwise plain AppleScript.
///
/// The distinction is surfaced through `activeBackend` and reported by `tnav spaces`, so a
/// silent downgrade to same-desktop-only focus is never mistaken for a bug.
public final class AdaptiveTabController: TabController {
    public enum Backend: String, Sendable {
        /// Reaches a tab on any desktop. For one on another desktop macOS answers by bringing
        /// the window here rather than taking you there — see `AXWindowMenuController`.
        case accessibilityWindowMenu
        /// Same-desktop only.
        case appleScriptOnly
    }

    private let axController: AXWindowMenuController
    private let scriptController: TerminalAppController

    public init(axController: AXWindowMenuController = AXWindowMenuController(),
                scriptController: TerminalAppController = TerminalAppController()) {
        self.axController = axController
        self.scriptController = scriptController
    }

    public var activeBackend: Backend {
        AXWindowMenuController.isPermitted ? .accessibilityWindowMenu : .appleScriptOnly
    }

    public var applicationBundleIdentifier: String { scriptController.applicationBundleIdentifier }

    /// Always reaches the tab. Getting there may bring the window to the user's desktop rather
    /// than the other way round, which is a nuisance they can see and undo — unlike a jump that
    /// refuses, which makes the app useless, or the private desktop-switching call, which breaks
    /// Spaces machine-wide.
    public func focus(tty: String) throws -> FocusOutcome {
        if AXWindowMenuController.isPermitted {
            do {
                return try axController.focus(tty: tty)
            } catch let error as TabControlError {
                // Logged including `accessibilityNotPermitted`, which used to be swallowed in
                // silence — the grant can lapse between the check and the call, and the only
                // symptom is jumps quietly becoming same-desktop-only.
                EventLog.append("AX focus failed (\(error)); falling back to AppleScript")
            }
        }
        return try scriptController.focus(tty: tty)
    }

    public func frontmostTTY() throws -> String? { try scriptController.frontmostTTY() }
    public func knownTTYs() throws -> [String] { try scriptController.knownTTYs() }
    public func setTitle(_ title: String?, tty: String) throws {
        try scriptController.setTitle(title, tty: tty)
    }
}
#endif

import AppKit
import TNavCore

/// Surfaces the things that silently degrade: a missing Accessibility grant drops focus to
/// same-Space-only, and a missing hook registration means nothing gets tracked at all. Both
/// look like "the app is broken" from the outside, so they get stated plainly.
enum Diagnostics {
    static func report(monitor: SessionMonitor) -> String {
        let backend = AdaptiveTabController().activeBackend
        let accessibility = AXWindowMenuController.isPermitted
        let onCurrentSpace = AXWindowMenuController.windowsOnCurrentSpace()

        var lines: [String] = []
        lines.append("Focus backend:   \(backend.rawValue)")
        lines.append("Accessibility:   \(accessibility ? "granted" : "NOT granted")")
        if !accessibility {
            lines.append("                 → tabs on other desktops cannot be reached")
        }
        // Stated plainly because it looks like a bug the first time it happens.
        lines.append("Other desktops:  jumping brings the window to you rather than")
        lines.append("                 switching desktops — a macOS limitation, see docs")
        lines.append("Hooks in settings: \(hooksRegistered ? "registered" : "NOT registered")")
        lines.append("Tracked sessions:  \(monitor.records.count)")
        lines.append("Notifications:     \(monitor.config.paused ? "paused" : "active")")
        lines.append("Muted tabs:        \(monitor.config.mutedTabs.count)")

        let controller = AXWindowMenuController()
        if let ttys = try? controller.knownTTYs() {
            let here = ttys.filter { tty in
                guard let info = try? controller.windowInfo(forTTY: tty) else { return false }
                return onCurrentSpace.contains(info.windowID)
            }
            lines.append("Terminal tabs:     \(ttys.count) (\(here.count) on this Space)")
        }
        return lines.joined(separator: "\n")
    }

    /// A hook that isn't registered fails silently and invisibly, so it's worth checking.
    static var hooksRegistered: Bool {
        let settings = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
        guard let data = try? Data(contentsOf: settings),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = object["hooks"] as? [String: Any]
        else { return false }
        return hooks["Stop"] != nil && hooks["Notification"] != nil
    }

    static func present(monitor: SessionMonitor) {
        let alert = NSAlert()
        alert.messageText = "ClaudeBar diagnostics"
        alert.informativeText = report(monitor: monitor)
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        if !AXWindowMenuController.isPermitted {
            alert.addButton(withTitle: "Open Accessibility Settings")
        }
        alert.addButton(withTitle: "Copy")

        // NSAlert returns alertFirstButtonReturn + n for the nth button, so the index is
        // plain arithmetic; matching on button.tag does not work here.
        let response = alert.runModal()
        let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        guard alert.buttons.indices.contains(index) else { return }

        switch alert.buttons[index].title {
        case "Open Accessibility Settings":
            openAccessibilitySettings()
        case "Copy":
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(report(monitor: monitor), forType: .string)
        default:
            break
        }
    }

    static func openAccessibilitySettings() {
        let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}

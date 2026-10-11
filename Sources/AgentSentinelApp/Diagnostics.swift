import AppKit
import TNavCore

/// Surfaces the things that silently degrade: a missing Accessibility grant drops focus to
/// same-Space-only, and a missing hook registration means nothing gets tracked at all for that
/// agent. Both look like "the app is broken" from the outside, so they get stated plainly.
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
        lines.append("")
        lines.append("Agents:")
        let counts = Dictionary(grouping: monitor.records, by: \.agent).mapValues(\.count)
        for status in HookRegistration.statuses() {
            let name = status.kind.displayName.padding(toLength: 13, withPad: " ", startingAt: 0)
            if !status.installed {
                lines.append("  \(name)not installed")
                continue
            }
            let hooks = status.registered ? "hooks registered" : "hooks NOT registered"
            let sessions = counts[status.kind].map { " · \($0) session\($0 == 1 ? "" : "s")" } ?? ""
            lines.append("  \(name)installed · \(hooks)\(sessions)")
        }
        lines.append("")
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

    /// Whether any agent at all has our hooks. What the launch log line checks.
    static var anyHooksRegistered: Bool {
        HookRegistration.statuses().contains(where: \.registered)
    }

    /// Agents that are installed but whose hooks are missing — each gets a button.
    static var unregisteredInstalledAgents: [AgentKind] {
        HookRegistration.statuses().filter { $0.installed && !$0.registered }.map(\.kind)
    }

    static func present(monitor: SessionMonitor) {
        let alert = NSAlert()
        alert.messageText = "AgentSentinel diagnostics"
        alert.informativeText = report(monitor: monitor)
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        if !AXWindowMenuController.isPermitted {
            alert.addButton(withTitle: "Open Accessibility Settings")
        }
        let pending = unregisteredInstalledAgents
        for kind in pending {
            alert.addButton(withTitle: "Register hooks for \(kind.displayName)…")
        }
        alert.addButton(withTitle: "Copy")

        // NSAlert returns alertFirstButtonReturn + n for the nth button, so the index is
        // plain arithmetic; matching on button.tag does not work here.
        let response = alert.runModal()
        let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        guard alert.buttons.indices.contains(index) else { return }

        let title = alert.buttons[index].title
        switch title {
        case "Open Accessibility Settings":
            openAccessibilitySettings()
        case "Copy":
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(report(monitor: monitor), forType: .string)
        default:
            if let kind = pending.first(where: { title == "Register hooks for \($0.displayName)…" }) {
                registerHooks(for: kind, monitor: monitor)
            }
        }
    }

    /// Runs the bundled registrar for one agent. This is the one place the app spawns a
    /// process, and only on an explicit click.
    static func registerHooks(for kind: AgentKind, monitor: SessionMonitor) {
        let bundle = Bundle.main
        guard let script = bundle.url(forResource: "register-hooks", withExtension: "py"),
              let tnav = bundle.executableURL?.deletingLastPathComponent().appendingPathComponent("tnav").path
        else {
            fail("This build has no bundled registrar. Run `make install` from the source tree instead.")
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-B", script.path, "--tnav", tnav, "--agents", kind.rawValue]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            fail("Could not run the registrar: \(error)")
            return
        }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        EventLog.append("diagnostics: register \(kind.rawValue) exit \(process.terminationStatus): \(output)")
        let alert = NSAlert()
        alert.messageText = process.terminationStatus == 0
            ? "Hooks registered for \(kind.displayName)"
            : "Could not register hooks for \(kind.displayName)"
        alert.informativeText = output.trimmingCharacters(in: .whitespacesAndNewlines)
        alert.alertStyle = process.terminationStatus == 0 ? .informational : .warning
        alert.runModal()
    }

    private static func fail(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Could not register hooks"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    static func openAccessibilitySettings() {
        let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}

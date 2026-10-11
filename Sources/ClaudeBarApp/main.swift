import AppKit
import TNavCore

/// Menu bar agent. No Dock icon, no windows — `.accessory` gives that without needing an
/// Info.plist LSUIElement key, so the binary is runnable straight from `swift build` during
/// development and still behaves correctly once bundled.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let monitor = SessionMonitor()
    private var statusItem: StatusItemController?
    private var settingsWindow: SettingsWindow?
    private var alerter: Alerter?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let controller = StatusItemController(monitor: monitor)
        controller.onDiagnostics = { [weak self] in
            guard let self else { return }
            Diagnostics.present(monitor: self.monitor)
        }
        let settings = SettingsWindow(monitor: monitor)
        settingsWindow = settings
        controller.onSettings = { settings.show() }
        statusItem = controller

        // Clicking a banner goes to that tab, exactly as clicking its row does.
        let alerter = Alerter { [weak controller] record in controller?.jump(to: record) }
        self.alerter = alerter

        monitor.onChange = { [weak controller, weak monitor] in
            controller?.render()
            guard let monitor else { return }
            // After the render, so a slow alert can never delay the menu updating.
            alerter.evaluate(records: monitor.records,
                             config: monitor.config,
                             frontmostTTY: monitor.frontmostTTY)
        }
        monitor.start()
        controller.render()

        // Verification path: print the menu that was actually built, then exit.
        // `exit` rather than NSApp.terminate, which tears down before stdout is flushed.
        if CommandLine.arguments.contains("--dump-menu") {
            print(controller.debugDump())
            fflush(stdout)
            monitor.stop()
            exit(0)
        }

        // The status item's glyph is a non-template image (the only way to get colour past
        // NSStatusBarButton), which means it is baked at render time and would otherwise stay
        // the wrong shade after a light/dark switch.
        DistributedNotificationCenter.default.addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak controller] _ in
            controller?.render()
        }

        if !Diagnostics.anyHooksRegistered {
            EventLog.append("app: launched but no agent has hooks registered")
        }

        // Stated at every launch because the downgrade is invisible from the outside: without
        // Accessibility, focusing a tab on another Space cannot switch to it, and what the user
        // sees instead looks like a bug in the jump rather than a missing permission. The grant
        // is keyed to the binary's code signature, so an ad-hoc build loses it on every rebuild.
        EventLog.append("app: focus backend = \(AdaptiveTabController().activeBackend.rawValue)")
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor.stop()
    }
}

// The menu bar item's tooltip is the only explanation of the badge available without opening
// anything, and AppKit's default wait of roughly two seconds is long enough that most people
// never discover it. Registered rather than set, so it lives in this process's in-memory
// defaults instead of being written into the user's plist — and registered here, before
// `NSApplication.shared` touches AppKit at all, so it cannot lose a race with the tooltip
// machinery reading it.
UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 150])

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()

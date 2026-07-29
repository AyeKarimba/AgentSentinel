import AppKit
import TNavCore

/// The settings window: how loudly the app may interrupt, and in which ways.
///
/// Every control writes straight through to `Config` and takes effect immediately — there is no
/// Apply button and nothing to confirm. For settings whose whole purpose is "is this the right
/// amount of interruption", being able to nudge a slider and hear or see the result is the only
/// way to actually judge it, and a modal round trip would break that.
final class SettingsWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let monitor: SessionMonitor
    /// Held so a preview sound is not cut off by its own deallocation.
    private var preview: NSSound?

    init(monitor: SessionMonitor) {
        self.monitor = monitor
    }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let content = buildContent()
        let window = NSWindow(contentRect: content.frame,
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "TerminalNavigator Settings"
        window.contentView = content
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window

        // An accessory app has no Dock icon, so without activating explicitly the window opens
        // behind whatever the user was in and looks like nothing happened.
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        // Back to accessory so the app does not linger in the Cmd-Tab list.
        NSApp.setActivationPolicy(.accessory)
    }

    // MARK: - Building

    private var settings: AlertSettings { monitor.config.alerts }

    private func update(_ body: @escaping (inout AlertSettings) -> Void) {
        monitor.mutate { config in body(&config.alerts) }
    }

    private func buildContent() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)

        stack.addArrangedSubview(heading("Banner"))
        stack.addArrangedSubview(checkbox("Show a banner when a tab needs you",
                                          settings.bannerEnabled) { [weak self] on in
            self?.update { $0.bannerEnabled = on }
        })
        stack.addArrangedSubview(sizePicker())
        stack.addArrangedSubview(slider("Stays for", value: settings.bannerSeconds,
                                        min: 2, max: 20, suffix: "s") { [weak self] value in
            self?.update { $0.bannerSeconds = value }
        })
        stack.addArrangedSubview(checkbox("Show over fullscreen apps",
                                          settings.bannerOverFullscreen) { [weak self] on in
            self?.update { $0.bannerOverFullscreen = on }
        })
        stack.addArrangedSubview(note("Off by default: going fullscreen is often a request not "
                                      + "to be interrupted."))

        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(heading("Sound"))
        stack.addArrangedSubview(checkbox("Play a sound", settings.soundEnabled) { [weak self] on in
            self?.update { $0.soundEnabled = on }
        })
        stack.addArrangedSubview(slider("Volume", value: settings.soundVolume,
                                        min: 0, max: 1, suffix: "") { [weak self] value in
            self?.update { $0.soundVolume = value }
        })
        stack.addArrangedSubview(soundPicker("Waiting", urgent: false))
        stack.addArrangedSubview(soundPicker("Needs permission", urgent: true))

        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(heading("Menu bar pulse"))
        stack.addArrangedSubview(checkbox("Pulse the icon", settings.pulseEnabled) { [weak self] on in
            self?.update { $0.pulseEnabled = on }
        })
        // Presented as brightness because that is what the user sees. Internally it is how far
        // the icon fades at the bottom of a pulse, so the slider is inverted.
        stack.addArrangedSubview(slider("Strength", value: 1 - settings.pulseDepth,
                                        min: 0, max: 0.9, suffix: "") { [weak self] value in
            self?.update { $0.pulseDepth = 1 - value }
        })
        stack.addArrangedSubview(checkbox("Pulse for finished turns too, not just permission "
                                          + "requests", settings.pulseForAllUnread) { [weak self] on in
            self?.update { $0.pulseForAllUnread = on }
        })
        stack.addArrangedSubview(note("Permission requests always pulse deeper and faster."))

        stack.setFrameSize(stack.fittingSize)
        stack.frame = NSRect(x: 0, y: 0, width: max(420, stack.fittingSize.width),
                             height: stack.fittingSize.height)
        return stack
    }

    // MARK: - Controls

    private func heading(_ text: String) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        return label
    }

    private func note(_ text: String) -> NSView {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = 380
        return label
    }

    private func separator() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        line.widthAnchor.constraint(equalToConstant: 380).isActive = true
        return line
    }

    private func checkbox(_ title: String, _ on: Bool,
                          _ action: @escaping (Bool) -> Void) -> NSView {
        let box = ActionButton(checkboxWithTitle: title, target: nil, action: nil)
        box.state = on ? .on : .off
        box.onAction = { [weak box] in action(box?.state == .on) }
        box.target = box
        box.action = #selector(ActionButton.fire)
        return box
    }

    private func slider(_ title: String, value: Double, min: Double, max: Double,
                        suffix: String, _ action: @escaping (Double) -> Void) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12)
        label.widthAnchor.constraint(equalToConstant: 90).isActive = true

        let readout = NSTextField(labelWithString: "")
        readout.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        readout.textColor = .secondaryLabelColor
        readout.widthAnchor.constraint(equalToConstant: 46).isActive = true
        func render(_ v: Double) {
            readout.stringValue = suffix.isEmpty ? "\(Int((v / max) * 100))%"
                                                 : String(format: "%.0f%@", v, suffix)
        }
        render(value)

        let control = ActionSlider(value: value, minValue: min, maxValue: max,
                                   target: nil, action: nil)
        control.isContinuous = true
        control.widthAnchor.constraint(equalToConstant: 200).isActive = true
        control.onAction = { [weak control] in
            guard let control else { return }
            render(control.doubleValue)
            action(control.doubleValue)
        }
        control.target = control
        control.action = #selector(ActionSlider.fire)

        let row = NSStackView(views: [label, control, readout])
        row.orientation = .horizontal
        row.spacing = 8
        return row
    }

    private func sizePicker() -> NSView {
        let label = NSTextField(labelWithString: "Size")
        label.font = .systemFont(ofSize: 12)
        label.widthAnchor.constraint(equalToConstant: 90).isActive = true

        let popup = ActionPopUp(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: AlertSettings.BannerSize.allCases.map(\.label))
        popup.selectItem(withTitle: settings.bannerSize.label)
        popup.onAction = { [weak self, weak popup] in
            guard let index = popup?.indexOfSelectedItem,
                  AlertSettings.BannerSize.allCases.indices.contains(index) else { return }
            let size = AlertSettings.BannerSize.allCases[index]
            self?.update { $0.bannerSize = size }
        }
        popup.target = popup
        popup.action = #selector(ActionPopUp.fire)

        let row = NSStackView(views: [label, popup])
        row.orientation = .horizontal
        row.spacing = 8
        return row
    }

    private func soundPicker(_ title: String, urgent: Bool) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12)
        label.widthAnchor.constraint(equalToConstant: 130).isActive = true

        let popup = ActionPopUp(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: AlertSettings.availableSounds)
        popup.selectItem(withTitle: urgent ? settings.urgentSoundName : settings.soundName)
        popup.onAction = { [weak self, weak popup] in
            guard let self, let name = popup?.titleOfSelectedItem else { return }
            self.update { urgent ? ($0.urgentSoundName = name) : ($0.soundName = name) }
            // Play it on selection: picking a sound blind and waiting for a real alert to find
            // out what it sounds like would make the setting useless.
            if let effect = NSSound(named: name) {
                effect.volume = Float(self.settings.soundVolume)
                self.preview = effect
                effect.play()
            }
        }
        popup.target = popup
        popup.action = #selector(ActionPopUp.fire)

        let row = NSStackView(views: [label, popup])
        row.orientation = .horizontal
        row.spacing = 8
        return row
    }
}

// AppKit controls take a target/action pair rather than a closure. These carry the closure so
// each control can be built and wired in one place instead of a screen of @objc methods.
private final class ActionButton: NSButton {
    var onAction: (() -> Void)?
    @objc func fire() { onAction?() }
}

private final class ActionSlider: NSSlider {
    var onAction: (() -> Void)?
    @objc func fire() { onAction?() }
}

private final class ActionPopUp: NSPopUpButton {
    var onAction: (() -> Void)?
    @objc func fire() { onAction?() }
}

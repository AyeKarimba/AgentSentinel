import AppKit
import TNavCore

/// Owns the menu bar item: the terminal glyph, the "2 · 4m" badge, and the dropdown.
///
/// Colour encodes urgency only (red = a permission request is blocking, amber = waiting) and
/// the badge text carries the count and the longest wait, so the two never say the same thing
/// twice.
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let monitor: SessionMonitor
    private let controller: AdaptiveTabController
    /// Replacing `statusItem.menu` while the menu is on screen dismisses it, so a *structural*
    /// change that lands mid-interaction waits for `menuDidClose`. Changes to the numbers go
    /// in through `refreshRows`, which is safe at any time — see `render`.
    private var isMenuOpen = false
    /// Drives row highlighting while the menu is open — see `startHoverTracking`.
    private var hoverTimer: Timer?
    /// Drives the menu bar pulse — see `updatePulse`.
    private var pulseTimer: Timer?
    private var pulsePhase: Double = 0
    private var pulseIsUrgent = false
    /// What the menu on screen was built from, so a reload that changed only numbers can skip
    /// the rebuild entirely.
    private var renderedShape: MenuShape?

    var onDiagnostics: (() -> Void)?
    var onSettings: (() -> Void)?

    init(monitor: SessionMonitor,
         controller: AdaptiveTabController = AdaptiveTabController()) {
        self.monitor = monitor
        self.controller = controller
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        statusItem.button?.imagePosition = .imageLeading
    }

    /// Two tiers, because the app now reloads about once a second and the two kinds of change
    /// have very different costs.
    ///
    /// Numbers and colours — elapsed time, the seen/unseen tint, mute and snooze state — are
    /// pushed into the rows that already exist. That works whether or not the menu is open,
    /// and it is what stops an open menu from sitting there frozen, which it did when a
    /// mid-interaction refresh could only touch the button.
    ///
    /// Rebuilding is reserved for a change in *shape*: a session appearing, disappearing or
    /// changing state. That is the case that cannot be done in place, and the only one worth
    /// throwing away seven views per row for.
    func render() {
        let summary = monitor.summary()
        renderButton(summary)

        if let menu = statusItem.menu {
            refreshRows(in: menu)
        }

        let shape = MenuShape(records: monitor.records, config: monitor.config, summary: summary)
        guard shape != renderedShape else { return }
        // Deliberately leaves `renderedShape` stale, so the rebuild happens in `menuDidClose`.
        guard !isMenuOpen else { return }

        let menu = buildMenu(summary: summary)
        menu.delegate = self
        statusItem.menu = menu
        renderedShape = shape
    }

    /// Everything that changes the menu's structure: which rows exist, in what order, and
    /// which of the fixed items are checked or dimmed. Numbers and colours are deliberately
    /// absent — those go in through `refreshRows` and must not trigger a rebuild.
    private struct MenuShape: Equatable {
        let rows: [String]
        let silencedWaitingCount: Int
        let paused: Bool
        let blockingOnly: Bool
        let showLastMessage: Bool
        let canJump: Bool

        init(records: [SessionRecord], config: Config, summary: StatusSummary) {
            rows = records.map { "\($0.sessionId)|\($0.state.rawValue)" }
            silencedWaitingCount = summary.silencedWaitingCount
            paused = config.paused
            blockingOnly = config.blockingOnly
            showLastMessage = config.showLastMessage
            canJump = summary.waitingCount > 0
        }
    }

    /// Pushes current values into rows already on screen. Rows whose session has since gone
    /// are left alone; the rebuild that removes them is already pending.
    private func refreshRows(in menu: NSMenu) {
        let now = Date().timeIntervalSince1970
        let byId = Dictionary(monitor.records.map { ($0.sessionId, $0) },
                              uniquingKeysWith: { first, _ in first })
        for item in menu.items {
            guard let row = item.view as? SessionRowView,
                  let record = byId[row.record.sessionId] else { continue }
            row.update(record: record,
                       isMuted: monitor.config.isMuted(record),
                       snoozeRemaining: monitor.config.snoozeRemaining(record, now: now),
                       showLastMessage: monitor.config.showLastMessage,
                       lastVisit: monitor.visits[record.sessionId],
                       now: now)
        }
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        isMenuOpen = true
        // The menu on screen is the one built at the last render, which between ticks can be
        // several seconds old — so without this the elapsed times are visibly stale for the
        // first moment you look at them. `render` rather than `monitor.reload`: it recomputes
        // every label against a fresh clock without touching disk or spending an Apple Event,
        // so nothing can delay the menu actually appearing.
        render()
        startHoverTracking(menu)
    }

    /// Called for standard items only — view-based rows drive their own highlight from
    /// `startHoverTracking`, for the reasons in `SessionRowView`.
    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        Legend.applyHighlight(in: menu, highlighted: item)
    }

    func menuDidClose(_ menu: NSMenu) {
        isMenuOpen = false
        stopHoverTracking(menu)
        // Closing while an item is highlighted never sends a final `willHighlight(nil)`, so an
        // inverted title would survive into the next opening — and the menu is only rebuilt
        // when its shape changes, which a highlight is not.
        Legend.applyHighlight(in: menu, highlighted: nil)
        // Pick up anything that changed while it was open (mutes, elapsed times, new sessions).
        render()
    }

    /// Highlighting a view-based menu item has to be done by hand, and neither obvious route
    /// works: `NSMenu` only calls `menu(_:willHighlight:)` for standard items, and a custom
    /// view's tracking areas never fire because the menu runs its own mouse-tracking loop.
    /// What is left is sampling the pointer against each row's screen frame.
    private func startHoverTracking(_ menu: NSMenu) {
        hoverTimer?.invalidate()
        let timer = Timer(timeInterval: 0.03, repeats: true) { [weak self, weak menu] _ in
            guard let self, let menu else { return }
            self.updateHover(in: menu)
        }
        // Menus spin the run loop in event-tracking mode; `.common` includes it, and a timer
        // added only in `.default` would simply never fire while the menu is up.
        RunLoop.main.add(timer, forMode: .common)
        hoverTimer = timer
    }

    private func stopHoverTracking(_ menu: NSMenu) {
        hoverTimer?.invalidate()
        hoverTimer = nil
        for item in menu.items {
            (item.view as? SessionRowView)?.isHighlighted = false
        }
    }

    private func updateHover(in menu: NSMenu) {
        let pointer = NSEvent.mouseLocation
        for item in menu.items {
            guard let row = item.view as? SessionRowView, let window = row.window else { continue }
            let onScreen = window.convertToScreen(row.convert(row.bounds, to: nil))
            row.isHighlighted = onScreen.contains(pointer)
        }
    }

    // MARK: - Pulse

    /// Breathes the menu bar item while something is unread.
    ///
    /// Driven by a timer rather than a Core Animation loop because the status item's image is a
    /// non-template image rebuilt on every render — an implicit animation on the layer would be
    /// discarded the next time the badge text changed, which is every second while a wait is
    /// counting in seconds.
    ///
    /// Only ever touches `alphaValue`, so it composes with whatever colour the badge is.
    private func updatePulse(_ summary: StatusSummary) {
        let settings = monitor.config.alerts
        let wanted = settings.pulseEnabled && !monitor.config.paused
            && (settings.pulseForAllUnread ? summary.needsAttentionCount > 0
                                           : summary.tint == .urgent)
        guard wanted else {
            stopPulse()
            return
        }
        // A blocking request dips further and cycles faster — the difference between "there is
        // something for you" and "something is stuck waiting on you" should be felt, not read.
        pulseIsUrgent = summary.tint == .urgent
        guard pulseTimer == nil else { return }
        pulsePhase = 0
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            self?.stepPulse()
        }
        RunLoop.main.add(timer, forMode: .common)
        pulseTimer = timer
    }

    private func stepPulse() {
        guard let button = statusItem.button else { return }
        let settings = monitor.config.alerts
        // Deeper dip and a faster cycle when it is urgent.
        let depth = pulseIsUrgent ? max(0.1, settings.pulseDepth * 0.7) : settings.pulseDepth
        let period = pulseIsUrgent ? 0.9 : 1.6
        pulsePhase += (1.0 / 30) / period
        // A raised cosine: smooth at both ends, so it reads as breathing rather than blinking.
        let wave = (cos(pulsePhase * 2 * .pi) + 1) / 2
        button.alphaValue = depth + (1 - depth) * wave
    }

    private func stopPulse() {
        pulseTimer?.invalidate()
        pulseTimer = nil
        statusItem.button?.alphaValue = 1
    }

    // MARK: - Menu bar button

    private func renderButton(_ summary: StatusSummary) {
        guard let button = statusItem.button else { return }
        updatePulse(summary)

        // Red and amber are shared with the rows unchanged. Purple is the one that needs a
        // menu bar variant — see `NSColor.menuBarPurple`. Idle has no row equivalent, since no
        // row means "nothing exists", so it uses the menu bar's own dimmed label colour.
        let tint: NSColor
        switch summary.tint {
        case .idle: tint = .secondaryLabelColor
        case .working: tint = .menuBarPurple
        case .waiting: tint = RowTint.waiting.color
        case .urgent: tint = RowTint.urgent.color
        }

        // The glyph is coloured through a palette symbol configuration rather than
        // `contentTintColor`: that property is applied by the status bar button on top of
        // everything, and it flattens the attributed title's own colour back to the default
        // menu bar text colour. Leaving it nil is what lets the badge show red/amber at all.
        let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [tint]))
        let glyph = NSImage(systemSymbolName: "apple.terminal",
                            accessibilityDescription: summary.accessibilityDescription)
            ?? NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)
        button.image = glyph?.withSymbolConfiguration(configuration)
        // Must be false, or macOS repaints it as a flat template in the menu bar colour.
        button.image?.isTemplate = false
        button.contentTintColor = nil
        button.toolTip = summary.accessibilityDescription

        // The dot is a separate signal from the count: the count says a reply is outstanding,
        // the dot says there is a blocking request you have not even opened. It therefore shows
        // even when everything is silenced, and survives merely opening this menu.
        let marker = summary.showsUnseenDot ? "\u{25CF} " : ""
        if let badge = summary.badgeText {
            button.attributedTitle = NSAttributedString(string: " \(marker)\(badge)", attributes: [
                .foregroundColor: tint,
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            ])
        } else if summary.showsUnseenDot {
            button.attributedTitle = NSAttributedString(string: " \(marker.trimmingCharacters(in: .whitespaces))", attributes: [
                .foregroundColor: NSColor.systemRed,
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            ])
        } else {
            button.attributedTitle = NSAttributedString(string: "")
        }
    }

    // MARK: - Dropdown

    func buildMenu(summary: StatusSummary) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let now = Date().timeIntervalSince1970

        let waiting = monitor.records.filter { $0.state == .waiting }
        let working = monitor.records.filter { $0.state == .working }

        if monitor.records.isEmpty {
            menu.addItem(disabled("No Claude sessions running"))
        } else if waiting.isEmpty {
            menu.addItem(disabled("All caught up"))
        }

        for record in waiting {
            menu.addItem(row(for: record, now: now))
        }
        if !waiting.isEmpty && !working.isEmpty {
            menu.addItem(.separator())
        }
        for record in working {
            menu.addItem(row(for: record, now: now))
        }

        menu.addItem(.separator())

        let jump = NSMenuItem(title: "Jump to oldest waiting",
                              action: #selector(jumpToOldest),
                              keyEquivalent: "j")
        jump.keyEquivalentModifierMask = [.option, .command]
        jump.target = self
        jump.isEnabled = summary.waitingCount > 0
        menu.addItem(jump)

        let blocking = NSMenuItem(title: "Only alert for permission requests",
                                  action: #selector(toggleBlockingOnly),
                                  keyEquivalent: "")
        blocking.target = self
        blocking.state = monitor.config.blockingOnly ? .on : .off
        blocking.toolTip = "Turn-completions stay in this menu and in the badge, they just stop notifying"
        menu.addItem(blocking)

        let pause = NSMenuItem(title: "Pause all notifications",
                               action: #selector(togglePause),
                               keyEquivalent: "")
        pause.target = self
        pause.state = monitor.config.paused ? .on : .off
        menu.addItem(pause)

        if summary.silencedWaitingCount > 0 {
            let plural = summary.silencedWaitingCount == 1 ? "tab is" : "tabs are"
            menu.addItem(disabled("\(summary.silencedWaitingCount) silenced \(plural) also waiting"))
        }

        menu.addItem(.separator())

        menu.addItem(Legend.menuItem())

        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings),
                                  keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let messages = NSMenuItem(title: "Show Claude's last message",
                                  action: #selector(toggleLastMessage),
                                  keyEquivalent: "")
        messages.target = self
        messages.state = monitor.config.showLastMessage ? .on : .off
        menu.addItem(messages)

        let diagnostics = NSMenuItem(title: "Diagnostics…",
                                     action: #selector(showDiagnostics),
                                     keyEquivalent: "")
        diagnostics.target = self
        menu.addItem(diagnostics)

        let quit = NSMenuItem(title: "Quit TerminalNavigator",
                              action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "q")
        menu.addItem(quit)

        return menu
    }

    func row(for record: SessionRecord, now: Double) -> NSMenuItem {
        let item = NSMenuItem()
        item.view = SessionRowView(
            record: record,
            isMuted: monitor.config.isMuted(record),
            snoozeRemaining: monitor.config.snoozeRemaining(record, now: now),
            showLastMessage: monitor.config.showLastMessage,
            lastVisit: monitor.visits[record.sessionId],
            now: now,
            onJump: { [weak self] record in self?.jump(to: record) },
            onToggleMute: { [weak self] record in self?.toggleMute(record) },
            onToggleSnooze: { [weak self] record in self?.toggleSnooze(record) },
            onForget: { [weak self] record in self?.monitor.forget(record) }
        )
        return item
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    /// Text rendering of the menu actually built by `buildMenu`, so its structure can be
    /// verified without driving the UI — an NSStatusItem menu cannot be opened from another
    /// process via Accessibility.
    func debugDump() -> String {
        let summary = monitor.summary()
        var lines: [String] = []
        let dot = summary.showsUnseenDot ? " \u{25CF}" : ""
        lines.append("menu bar: [ >_\(dot)\(summary.badgeText.map { " " + $0 } ?? "") ]   tint=\(summary.tint.rawValue)  needs=\(summary.needsAttentionCount) opened=\(summary.attendedWaitingCount) silenced-unseen=\(summary.silencedUnseenUrgentCount)")
        lines.append("tooltip:  \(summary.accessibilityDescription)")
        lines.append("")
        lines.append(contentsOf: dump(buildMenu(summary: summary), indent: "  "))
        return lines.joined(separator: "\n")
    }

    /// Recurses into submenus so the colour guide — which is only ever a submenu — can be
    /// checked here rather than by opening the menu and looking at it.
    private func dump(_ menu: NSMenu, indent: String) -> [String] {
        var lines: [String] = []
        for item in menu.items {
            if item.isSeparatorItem {
                lines.append(indent + String(repeating: "\u{2500}", count: 42))
                continue
            }
            if let row = item.view as? SessionRowView {
                lines.append(indent + row.debugLine())
                continue
            }
            // The attributed title carries the colours, which is the whole point of the guide;
            // `title` alone would render every sample identically.
            var line = indent + (item.attributedTitle.map(describe) ?? item.title)
            if !item.keyEquivalent.isEmpty {
                let mods = item.keyEquivalentModifierMask
                var glyphs = ""
                if mods.contains(.control) { glyphs += "\u{2303}" }
                if mods.contains(.option) { glyphs += "\u{2325}" }
                if mods.contains(.shift) { glyphs += "\u{21E7}" }
                if mods.contains(.command) { glyphs += "\u{2318}" }
                line += "   \(glyphs)\(item.keyEquivalent.uppercased())"
            }
            if item.state == .on { line += "   \u{2713}" }
            if !item.isEnabled { line += "   (dimmed)" }
            lines.append(line)
            if let submenu = item.submenu {
                lines.append(contentsOf: dump(submenu, indent: indent + "    "))
            }
        }
        return lines
    }

    /// Renders an attributed title as text plus the name of each colour it uses, so a dump can
    /// show that the guide's swatches are the colours they claim to be.
    private func describe(_ text: NSAttributedString) -> String {
        var names: [String] = []
        text.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: text.length)) {
            value, range, _ in
            guard let color = value as? NSColor, !names.contains(color.colorNameForDump) else { return }
            let fragment = text.attributedSubstring(from: range).string
                .trimmingCharacters(in: .whitespaces)
            guard !fragment.isEmpty else { return }
            names.append(color.colorNameForDump)
        }
        return names.isEmpty ? text.string : "\(text.string)   {\(names.joined(separator: ", "))}"
    }

    // MARK: - Actions

    /// Also the banner's click target — a banner and its row lead to the same place.
    func jump(to record: SessionRecord) {
        do {
            if try controller.focus(tty: record.tty) == .notFound {
                EventLog.append("menu: no tab owns \(record.tty)")
                return
            }
            // Arriving via the menu counts as having looked at it, so clear the unseen dot
            // now rather than waiting for the next frontmost poll.
            monitor.noteVisit(sessionId: record.sessionId)
        } catch {
            presentError(error)
        }
    }

    /// Goes to the oldest tab still asking for you — the one the badge is describing, since
    /// the badge's number has to name where this action lands. Once you have worked through
    /// the queue it falls back to the oldest unanswered tab, so the shortcut still reaches
    /// something rather than going dead while sessions are visibly waiting.
    @objc private func jumpToOldest() {
        let now = Date().timeIntervalSince1970
        let audible = monitor.records.filter {
            $0.state == .waiting && !monitor.config.isSilenced($0, now: now)
        }
        let unread = audible.filter { $0.isUnseen(lastVisit: monitor.visits[$0.sessionId]) }
        guard let oldest = (unread.isEmpty ? audible : unread).min(by: { $0.since < $1.since })
        else { return }
        jump(to: oldest)
    }

    @objc private func togglePause() {
        monitor.mutate { $0.paused.toggle() }
    }

    @objc private func toggleBlockingOnly() {
        monitor.mutate { $0.blockingOnly.toggle() }
    }

    @objc private func toggleLastMessage() {
        monitor.mutate { $0.showLastMessage.toggle() }
    }

    private func toggleMute(_ record: SessionRecord) {
        let key = record.tabMuteKey
        var nowMuted = false
        monitor.mutate { config in
            if let index = config.mutedTabs.firstIndex(of: key) {
                config.mutedTabs.remove(at: index)
                nowMuted = false
            } else {
                config.mutedTabs.append(key)
                nowMuted = true
            }
        }
        _ = nowMuted
    }

    /// Snooze is deliberately separate from mute: mute waits for you to undo it, a snooze comes
    /// back on its own. ⌥-click gives the longer one.
    private func toggleSnooze(_ record: SessionRecord) {
        let now = Date().timeIntervalSince1970
        if monitor.config.snoozeRemaining(record, now: now) != nil {
            monitor.cancelSnooze(record)
        } else {
            let long = NSEvent.modifierFlags.contains(.option)
            monitor.snooze(record, seconds: long ? 30 * 60 : 10 * 60)
        }
    }

    @objc private func showDiagnostics() {
        onDiagnostics?()
    }

    @objc private func showSettings() {
        onSettings?()
    }

    private func presentError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Could not switch to that tab"
        alert.informativeText = "\(error)"
        alert.alertStyle = .warning
        if case TabControlError.accessibilityNotPermitted = error {
            alert.addButton(withTitle: "Open Settings")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn {
                Diagnostics.openAccessibilitySettings()
            }
            return
        }
        alert.runModal()
    }
}

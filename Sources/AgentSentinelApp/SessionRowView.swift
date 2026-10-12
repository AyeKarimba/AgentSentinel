import AppKit
import TNavCore

/// A two-line session row: project + elapsed on top, detail plus the snooze and mute controls
/// below.
///
/// `NSMenu` runs its own mouse-tracking loop, which has two consequences that shape this view:
///
///  - Tracking areas never fire, so `mouseEntered`/`mouseExited` cannot drive the highlight —
///    and `menu(_:willHighlight:)` is no help either, since NSMenu only calls it for standard
///    items, not view-based ones. `isHighlighted` is pushed in from `StatusItemController`,
///    which samples the pointer while the menu is open.
///  - An `NSButton` subview never receives clicks. The controls are therefore plain image
///    views, hit-tested by hand in `mouseUp`. (`mouseUp` itself does reach the view, which is
///    why clicking the row body works.)
final class SessionRowView: NSView {
    private(set) var record: SessionRecord
    private(set) var isMuted: Bool
    private(set) var snoozeRemaining: Double?
    private var showLastMessage: Bool
    /// When the user was last in this tab, which is what separates "still waiting" from
    /// "waiting and you haven't looked". Drives `tint`, and through it the timestamp colour.
    private var lastVisit: Double?
    private var now: Double

    private var tint: RowTint { record.tint(lastVisit: lastVisit) }
    private var isUnseenUrgent: Bool { record.isUnseenUrgent(lastVisit: lastVisit) }

    private let onJump: (SessionRecord) -> Void
    private let onToggleMute: (SessionRecord) -> Void
    private let onToggleSnooze: (SessionRecord) -> Void
    private let onForget: (SessionRecord) -> Void

    private let statusDot = NSTextField(labelWithString: "")
    private let unseenDot = NSTextField(labelWithString: "")
    private let projectLabel = NSTextField(labelWithString: "")
    private let elapsedLabel = NSTextField(labelWithString: "")
    private let agentLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let snoozeIcon = NSImageView()
    private let muteIcon = NSImageView()

    static let rowHeight: CGFloat = 44
    static let rowWidth: CGFloat = 360
    /// Generous click targets — the glyphs themselves are only 15pt.
    private static let hitSize: CGFloat = 28

    var isHighlighted = false {
        didSet {
            guard isHighlighted != oldValue else { return }
            applyHighlight()
            needsDisplay = true
        }
    }

    init(record: SessionRecord,
         isMuted: Bool,
         snoozeRemaining: Double?,
         showLastMessage: Bool,
         lastVisit: Double?,
         now: Double,
         onJump: @escaping (SessionRecord) -> Void,
         onToggleMute: @escaping (SessionRecord) -> Void,
         onToggleSnooze: @escaping (SessionRecord) -> Void,
         onForget: @escaping (SessionRecord) -> Void) {
        self.record = record
        self.isMuted = isMuted
        self.snoozeRemaining = snoozeRemaining
        self.showLastMessage = showLastMessage
        self.lastVisit = lastVisit
        self.now = now
        self.onJump = onJump
        self.onToggleMute = onToggleMute
        self.onToggleSnooze = onToggleSnooze
        self.onForget = onForget
        super.init(frame: NSRect(x: 0, y: 0, width: Self.rowWidth, height: Self.rowHeight))
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    private func build() {
        statusDot.font = .systemFont(ofSize: 10)

        unseenDot.font = .systemFont(ofSize: 9)
        unseenDot.textColor = .systemRed
        unseenDot.toolTip = "You haven't opened this tab since it asked for permission"

        projectLabel.lineBreakMode = .byTruncatingTail

        elapsedLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        elapsedLabel.alignment = .right

        // The agent's name, smaller and in the secondary colour: present enough to tell Codex
        // from Claude at a glance, quiet enough that the project name stays the thing you read.
        agentLabel.font = .systemFont(ofSize: 11, weight: .medium)
        agentLabel.textColor = .secondaryLabelColor
        // The agent name keeps its width; a long project name truncates instead of squeezing
        // it off.
        agentLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        agentLabel.setContentHuggingPriority(.required, for: .horizontal)
        projectLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.lineBreakMode = .byTruncatingTail

        snoozeIcon.imageScaling = .scaleProportionallyDown
        muteIcon.imageScaling = .scaleProportionallyDown

        let views: [NSView] = [statusDot, unseenDot, projectLabel, elapsedLabel,
                               agentLabel, detailLabel, snoozeIcon, muteIcon]
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }

        NSLayoutConstraint.activate([
            statusDot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            statusDot.centerYAnchor.constraint(equalTo: projectLabel.centerYAnchor),

            projectLabel.leadingAnchor.constraint(equalTo: statusDot.trailingAnchor, constant: 8),
            projectLabel.topAnchor.constraint(equalTo: topAnchor, constant: 6),

            agentLabel.leadingAnchor.constraint(equalTo: projectLabel.trailingAnchor, constant: 6),
            agentLabel.centerYAnchor.constraint(equalTo: projectLabel.centerYAnchor),

            unseenDot.leadingAnchor.constraint(equalTo: agentLabel.trailingAnchor, constant: 5),
            unseenDot.centerYAnchor.constraint(equalTo: projectLabel.centerYAnchor),
            unseenDot.trailingAnchor.constraint(lessThanOrEqualTo: elapsedLabel.leadingAnchor,
                                                constant: -8),

            elapsedLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            elapsedLabel.centerYAnchor.constraint(equalTo: projectLabel.centerYAnchor),
            elapsedLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 36),

            detailLabel.leadingAnchor.constraint(equalTo: projectLabel.leadingAnchor),
            detailLabel.topAnchor.constraint(equalTo: projectLabel.bottomAnchor, constant: 2),
            detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: snoozeIcon.leadingAnchor,
                                                  constant: -8),

            snoozeIcon.trailingAnchor.constraint(equalTo: muteIcon.leadingAnchor, constant: -12),
            snoozeIcon.centerYAnchor.constraint(equalTo: detailLabel.centerYAnchor),
            snoozeIcon.widthAnchor.constraint(equalToConstant: 15),
            snoozeIcon.heightAnchor.constraint(equalToConstant: 15),

            muteIcon.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            muteIcon.centerYAnchor.constraint(equalTo: detailLabel.centerYAnchor),
            muteIcon.widthAnchor.constraint(equalToConstant: 15),
            muteIcon.heightAnchor.constraint(equalToConstant: 15),
        ])

        applyContent()
    }

    /// The agent's closing message — you can often answer that without switching tabs at
    /// all — led by the model when the agent reports one. The agent itself is already named
    /// on the line above. Falls back to the generic reason when there's no message or the
    /// option is off.
    private func detailText() -> String {
        if let remaining = snoozeRemaining {
            return "snoozed \(Elapsed.short(remaining)) · \(deviceName)"
        }
        if showLastMessage,
           let message = record.lastAssistantMessage?
               .trimmingCharacters(in: .whitespacesAndNewlines)
               .replacingOccurrences(of: "\n", with: " "),
           !message.isEmpty {
            if let model = record.model, !model.isEmpty {
                return "\(model) — \(message)"
            }
            return message
        }
        return "\(record.reason?.label ?? "working") · \(deviceName)"
    }

    private var deviceName: String {
        record.tty.replacingOccurrences(of: "/dev/", with: "")
    }

    // MARK: - Updating

    /// Re-states everything except the layout, so a row already on screen can be brought
    /// current without rebuilding the menu — which would dismiss it out from under the user,
    /// and which at one reload a second would mean discarding seven views per row per tick.
    func update(record: SessionRecord,
                isMuted: Bool,
                snoozeRemaining: Double?,
                showLastMessage: Bool,
                lastVisit: Double?,
                now: Double) {
        self.record = record
        self.isMuted = isMuted
        self.snoozeRemaining = snoozeRemaining
        self.showLastMessage = showLastMessage
        self.lastVisit = lastVisit
        self.now = now
        applyContent()
        needsDisplay = true
    }

    // MARK: - Appearance

    /// The one colour in the row that answers "have you dealt with this", rather than "what
    /// is this session doing".
    ///
    /// The dot, the project name and the timestamp all carry it, so a row you have opened goes
    /// quiet wholesale even while it is still waiting for a reply — which is what stops a menu
    /// full of waiting sessions from reading as a wall of red. Colour alone separates an opened
    /// wait (grey) from a session still working (purple), so every dot is filled.
    /// Defined once in `Legend.swift`, alongside the guide that explains it.
    private var tintColor: NSColor { tint.color }

    /// The tint as applied to words rather than to the dot.
    ///
    /// A 10pt glyph carries `tertiaryLabelColor` fine; a name and a number you have to read do
    /// not — at that weight it reads as damage rather than as de-emphasis. Settled lettering
    /// therefore steps up to the secondary grey, which is still unmistakably grey.
    private var tintTextColor: NSColor {
        tint == .settled ? .secondaryLabelColor : tintColor
    }

    private var isSilenced: Bool { isMuted || snoozeRemaining != nil }

    private func applyContent() {
        let waiting = record.state == .waiting

        // Glyph and meaning both come from the tint, so the row and the legend agree.
        statusDot.stringValue = tint.glyph
        statusDot.toolTip = tint.meaning
        projectLabel.stringValue = record.project
        projectLabel.font = .systemFont(ofSize: 13, weight: waiting ? .semibold : .regular)
        agentLabel.stringValue = record.agent.shortName
        agentLabel.toolTip = record.model.map { "\(record.agent.displayName) · \($0)" } ?? record.agent.displayName
        elapsedLabel.stringValue = Elapsed.short(record.elapsed(now: now))
        elapsedLabel.toolTip = tint.meaning

        // Separate from the status dot: that one says "waiting", this one says "you have not
        // even opened it". A request can be both, or waiting-but-seen.
        unseenDot.stringValue = isUnseenUrgent ? "◉" : ""

        let snoozed = snoozeRemaining != nil
        snoozeIcon.image = NSImage(systemSymbolName: snoozed ? "clock.badge.checkmark" : "clock",
                                   accessibilityDescription: snoozed ? "Snoozed" : "Snooze")
        snoozeIcon.toolTip = snoozed
            ? "Snoozed — click to bring it back now"
            : "Snooze this tab for 10 minutes (⌥-click for 30)"

        muteIcon.image = NSImage(systemSymbolName: isMuted ? "bell.slash.fill" : "bell.fill",
                                 accessibilityDescription: isMuted ? "Muted" : "Notifications on")
        muteIcon.toolTip = isMuted
            ? "Notifications are off for this tab — click to turn them back on"
            : "Silence this tab until you turn it back on"

        detailLabel.stringValue = detailText()
        detailLabel.toolTip = record.lastAssistantMessage
        applyHighlight()
    }

    /// Selection in a menu paints white-on-blue, so every label has to flip together;
    /// otherwise secondary text disappears into the highlight fill.
    private func applyHighlight() {
        let dimmed: CGFloat = isSilenced ? 0.5 : 1
        if isHighlighted {
            projectLabel.textColor = .selectedMenuItemTextColor
            detailLabel.textColor = .selectedMenuItemTextColor
            elapsedLabel.textColor = .selectedMenuItemTextColor
            agentLabel.textColor = .selectedMenuItemTextColor
            statusDot.textColor = .selectedMenuItemTextColor
            unseenDot.textColor = .selectedMenuItemTextColor
            snoozeIcon.contentTintColor = .selectedMenuItemTextColor
            muteIcon.contentTintColor = .selectedMenuItemTextColor
            detailLabel.alphaValue = 0.85 * dimmed
            elapsedLabel.alphaValue = 0.85
        } else {
            // Name and time both carry the tint; the detail line deliberately does not. It is
            // often a full sentence of the agent's, and colouring it too would turn the row into
            // a block of red rather than a signal you can pick out at a glance.
            projectLabel.textColor = tintTextColor
            elapsedLabel.textColor = tintTextColor
            detailLabel.textColor = .secondaryLabelColor
            agentLabel.textColor = .secondaryLabelColor
            statusDot.textColor = tintColor
            unseenDot.textColor = .systemRed
            snoozeIcon.contentTintColor = snoozeRemaining != nil ? .systemOrange : .secondaryLabelColor
            muteIcon.contentTintColor = isMuted ? .tertiaryLabelColor : .secondaryLabelColor
            detailLabel.alphaValue = dimmed
            elapsedLabel.alphaValue = 1
        }
        projectLabel.alphaValue = dimmed
        agentLabel.alphaValue = dimmed
        statusDot.alphaValue = isSilenced ? 0.5 : 1
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard isHighlighted else { return }
        NSColor.selectedContentBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 2), xRadius: 5, yRadius: 5).fill()
    }

    // MARK: - Hit testing

    private func hitRect(around view: NSView) -> NSRect {
        NSRect(x: view.frame.midX - Self.hitSize / 2,
               y: view.frame.midY - Self.hitSize / 2,
               width: Self.hitSize,
               height: Self.hitSize)
    }

    override func mouseUp(with event: NSEvent) {
        // ⌘ wins over everything on the row: over the snooze and mute icons, and over ⌥.
        // Like the controls, it does not dismiss the menu — the row visibly vanishes instead,
        // spliced out of the open menu by `StatusItemController.forget(_:)` rather than left
        // for the next rebuild, which while the menu is open could be arbitrarily far off.
        if event.modifierFlags.contains(.command) {
            onForget(record)
            return
        }
        let location = convert(event.locationInWindow, from: nil)
        // Controls first, and neither dismisses the menu.
        if hitRect(around: muteIcon).contains(location) {
            onToggleMute(record)
            return
        }
        if hitRect(around: snoozeIcon).contains(location) {
            onToggleSnooze(record)
            return
        }
        enclosingMenuItem?.menu?.cancelTracking()
        onJump(record)
    }

    /// Flattens the row to one line for `--dump-menu`, reading the labels that were actually
    /// laid out rather than re-deriving them from the record.
    func debugLine() -> String {
        let name = projectLabel.stringValue.padding(toLength: max(22, projectLabel.stringValue.count),
                                                   withPad: " ", startingAt: 0)
        let elapsed = elapsedLabel.stringValue.padding(toLength: 5, withPad: " ", startingAt: 0)
        let unseen = isUnseenUrgent ? " ◉unseen" : ""
        let snooze = snoozeRemaining != nil ? "◷ snoozed" : "◷"
        let bell = isMuted ? "◌ muted" : "◉"
        // Reports the colours the labels are actually wearing, not the tint they were derived
        // from — restating the input would not catch a label that failed to pick it up, and a
        // text dump is the only way this menu can be inspected.
        let paint = "[\(tint.rawValue)"
            + " name=\(projectLabel.textColor?.colorNameForDump ?? "?")"
            + " time=\(elapsedLabel.textColor?.colorNameForDump ?? "?")"
            + " dot=\(statusDot.textColor?.colorNameForDump ?? "?")]"
        return "\(statusDot.stringValue)\(unseen) \(name) \(agentLabel.stringValue) \(elapsed) \(paint)  \(detailLabel.stringValue)   \(snooze) \(bell)"
    }
}

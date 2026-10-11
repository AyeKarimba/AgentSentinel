import AppKit
import TNavCore

/// The alert banner.
///
/// Deliberately the app's own window rather than a `UNUserNotification`. A system notification
/// is the more conventional choice and needs less code, but its size is fixed by macOS and
/// whether it appears over a fullscreen app is decided by the user's Focus settings, with no
/// say for the app. Both of those are settings here, so the banner has to be ours.
///
/// The cost of that choice, stated plainly: this does not respect Do Not Disturb. Which is why
/// `bannerOverFullscreen` defaults to off — going fullscreen is often exactly a request not to
/// be interrupted, and quietly overriding it would be rude.
final class BannerPanel {
    private var panel: NSPanel?
    private var dismissTimer: Timer?
    private let onClick: (SessionRecord) -> Void
    private var record: SessionRecord?

    init(onClick: @escaping (SessionRecord) -> Void) {
        self.onClick = onClick
    }

    func show(record: SessionRecord, tint: RowTint, settings: AlertSettings) {
        dismiss()
        self.record = record

        let size = settings.bannerSize
        let content = BannerView(record: record, tint: tint,
                                 width: size.width,
                                 titleSize: size.titleSize, bodySize: size.bodySize) { [weak self] in
            guard let self, let record = self.record else { return }
            self.dismiss()
            self.onClick(record)
        }

        // .nonactivatingPanel so showing the banner never steals focus from what the user is
        // typing into — the whole point is to inform without taking over.
        let panel = NSPanel(contentRect: content.frame,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.contentView = content
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.level = .statusBar
        panel.collectionBehavior = settings.bannerOverFullscreen
            ? [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            : [.moveToActiveSpace, .ignoresCycle]

        // Top-right, tucked under the menu bar, where macOS puts its own notifications.
        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: visible.maxX - content.frame.width - 16,
                                         y: visible.maxY - content.frame.height - 8))
        }

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panel.animator().alphaValue = 1
        }
        self.panel = panel

        dismissTimer = Timer.scheduledTimer(withTimeInterval: settings.bannerSeconds,
                                            repeats: false) { [weak self] _ in
            self?.dismiss()
        }
    }

    func dismiss() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        guard let panel else { return }
        self.panel = nil
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = 0
        } completionHandler: {
            panel.orderOut(nil)
        }
    }
}

/// The banner's contents. Sized from the settings rather than a fixed layout, which is the
/// whole reason this is a custom view.
///
/// Colours come from `RowTint.color`, the same definition the rows and the legend read, so a
/// banner is recognisably the same alert as the row it will take you to — and so changing the
/// palette cannot leave the banner behind.
private final class BannerView: NSView {
    private let action: () -> Void

    init(record: SessionRecord, tint: RowTint,
         width: Double, titleSize: Double, bodySize: Double, action: @escaping () -> Void) {
        self.action = action

        let accent = tint.color
        let title = NSTextField(labelWithString: "\(record.project) (\(record.agent.displayName))")
        title.font = .systemFont(ofSize: titleSize, weight: .semibold)
        title.textColor = accent
        title.lineBreakMode = .byTruncatingTail

        // Carries the tint too: in a banner the reason is the point, not an aside, and it is
        // what makes red-versus-amber legible without reading a word. Name and reason are the
        // whole banner — the agent's closing message stays in the menu row, where the user reads
        // at their own pace rather than against a dismiss timer.
        let reason = NSTextField(labelWithString: record.reason?.label ?? "waiting")
        reason.font = .systemFont(ofSize: bodySize - 1, weight: .medium)
        reason.textColor = accent
        reason.alphaValue = 0.8

        let dot = NSTextField(labelWithString: tint.glyph)
        dot.font = .systemFont(ofSize: titleSize - 2)
        dot.textColor = accent

        let text = NSStackView(views: [title, reason])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2

        let row = NSStackView(views: [dot, text])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)

        row.translatesAutoresizingMaskIntoConstraints = false
        let height = row.fittingSize.height
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: max(64, height)))

        let background = NSVisualEffectView(frame: bounds)
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.masksToBounds = true
        background.autoresizingMask = [.width, .height]
        addSubview(background)

        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func mouseUp(with event: NSEvent) { action() }
}

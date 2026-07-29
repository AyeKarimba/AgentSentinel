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

    func show(record: SessionRecord, tint: RowTint, settings: AlertSettings, message: String?) {
        dismiss()
        self.record = record

        let size = settings.bannerSize
        let content = BannerView(record: record, tint: tint, message: message,
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

    /// Equal on all four sides. The banner is one short block of text, so anything uneven reads
    /// as a mistake rather than as emphasis.
    private static let inset: CGFloat = 15
    private static let dotWidth: CGFloat = 12
    private static let dotSpacing: CGFloat = 10

    init(record: SessionRecord, tint: RowTint, message: String?,
         width: Double, titleSize: Double, bodySize: Double, action: @escaping () -> Void) {
        self.action = action

        let accent = tint.color
        let title = NSTextField(labelWithString: record.project)
        title.font = .systemFont(ofSize: titleSize, weight: .semibold)
        title.textColor = accent
        title.lineBreakMode = .byTruncatingTail

        // Carries the tint too: in a banner the reason is the point, not an aside, and it is
        // what makes red-versus-amber legible without reading a word.
        let reason = NSTextField(labelWithString: record.reason?.label ?? "waiting")
        reason.font = .systemFont(ofSize: bodySize - 1, weight: .medium)
        reason.textColor = accent
        reason.alphaValue = 0.8

        // Claude's own words stay in plain label colour. This is the one part the user has to
        // actually read, and the row makes the same call for the same reason — tinting it would
        // turn the banner into a block of colour with nothing standing out.
        let body = NSTextField(wrappingLabelWithString: message ?? "")
        body.font = .systemFont(ofSize: bodySize)
        body.textColor = .labelColor
        body.maximumNumberOfLines = 3
        body.isSelectable = false
        // The exact width the label will actually get. Derived rather than guessed, because it
        // is what decides how many lines the text wraps to, and therefore the banner's height.
        body.preferredMaxLayoutWidth = width - Self.inset * 2 - Self.dotWidth - Self.dotSpacing

        let dot = NSTextField(labelWithString: tint.glyph)
        dot.font = .systemFont(ofSize: titleSize - 2)
        dot.textColor = accent

        let text = NSStackView(views: message.map { _ in [title, reason, body] } ?? [title, reason])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2

        let row = NSStackView(views: [dot, text])
        row.orientation = .horizontal
        // Sits the dot on the title's baseline rather than on the box's top edge, which is where
        // top alignment puts it and where it looks a fraction high.
        row.alignment = .firstBaseline
        row.spacing = Self.dotSpacing
        // Padding comes from the pin constants below, never from `edgeInsets`. `NSStackView`
        // does not report its insets fully through `fittingSize` — measured, a horizontal stack
        // counted 15 of 30 vertical points with baseline or top alignment, and none at all with
        // centre alignment. Sizing a window from that is what clipped the last line.

        // Generous to begin with, so pinning the row to both top and bottom has slack to satisfy
        // rather than an immediate conflict to resolve. The real height is measured below.
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 400))

        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.masksToBounds = true
        background.translatesAutoresizingMaskIntoConstraints = false
        addSubview(background)
        addSubview(row)

        NSLayoutConstraint.activate([
            // Pinned on all four sides. The previous version pinned only `centerY`, so the row's
            // height was never tied to the view: when the text needed more room than the frame
            // had, it overflowed past both edges and the bottom line was clipped.
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.inset),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.inset),
            row.topAnchor.constraint(equalTo: topAnchor, constant: Self.inset),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.inset),
            dot.widthAnchor.constraint(equalToConstant: Self.dotWidth),
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            background.topAnchor.constraint(equalTo: topAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // Only now is this the true height: the row is in a hierarchy, it has a width, and the
        // wrapping label has therefore settled on its real number of lines. Measuring before any
        // of that — which is what the first version did — reported a single line every time.
        layoutSubtreeIfNeeded()
        setFrameSize(NSSize(width: width, height: ceil(fittingSize.height)))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func mouseUp(with event: NSEvent) { action() }
}

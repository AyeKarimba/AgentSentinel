import AppKit
import TNavCore

extension RowTint {
    /// The single definition of what each tint looks like.
    ///
    /// Both the rows and the guide that explains them read it from here. A legend maintained
    /// separately from the thing it describes is a legend that goes quietly wrong the first
    /// time a colour changes.
    var color: NSColor {
        switch self {
        case .urgent: return .systemRed
        case .waiting: return .systemOrange
        case .working: return .royalPurple
        case .settled: return .settledGrey
        }
    }

    /// Always filled — the same glyph the rows draw, so the guide shows the real thing rather
    /// than an approximation.
    ///
    /// A working session used to be hollow, from when it shared grey with an
    /// opened-but-unanswered one and the outline was the only thing telling them apart. Purple
    /// does that now, so the hollow ring bought nothing and cost legibility: it read as a
    /// fainter, less active row when the opposite is true.
    var glyph: String { "●" }

    var meaning: String {
        switch self {
        case .urgent: return "Needs your permission — you haven't opened it yet"
        case .waiting: return "Finished its turn — you haven't opened it yet"
        case .settled: return "You've opened it; still waiting on your reply"
        case .working: return "Claude is working in this tab"
        }
    }
}

extension NSColor {
    /// Royal purple, for a tab Claude is actively working in.
    ///
    /// Dynamic rather than a fixed value because royal purple proper (#7851A9) is dark enough
    /// that it reads as near-black against a dark menu background — the light-mode shade is
    /// the real colour, and the dark-mode one is that hue lifted until it stays legible.
    /// `bestMatch` rather than a raw name comparison because menus draw in a vibrant
    /// appearance, which is a distinct name that still maps onto aqua/darkAqua.
    static let royalPurple = NSColor(name: "royalPurple") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.663, green: 0.557, blue: 0.855, alpha: 1)   // #A98EDA
            : NSColor(srgbRed: 0.471, green: 0.318, blue: 0.663, alpha: 1)   // #7851A9
    }

    /// The dot's grey. Kept distinct from the lettering's `secondaryLabelColor`: tertiary is
    /// right for a 10pt glyph and too faint for words you have to read.
    static let settledGrey = NSColor.tertiaryLabelColor

    /// Purple for the menu bar icon, deliberately more saturated than `royalPurple`.
    ///
    /// The row purple is tuned against the dropdown's dark translucent background, where it
    /// reads clearly. The menu bar is a different problem: it sits over whatever wallpaper the
    /// user has, and `apple.terminal` is a thin outline with very little area to carry a colour.
    /// A pale lavender there reads as plain white — which is exactly how it looked on a
    /// blue-purple desktop, indistinguishable from the grey "nothing running" state.
    ///
    /// Red and amber need no such variant: they are already saturated enough to survive a thin
    /// stroke over an arbitrary background.
    static let menuBarPurple = NSColor(name: "menuBarPurple") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.776, green: 0.494, blue: 1.0, alpha: 1)   // #C67EFF
            : NSColor(srgbRed: 0.478, green: 0.216, blue: 0.788, alpha: 1) // #7A37C9
    }

    /// Deep gold, for the legend entry itself.
    ///
    /// Deliberately outside the row palette — red, amber, purple and grey all mean something
    /// about a session, and the guide is not a session.
    ///
    /// The light shade is darker than a textbook gold on purpose: plain darkgoldenrod
    /// (#B8860B) measures 2.98:1 against a light menu, well under the 4.5:1 needed to read
    /// comfortably. #8B6914 gets that to 4.66:1 while still reading as gold rather than brown.
    /// Dark mode uses a lifted shade at 8.31:1, where the dark one would look muddy.
    static let deepGold = NSColor(name: "deepGold") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.878, green: 0.741, blue: 0.361, alpha: 1)   // #E0BD5C
            : NSColor(srgbRed: 0.545, green: 0.412, blue: 0.078, alpha: 1)   // #8B6914
    }
}

extension NSColor {
    /// Identifies a colour for `--dump-menu`. Compares against the tints by resolved value so
    /// a dynamic colour reports the same name whichever appearance it was resolved under.
    var colorNameForDump: String {
        let named: [(String, NSColor)] = [
            ("red", .systemRed), ("orange", .systemOrange), ("purple", .royalPurple),
            ("gold", .deepGold), ("grey", .tertiaryLabelColor), ("grey", .secondaryLabelColor),
            ("label", .labelColor),
        ]
        for (name, candidate) in named where candidate == self { return name }
        return "?"
    }
}

extension NSMenuItem {
    /// Sets a coloured title and keeps the un-highlighted version to restore later.
    ///
    /// `representedObject` is otherwise unused on these items and is exactly the "caller's
    /// own data" slot, which beats a side table keyed on object identity.
    func setTintedTitle(_ text: NSAttributedString) {
        attributedTitle = text
        representedObject = text
    }

    var tintedTitle: NSAttributedString? { representedObject as? NSAttributedString }
}

/// The "App Legend" guide.
///
/// A submenu rather than a window: hovering the item opens it, which is the cheapest possible
/// gesture, and it needs no window to manage or dismiss. Items are enabled but actionless so
/// they render at full colour — a disabled `NSMenuItem` dims its title, which would wash out
/// the very thing being demonstrated.
enum Legend {
    static let title = "App Legend"

    static func menuItem() -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        // `menuFont(ofSize: 0)` is the system menu font at its default size, so the gold entry
        // sits at exactly the same weight and size as the plain items around it — only the
        // colour sets it apart.
        item.setTintedTitle(NSAttributedString(string: title, attributes: [
            .foregroundColor: NSColor.deepGold,
            .font: NSFont.menuFont(ofSize: 0),
        ]))
        item.submenu = buildSubmenu()
        item.toolTip = "A guide to every colour and marker in this menu"
        return item
    }

    /// Restores or inverts the stashed titles as the pointer moves.
    ///
    /// Highlighting a menu row paints white on blue, and an attributed title keeps its own
    /// colours straight through that — so the gold entry would sit unreadable on the highlight
    /// at exactly the moment the user hovers it to open the guide. AppKit does no automatic
    /// flip for attributed titles, so each one is swapped by hand against its stashed original.
    static func applyHighlight(in menu: NSMenu, highlighted: NSMenuItem?) {
        for item in menu.items {
            guard let original = item.tintedTitle else { continue }
            item.attributedTitle = item === highlighted ? inverted(original) : original
        }
    }

    private static func inverted(_ text: NSAttributedString) -> NSAttributedString {
        let copy = NSMutableAttributedString(attributedString: text)
        copy.addAttribute(.foregroundColor,
                          value: NSColor.selectedMenuItemTextColor,
                          range: NSRange(location: 0, length: copy.length))
        return copy
    }

    /// Menus do not retain their delegates, so the submenu's has to be owned somewhere.
    private static let highlighting = HighlightingDelegate()

    /// Kept separate from `StatusItemController`, which is the *main* menu's delegate: reusing
    /// it here would fire `menuDidClose` when the submenu closed, and that rebuilds the menu —
    /// dismissing the still-open parent out from under the pointer.
    private final class HighlightingDelegate: NSObject, NSMenuDelegate {
        func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
            Legend.applyHighlight(in: menu, highlighted: item)
        }

        /// Same reason as the main menu's: closing on a highlighted item sends no final
        /// `willHighlight(nil)`, and this submenu outlives its own closing.
        func menuDidClose(_ menu: NSMenu) {
            Legend.applyHighlight(in: menu, highlighted: nil)
        }
    }

    private static func buildSubmenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = highlighting

        menu.addItem(heading("The name, dot and time on each row"))
        for tint in [RowTint.urgent, .waiting, .settled, .working] {
            menu.addItem(sample(tint.glyph, "4m", tint.meaning, color: tint.color))
        }

        menu.addItem(.separator())
        menu.addItem(heading("The menu bar icon"))
        menu.addItem(sample(">_", "2 · 4m", "A tab needs permission; 2 are waiting",
                            color: RowTint.urgent.color))
        menu.addItem(sample(">_", "1 · 2m", "A tab has finished and is waiting on you",
                            color: RowTint.waiting.color))
        menu.addItem(sample(">_", "", "Claude is running; nothing wants you",
                            color: RowTint.working.color))
        menu.addItem(sample(">_", "", "No Claude sessions at all",
                            color: .secondaryLabelColor))
        menu.addItem(sample("●", "", "Unopened request in a muted or snoozed tab",
                            color: RowTint.urgent.color))

        menu.addItem(.separator())
        menu.addItem(heading("The buttons on each row"))
        menu.addItem(symbol("clock", "Snooze this tab for 10 minutes (⌥-click for 30)"))
        menu.addItem(symbol("bell.fill", "Mute this tab until you turn it back on"))

        menu.addItem(.separator())
        menu.addItem(heading("Clicking a row jumps to that tab, which marks it opened"))

        return menu
    }

    /// A colour swatch plus its meaning. The swatch is drawn in the row's real font and
    /// colour; the explanation stays in plain label colour so the eye goes to the sample.
    private static func sample(_ glyph: String,
                               _ text: String,
                               _ meaning: String,
                               color: NSColor) -> NSMenuItem {
        let line = NSMutableAttributedString()
        let swatch: [NSAttributedString.Key: Any] = [
            .foregroundColor: color,
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
        ]
        // Padded to a fixed width so every meaning starts in the same column.
        let shown = "\(glyph) \(text)".trimmingCharacters(in: .whitespaces)
        line.append(NSAttributedString(string: shown.padding(toLength: max(8, shown.count),
                                                             withPad: " ", startingAt: 0),
                                       attributes: swatch))
        line.append(NSAttributedString(string: "  \(meaning)", attributes: [
            .foregroundColor: NSColor.labelColor,
            .font: NSFont.systemFont(ofSize: 12),
        ]))

        let item = NSMenuItem(title: shown, action: nil, keyEquivalent: "")
        item.setTintedTitle(line)
        item.isEnabled = true
        return item
    }

    private static func symbol(_ name: String, _ meaning: String) -> NSMenuItem {
        let item = NSMenuItem(title: meaning, action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        item.image?.isTemplate = true
        item.isEnabled = true
        return item
    }

    private static func heading(_ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.attributedTitle = NSAttributedString(string: text, attributes: [
            .foregroundColor: NSColor.secondaryLabelColor,
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
        ])
        item.isEnabled = false
        return item
    }
}

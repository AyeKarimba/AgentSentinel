import XCTest
@testable import TNavCore

/// Terminal's `windows` element is not only terminal windows. Once Shell ▸ New Command… has
/// been opened, its panel is listed too (Terminal 2.15, macOS 26.5): every property of it is
/// `missing value` and `tabs of` it raises -1728. A walk written as
/// `repeat with aTab in tabs of aWindow` died on that panel and took the jump with it, even
/// though the wanted tab sat in the very next window. Every script that walks tabs must go
/// through the one guarded prologue, so the fix cannot quietly regress in a single script.
final class TerminalScriptTests: XCTestCase {
    private let tty = "/dev/ttys004"

    private var scripts: [(name: String, source: String)] {
        [
            ("windowInfo", TerminalQueries.windowInfoScript(tty: tty)),
            ("selectTab", TerminalQueries.selectTabScript(tty: tty)),
            ("knownTTYs", TerminalQueries.knownTTYsScript),
            ("setTitle", TerminalQueries.setTitleScript("marker", tty: tty)),
            ("clearTitle", TerminalQueries.setTitleScript(nil, tty: tty)),
            ("focus", TerminalAppController.focusScript(tty: tty)),
        ]
    }

    func testEveryTabWalkUsesTheGuardedPrologue() {
        for script in scripts {
            XCTAssertTrue(script.source.contains(TerminalQueries.guardedTabWalk),
                          "\(script.name) does not walk tabs through the guarded prologue")
        }
    }

    func testNoScriptWalksTabsOfAWindowDirectly() {
        for script in scripts {
            XCTAssertFalse(script.source.contains("in tabs of aWindow"),
                           "\(script.name) walks `tabs of aWindow` unguarded; -1728 on a panel aborts it")
        }
    }

    func testGuardYieldsAnEmptyTabListForAWindowThatHasNone() {
        // The shape that was verified live against a Terminal listing the New Command panel:
        // an empty default, the fetch inside try, no handler needed.
        let guardText = TerminalQueries.guardedTabWalk
        let emptyDefault = guardText.range(of: "set windowTabs to {}")
        let fetch = guardText.range(of: "set windowTabs to tabs of aWindow")
        let tryStart = guardText.range(of: "try")
        let tryEnd = guardText.range(of: "end try")
        XCTAssertNotNil(emptyDefault)
        XCTAssertNotNil(fetch)
        XCTAssertNotNil(tryStart)
        XCTAssertNotNil(tryEnd)
        guard let emptyDefault, let fetch, let tryStart, let tryEnd else { return }
        XCTAssertLessThan(emptyDefault.lowerBound, tryStart.lowerBound)
        XCTAssertLessThan(tryStart.lowerBound, fetch.lowerBound)
        XCTAssertLessThan(fetch.lowerBound, tryEnd.lowerBound)
        XCTAssertTrue(guardText.contains("repeat with aTab in windowTabs"))
    }
}

import XCTest
@testable import TNavCore

/// Regression cover for the Window-menu correlation path. The distinction between "no such
/// tab" and "the reply made no sense" matters: the former legitimately prunes session
/// records, so conflating them let a scripting quirk delete good state.
final class WindowInfoParsingTests: XCTestCase {
    func testParsesWindowIdAndTitle() throws {
        let info = try TerminalQueries.parseWindowInfo("4312\nMacTerminalNavigator — claude — 160×41")
        XCTAssertEqual(info?.windowID, 4312)
        XCTAssertEqual(info?.title, "MacTerminalNavigator — claude — 160×41")
    }

    func testEmptyReplyMeansNoSuchTab() throws {
        XCTAssertNil(try TerminalQueries.parseWindowInfo(""))
    }

    func testTheTabKeywordCollisionThrowsRatherThanReportingNotFound() {
        // The exact string Terminal produced when the script joined with `tab`: the class name
        // won over the tab character. If this returns nil instead of throwing, records get
        // pruned for a tab that is very much still open.
        XCTAssertThrowsError(
            try TerminalQueries.parseWindowInfo("85tabwebapp — claude — 178×46")
        ) { error in
            guard case TabControlError.scriptFailed = error else {
                return XCTFail("expected scriptFailed, got \(error)")
            }
        }
    }

    func testTitleContainingSeparatorsSurvives() throws {
        // Titles routinely contain em dashes and the multiplication sign; only a newline
        // would break the encoding, and window titles cannot contain one.
        let info = try TerminalQueries.parseWindowInfo("85\nwebapp — caffeinate ◂ claude — 178×46")
        XCTAssertEqual(info?.windowID, 85)
        XCTAssertEqual(info?.title, "webapp — caffeinate ◂ claude — 178×46")
    }

    func testNonNumericIdThrows() {
        XCTAssertThrowsError(try TerminalQueries.parseWindowInfo("notanumber\nSome Title"))
    }

    func testMissingTitleThrows() {
        XCTAssertThrowsError(try TerminalQueries.parseWindowInfo("4312\n"))
        XCTAssertThrowsError(try TerminalQueries.parseWindowInfo("4312"))
    }
}

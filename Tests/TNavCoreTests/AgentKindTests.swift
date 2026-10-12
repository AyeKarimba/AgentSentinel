import XCTest
@testable import TNavCore

final class AgentKindTests: XCTestCase {
    func testKnownKindsHaveDistinctNames() {
        let names = AgentKind.known.map(\.shortName)
        XCTAssertEqual(Set(names).count, names.count, "two agents must never share a row label")
        XCTAssertEqual(AgentKind.claude.displayName, "Claude Code")
        XCTAssertEqual(AgentKind.codex.displayName, "Codex")
        XCTAssertEqual(AgentKind.gemini.displayName, "Gemini CLI")
        XCTAssertEqual(AgentKind.copilot.displayName, "Copilot CLI")
        XCTAssertEqual(AgentKind.claude.shortName, "Claude")
        XCTAssertEqual(AgentKind.codex.shortName, "Codex")
        XCTAssertEqual(AgentKind.gemini.shortName, "Gemini")
        XCTAssertEqual(AgentKind.copilot.shortName, "Copilot")
    }

    func testUnknownKindStillHasAUsableName() {
        // A record from a newer build must render, not crash the menu.
        let future = AgentKind(rawValue: "hermes")
        XCTAssertEqual(future.displayName, "hermes")
        XCTAssertEqual(future.shortName, "Hermes")
        XCTAssertNil(future.configDirectoryName)
    }

    func testKindRoundTripsThroughJSONAsItsRawString() throws {
        let data = try JSONEncoder().encode(AgentKind.codex)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "\"codex\"")
        XCTAssertEqual(try JSONDecoder().decode(AgentKind.self, from: data), .codex)
    }

    func testConfigDirectories() {
        XCTAssertEqual(AgentKind.claude.configDirectoryName, ".claude")
        XCTAssertEqual(AgentKind.codex.configDirectoryName, ".codex")
        XCTAssertEqual(AgentKind.gemini.configDirectoryName, ".gemini")
        XCTAssertEqual(AgentKind.copilot.configDirectoryName, ".copilot")
    }
}

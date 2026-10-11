import XCTest
@testable import TNavCore

final class AgentKindTests: XCTestCase {
    func testKnownKindsHaveDistinctTagsAndNames() {
        let tags = AgentKind.known.map(\.tag)
        XCTAssertEqual(Set(tags).count, tags.count, "two agents must never share a row tag")
        XCTAssertEqual(AgentKind.claude.displayName, "Claude Code")
        XCTAssertEqual(AgentKind.codex.displayName, "Codex")
        XCTAssertEqual(AgentKind.gemini.displayName, "Gemini CLI")
        XCTAssertEqual(AgentKind.copilot.displayName, "Copilot CLI")
        XCTAssertEqual(AgentKind.claude.tag, "CC")
        XCTAssertEqual(AgentKind.codex.tag, "CX")
        XCTAssertEqual(AgentKind.gemini.tag, "GM")
        XCTAssertEqual(AgentKind.copilot.tag, "CP")
    }

    func testUnknownKindStillHasAUsableTagAndName() {
        // A record from a newer build must render, not crash the menu.
        let future = AgentKind(rawValue: "hermes")
        XCTAssertEqual(future.displayName, "hermes")
        XCTAssertEqual(future.tag, "HE")
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

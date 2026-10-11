import XCTest
@testable import TNavCore

final class HookRegistrationTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tnav-home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private func write(_ relative: String, _ json: String) throws {
        let url = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(json.utf8).write(to: url)
    }

    func testNotInstalledWithoutConfigDirectory() {
        XCTAssertFalse(HookRegistration.isInstalled(.codex, home: home))
        XCTAssertFalse(HookRegistration.isRegistered(.codex, home: home))
    }

    func testConfigFiles() {
        XCTAssertEqual(HookRegistration.configFile(for: .claude, home: home)?.lastPathComponent, "settings.json")
        XCTAssertEqual(HookRegistration.configFile(for: .codex, home: home)?.lastPathComponent, "hooks.json")
        XCTAssertEqual(HookRegistration.configFile(for: .gemini, home: home)?.lastPathComponent, "settings.json")
        XCTAssertEqual(HookRegistration.configFile(for: .copilot, home: home)?.lastPathComponent, "agentsentinel.json")
        XCTAssertNil(HookRegistration.configFile(for: AgentKind(rawValue: "hermes"), home: home))
    }

    func testClaudeRegisteredWithAgentFlagOrLegacyBareCommand() throws {
        try write(".claude/settings.json", """
        {"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/a/tnav hook --agent claude"}]}],
                  "Notification":[{"hooks":[{"type":"command","command":"/a/tnav hook --agent claude"}]}]}}
        """)
        XCTAssertTrue(HookRegistration.isRegistered(.claude, home: home))
        try write(".claude/settings.json", """
        {"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/a/tnav hook"}]}],
                  "Notification":[{"hooks":[{"type":"command","command":"/a/tnav hook"}]}]}}
        """)
        XCTAssertTrue(HookRegistration.isRegistered(.claude, home: home), "1.0.x registrations still count")
    }

    func testMissingRequiredEventMeansNotRegistered() throws {
        try write(".codex/hooks.json", """
        {"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/a/tnav hook --agent codex"}]}]}}
        """)
        XCTAssertTrue(HookRegistration.isInstalled(.codex, home: home))
        XCTAssertFalse(HookRegistration.isRegistered(.codex, home: home), "PermissionRequest is required too")
    }

    func testCopilotFileWithBashCommands() throws {
        try write(".copilot/hooks/agentsentinel.json", """
        {"version":1,"hooks":{"agentStop":[{"type":"command","bash":"/a/tnav hook --agent copilot --event agentStop"}],
                             "permissionRequest":[{"type":"command","bash":"/a/tnav hook --agent copilot --event permissionRequest"}]}}
        """)
        XCTAssertTrue(HookRegistration.isRegistered(.copilot, home: home))
    }

    func testAnotherAgentsCommandDoesNotCount() throws {
        try write(".gemini/settings.json", """
        {"hooks":{"AfterAgent":[{"hooks":[{"type":"command","command":"/a/tnav hook --agent codex"}]}],
                  "Notification":[{"hooks":[{"type":"command","command":"/a/tnav hook --agent codex"}]}]}}
        """)
        XCTAssertFalse(HookRegistration.isRegistered(.gemini, home: home))
    }

    func testMalformedFileIsNotRegistered() throws {
        try write(".gemini/settings.json", "{nope")
        XCTAssertTrue(HookRegistration.isInstalled(.gemini, home: home))
        XCTAssertFalse(HookRegistration.isRegistered(.gemini, home: home))
    }

    func testStatusesCoverEveryKnownKind() {
        let statuses = HookRegistration.statuses(home: home)
        XCTAssertEqual(statuses.map(\.kind), AgentKind.known)
        XCTAssertTrue(statuses.allSatisfy { !$0.installed && !$0.registered })
    }
}

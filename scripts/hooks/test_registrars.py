"""Run with:  python3 -m unittest discover -s scripts/hooks -t scripts"""
import json
import os
import tempfile
import unittest

from hooks import claude, codex, copilot, gemini, common

TNAV = "/Applications/AgentSentinel.app/Contents/MacOS/tnav"


class RegistrarCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.home = self.tmp.name

    def tearDown(self):
        self.tmp.cleanup()

    def path(self, *parts):
        return os.path.join(self.home, *parts)

    def write(self, rel, obj):
        full = self.path(rel)
        os.makedirs(os.path.dirname(full), exist_ok=True)
        with open(full, "w") as handle:
            json.dump(obj, handle)
        return full

    def read(self, rel):
        with open(self.path(rel)) as handle:
            return json.load(handle)


class ClaudeTests(RegistrarCase):
    def test_not_installed_without_config_dir(self):
        self.assertFalse(claude.installed(self.home))
        os.makedirs(self.path(".claude"))
        self.assertTrue(claude.installed(self.home))

    def test_registers_six_events_with_agent_flag(self):
        os.makedirs(self.path(".claude"))
        claude.register(self.home, TNAV)
        hooks = self.read(".claude/settings.json")["hooks"]
        self.assertEqual(set(hooks), {"SessionStart", "UserPromptSubmit", "PreToolUse", "Notification", "Stop", "SessionEnd"})
        self.assertEqual(hooks["Stop"][0]["hooks"][0]["command"], f"{TNAV} hook --agent claude")
        self.assertTrue(claude.registered(self.home))

    def test_merge_keeps_other_tools_and_replaces_old_claudebar_entries(self):
        self.write(".claude/settings.json", {
            "permissions": {"allow": ["Bash"]},
            "hooks": {
                "Stop": [
                    {"hooks": [{"type": "command", "command": "/opt/other/notify.sh"}]},
                    {"hooks": [{"type": "command", "command": "/Applications/ClaudeBar.app/Contents/MacOS/tnav hook"}]},
                ],
            },
        })
        claude.register(self.home, TNAV)
        settings = self.read(".claude/settings.json")
        self.assertEqual(settings["permissions"], {"allow": ["Bash"]})
        stop_commands = [h["command"] for g in settings["hooks"]["Stop"] for h in g["hooks"]]
        self.assertIn("/opt/other/notify.sh", stop_commands)
        self.assertIn(f"{TNAV} hook --agent claude", stop_commands)
        self.assertNotIn("/Applications/ClaudeBar.app/Contents/MacOS/tnav hook", stop_commands)
        self.assertTrue(os.path.exists(self.path(".claude/settings.json.tnav-backup")))

    def test_idempotent(self):
        os.makedirs(self.path(".claude"))
        claude.register(self.home, TNAV)
        claude.register(self.home, TNAV)
        self.assertEqual(len(self.read(".claude/settings.json")["hooks"]["Stop"]), 1)

    def test_remove_strips_ours_and_drops_empty_hooks_key(self):
        os.makedirs(self.path(".claude"))
        claude.register(self.home, TNAV)
        claude.remove(self.home)
        self.assertNotIn("hooks", self.read(".claude/settings.json"))
        self.assertFalse(claude.registered(self.home))

    def test_refuses_malformed_file(self):
        full = self.path(".claude/settings.json")
        os.makedirs(os.path.dirname(full))
        with open(full, "w") as handle:
            handle.write("{not json")
        with self.assertRaises(common.RegistrarError):
            claude.register(self.home, TNAV)
        with open(full) as handle:
            self.assertEqual(handle.read(), "{not json")

    def test_legacy_registration_without_agent_flag_counts_as_registered(self):
        self.write(".claude/settings.json", {"hooks": {
            "Stop": [{"hooks": [{"type": "command", "command": "/x/tnav hook"}]}],
            "Notification": [{"hooks": [{"type": "command", "command": "/x/tnav hook"}]}],
        }})
        self.assertTrue(claude.registered(self.home))


class CodexTests(RegistrarCase):
    def test_creates_hooks_json_when_absent(self):
        os.makedirs(self.path(".codex"))
        codex.register(self.home, TNAV)
        hooks = self.read(".codex/hooks.json")["hooks"]
        self.assertEqual(set(hooks), {"SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "Stop", "SessionEnd"})
        entry = hooks["PermissionRequest"][0]["hooks"][0]
        self.assertEqual(entry["command"], f"{TNAV} hook --agent codex")
        self.assertEqual(entry["type"], "command")
        self.assertEqual(entry["timeout"], 10)
        self.assertTrue(codex.registered(self.home))

    def test_merges_into_existing_hooks_json(self):
        self.write(".codex/hooks.json", {"description": "mine", "hooks": {
            "PreToolUse": [{"matcher": "^Bash$", "hooks": [{"type": "command", "command": "/opt/policy.py"}]}]}})
        codex.register(self.home, TNAV)
        data = self.read(".codex/hooks.json")
        self.assertEqual(data["description"], "mine")
        self.assertEqual(data["hooks"]["PreToolUse"][0]["matcher"], "^Bash$")
        self.assertEqual(len(data["hooks"]["PreToolUse"]), 2)

    def test_remove(self):
        os.makedirs(self.path(".codex"))
        codex.register(self.home, TNAV)
        codex.remove(self.home)
        self.assertFalse(codex.registered(self.home))


class GeminiTests(RegistrarCase):
    def test_registers_into_settings_json(self):
        os.makedirs(self.path(".gemini"))
        gemini.register(self.home, TNAV)
        hooks = self.read(".gemini/settings.json")["hooks"]
        self.assertEqual(set(hooks), {"SessionStart", "BeforeAgent", "BeforeTool", "AfterAgent", "Notification", "SessionEnd"})
        self.assertEqual(hooks["AfterAgent"][0]["hooks"][0]["command"], f"{TNAV} hook --agent gemini")
        self.assertTrue(gemini.registered(self.home))

    def test_keeps_other_settings(self):
        self.write(".gemini/settings.json", {"theme": "Default", "hooks": {}})
        gemini.register(self.home, TNAV)
        self.assertEqual(self.read(".gemini/settings.json")["theme"], "Default")


class CopilotTests(RegistrarCase):
    def test_writes_own_file_with_event_flag_per_event(self):
        os.makedirs(self.path(".copilot"))
        copilot.register(self.home, TNAV)
        data = self.read(".copilot/hooks/agentsentinel.json")
        self.assertEqual(data["version"], 1)
        self.assertEqual(set(data["hooks"]), {"sessionStart", "userPromptSubmitted", "preToolUse", "permissionRequest", "notification", "agentStop", "sessionEnd"})
        self.assertEqual(data["hooks"]["agentStop"][0]["bash"], f"{TNAV} hook --agent copilot --event agentStop")
        self.assertEqual(data["hooks"]["agentStop"][0]["type"], "command")
        self.assertTrue(copilot.registered(self.home))

    def test_remove_deletes_the_file_only(self):
        os.makedirs(self.path(".copilot/hooks"))
        self.write(".copilot/hooks/other.json", {"version": 1, "hooks": {}})
        copilot.register(self.home, TNAV)
        copilot.remove(self.home)
        self.assertFalse(os.path.exists(self.path(".copilot/hooks/agentsentinel.json")))
        self.assertTrue(os.path.exists(self.path(".copilot/hooks/other.json")))


if __name__ == "__main__":
    unittest.main()

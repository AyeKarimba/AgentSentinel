"""Gemini CLI: ~/.gemini/settings.json, `hooks` object, Claude-shaped groups."""
import os
from . import common

KIND = "gemini"
CONFIG_DIR = ".gemini"
EVENTS = ["SessionStart", "BeforeAgent", "BeforeTool", "AfterAgent", "Notification", "SessionEnd"]
REQUIRED = ["AfterAgent", "Notification"]

installed, registered, register, remove = common.grouped_registrar(
    KIND, os.path.join(CONFIG_DIR, "settings.json"), "hooks", EVENTS, REQUIRED)

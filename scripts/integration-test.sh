#!/bin/bash
# End-to-end exercise of the hook → state → list pipeline using canned payloads.
# Runs against a scratch state directory so it never disturbs real session records.
set -uo pipefail

TNAV="${TNAV:-$(cd "$(dirname "$0")/.." && pwd)/.build/debug/tnav}"
SESSION="integration-test-$$"
# Genuinely a scratch directory. This used to write into the real ~/.claude/tnav despite the
# claim above, which meant a failed run left a stray record in the live menu.
export TNAV_STATE_DIR="${TMPDIR:-/tmp}/tnav-integration-$$"
# This script runs under whatever agent is driving development; its payloads are canned, and
# the per-agent sections would otherwise be ignored as "nested under a different agent".
export TNAV_HOOK_IGNORE_ANCESTRY_MISMATCH=1
STATE="$TNAV_STATE_DIR/sessions/claude-$SESSION.json"
CWD="/Users/you/code/DemoProject"
failures=0

mkdir -p "$TNAV_STATE_DIR/sessions"
cleanup() { rm -rf "$TNAV_STATE_DIR"; }
trap cleanup EXIT

AGENT="${AGENT:-claude}"
EXTRA_ARGS=()   # e.g. (--event agentStop) for copilot

emit() {  # emit <event-json-object-without-braces>
  # Caller supplies the full field list, because each agent spells them differently.
  local body="$1"
  local out
  # ${arr[@]+"${arr[@]}"} rather than "${arr[@]}": macOS ships bash 3.2, where an empty
  # array under `set -u` is an unbound-variable error.
  out=$(printf '{%s}' "$body" | "$TNAV" hook --agent "$AGENT" ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"})
  local code=$?
  if [ $code -ne 0 ]; then
    echo "  FAIL: hook exited $code (hooks must always exit 0)"
    failures=$((failures + 1))
  fi
  if [ -n "$out" ]; then
    echo "  FAIL: hook printed to stdout: $out (a permission hook's stdout is read as a decision)"
    failures=$((failures + 1))
  fi
}

# Claude-shaped convenience: emit_claude <event> [extra json]
emit_claude() {
  local event="$1" extra="${2:-}"
  emit "\"session_id\":\"$SESSION\",\"cwd\":\"$CWD\",\"hook_event_name\":\"$event\"$extra"
}

check() {  # check <description> <jq filter> <expected>
  local description="$1" filter="$2" expected="$3"
  local actual
  actual=$(jq -r "$filter" "$STATE" 2>/dev/null)
  if [ "$actual" = "$expected" ]; then
    echo "  ok   $description"
  else
    echo "  FAIL $description — expected '$expected', got '$actual'"
    failures=$((failures + 1))
  fi
}

check_absent() {
  if [ -f "$STATE" ]; then
    echo "  FAIL $1 — record still present"
    failures=$((failures + 1))
  else
    echo "  ok   $1"
  fi
}

echo "SessionStart → session is working, nothing pending"
emit_claude SessionStart ',"source":"startup"'
check "state is working"        '.state'    'working'
check "no wait reason"          '.reason'   'null'
check "project from cwd"        '.cwd'      "$CWD"
check "not yet notified"        '.notified' 'false'

echo
echo "Stop → session is waiting, normal tier, message captured"
emit_claude Stop ',"last_assistant_message":"Which approach do you want?"'
check "state is waiting"        '.state'                'waiting'
check "reason is turn_complete" '.reason'               'turn_complete'
check "message captured inline" '.lastAssistantMessage' 'Which approach do you want?'
FIRST_SINCE=$(jq -r '.since' "$STATE")

echo
echo "Notification(idle_prompt) → same news as the finish, wait start preserved"
emit_claude Notification ',"message":"Claude is waiting for your input","notification_type":"idle_prompt"'
check "reason updated"          '.reason'   'idle_prompt'
check "wait start preserved"    '.since'    "$FIRST_SINCE"
check "alert not re-armed"      '.notified' 'false'

echo
echo "Notification(unknown type) → treated as permission, not dropped"
emit_claude Notification ',"message":"Claude needs your permission","notification_type":"tool_permission_v9"'
check "unknown type is urgent"  '.reason'   'permission'
check "wait start still preserved" '.since' "$FIRST_SINCE"

echo
echo "PreToolUse → permission answered, tool running, session working again"
emit_claude PreToolUse ',"tool_name":"Bash"'
check "back to working"         '.state'    'working'
check "reason cleared"          '.reason'   'null'

echo
echo "UserPromptSubmit → user answered, alert cleared"
emit_claude UserPromptSubmit ',"prompt":"go ahead"'
check "back to working"         '.state'     'working'
check "reason cleared"          '.reason'    'null'
check "notified cleared"        '.notified'  'false'

echo
echo "SessionEnd → record removed"
emit_claude SessionEnd ',"reason":"other"'
check_absent "record deleted"

echo
echo "Unknown event → ignored, no record resurrected"
emit_claude SubagentStop ',"tool_name":"Bash"'
check_absent "unhandled event ignored"

echo
echo "Malformed payload → still exits 0, still no record"
printf 'not json at all' | "$TNAV" hook --agent claude
if [ $? -ne 0 ]; then
  echo "  FAIL malformed payload should still exit 0"
  failures=$((failures + 1))
else
  echo "  ok   malformed payload exits 0"
fi
printf '' | "$TNAV" hook --agent claude
if [ $? -ne 0 ]; then
  echo "  FAIL empty payload should still exit 0"
  failures=$((failures + 1))
else
  echo "  ok   empty payload exits 0"
fi

echo
echo "Unknown agent → exits 0, prints nothing, writes nothing"
out=$(printf '{"session_id":"%s","cwd":"%s","hook_event_name":"Stop"}' "$SESSION" "$CWD" | "$TNAV" hook --agent mystery)
if [ $? -ne 0 ] || [ -n "$out" ]; then
  echo "  FAIL unknown agent must exit 0 silently"
  failures=$((failures + 1))
elif ls "$TNAV_STATE_DIR/sessions"/*mystery* >/dev/null 2>&1; then
  echo "  FAIL unknown agent must not write a record"
  failures=$((failures + 1))
else
  echo "  ok   unknown agent is a silent no-op"
fi

echo
echo "Legacy registration (no --agent) → still Claude"
printf '{"session_id":"legacy-%s","cwd":"%s","hook_event_name":"SessionStart"}' "$$" "$CWD" | "$TNAV" hook
if [ -f "$TNAV_STATE_DIR/sessions/claude-legacy-$$.json" ]; then
  echo "  ok   defaults to claude"
else
  echo "  FAIL no --agent should mean claude"
  failures=$((failures + 1))
fi

echo
echo "=== codex ==="
AGENT=codex
CODEX_SESSION="01a1-codex-$$"
STATE="$TNAV_STATE_DIR/sessions/codex-$CODEX_SESSION.json"
emit "\"session_id\":\"$CODEX_SESSION\",\"cwd\":\"$CWD\",\"hook_event_name\":\"SessionStart\",\"model\":\"gpt-5\",\"source\":\"startup\""
check "codex record is working"   '.state' 'working'
check "agent recorded"            '.agent' 'codex'
check "model recorded"            '.model' 'gpt-5'

echo "PermissionRequest prints nothing on stdout and marks urgent"
emit "\"session_id\":\"$CODEX_SESSION\",\"cwd\":\"$CWD\",\"hook_event_name\":\"PermissionRequest\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ls\",\"description\":\"List files\"}"
check "needs permission"          '.reason' 'permission'
check "message is the description" '.lastAssistantMessage' 'List files'
check "model survives an event without it" '.model' 'gpt-5'

emit "\"session_id\":\"$CODEX_SESSION\",\"cwd\":\"$CWD\",\"hook_event_name\":\"Stop\",\"last_assistant_message\":\"Done.\""
check "stop is turn_complete"     '.reason' 'turn_complete'

emit "\"session_id\":\"$CODEX_SESSION\",\"cwd\":\"$CWD\",\"hook_event_name\":\"SessionEnd\",\"reason\":\"other\""
check_absent "codex record removed"
AGENT=claude

echo
echo "=== gemini ==="
AGENT=gemini
G_SESSION="gem-$$"
STATE="$TNAV_STATE_DIR/sessions/gemini-$G_SESSION.json"
emit "\"session_id\":\"$G_SESSION\",\"cwd\":\"$CWD\",\"hook_event_name\":\"BeforeAgent\",\"prompt\":\"go\",\"timestamp\":\"2026-10-10T00:00:00Z\""
check "gemini record is working" '.state' 'working'
check "agent recorded"           '.agent' 'gemini'
emit "\"session_id\":\"$G_SESSION\",\"cwd\":\"$CWD\",\"hook_event_name\":\"AfterAgent\",\"prompt\":\"go\",\"prompt_response\":\"Done.\""
check "AfterAgent is turn_complete" '.reason' 'turn_complete'
check "response captured"        '.lastAssistantMessage' 'Done.'
emit "\"session_id\":\"$G_SESSION\",\"cwd\":\"$CWD\",\"hook_event_name\":\"Notification\",\"notification_type\":\"ToolPermission\",\"message\":\"Allow?\""
check "ToolPermission is urgent" '.reason' 'permission'
emit "\"session_id\":\"$G_SESSION\",\"cwd\":\"$CWD\",\"hook_event_name\":\"SessionEnd\",\"reason\":\"exit\""
check_absent "gemini record removed"
AGENT=claude

echo
if [ $failures -eq 0 ]; then
  echo "integration: all checks passed"
else
  echo "integration: $failures check(s) FAILED"
fi
exit $failures

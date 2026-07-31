#!/bin/bash
# End-to-end exercise of the hook → state → list pipeline using canned payloads.
# Runs against a scratch state directory so it never disturbs real session records.
set -uo pipefail

TNAV="${TNAV:-$(cd "$(dirname "$0")/.." && pwd)/.build/debug/tnav}"
SESSION="integration-test-$$"
# Genuinely a scratch directory. This used to write into the real ~/.claude/tnav despite the
# claim above, which meant a failed run left a stray record in the live menu.
export TNAV_STATE_DIR="${TMPDIR:-/tmp}/tnav-integration-$$"
STATE="$TNAV_STATE_DIR/sessions/$SESSION.json"
CWD="/Users/you/code/DemoProject"
failures=0

mkdir -p "$TNAV_STATE_DIR/sessions"
cleanup() { rm -rf "$TNAV_STATE_DIR"; }
trap cleanup EXIT

emit() {  # emit <event> [extra json]
  local event="$1" extra="${2:-}"
  local json="{\"session_id\":\"$SESSION\",\"cwd\":\"$CWD\",\"hook_event_name\":\"$event\"$extra}"
  printf '%s' "$json" | "$TNAV" hook
  local code=$?
  if [ $code -ne 0 ]; then
    echo "  FAIL: hook exited $code for $event (hooks must always exit 0)"
    failures=$((failures + 1))
  fi
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
emit SessionStart ',"source":"startup"'
check "state is working"        '.state'    'working'
check "no wait reason"          '.reason'   'null'
check "project from cwd"        '.cwd'      "$CWD"
check "not yet notified"        '.notified' 'false'

echo
echo "Stop → session is waiting, normal tier, message captured"
emit Stop ',"last_assistant_message":"Which approach do you want?"'
check "state is waiting"        '.state'                'waiting'
check "reason is turn_complete" '.reason'               'turn_complete'
check "message captured inline" '.lastAssistantMessage' 'Which approach do you want?'
FIRST_SINCE=$(jq -r '.since' "$STATE")

echo
echo "Notification(idle_prompt) → same news as the finish, wait start preserved"
emit Notification ',"message":"Claude is waiting for your input","notification_type":"idle_prompt"'
check "reason updated"          '.reason'   'idle_prompt'
check "wait start preserved"    '.since'    "$FIRST_SINCE"
check "alert not re-armed"      '.notified' 'false'

echo
echo "Notification(unknown type) → treated as permission, not dropped"
emit Notification ',"message":"Claude needs your permission","notification_type":"tool_permission_v9"'
check "unknown type is urgent"  '.reason'   'permission'
check "wait start still preserved" '.since' "$FIRST_SINCE"

echo
echo "PreToolUse → permission answered, tool running, session working again"
emit PreToolUse ',"tool_name":"Bash"'
check "back to working"         '.state'    'working'
check "reason cleared"          '.reason'   'null'

echo
echo "UserPromptSubmit → user answered, alert cleared"
emit UserPromptSubmit ',"prompt":"go ahead"'
check "back to working"         '.state'     'working'
check "reason cleared"          '.reason'    'null'
check "notified cleared"        '.notified'  'false'

echo
echo "SessionEnd → record removed"
emit SessionEnd ',"reason":"other"'
check_absent "record deleted"

echo
echo "Unknown event → ignored, no record resurrected"
emit SubagentStop ',"tool_name":"Bash"'
check_absent "unhandled event ignored"

echo
echo "Malformed payload → still exits 0, still no record"
printf 'not json at all' | "$TNAV" hook
if [ $? -ne 0 ]; then
  echo "  FAIL malformed payload should still exit 0"
  failures=$((failures + 1))
else
  echo "  ok   malformed payload exits 0"
fi
printf '' | "$TNAV" hook
if [ $? -ne 0 ]; then
  echo "  FAIL empty payload should still exit 0"
  failures=$((failures + 1))
else
  echo "  ok   empty payload exits 0"
fi

echo
if [ $failures -eq 0 ]; then
  echo "integration: all checks passed"
else
  echo "integration: $failures check(s) FAILED"
fi
exit $failures

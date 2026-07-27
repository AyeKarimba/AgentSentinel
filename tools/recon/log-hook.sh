#!/bin/sh
# Phase 0 recon only. Captures the raw hook payload plus the PPID chain so we can
# confirm both the JSON shape and TTY resolution before building on assumptions.
# Deliberately does nothing else and always exits 0 so it can never block a session.

LOG="${HOME}/.claude/tnav/recon.log"
mkdir -p "$(dirname "$LOG")"

start_ns=$(python3 -c 'import time;print(time.time_ns())')
payload=$(cat)

{
  printf '===== %s =====\n' "$(date '+%Y-%m-%d %H:%M:%S')"
  printf -- '--- payload ---\n%s\n' "$payload"

  printf -- '--- ppid chain (walk until tty != ??) ---\n'
  pid=$$
  n=0
  while [ "$pid" -gt 1 ] && [ "$n" -lt 12 ]; do
    line=$(ps -o pid=,ppid=,tty=,comm= -p "$pid" 2>/dev/null) || break
    [ -z "$line" ] && break
    printf '  %s\n' "$line"
    pid=$(printf '%s' "$line" | awk '{print $2}')
    n=$((n + 1))
  done

  printf -- '--- elapsed_ms ---\n'
  python3 -c "print(round((time.time_ns()-$start_ns)/1e6,1))" 2>/dev/null \
    || python3 -c "import time;print(round((time.time_ns()-$start_ns)/1e6,1))"
  printf '\n'
} >>"$LOG" 2>&1

exit 0

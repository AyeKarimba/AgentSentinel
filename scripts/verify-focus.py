#!/usr/bin/env python3
"""Verify that `tnav jump` lands on the exact target tab, including across Spaces.

Reports, per tab, whether it started on the Space you were looking at — so a run where
everything happened to be co-located can't be mistaken for proof of cross-Space focus.
"""
import subprocess
import sys
import time

TNAV = sys.argv[1] if len(sys.argv) > 1 else ".build/debug/tnav"

FRONT = '''tell application "Terminal"
  if not frontmost then return ""
  return tty of selected tab of window 1
end tell'''

TABS = '''tell application "Terminal"
  set out to ""
  repeat with w in windows
    repeat with t in tabs of w
      set out to out & (tty of t) & "," & ((id of w) as text) & linefeed
    end repeat
  end repeat
  return out
end tell'''


def osa(script):
    return subprocess.run(["osascript", "-e", script],
                          capture_output=True, text=True).stdout.strip()


def tabs():
    """[(tty, cgWindowID)] for every Terminal tab."""
    rows = []
    for line in osa(TABS).splitlines():
        if "," in line:
            tty, wid = line.rsplit(",", 1)
            rows.append((tty.strip(), int(wid)))
    return rows


def on_current_space():
    """CGWindowIDs of Terminal windows on the active Space, via `tnav spaces --porcelain`."""
    out = subprocess.run([TNAV, "spaces", "--porcelain"], capture_output=True, text=True)
    if out.returncode != 0:
        return None
    ids = set()
    for line in out.stdout.splitlines():
        parts = line.split(",")
        if len(parts) == 3 and parts[2] == "1":
            ids.add(int(parts[1]))
    return ids


def fingerprint():
    """IDs of every on-screen window, all apps — which desktop is currently showing.

    Terminal's own windows are not enough to judge this: the target ends up visible whether
    macOS switched to its desktop or dragged it onto ours, so the two are indistinguishable
    from Terminal alone. The rest of the desktop is what differs.
    """
    out = subprocess.run([TNAV, "spaces", "--fingerprint"], capture_output=True, text=True)
    if out.returncode != 0:
        return None
    return {int(line) for line in out.stdout.split() if line.isdigit()}


def landed_how(before, after, target, started_here):
    """Did we switch to the window's desktop, or drag the window onto ours?

    A pull leaves the desktop we started on intact and merely adds the target to it; a Space
    switch replaces the visible window set wholesale.
    """
    if before is None or after is None:
        return "unknown"
    if started_here:
        return "already here"
    if target not in after:
        return "target not visible"
    if not before:
        return "ambiguous (started on an empty desktop)"
    kept = len(before & after) / len(before)
    return "PULLED to this desktop" if kept > 0.5 else "switched desktop"


def main():
    only = None
    if "--tty" in sys.argv:
        only = sys.argv[sys.argv.index("--tty") + 1]

    rows = tabs()
    if only:
        rows = [r for r in rows if r[0] == only]
    if not rows:
        print("no Terminal tabs found")
        return 1

    passes, crossed, failures = 0, 0, []
    print("%-14s %-10s %-14s %-10s %s" % ("tab", "window", "started", "result", "how"))
    print("-" * 82)

    for tty, wid in rows:
        space = on_current_space()
        started_here = None if space is None else (wid in space)
        before = fingerprint()

        subprocess.run([TNAV, "jump", tty], capture_output=True)

        landed = False
        observed = ""
        deadline = time.time() + 3.0
        while time.time() < deadline:
            observed = osa(FRONT)
            if observed == tty:
                landed = True
                break
            time.sleep(0.03)

        if landed:
            passes += 1
            if started_here is False:
                crossed += 1
        else:
            failures.append((tty, observed))

        how = landed_how(before, fingerprint(), wid, started_here)
        started = {True: "this Space", False: "ANOTHER Space", None: "unknown"}[started_here]
        print("%-14s %-10s %-14s %-10s %s" % (
            tty, wid, started, "PASS" if landed else "FAIL", how))
        if not landed:
            print("               got '%s'" % observed)
        if "PULLED" in how:
            failures.append((tty, "window dragged onto the current desktop"))

    print("-" * 58)
    print("%d/%d landed on the exact target tab" % (passes, len(rows)))
    print("%d of those required crossing a Space" % crossed)
    if crossed == 0:
        print("NOTE: no cross-Space jump was exercised — move a Terminal window to another "
              "Space and re-run to prove that path.")
    for tty, observed in failures:
        print("  FAILED %s -> '%s'" % (tty, observed))
    return 0 if not failures else 1


if __name__ == "__main__":
    sys.exit(main())

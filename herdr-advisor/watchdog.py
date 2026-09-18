#!/usr/bin/env python3
"""Keep a Herdr advisor's loop alive from outside its harness.

ADVISOR.md makes the advisor's whole life one turn. Models end turns early
anyway, and of the sixteen harnesses the skill launches, three cannot gate a
turn end at all and the rest each do it differently, so this runs beside the
advisor instead: planted in its pane before `herdr agent start`, it watches
the pane through herdr and re-prompts every turn that ends while the pane
still holds an `*-advisor` name. The advisor ends by clearing that name
(`herdr agent rename "$HERDR_PANE_ID" --clear`), and so can the user.

Usage: python3 watchdog.py <pane-id>    (from the advisor pane's own shell, backgrounded)
"""
import json
import subprocess
import sys
import time
from pathlib import Path

LOG = Path.home() / "Library/Logs/herdr-advisor.log"
SKILL = "~/.agents/skills/herdr-advisor/ADVISOR.md"
MAX_BLOCKS, WINDOW_S, GRACE_S, START_S = 8, 3600, 10, 300
REASON = (f"Re-read {SKILL} first, then resume. Your loop has not met its end condition, "
          "so this turn may not end: start the next pass from `herdr agent get` and continue.")


def herdr(*args):
    """Run a herdr command and return its stdout; "" on any failure, since nothing here may raise."""
    try:
        return subprocess.run(["herdr", *args], capture_output=True, text=True).stdout
    except OSError:
        return ""


def state(pane):
    """(name, status, turn) of the pane's agent, or ("", "gone", -1) once the pane or agent is gone."""
    out = herdr("agent", "get", pane)
    try:
        a = json.loads(out[out.index("{"):])["result"]["agent"]   # herdr prefixes a terminal-title escape
        return a.get("name") or "", a.get("agent_status") or "", a["turn"] if a.get("turn") is not None else -1
    except Exception:
        return "", "gone", -1


def log(pane, action, blocks=0):
    try:
        LOG.parent.mkdir(parents=True, exist_ok=True)
        with LOG.open("a") as fh:
            fh.write(json.dumps({"ts": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "unix": int(time.time()),
                                 "pane": pane, "action": action, "blocks": blocks},
                                separators=(",", ":")) + "\n")
    except OSError:
        pass


def consecutive_blocks(pane):
    """Blocks this pane has taken inside the window since it last did anything else."""
    try:
        lines = LOG.read_text().splitlines()[-400:]
    except OSError:
        return 0
    cutoff, n = time.time() - WINDOW_S, 0
    for line in reversed(lines):
        try:
            r = json.loads(line)
        except ValueError:
            continue
        if r.get("pane") != pane:
            continue
        if r.get("action") != "blocked" or float(r.get("unix", 0)) < cutoff:
            break
        n += 1
    return n


def main(pane):
    def advisor(name):
        """Exit once the pane no longer holds an advisor's name: the end signal."""
        if not name.endswith("-advisor"):
            log(pane, "allowed-end")
            raise SystemExit(0)

    # Planted before `agent start`, so the pane holds no agent yet and every herdr
    # call errors at once; give the advisor START_S seconds to register.
    for _ in range(START_S):
        if state(pane)[0].endswith("-advisor"):
            break
        time.sleep(1)
    else:
        log(pane, "no-advisor")
        return

    last = 0   # turn counts completed turns; 0 until the handoff's turn ends
    while True:
        herdr("agent", "wait", pane, "--until", "working", "--until", "blocked", "--timeout", "60000")
        herdr("agent", "wait", pane, "--timeout", "60000")
        name, status, turn = state(pane)
        advisor(name)
        if status == "blocked":          # a dialog is the user's; wait it out
            time.sleep(5)
            continue
        if turn <= last:                 # nothing new since the last pass
            continue
        time.sleep(GRACE_S)              # a user may be typing, or stopping it, after an Esc
        name, status2, turn2 = state(pane)
        advisor(name)
        if turn2 != turn or status2 == "working":
            continue
        last = turn
        n = consecutive_blocks(pane)
        if n >= MAX_BLOCKS:
            log(pane, "allowed-cap", n)
            herdr("notification", "show", "Herdr advisor released",
                  "--body", f"{name} ended early {n}x in an hour; its worker is now unwatched.")
            return
        log(pane, "blocked", n + 1)
        herdr("agent", "prompt", pane, REASON)


if __name__ == "__main__":
    main(sys.argv[1])

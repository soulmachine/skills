#!/usr/bin/env python3
"""Offline self-test of watchdog.sh: no Herdr, a fake `herdr` on PATH.

The fake answers `agent get` from a state file and records every other call,
so each scenario sets a state, runs the watchdog until it exits or has made
one pass, and checks what it sent.

Run: python3 watchdog_selftest.py [path/to/watchdog.sh]
"""
import json, os, pathlib, subprocess, sys, tempfile, time

WD = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "watchdog.sh").resolve()
HOME = pathlib.Path(tempfile.mkdtemp())
LOG = HOME / "Library" / "Logs" / "herdr-advisor.log"
STATE, CALLS = HOME / "state", HOME / "calls"

FAKE = HOME / "herdr"
FAKE.write_text(f"""#!/bin/sh
echo "$*" >> {CALLS}
case "$1 $2" in
  "agent get") cat {STATE}   # .next: state after this get; .next2: the one after that
    [ -f {STATE}.next ] && mv {STATE}.next {STATE}
    [ -f {STATE}.next2 ] && mv {STATE}.next2 {STATE}.next ;;
  "agent wait") sleep 0.2 ;;   # the real one blocks; here every wait returns at once
esac
""")
FAKE.chmod(0o755)
ENV = dict(os.environ, HOME=str(HOME), PATH=f"{HOME}:{os.environ['PATH']}")


def run(name, status, turn, grace=0, seconds=3):
    """Run the watchdog against one fixed state for a few seconds; return its
    calls (excluding get/wait), its log actions, and whether it exited."""
    STATE.write_text(json.dumps({"result": {"agent": {"name": name, "agent_status": status, "turn": turn}}}))
    CALLS.write_text("")
    src = WD.read_text()
    for marker in ("GRACE_S=10", "START_S=300"):   # retuned by text: a rename must fail here, not run at production timings
        assert marker in src, f"{marker} not found in {WD}"
    script = src.replace("GRACE_S=10", f"GRACE_S={grace}").replace("START_S=300", "START_S=2")
    (HOME / "wd.sh").write_text(script)
    p = subprocess.Popen(["sh", str(HOME / "wd.sh"), "t:p1"], env=ENV,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        p.wait(timeout=seconds); exited = True
    except subprocess.TimeoutExpired:
        p.kill(); exited = False
    calls = [l for l in CALLS.read_text().splitlines() if not l.startswith(("agent get", "agent wait"))]
    return calls, exited


def actions():
    return [json.loads(l)["action"] for l in LOG.read_text().splitlines()] if LOG.exists() else []


def advisor_state(status, turn):
    return json.dumps({"result": {"agent": {"name": "pair-advisor", "agent_status": status, "turn": turn}}})


# 1. Planted before `agent start`: no agent yet, then an advisor registers
#    (the fake serves it from the second get onward) → the loop runs and
#    re-prompts its ended turn.
(STATE.parent / "state.next").write_text(advisor_state("idle", 1))
calls, exited = run("", "idle", 0, seconds=4)
assert not exited and any(c.startswith("agent prompt") for c in calls), calls
STATE.write_text("")   # never registers: gives up after START_S, no prompt
calls, exited = run("", "idle", 0, seconds=5)
assert exited and calls == [] and actions()[-1] == "no-advisor", (calls, actions())

# 2. Name cleared (the end signal) once running: exits without prompting.
(STATE.parent / "state.next").write_text(json.dumps({"result": {"agent": {"name": "", "agent_status": "idle", "turn": 3}}}))
calls, exited = run("pair-advisor", "idle", 3)
assert exited and calls == [] and actions()[-1] == "allowed-end", (calls, actions())

# 3. Renamed to a worker's name (no -advisor suffix): same exit, no prompt.
(STATE.parent / "state.next").write_text(json.dumps({"result": {"agent": {"name": "pair", "agent_status": "idle", "turn": 3}}}))
calls, exited = run("pair-advisor", "idle", 3)
assert exited and calls == [] and actions()[-1] == "allowed-end"

# 4. Advisor idle at a new turn: one re-prompt per turn, never two for the same
#    turn, logged as blocked. Turn 0 (handoff not yet answered) is not a turn.
LOG.unlink()
calls, exited = run("pair-advisor", "idle", 0)
assert not exited and not [c for c in calls if c.startswith("agent prompt")], calls
calls, exited = run("pair-advisor", "idle", 1, seconds=4)
prompts = [c for c in calls if c.startswith("agent prompt")]
assert not exited and len(prompts) == 1 and "herdr agent get" in prompts[0], calls
assert actions() == ["blocked"], actions()

# 5. Blocked (a dialog): never prompts.
calls, exited = run("pair-advisor", "blocked", 2)
assert not exited and not [c for c in calls if c.startswith("agent prompt")], calls

# 6. Cap: eight recent blocks for this pane release the ninth with a
#    notification; blocks older than the window or on another pane do not.
def seed(pane, n, age=0):
    with LOG.open("a") as fh:
        fh.writelines(json.dumps({"unix": time.time() - age, "pane": pane, "action": "blocked", "blocks": i}) + "\n"
                      for i in range(n))

LOG.write_text(""); seed("t:p1", 8)
calls, exited = run("pair-advisor", "idle", 5)
assert exited and any(c.startswith("notification show") for c in calls) and actions()[-1] == "allowed-cap", (calls, actions())

LOG.write_text(""); seed("t:p1", 8, age=4000)
calls, exited = run("pair-advisor", "idle", 6)
assert not exited and any(c.startswith("agent prompt") for c in calls), calls

LOG.write_text(""); seed("t:p2", 8)
calls, exited = run("pair-advisor", "idle", 7)
assert not exited and any(c.startswith("agent prompt") for c in calls), calls

# 7. Grace: a turn that moves on during the grace period is not re-prompted.
#    Gets: registration → idle 8, pass → idle 8, after grace and ever after →
#    working 9, which no pass can re-prompt.
LOG.write_text("")
(STATE.parent / "state.next").write_text(advisor_state("idle", 8))
(STATE.parent / "state.next2").write_text(advisor_state("working", 9))
calls, exited = run("pair-advisor", "idle", 8, grace=1)
assert not exited and not [c for c in calls if c.startswith("agent prompt")], calls
assert actions() == [], actions()

# 8. A stop that lands inside the grace (name cleared after the pass's get):
#    exit, no re-prompt.
(STATE.parent / "state.next").write_text(advisor_state("idle", 5))
(STATE.parent / "state.next2").write_text(json.dumps({"result": {"agent": {"name": "", "agent_status": "idle", "turn": 5}}}))
calls, exited = run("pair-advisor", "idle", 5, grace=1)
assert exited and calls == [] and actions() == ["allowed-end"], (calls, actions())

print("ok")

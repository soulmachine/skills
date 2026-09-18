#!/usr/bin/env python3
"""Offline self-test of stop-hook.sh's gate: no Herdr, a fake `herdr` on PATH.

Run: python3 hook_selftest.py [path/to/stop-hook.sh]
"""
import json, os, pathlib, subprocess, sys, tempfile

HOOK = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "stop-hook.sh").resolve()
MARK = "ADVISOR LOOP ENDED: both answers were 'nothing left'"
HOME = pathlib.Path(tempfile.mkdtemp())
LOG = HOME / "Library" / "Logs" / "herdr-advisor.log"
CALLS = HOME / "calls"

# The fake herdr records every call and reports the pane's name from a file.
FAKE = HOME / "herdr"
FAKE.write_text(f"#!/bin/sh\necho \"$*\" >> {CALLS}\nprintf '\\033]0;x\\007'\n"
                f"printf '{{\"result\":{{\"agent\":{{\"name\":\"%s\"}}}}}}' \"$(cat {HOME}/name)\"\n")
FAKE.chmod(0o755)
ENV = dict(os.environ, HOME=str(HOME), HERDR_ENV="1", HERDR_SOCKET_PATH="/x",
           HERDR_BIN_PATH=str(FAKE))


def gate(last, name="pair-advisor", pane="t:p1"):
    """The hook's decision for a turn ending with `last` in `pane`."""
    (HOME / "name").write_text(name)
    out = subprocess.run(["sh", str(HOOK)], input=json.dumps({"last_assistant_message": last}),
                         capture_output=True, text=True, env=dict(ENV, HERDR_PANE_ID=pane))
    assert out.returncode == 0, out.stderr
    return json.loads(out.stdout).get("decision", "allow")


def actions():
    return [json.loads(l)["action"] for l in LOG.read_text().splitlines()]


# 1. Outside Herdr: silent no-op, no log.
out = subprocess.run(["sh", str(HOOK)], input="{}", capture_output=True, text=True,
                     env={"PATH": os.environ["PATH"], "HOME": str(HOME)})
assert out.stdout == "{}" and not LOG.exists(), out

# 2. A worker pane (no -advisor suffix): allowed, not logged.
assert gate("done, holding", name="pair") == "allow" and not LOG.exists()

# 3. The marker as the last non-empty line lets the turn end, plain, fenced or
#    emphasised; anything else is blocked with a pointer at the manual.
assert gate("Both said nothing left.\n" + MARK + "\n\n") == "allow"
assert gate("Done.\n```\n" + MARK + "\n```\n") == "allow"
assert gate("Done.\n**" + MARK + "**") == "allow"
assert gate(MARK + "\nactually one more thing") == "block"
assert gate("Holding for the user.\nEnding my turn.") == "block"

# 4. Cap: after 8 consecutive blocks the ninth early end is released, once,
#    with a notification; a legitimate end resets the run.
assert gate(MARK) == "allow"
assert [gate("still going") for _ in range(9)] == ["block"] * 8 + ["allow"]
assert CALLS.read_text().count("notification show") == 1
assert gate(MARK) == "allow" and gate("early again") == "block"

# 5. Another pane's blocks do not count against this one.
assert gate("x", name="other-advisor", pane="t:p2") == "block"
assert actions().count("allowed-cap") == 1, actions()

# 6. The cap is a window, not a lifetime budget: eight blocks older than an
#    hour do not release the next early end.
with LOG.open("a") as fh:
    fh.writelines(json.dumps({"unix": 0, "pane": "t:p3", "action": "blocked"}) + "\n"
                  for _ in range(8))
assert gate("early", name="slow-advisor", pane="t:p3") == "block"

print("ok")

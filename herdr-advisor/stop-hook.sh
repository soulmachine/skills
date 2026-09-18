#!/bin/sh
# Keep a Herdr advisor's loop alive: block its turn end unless the loop has
# legitimately ended.
#
# ADVISOR.md makes the advisor's whole life one turn, ended only by a final
# line `ADVISOR LOOP ENDED: <reason>`. Models end turns early anyway. This runs
# as the ADVISOR's own Stop hook: a turn end without that line is sent back
# with a reason, which both Claude Code and Codex feed to the model as its next
# instruction, so the same turn continues.
#
# Registered by ~/.agents/hooks/Stop.toml, which agentstow renders into both
# ~/.claude/settings.json and ~/.codex/hooks.json. The logic lives here, in the
# skill it enforces, so an edit to the loop and to its gate land together.
#
# Runs on EVERY Claude Code and Codex turn on this machine. It must be a cheap
# silent no-op everywhere except an advisor pane, and it must never fail a
# turn: every path exits 0 and prints JSON.

# Both agents deliver the hook payload as JSON on stdin. Drain it either way, or
# the writer can see a closed pipe.
HERDR_HOOK_INPUT=$(cat 2>/dev/null)
export HERDR_HOOK_INPUT

# Keep these three first and cheap. Outside Herdr this is the whole hook.
[ "${HERDR_ENV:-}" = "1" ]        || { printf '{}'; exit 0; }
[ -n "${HERDR_SOCKET_PATH:-}" ]   || { printf '{}'; exit 0; }
[ -n "${HERDR_PANE_ID:-}" ]       || { printf '{}'; exit 0; }

# python3 rather than node: a hook PATH is not a login PATH, and bare `node` is
# already a live failure on this fleet from a first-party plugin doing exactly
# that. python3 ships with the OS and is what herdr's own integration uses.
command -v python3 >/dev/null 2>&1 || { printf '{}'; exit 0; }

python3 - <<'PY'
import json, os, pathlib, subprocess, time

HERDR = os.environ.get("HERDR_BIN_PATH") or "herdr"
PANE = os.environ.get("HERDR_PANE_ID", "")
LOG = pathlib.Path.home() / "Library" / "Logs" / "herdr-advisor.log"

MARKER = "ADVISOR LOOP ENDED:"
SKILL = "~/.agents/skills/herdr-advisor/ADVISOR.md"

# Claude Code documents a cap of 8 consecutive blocks, Codex none, and a probe
# showed neither enforced, so this is the only ceiling: past it the advisor is
# released and the worker runs unwatched. Blocks older than the window do not
# count, or the cap would be a lifetime budget that silently releases an
# advisor which recovers from every early end.
MAX_BLOCKS, WINDOW_S = 8, 3600

REASON = (f"Re-read {SKILL} first, then resume. Your loop has not met its end "
          f"condition, so this turn may not end: start the next pass from "
          f"`herdr agent get` and continue.")


def log(action, **fields):
    rec = {"ts": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "unix": time.time(),
           "pane": PANE, "action": action}
    rec.update(fields)
    try:
        LOG.parent.mkdir(parents=True, exist_ok=True)
        with LOG.open("a", encoding="utf-8") as fh:
            fh.write(json.dumps(rec) + "\n")
    except Exception:
        pass  # a hook that cannot log still must not fail the turn


def consecutive_blocks():
    """Blocks this pane has taken inside the window since it last ended a turn
    any other way."""
    try:
        with LOG.open(encoding="utf-8") as fh:
            lines = fh.readlines()[-400:]
    except Exception:
        return 0
    n, cutoff = 0, time.time() - WINDOW_S
    for line in reversed(lines):
        try:
            r = json.loads(line)
        except Exception:
            continue
        if r.get("pane") != PANE:
            continue
        if r.get("action") != "blocked" or float(r.get("unix", 0)) < cutoff:
            break
        n += 1
    return n


def ended(last_message):
    """True when the message's last non-empty line is the end marker, after
    stripping the fence or emphasis a model tends to wrap it in."""
    for line in reversed(last_message.splitlines()):
        line = line.strip().strip("`*_ ")
        if line:
            return line.startswith(MARKER)
    return False


def herdr(*args):
    """Run herdr and parse its JSON. The CLI prefixes a terminal escape, so the
    document starts at the first brace rather than at byte zero."""
    out = subprocess.run([HERDR, *args], capture_output=True, text=True,
                         timeout=10)
    out.check_returncode()
    return json.loads(out.stdout[out.stdout.index("{"):])


def main():
    name = herdr("agent", "get", PANE)["result"]["agent"].get("name") or ""
    if not name.endswith("-advisor"):
        return {}  # a worker, or an unpaired pane: not ours

    payload = json.loads(os.environ.get("HERDR_HOOK_INPUT") or "{}")
    if ended(payload.get("last_assistant_message") or ""):
        log("allowed-end", advisor=name)
        return {}

    n = consecutive_blocks()
    if n >= MAX_BLOCKS:
        log("allowed-cap", advisor=name, blocks=n)
        herdr("notification", "show", "Herdr advisor released", "--body",
              f"{name} ended early {n}x in an hour; its worker is now unwatched.")
        return {}

    log("blocked", advisor=name, blocks=n + 1)
    return {"decision": "block", "reason": REASON}


try:
    result = main()
except Exception as exc:
    log("error", error=f"{type(exc).__name__}: {exc}"[:300])
    result = {}
print(json.dumps(result))
PY

exit 0

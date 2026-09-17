#!/bin/sh
# Re-arm a Herdr advisor whose next-task loop has ended.
#
# The advisor's `herdr agent wait` lives only inside an advisor turn, so when
# that turn ends nothing watches the worker and nothing can restart it. This
# fires on the worker's turn end and pokes the advisor when its loop is gone.
#
# Registered by ~/.agents/hooks/Stop.toml, which agentstow renders into both
# ~/.claude/settings.json and ~/.codex/hooks.json. The logic lives here, in the
# skill it enforces, so an edit to the loop and to its watchdog land together.
#
# Runs on EVERY Claude Code and Codex turn on this machine. It must be a cheap
# silent no-op everywhere except a paired Herdr worker pane, and it must never
# fail a turn: every path exits 0.
#
# Poking is opt-in. Without ~/.config/herdr-advisor/enabled it only records the
# poke it would have sent, which is the log-only rollout phase.

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
import json, os, pathlib, subprocess, sys, time

HERDR = os.environ.get("HERDR_BIN_PATH") or "herdr"
PANE = os.environ.get("HERDR_PANE_ID", "")
TAB = os.environ.get("HERDR_TAB_ID", "")
CFG = pathlib.Path.home() / ".config" / "herdr-advisor"
LOG = pathlib.Path.home() / "Library" / "Logs" / "herdr-advisor.log"

# Thrash signature: a healthy pair re-arms at most once per worker turn.
BURST_N, BURST_WINDOW_S = 5, 600

SKILL = "~/.agents/skills/herdr-advisor/SKILL.md"


def log(action, **fields):
    rec = {"ts": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "unix": time.time(),
           "worker_pane": PANE, "action": action}
    rec.update(fields)
    try:
        LOG.parent.mkdir(parents=True, exist_ok=True)
        with LOG.open("a", encoding="utf-8") as fh:
            fh.write(json.dumps(rec) + "\n")
    except Exception:
        pass  # a hook that cannot log still must not fail the turn
    return rec


def herdr(*args, timeout=10):
    """Run herdr and parse its JSON. The CLI prefixes a terminal escape, so the
    document starts at the first brace rather than at byte zero."""
    out = subprocess.run([HERDR, *args], capture_output=True, text=True,
                         timeout=timeout)
    if out.returncode != 0:
        raise RuntimeError((out.stderr or out.stdout or "").strip()[:200])
    i = out.stdout.find("{")
    if i < 0:
        raise RuntimeError("no JSON in herdr output")
    return json.loads(out.stdout[i:])


def recent_pokes(advisor_pane):
    """How many pokes this pair has taken inside the burst window."""
    try:
        with LOG.open(encoding="utf-8") as fh:
            lines = fh.readlines()[-400:]
    except Exception:
        return 0
    now, n = time.time(), 0
    for line in lines:
        try:
            r = json.loads(line)
        except Exception:
            continue
        if (r.get("action") == "poked" and r.get("worker_pane") == PANE
                and r.get("advisor_pane") == advisor_pane
                and now - float(r.get("unix", 0)) <= BURST_WINDOW_S):
            n += 1
    return n


def main():
    # 1. Kill switch, both granularities. Checked before any herdr call so a
    #    paused pair costs nothing.
    for flag, scope in ((CFG / "paused", "global"),
                        (CFG / f"paused.{PANE}", "pair")):
        if flag.exists():
            log("skipped-paused", scope=scope)
            return

    agents = herdr("agent", "list")["result"]["agents"]
    me = next((a for a in agents if a.get("pane_id") == PANE), None)
    if me is None:
        log("skipped-unregistered")
        return

    name = me.get("name")
    if not name:
        # Unnamed pane: the advisor's name cannot be derived. Not an error --
        # most panes on this machine are not paired workers.
        log("skipped-unnamed")
        return

    # 2. Discovery needs name AND tab to agree. Either alone has a real false
    #    positive -- a tab can hold unrelated agents, and names outlive the
    #    agents that held them -- and a mis-poke lands in a stranger's pane.
    want = f"{name}-advisor"
    by_name = [a for a in agents if a.get("name") == want]
    advisor = next((a for a in by_name if a.get("tab_id") == TAB), None)
    if advisor is None:
        log("skipped-no-advisor", worker=name, want=want,
            name_matches=len(by_name),
            reason="tab-mismatch" if by_name else "absent")
        return

    status = advisor.get("agent_status")
    apane = advisor.get("pane_id")

    # 3. `working` means the loop is alive and needs nothing. This same gate is
    #    what keeps us off `herdr agent prompt`'s turn-attribution hazard: it
    #    cannot tell whose turn a wait matched, so we only ever inject into an
    #    agent that is not mid-turn.
    if status not in ("idle", "done"):
        log("skipped-advisor-busy", worker=name, advisor=want,
            advisor_pane=apane, advisor_status=status)
        return

    nudge = (
        f"Re-read {SKILL} first, then resume. You are the read-only advisor for "
        f"worker {name} (pane {PANE}), which is now {status} at turn "
        f"{me.get('turn')}. Your next-task loop is not running -- continue it, "
        f"and keep it running across worker turns rather than ending your turn. "
        f"Relay to the user only what an agent cannot answer."
    )

    # 4. Log-only until explicitly enabled.
    if not (CFG / "enabled").exists():
        log("would-poke", worker=name, advisor=want, advisor_pane=apane,
            advisor_status=status, worker_turn=me.get("turn"))
        return

    prior = recent_pokes(apane)
    try:
        herdr("agent", "prompt", want, nudge, timeout=20)
    except Exception as exc:
        msg = str(exc)
        # A dead advisor process is detected here and reported, never relaunched:
        # the launch recipes are the read-only flags, and an agent crashing at
        # startup would be relaunched on every worker turn with no ceiling.
        dead = "agent_not_running" in msg or "agent_not_found" in msg
        log("poke-failed", worker=name, advisor=want, advisor_pane=apane,
            dead=dead, error=msg[:200])
        if dead:
            notify("Herdr advisor is gone",
                   f"{want} did not answer; {name} is running unwatched.")
        return

    log("poked", worker=name, advisor=want, advisor_pane=apane,
        advisor_status=status, worker_turn=me.get("turn"))

    if prior + 1 >= BURST_N:
        notify("Herdr advisor re-arm thrash",
               f"{want} re-armed {prior + 1}x in {BURST_WINDOW_S // 60}m. "
               f"Pause: touch ~/.config/herdr-advisor/paused.{PANE}")


def notify(title, body):
    try:
        subprocess.run([HERDR, "notification", "show", title, "--body", body],
                       capture_output=True, timeout=10)
    except Exception:
        pass


try:
    main()
except Exception as exc:
    log("error", error=f"{type(exc).__name__}: {exc}"[:300])
PY

printf '{}'
exit 0

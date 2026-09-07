#!/bin/sh
# herdr-rename-agent.sh — mirror a coding agent's session title onto Herdr: agent name, pane label, tab label.
#
# Serves two agents from one script: Claude Code and Codex. Both call it as a lifecycle hook and
# it renames the calling pane the same way; only the way a rename is *noticed* differs.
# Custom hook that lives beside Herdr's managed herdr-agent-state.sh (which must not be edited).
# Source of truth: ~/github.com/soulmachine/skills/herdr-rename-hook/scripts/ (git, fanned out by
# agentstow; ~/.claude/skills/herdr-rename-hook links to it) — edit there and re-run its install.sh.
#
# Wired from ~/.claude/settings.json (Claude Code):
#   SessionStart : bash ~/.claude/hooks/herdr-rename-agent.sh session
#                  registers the watch path below; for a resumed session that already has a
#                  title it also fills in what is still blank in this pane: an unnamed Herdr
#                  agent gets the title's slug, an unlabelled pane and its tab get the title.
#   FileChanged  : bash ~/.claude/hooks/herdr-rename-agent.sh changed
#                  fires after /rename and renames this pane's Herdr agent, the pane and its tab.
# Wired from ~/.codex/hooks.json (Codex), pointing at the same installed script:
#   SessionStart : bash ~/.claude/hooks/herdr-rename-agent.sh codex-session
#                  starts the detached watcher below.
#
# How it works, Claude Code: it has no rename hook event, but /rename persists the title to
#   ~/.claude/projects/<project>/<session_id>/custom-title.json
# The SessionStart action returns that path as a FileChanged watch path
# (hookSpecificOutput.watchPaths). When the file is written, the FileChanged action reads
# the title and renames.
#
# How it works, Codex: it has no FileChanged event at all (its events are PreToolUse,
# PermissionRequest, PostToolUse, Pre/PostCompact, SessionStart, SessionEnd, UserPromptSubmit,
# SubagentStart/Stop, Stop, Interrupt), so nothing can be watched for us. /rename appends
#   {"id": <session>, "thread_name": <name>, "updated_at": ...}
# to ~/.codex/session_index.jsonl — append-only, last line for an id wins. So the codex-session
# action spawns a detached "codex-watch" child that polls that file for its own session id and
# renames on every change. Two Codex facts shape it:
#   * SessionStart fires on the session's FIRST TURN, not at TUI launch (Codex creates a session
#     lazily), so the watcher starts a turn late and syncs whatever name the session already has.
#   * Codex titles a new thread itself on that first turn (one or two appends within seconds,
#     never again). Those are indistinguishable from a typed /rename, so a change seen within
#     CODEX_SETTLE seconds of the watcher starting is treated as the title the session arrived
#     with — it fills in blanks only and never overwrites a label someone set by hand. After that
#     window a change is a real /rename and overwrites, exactly like Claude Code's.
#
# Either way the rename runs three commands for the calling pane:
#   herdr agent rename "$HERDR_PANE_ID" <slug>   slug = title mapped to [a-z][a-z0-9_-]{0,31};
#                                                if another live agent holds it: <slug>-2 … <slug>-9
#   herdr pane rename  "$HERDR_PANE_ID" <label>  label = the title as typed, whitespace collapsed
#   herdr tab rename   <tab_id> <label>          tab_id is read live from `herdr pane get`, so a
#                                                pane moved to another tab labels the right one
# The three run independently: one failing does not stop the others. A cleared title
# (custom-title.json deleted) leaves all three names as they are.
# Outside a Herdr pane (HERDR_ENV != 1) it exits immediately and prints nothing.
# It never blocks the agent: every exit is 0. Log: ~/Library/Logs/herdr-rename-agent.log
set -u
action="${1:-}"
[ "${HERDR_ENV:-}" = 1 ] || exit 0
[ -n "${HERDR_PANE_ID:-}" ] || exit 0
command -v python3 >/dev/null 2>&1 || exit 0
case "$action" in session|changed|sync|codex-session|codex-watch) ;; *) exit 0 ;; esac

tmp=$(mktemp "${TMPDIR:-/tmp}/herdr-rename-agent.XXXXXX") || exit 0
trap 'rm -f "$tmp"' EXIT
# Hook input JSON arrives on stdin; the detached "sync" and "codex-watch" children get their
# data via env instead.
case "$action" in sync|codex-watch) ;; *) cat >"$tmp" ;; esac

HERDR_HOOK_INPUT_FILE="$tmp" HERDR_HOOK_ACTION="$action" HERDR_HOOK_SELF="$0" python3 - <<'PY' || true
import json, os, re, subprocess, sys, time, unicodedata
from datetime import datetime

ACTION = os.environ.get("HERDR_HOOK_ACTION", "")
PANE = os.environ["HERDR_PANE_ID"]
HERDR = os.environ.get("HERDR_BIN_PATH") or "/opt/homebrew/bin/herdr"
SELF = os.environ.get("HERDR_HOOK_SELF", "")
LOG = os.path.expanduser("~/Library/Logs/herdr-rename-agent.log")
SIDECAR = "custom-title.json"
RETRY_CODES = {"agent_not_found", "agent_launch_pending", "agent_pane_busy", "cli_error"}
# Codex: its append-only thread-name log, and the watcher's timings (seconds).
CODEX_INDEX = os.path.expanduser("~/.codex/session_index.jsonl")
CODEX_SETTLE = 60.0     # a name change this soon after the watcher starts is Codex's own auto-title
CODEX_POLL = 2.0        # index stat interval; the file is only read when it grows
CODEX_LIVENESS = 30.0   # how often to ask Herdr whether this pane still hosts this session
CODEX_MAX_LIFE = 24 * 3600.0


def log(msg):
    try:
        os.makedirs(os.path.dirname(LOG), exist_ok=True)
        stamp = datetime.now().astimezone().strftime("%Y-%m-%d %H:%M:%S %z")
        with open(LOG, "a", encoding="utf-8") as fh:
            fh.write(f"{stamp} [{ACTION} {PANE}] {msg}\n")
    except OSError:
        pass


def emit(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


def hook_input():
    path = os.environ.get("HERDR_HOOK_INPUT_FILE")
    if not path:
        return {}
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def read_title(path):
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return ""
    title = data.get("customTitle") if isinstance(data, dict) else None
    return title.strip() if isinstance(title, str) else ""


def slugify(title, session_id=""):
    """Map a free-form session title onto Herdr's agent-name rules: [a-z][a-z0-9_-]{0,31}."""
    s = unicodedata.normalize("NFKD", title or "").encode("ascii", "ignore").decode("ascii").lower()
    s = re.sub(r"[^a-z0-9_-]+", "-", s)
    s = re.sub(r"-{2,}", "-", s).strip("-")
    if s and not ("a" <= s[0] <= "z"):
        s = "s-" + s
    if not s:
        s = "session-" + (re.sub(r"[^a-z0-9]", "", session_id.lower())[:8] or "untitled")
    return s[:32].rstrip("-")


def labelize(title):
    """Pane/tab label: the title as typed, with runs of whitespace (newlines included) collapsed."""
    return re.sub(r"\s+", " ", title or "").strip()


def parse_reply(text):
    """The CLI's JSON reply. Inside a Herdr pane the CLI first writes a terminal-title escape
    sequence to stdout, so skip anything before the JSON object."""
    text = re.sub(r"\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)", "", text or "")
    start = text.find("{")
    if start < 0:
        return None
    try:
        out = json.loads(text[start:])
    except ValueError:
        return None
    return out if isinstance(out, dict) else None


def herdr(*args, timeout=10):
    """Run the herdr CLI. Returns (ok, parsed_stdout, error_code, message)."""
    try:
        p = subprocess.run([HERDR, *args], capture_output=True, text=True,
                           timeout=timeout, stdin=subprocess.DEVNULL)
    except (OSError, subprocess.TimeoutExpired) as exc:
        return False, None, "cli_error", str(exc)
    if p.returncode == 0:
        return True, parse_reply(p.stdout), "", ""
    text = (p.stderr or p.stdout or "").strip()
    m = re.search(r'"code"\s*:\s*"([A-Za-z0-9_]+)"', text)
    code = m.group(1) if m else f"exit_{p.returncode}"
    m = re.search(r'"message"\s*:\s*"((?:[^"\\]|\\.)*)"', text)
    msg = m.group(1) if m else text[:200]
    return False, None, code, msg


def result_obj(out, key):
    """out["result"][key] when it is a JSON object, else None."""
    res = out.get("result") if isinstance(out, dict) else None
    obj = res.get(key) if isinstance(res, dict) else None
    return obj if isinstance(obj, dict) else None


def current_pane():
    """The pane object for this pane, or None."""
    ok, out, _, _ = herdr("pane", "get", PANE, timeout=5)
    return result_obj(out, "pane") if ok else None


def current_agent():
    """(present, name, error_code) for the agent hosted by this pane."""
    ok, out, code, _ = herdr("agent", "get", PANE)
    if not ok:
        return False, None, code
    agent = result_obj(out, "agent")
    if agent is None:
        return False, None, "no_agent"
    name = agent.get("name")
    return True, (name if isinstance(name, str) and name else None), ""


def rename_to(slug, deadline):
    """Rename this pane's agent to slug, or slug-2 … slug-9 on collision. Returns (name, error)."""
    candidates = [slug] + [f"{slug[:30]}-{i}" for i in range(2, 10)]
    idx, delay = 0, 0.5
    while True:
        name = candidates[idx]
        ok, _, code, msg = herdr("agent", "rename", PANE, name)
        if ok:
            return name, ""
        if code == "agent_name_taken" and idx + 1 < len(candidates):
            idx += 1
            continue
        if code in RETRY_CODES and time.monotonic() < deadline:
            time.sleep(delay)
            delay = min(delay * 1.6, 3.0)
            continue
        return None, f"{code}: {msg}" if msg else code


def relabel(label, pane=None):
    """Label this pane and the tab it sits in. Returns (errors, tab_id); errors empty = both done."""
    errors = []
    ok, _, code, msg = herdr("pane", "rename", PANE, label, timeout=5)
    if not ok:
        errors.append(f"pane {PANE}: {code}" + (f": {msg}" if msg else ""))
    if pane is None:
        pane = current_pane()
    tab = (pane or {}).get("tab_id") or os.environ.get("HERDR_TAB_ID") or ""
    if not isinstance(tab, str) or not tab:
        errors.append(f"tab of {PANE}: not found")
        return errors, None
    ok, _, code, msg = herdr("tab", "rename", tab, label, timeout=5)
    if not ok:
        errors.append(f"tab {tab}: {code}" + (f": {msg}" if msg else ""))
    return errors, tab


def fill_blanks(title, sid, agent_wait=45.0, tag="sync"):
    """Fill in only what is blank after a title the session already had: an unlabelled pane and
    its tab get the label, an unnamed agent gets the slug. Anything already named is left alone,
    so labels set by an earlier rename or by hand survive."""
    if not title:
        return
    slug, label = slugify(title, sid), labelize(title)
    # Pane and tab first: they exist whether or not Herdr has recognised the agent yet.
    pane = current_pane()
    if pane is None:
        log(f"{tag}: pane {PANE} not found; leaving pane and tab labels")
    elif pane.get("label"):
        log(f"{tag}: pane already labelled {pane.get('label')!r}; leaving pane and tab (title {title!r})")
    else:
        errors, tab = relabel(label, pane)
        log(f"{tag}: title {title!r} -> pane {PANE} + tab {tab or '?'} labelled {label!r}"
            + (f"; failed: {'; '.join(errors)}" if errors else ""))
    deadline = time.monotonic() + agent_wait
    while True:  # wait for Herdr to recognise the agent in this pane
        present, name, code = current_agent()
        if present:
            break
        if time.monotonic() > deadline:
            log(f"{tag}: no agent recognised in {PANE} ({code}); giving up")
            return
        time.sleep(1)
    if name:
        log(f"{tag}: agent already named {name!r}; leaving it (title {title!r})")
        return
    name, err = rename_to(slug, time.monotonic() + 20)
    if name is None:
        log(f"{tag}: rename to {slug!r} failed: {err}")
    else:
        log(f"{tag}: title {title!r} -> herdr agent {name!r}")


def mirror(title, sid, announce=True, tag=""):
    """An explicit rename: agent name, pane label and tab label are all overwritten."""
    slug, label = slugify(title, sid), labelize(title)
    name, err = rename_to(slug, time.monotonic() + 8)
    errors, tab = relabel(label)
    if name is None:
        errors.insert(0, f"agent {PANE}: {err}")
    log((f"{tag}: " if tag else "")
        + f"title {title!r} -> agent {name!r}, pane {PANE} + tab {tab or '?'} labelled {label!r}"
        + (f"; failed: {'; '.join(errors)}" if errors else ""))
    if not announce:
        return
    if errors:
        emit({"systemMessage": f"Herdr: rename incomplete for '{label}' — " + "; ".join(errors)})
    elif name != slug:
        emit({"systemMessage": f"Herdr: '{slug}' is taken by another agent; this pane's agent is now '{name}'"})


def do_session():
    data = hook_input()
    if data.get("agent_id"):
        return  # subagent context: nothing to watch or rename
    sid = str(data.get("session_id") or "")
    transcript = str(data.get("transcript_path") or "")
    source = str(data.get("source") or "")
    title = data.get("session_title") or data.get("sessionTitle") or ""
    title = title.strip() if isinstance(title, str) else ""
    sidecar = None
    if sid and transcript:
        sdir = os.path.join(os.path.dirname(transcript), sid)
        try:
            # The watcher can only catch the first write if the parent directory already exists.
            os.makedirs(sdir, mode=0o700, exist_ok=True)
        except OSError as exc:
            log(f"cannot create {sdir}: {exc}")
        sidecar = os.path.join(sdir, SIDECAR)
        emit({"hookSpecificOutput": {"hookEventName": "SessionStart", "watchPaths": [sidecar]}})
        if not title:
            title = read_title(sidecar)
    else:
        log("SessionStart input has no session_id/transcript_path; not watching")
    log(f"source={source or '?'} session={sid[:8] or '?'} watch={sidecar or '-'} title={title!r}")
    if title and SELF:
        # Fill in blank Herdr names after the existing title, without holding up startup.
        spawn("sync", {"HERDR_RENAME_TITLE": title, "HERDR_RENAME_SESSION": sid})


def spawn(child_action, env_extra):
    """Run this script again, detached, so a hook never waits on Herdr."""
    if os.environ.get("HERDR_RENAME_SELFCHECK"):
        log(f"{child_action}: spawn suppressed (install.sh self-check)")
        return
    env = dict(os.environ, **env_extra)
    try:
        subprocess.Popen(["/bin/sh", SELF, child_action], env=env, start_new_session=True,
                         stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                         stderr=subprocess.DEVNULL, close_fds=True)
    except OSError as exc:
        log(f"cannot spawn {child_action} child: {exc}")


def do_sync():
    fill_blanks(os.environ.get("HERDR_RENAME_TITLE", "").strip(),
                os.environ.get("HERDR_RENAME_SESSION", ""))


def do_changed():
    data = hook_input()
    if data.get("agent_id"):
        return
    path = str(data.get("file_path") or "")
    event = str(data.get("event") or "")
    if os.path.basename(path) != SIDECAR:
        return  # some other watched file
    if event == "unlink":
        log(f"title cleared ({path}); leaving the Herdr agent, pane and tab names unchanged")
        return
    sid = str(data.get("session_id") or "")
    if sid and f"{os.sep}{sid}{os.sep}" not in path:
        log(f"warning: {path} is not under session {sid}; acting anyway")
    title = read_title(path)
    if not title:
        log(f"no title in {path}; nothing to do")
        return
    mirror(title, sid)


# ---------------------------------------------------------------- Codex ----
def codex_name(sid, tail=1 << 18):
    """The last thread_name Codex recorded for sid in its append-only session index."""
    try:
        with open(CODEX_INDEX, "rb") as fh:
            fh.seek(0, os.SEEK_END)
            size = fh.tell()
            fh.seek(max(0, size - tail))
            chunk = fh.read()
    except OSError:
        return ""
    if size > tail:
        _, _, chunk = chunk.partition(b"\n")  # drop the partial first line
    name = ""
    for line in chunk.splitlines():
        try:
            rec = json.loads(line)
        except ValueError:
            continue
        if isinstance(rec, dict) and rec.get("id") == sid:
            value = rec.get("thread_name")
            if isinstance(value, str) and value.strip():
                name = value.strip()  # append-only: the last one wins
    return name


def codex_stamp():
    try:
        st = os.stat(CODEX_INDEX)
        return (st.st_mtime_ns, st.st_size)
    except OSError:
        return None


def claim_path():
    """One watcher per pane; the file names the pid that owns it."""
    base = os.path.join(os.path.expanduser("~/.cache"), "herdr-rename")
    return os.path.join(base, re.sub(r"[^A-Za-z0-9_.-]", "_", PANE) + ".watch")


def claim_watch(sid):
    path = claim_path()
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as fh:
            json.dump({"pid": os.getpid(), "session": sid}, fh)
    except OSError as exc:
        log(f"codex watch: cannot claim {path}: {exc}")
    return path


def holds_watch(path):
    """False once a newer watcher for this pane has claimed the file."""
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh).get("pid") == os.getpid()
    except (OSError, ValueError):
        return False


def pane_hosts_session(sid):
    """False once the pane is gone, empty, or hosting a different agent session."""
    ok, out, _, _ = herdr("agent", "get", PANE)
    if not ok:
        return False
    agent = result_obj(out, "agent")
    if agent is None:
        return False
    ident = agent.get("agent_session_id")
    value = ident.get("value") if isinstance(ident, dict) else ident
    return not (isinstance(value, str) and value and value != sid)


def do_codex_session():
    data = hook_input()
    if data.get("agent_id"):
        return  # subagent context
    if str(data.get("hook_event_name") or "SessionStart") != "SessionStart":
        return
    sid = str(data.get("session_id") or "")
    source = str(data.get("source") or "")
    if not sid:
        log("codex SessionStart input has no session_id; not watching")
        return
    log(f"codex source={source or '?'} session={sid[:8]} name={codex_name(sid)!r}")
    if SELF:
        spawn("codex-watch", {"HERDR_RENAME_SESSION": sid})


def do_codex_watch():
    """Poll Codex's session index for this session's thread_name and mirror every change."""
    sid = os.environ.get("HERDR_RENAME_SESSION", "")
    if not sid:
        return
    claim = claim_watch(sid)
    started = time.monotonic()
    stamp, seen = codex_stamp(), codex_name(sid)
    log(f"codex watch: session={sid[:8]} pid={os.getpid()} baseline={seen!r}")
    if seen:
        # A name is already recorded when the watcher starts — a resumed thread, or /rename
        # typed before the first turn. Treat it like Claude Code's resume case.
        fill_blanks(seen, sid, agent_wait=20.0, tag="codex")
    next_live = started + CODEX_LIVENESS
    while time.monotonic() - started < CODEX_MAX_LIFE:
        time.sleep(CODEX_POLL)
        if not holds_watch(claim):
            log("codex watch: a newer watcher owns this pane; exiting")
            return
        now = codex_stamp()
        if now != stamp:
            stamp = now
            name = codex_name(sid)
            if name and name != seen:
                first_turn = time.monotonic() - started <= CODEX_SETTLE
                seen = name
                if first_turn:
                    # Codex names a new thread itself on its first turn. Indistinguishable from a
                    # typed /rename, so treat it as the title the session arrived with: blanks only.
                    fill_blanks(name, sid, agent_wait=10.0, tag="codex auto-title")
                else:
                    mirror(name, sid, announce=False, tag="codex")
        if time.monotonic() >= next_live:
            next_live = time.monotonic() + CODEX_LIVENESS
            if not pane_hosts_session(sid):
                log("codex watch: pane closed or session replaced; exiting")
                try:
                    os.remove(claim)
                except OSError:
                    pass
                return
    log("codex watch: max lifetime reached; exiting")


try:
    {"session": do_session, "sync": do_sync, "changed": do_changed,
     "codex-session": do_codex_session, "codex-watch": do_codex_watch}[ACTION]()
except Exception as exc:  # never block the agent
    log(f"unexpected error: {exc!r}")
PY
exit 0

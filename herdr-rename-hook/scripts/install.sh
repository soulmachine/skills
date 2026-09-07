#!/bin/sh
# install.sh — install, check or remove the herdr-rename-agent hook for $HOME, for both
# Claude Code and Codex. One installed script serves both; each agent gets its own wiring.
#
#   install.sh              install or refresh (idempotent), then self-check inside a Herdr pane
#   install.sh --check      report state only; exit 0 = fully installed, 1 = missing or drifted
#   install.sh --uninstall  remove every owned entry and the installed script
#
# Owned entries in ~/.claude/settings.json (every other hook is left exactly as it was):
#   hooks.SessionStart[]  {"matcher":"*","hooks":[{"type":"command","command":"bash '<hook>' session","timeout":10}]}
#   hooks.FileChanged[]   {"hooks":[{"type":"command","command":"bash '<hook>' changed","timeout":15}]}
# Owned entry in ~/.codex/hooks.json (Herdr's own herdr-agent-state.sh entry is left alone):
#   hooks.SessionStart[]  {"hooks":[{"type":"command","command":"bash '<hook>' codex-session","timeout":10}]}
# Codex is skipped entirely when it is not installed. Codex also needs `hooks = true` under
# [features] in ~/.codex/config.toml, and asks you to trust a new or changed hook the next time
# it starts; this script reports both rather than editing config.toml behind your back.
set -eu
mode="${1:-install}"
case "$mode" in
  install|--install) mode=install ;;
  --check) mode=check ;;
  --uninstall) mode=uninstall ;;
  *) echo "usage: install.sh [--check | --uninstall]" >&2; exit 2 ;;
esac
here=$(cd "$(dirname "$0")" && pwd)
src="$here/herdr-rename-agent.sh"
dst="$HOME/.claude/hooks/herdr-rename-agent.sh"
settings="$HOME/.claude/settings.json"
codex_hooks="$HOME/.codex/hooks.json"
codex_config="$HOME/.codex/config.toml"
command -v python3 >/dev/null 2>&1 || { echo "python3 is required (the hook itself runs on it)" >&2; exit 1; }
[ -f "$src" ] || { echo "bundled hook missing: $src" >&2; exit 1; }
if command -v codex >/dev/null 2>&1 || [ -d "$HOME/.codex" ]; then have_codex=1; else have_codex=0; fi
rc=0

case "$mode" in
  install)
    mkdir -p "$HOME/.claude/hooks"
    if [ -f "$dst" ] && cmp -s "$src" "$dst"; then
      echo "hook script: up to date ($dst)"
    else
      cp "$src" "$dst" && chmod 0755 "$dst"
      echo "hook script: installed ($dst)"
    fi ;;
  check)
    if [ ! -f "$dst" ]; then echo "hook script: missing ($dst)"; rc=1
    elif cmp -s "$src" "$dst"; then echo "hook script: ok ($dst)"
    else echo "hook script: drifted from the bundled copy (edited in place?) — run install.sh to refresh"; rc=1
    fi ;;
  uninstall)
    if [ -f "$dst" ]; then rm -f "$dst"; echo "hook script: removed ($dst)"; else echo "hook script: already absent"; fi ;;
esac

# ---- Claude Code: ~/.claude/settings.json -----------------------------------------------
HOOK_MODE="$mode" HOOK_DST="$dst" SETTINGS="$settings" python3 - <<'PY' || rc=1
import json, os, sys, time

mode, hook, path = os.environ["HOOK_MODE"], os.environ["HOOK_DST"], os.environ["SETTINGS"]
TAG = "herdr-rename-agent.sh"
WANT = {
    "SessionStart": {"matcher": "*", "hooks": [{"type": "command", "command": f"bash '{hook}' session", "timeout": 10}]},
    "FileChanged": {"hooks": [{"type": "command", "command": f"bash '{hook}' changed", "timeout": 15}]},
}


def owned(group):
    return isinstance(group, dict) and any(
        isinstance(h, dict) and TAG in str(h.get("command", "")) for h in group.get("hooks", []))


try:
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    data = json.loads(text) if text.strip() else {}
except FileNotFoundError:
    text, data = "", {}
except ValueError as exc:
    sys.exit(f"{path} is not valid JSON ({exc}); fix it first — nothing was changed")
if not isinstance(data, dict):
    sys.exit(f"{path}: top level is not a JSON object; nothing was changed")
hooks = data.get("hooks")
if hooks is None:
    hooks = {}
if not isinstance(hooks, dict):
    sys.exit(f"{path}: 'hooks' is not an object; nothing was changed")

state = {}
for event, want in WANT.items():
    groups = hooks.get(event) or []
    mine = [g for g in groups if owned(g)]
    state[event] = "ok" if any(g == want for g in mine) else ("stale" if mine else "missing")

if mode == "check":
    for event, st in state.items():
        print(f"settings {event}: {st}")
    sys.exit(0 if all(st == "ok" for st in state.values()) else 1)

target = "ok" if mode == "install" else "missing"
todo = [e for e in WANT if state[e] != target]
for event in todo:
    groups = [g for g in (hooks.get(event) or []) if not owned(g)]
    if mode == "install":
        groups.append(WANT[event])
    if groups:
        hooks[event] = groups
    else:
        hooks.pop(event, None)
if todo:
    if hooks:
        data["hooks"] = hooks
    else:
        data.pop("hooks", None)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    if text:
        backup = f"{path}.bak-herdr-rename-{time.strftime('%Y%m%d%H%M%S')}"
        with open(backup, "w", encoding="utf-8") as fh:
            fh.write(text)
        print(f"settings backup: {backup}")
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(json.dumps(data, indent=2, ensure_ascii=False) + "\n")
    os.replace(tmp, path)
verb = "installed" if mode == "install" else "removed"
for event in WANT:
    print(f"settings {event}: {verb}" + ("" if event in todo else " (already)"))
PY

# ---- Codex: ~/.codex/hooks.json + the [features] hooks switch ----------------------------
if [ "$have_codex" = 1 ]; then
  HOOK_MODE="$mode" HOOK_DST="$dst" CODEX_HOOKS="$codex_hooks" CODEX_CONFIG="$codex_config" python3 - <<'PY' || rc=1
import json, os, sys, time

mode, hook = os.environ["HOOK_MODE"], os.environ["HOOK_DST"]
path, config = os.environ["CODEX_HOOKS"], os.environ["CODEX_CONFIG"]
TAG = "herdr-rename-agent.sh"
# Codex has no FileChanged event, so SessionStart is the only wiring; it starts the watcher.
WANT = {"hooks": [{"type": "command", "command": f"bash '{hook}' codex-session", "timeout": 10}]}


def owned(group):
    return isinstance(group, dict) and any(
        isinstance(h, dict) and TAG in str(h.get("command", "")) for h in group.get("hooks", []))


def feature_on():
    """Codex only runs hooks when [features] hooks = true."""
    try:
        with open(config, "rb") as fh:
            raw = fh.read()
    except OSError:
        return None
    try:
        import tomllib
        return bool((tomllib.loads(raw.decode("utf-8")).get("features") or {}).get("hooks"))
    except Exception:
        import re
        block = re.split(r"^\[", raw.decode("utf-8", "replace"), flags=re.M)
        return any(b.startswith("features]") and re.search(r"^\s*hooks\s*=\s*true", b, re.M) for b in block)


try:
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    data = json.loads(text) if text.strip() else {}
except FileNotFoundError:
    text, data = "", {}
except ValueError as exc:
    sys.exit(f"{path} is not valid JSON ({exc}); fix it first — nothing was changed")
if not isinstance(data, dict):
    sys.exit(f"{path}: top level is not a JSON object; nothing was changed")
hooks = data.get("hooks") or {}
if not isinstance(hooks, dict):
    sys.exit(f"{path}: 'hooks' is not an object; nothing was changed")

groups = hooks.get("SessionStart") or []
mine = [g for g in groups if owned(g)]
state = "ok" if any(g == WANT for g in mine) else ("stale" if mine else "missing")
on = feature_on()

if mode == "check":
    print(f"codex SessionStart: {state}")
    print("codex hooks feature: " + {True: "enabled", False: "DISABLED — add 'hooks = true' under [features] in "
                                            + config, None: "unknown (" + config + " unreadable)"}[on])
    sys.exit(0 if state == "ok" and on is not False else 1)

if state != ("ok" if mode == "install" else "missing"):
    kept = [g for g in groups if not owned(g)]
    if mode == "install":
        kept.append(WANT)
    if kept:
        hooks["SessionStart"] = kept
    else:
        hooks.pop("SessionStart", None)
    if hooks:
        data["hooks"] = hooks
    else:
        data.pop("hooks", None)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    if text:
        backup = f"{path}.bak-herdr-rename-{time.strftime('%Y%m%d%H%M%S')}"
        with open(backup, "w", encoding="utf-8") as fh:
            fh.write(text)
        print(f"codex hooks backup: {backup}")
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(json.dumps(data, indent=2, ensure_ascii=False) + "\n")
    os.replace(tmp, path)
    print("codex SessionStart: " + ("installed" if mode == "install" else "removed")
          + " — Codex asks you to trust a new or changed hook the next time it starts")
else:
    print("codex SessionStart: " + ("installed" if mode == "install" else "removed") + " (already)")
if mode == "install" and on is False:
    print(f"codex hooks feature: DISABLED — hooks will not run until 'hooks = true' is set under [features] in {config}")
PY
else
  echo "codex: not installed, skipped"
fi

# ---- self-checks -------------------------------------------------------------------------
if [ "$mode" = install ] && [ "$rc" = 0 ]; then
  if [ "${HERDR_ENV:-}" = 1 ] && [ -n "${HERDR_PANE_ID:-}" ]; then
    tmpd=$(mktemp -d "${TMPDIR:-/tmp}/herdr-rename-selfcheck.XXXXXX")
    sid=selfcheck-0000-0000-0000-000000000000
    out=$(printf '{"session_id":"%s","transcript_path":"%s/proj/%s.jsonl","hook_event_name":"SessionStart","source":"startup"}' \
          "$sid" "$tmpd" "$sid" | bash "$dst" session) || true
    case "$out" in
      *watchPaths*"$tmpd/proj/$sid/custom-title.json"*)
        echo "self-check: OK (SessionStart registers the custom-title.json watch path)" ;;
      *)
        echo "self-check: FAILED — expected a watchPaths line from '$dst session', got: ${out:-<nothing>}" >&2; rc=1 ;;
    esac
    if [ "$have_codex" = 1 ]; then
      log="$HOME/Library/Logs/herdr-rename-agent.log"
      before=$( [ -f "$log" ] && wc -c <"$log" || echo 0 )
      # Codex must receive nothing on stdout, and the action must reach its spawn point.
      out=$(printf '{"session_id":"%s","transcript_path":"%s/rollout.jsonl","cwd":"%s","hook_event_name":"SessionStart","source":"startup"}' \
            "$sid" "$tmpd" "$tmpd" | HERDR_RENAME_SELFCHECK=1 bash "$dst" codex-session) || true
      added=$( [ -f "$log" ] && dd if="$log" bs=1 skip="$before" 2>/dev/null || echo "" )
      if [ -n "$out" ]; then
        echo "self-check: FAILED — 'codex-session' wrote to stdout, which Codex parses: $out" >&2; rc=1
      else
        case "$added" in
          *"codex-watch: spawn suppressed"*)
            echo "self-check: OK (codex SessionStart starts the session-index watcher)" ;;
          *)
            echo "self-check: FAILED — 'codex-session' did not reach its watcher; log added: ${added:-<nothing>}" >&2; rc=1 ;;
        esac
      fi
    fi
    rm -rf "$tmpd"
  else
    echo "self-check: skipped (not inside a Herdr pane; the hook is silent outside Herdr)"
  fi
fi

if [ "$rc" = 0 ]; then
  case "$mode" in
    install) echo "installed. Claude Code sessions already running load hooks at startup: open /hooks once or restart them. Codex asks you to trust the hook the next time it starts. Log: ~/Library/Logs/herdr-rename-agent.log" ;;
    check) echo "installed" ;;
    uninstall) echo "uninstalled. Sessions already running keep the old hook config until /hooks or a restart; a Codex watcher already running exits when its pane closes." ;;
  esac
fi
exit "$rc"

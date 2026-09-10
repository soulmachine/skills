#!/usr/bin/env python3
"""Export paseo agent profiles from one host and merge them into another's config.

paseo has no profile export/import command: the profiles live as a JSON array at
daemon.agentProfiles in ~/.paseo/config.json.  That file also holds host-specific
settings (listen address, relay toggle, daemon password hash), so the transfer has
to be a key-scoped merge rather than a file copy.

Stdlib only, so the same file runs on both ends of an ssh pipe.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

ENVELOPE_VERSION = 1
DEFAULT_CONFIG = Path.home() / ".paseo" / "config.json"

PROFILES_PATH = "daemon.agentProfiles"

# Scalar settings carried alongside the profiles.  Everything else in the target
# config -- daemon.listen, daemon.relay.enabled, daemon.cors, app.baseUrl, any
# password hash -- is read, left alone, and written back verbatim.
SYNCED_SETTINGS = (
    "daemon.mcp.injectIntoAgents",
    "daemon.browserTools.enabled",
    "agents.providers.omp.enabled",
)

# paseo is not on the non-interactive ssh PATH on every host.  Hosts moved off
# Paseo.app run the npm CLI through a mise shim; the two Homebrew paths and the
# app bundle cover hosts still on the desktop app, whose Homebrew binary is
# itself only a symlink into that bundle.
PASEO_FALLBACKS = (
    os.path.expanduser("~/.local/share/mise/shims/paseo"),
    "/opt/homebrew/bin/paseo",
    "/usr/local/bin/paseo",
    "/Applications/Paseo.app/Contents/Resources/bin/paseo",
)

# Remote staging path for `push`; per-uid so a shared host has no permission clash.
REMOTE_SCRIPT = '/tmp/paseo-profiles-$(id -u).py'


def die(msg: str) -> "NoReturn":  # noqa: F821
    print(f"error: {msg}", file=sys.stderr)
    raise SystemExit(2)


# --------------------------------------------------------------------------- paths


def dig(obj, dotted: str):
    """Read a dotted path, or None if any segment is missing."""
    cur = obj
    for key in dotted.split("."):
        if not isinstance(cur, dict) or key not in cur:
            return None
        cur = cur[key]
    return cur


def plant(obj: dict, dotted: str, value) -> None:
    """Write a dotted path, creating intermediate dicts as needed."""
    keys = dotted.split(".")
    cur = obj
    for key in keys[:-1]:
        nxt = cur.get(key)
        if not isinstance(nxt, dict):
            nxt = {}
            cur[key] = nxt
        cur = nxt
    cur[keys[-1]] = value


def touches(reported: str, watched) -> bool:
    """True if a path paseo reported overlaps one of ours (either may be a parent)."""
    return any(
        w == reported or w.startswith(reported + ".") or reported.startswith(w + ".")
        for w in watched
    )


# --------------------------------------------------------------------------- merge


def merge_profiles(existing, incoming):
    """Merge incoming profiles into existing, keyed on id then name.

    id match      -> replace in place (only counted when the content differs, so a
                     repeat import is a no-op)
    name match    -> replace that slot, incoming id wins; importing "Software
                     Engineer" must not leave the target holding two of them
    neither       -> append

    Profiles only the target has are never deleted.
    """
    merged = [dict(p) for p in existing]
    stats = {"added": [], "updated": [], "replaced": []}

    for prof in incoming:
        pid = prof.get("id")
        name = prof.get("name")

        hit = next((i for i, p in enumerate(merged) if pid and p.get("id") == pid), None)
        if hit is not None:
            if merged[hit] != prof:
                merged[hit] = dict(prof)
                stats["updated"].append(name or pid)
            continue

        hit = next((i for i, p in enumerate(merged) if name and p.get("name") == name), None)
        if hit is not None:
            merged[hit] = dict(prof)
            stats["replaced"].append(name)
            continue

        merged.append(dict(prof))
        stats["added"].append(name or pid)

    return merged, stats


# --------------------------------------------------------------------------- config io


def load_config(path: Path) -> dict:
    if not path.exists():
        return {"version": 1}
    try:
        return json.loads(path.read_text())
    except json.JSONDecodeError as exc:
        die(f"{path} is not valid JSON: {exc}")


def save_config(path: Path, config: dict):
    """Back up, then write atomically at 0600 (the real file holds secrets)."""
    path.parent.mkdir(parents=True, exist_ok=True)

    backup = None
    if path.exists():
        stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        backup = path.with_name(f"{path.name}.bak-{stamp}")
        shutil.copy2(path, backup)

    fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix=".paseo-config-", suffix=".json")
    try:
        with os.fdopen(fd, "w") as fh:
            json.dump(config, fh, indent=2, ensure_ascii=False)
            fh.write("\n")
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    except BaseException:
        Path(tmp).unlink(missing_ok=True)
        raise

    return backup


def build_envelope(config: dict) -> dict:
    settings = {p: dig(config, p) for p in SYNCED_SETTINGS}
    return {
        "version": ENVELOPE_VERSION,
        "source": socket.gethostname(),
        "exportedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "profiles": dig(config, PROFILES_PATH) or [],
        "settings": {k: v for k, v in settings.items() if v is not None},
    }


# --------------------------------------------------------------------------- reload


def reload_daemon(host: str) -> None:
    paseo = shutil.which("paseo") or next(
        (p for p in PASEO_FALLBACKS if os.access(p, os.X_OK)), None
    )
    if not paseo:
        print(f"[{host}] paseo binary not found; restart the daemon to apply")
        return

    proc = subprocess.run(
        [paseo, "daemon", "reload", "--json"], capture_output=True, text=True
    )
    if proc.returncode != 0:
        print(f"[{host}] daemon not running; profiles load on next start")
        return

    try:
        result = json.loads(proc.stdout)
    except json.JSONDecodeError:
        print(f"[{host}] daemon reloaded")
        return

    watched = (PROFILES_PATH, *SYNCED_SETTINGS)
    restart = [p for p in result.get("restartRequiredPaths") or [] if touches(p, watched)]
    override = [p for p in result.get("overrideControlledPaths") or [] if touches(p, watched)]

    print(f"[{host}] daemon reloaded")
    if restart:
        print(f"[{host}] restart required for {', '.join(restart)} -> paseo daemon restart")
    if override:
        print(f"[{host}] WARNING override-controlled, edit may be ignored: {', '.join(override)}")


# --------------------------------------------------------------------------- commands


def do_export(args) -> int:
    envelope = build_envelope(load_config(args.config))
    text = json.dumps(envelope, indent=2, ensure_ascii=False) + "\n"

    if args.output and args.output != "-":
        Path(args.output).write_text(text)
        print(f"exported {len(envelope['profiles'])} profile(s) -> {args.output}", file=sys.stderr)
    else:
        sys.stdout.write(text)
    return 0


def do_import(args) -> int:
    raw = (
        Path(args.input).read_text()
        if args.input and args.input != "-"
        else sys.stdin.read()
    )
    if not raw.strip():
        die("no export data on stdin")
    try:
        envelope = json.loads(raw)
    except json.JSONDecodeError as exc:
        die(f"export data is not valid JSON: {exc}")

    if envelope.get("version") != ENVELOPE_VERSION:
        die(f"unsupported export version {envelope.get('version')!r}, expected {ENVELOPE_VERSION}")

    host = socket.gethostname()
    config = load_config(args.config)
    before = json.dumps(config, sort_keys=True)

    existing = dig(config, PROFILES_PATH) or []
    merged, stats = merge_profiles(existing, envelope.get("profiles") or [])
    if merged:
        plant(config, PROFILES_PATH, merged)

    touched_settings = []
    for path, value in (envelope.get("settings") or {}).items():
        if path not in SYNCED_SETTINGS:
            continue  # never write a path this version does not know about
        if dig(config, path) != value:
            plant(config, path, value)
            touched_settings.append(f"{path}={json.dumps(value)}")

    if json.dumps(config, sort_keys=True) == before:
        print(f"[{host}] no changes ({len(merged)} profile(s) already current)")
        return 0

    counts = ", ".join(f"{k} {len(v)}" for k, v in stats.items() if v) or "profiles unchanged"
    print(f"[{host}] {counts}")
    for kind, names in stats.items():
        for name in names:
            print(f"[{host}]   {kind:8} {name}")
    for setting in touched_settings:
        print(f"[{host}]   setting  {setting}")

    if args.dry_run:
        print(f"[{host}] dry run, {args.config} not written")
        return 0

    backup = save_config(args.config, config)
    tail = f" (backup {backup.name})" if backup else ""
    print(f"[{host}] wrote {args.config}{tail}")

    if not args.no_reload:
        reload_daemon(host)
    return 0


def do_push(args) -> int:
    envelope = build_envelope(load_config(args.config))
    if not envelope["profiles"]:
        die(f"no profiles at {PROFILES_PATH} in {args.config}")
    payload = json.dumps(envelope) + "\n"
    source = Path(__file__).read_text()

    flags = ""
    if args.dry_run:
        flags += " --dry-run"
    if args.no_reload:
        flags += " --no-reload"

    print(
        f"pushing {len(envelope['profiles'])} profile(s) from {envelope['source']} "
        f"to {len(args.hosts)} host(s)",
        flush=True,  # subprocesses write straight to the fd; don't print out of order
    )

    rc = 0
    for host in args.hosts:
        # The remote labels its own output with its hostname, which need not
        # resemble the ssh target ("Mac" for macbook-pro-nickel); name the
        # target so a fleet push stays readable.
        print(f"--- {host}", flush=True)
        try:
            subprocess.run(
                ["ssh", host, f'p={REMOTE_SCRIPT}; cat > "$p"'],
                input=source, text=True, check=True,
            )
            subprocess.run(
                ["ssh", host, f'p={REMOTE_SCRIPT}; python3 "$p" import{flags}'],
                input=payload, text=True, check=True,
            )
        except subprocess.CalledProcessError as exc:
            print(f"[{host}] FAILED (exit {exc.returncode})", file=sys.stderr)
            rc = 1
    return rc


def do_selftest(args) -> int:
    base = [
        {"id": "a", "name": "Architect", "model": "old"},
        {"id": "local", "name": "Local Only", "model": "keep"},
    ]
    incoming = [
        {"id": "a", "name": "Architect", "model": "new"},      # id hit, changed
        {"id": "b2", "name": "Local Only", "model": "fresh"},  # name hit, other id
        {"id": "c", "name": "Writer", "model": "x"},           # novel
    ]

    merged, stats = merge_profiles(base, incoming)
    assert [p["id"] for p in merged] == ["a", "b2", "c"], merged
    assert merged[0]["model"] == "new"
    assert stats == {"added": ["Writer"], "updated": ["Architect"], "replaced": ["Local Only"]}, stats

    again, stats2 = merge_profiles(merged, incoming)
    assert again == merged, "merge is not idempotent"
    assert stats2 == {"added": [], "updated": [], "replaced": []}, stats2

    keep, stats3 = merge_profiles(base, [])
    assert keep == base and not any(stats3.values())

    cfg = {"daemon": {"relay": {"enabled": False}}}
    plant(cfg, "daemon.mcp.injectIntoAgents", True)
    assert cfg["daemon"]["relay"]["enabled"] is False, "unrelated key clobbered"
    assert dig(cfg, "daemon.mcp.injectIntoAgents") is True
    assert dig(cfg, "daemon.nope.deep") is None

    assert touches("daemon", (PROFILES_PATH,))
    assert touches("daemon.agentProfiles", (PROFILES_PATH,))
    assert not touches("daemon.relay.enabled", (PROFILES_PATH,))

    print("selftest ok")
    return 0


# --------------------------------------------------------------------------- cli


def main(argv=None) -> int:
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--config", type=Path, default=DEFAULT_CONFIG,
                        help="paseo config.json (default: %(default)s)")
    common.add_argument("--dry-run", action="store_true", help="report changes, write nothing")
    common.add_argument("--no-reload", action="store_true", help="skip paseo daemon reload")

    parser = argparse.ArgumentParser(
        prog="paseo-profiles", description=__doc__.splitlines()[0]
    )
    subs = parser.add_subparsers(dest="cmd", required=True)

    p = subs.add_parser("export", parents=[common], help="write this host's profiles as JSON")
    p.add_argument("-o", "--output", help="output file (default: stdout)")
    p.set_defaults(func=do_export)

    p = subs.add_parser("import", parents=[common], help="merge exported profiles into this host")
    p.add_argument("input", nargs="?", help="export file (default: stdin)")
    p.set_defaults(func=do_import)

    p = subs.add_parser("push", parents=[common], help="export here, import on remote hosts over ssh")
    p.add_argument("hosts", nargs="+", help="ssh targets")
    p.set_defaults(func=do_push)

    p = subs.add_parser("selftest", parents=[common], help="check the merge logic")
    p.set_defaults(func=do_selftest)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())

---
name: sync-claude-accounts
description: Distributes a Claude Code accounts export (claude-accounts.json) to one or more macOS machines, imports it into claude-swap, and registers every discovered account with cux. Use when syncing or propagating Claude Code logins across Macs or a fleet, or when the user mentions claude-accounts.json, accounts.json, cswap import, cux add, claude-swap, or adding multiple Claude accounts to remote machines.
---

# Sync Claude Accounts

Push a claude-swap export to N macOS machines and register every account with cux.
Accounts are **auto-discovered** from the export — no email addresses are hardcoded.

## Quick start

```bash
scripts/push-claude-accounts ~/Downloads/claude-accounts.json \
    127.0.0.1 mac-mini-m2 archs-mac-mini 10.0.0.42
```

Per machine this: uploads the file to `/tmp/claude-accounts.json` (mode 600), installs
`~/.local/bin/sync-claude-accounts` if absent, runs it, and deletes the credentials file.
`127.0.0.1` / `localhost` / `local` / the machine's own hostname are handled with `cp`
and direct execution — no SSH.

To run the per-machine step alone (already on the box):

```bash
~/.local/bin/sync-claude-accounts            # defaults to /tmp/claude-accounts.json
```

## What the per-machine script does

1. Preflight `cswap` + `cux` (including that cux's native binary really downloaded).
2. `cswap import <file>`.
3. Unlock the login keychain if needed.
4. Discover all accounts via `cswap list --json`.
5. For each: `cswap switch <email> --force` then `cux add`.
6. Restore whichever account was active before, and delete the credentials file.

## Non-obvious constraints

These are the failure modes this skill exists to encode — do not "simplify" them away:

- **`cux add` only captures the currently logged-in account.** Registering N accounts
  requires making each one live first. There is no flag to feed it credentials directly.
- **`cswap switch` needs `--force`.** Switching to an account that is *already active*
  prints `Already on Account-N` and declines to rewrite the live login from the stored
  backup — so `cux add` would silently capture **stale** credentials.
- **The macOS login keychain is locked in SSH sessions.** `cux add` reads it directly and
  dies with `security find-generic-password ... exit 36` (`errSecInteractionNotAllowed`).
  It does *not* fall back to `~/.claude/.credentials.json`, and no env var forces file
  mode. `cswap` degrades gracefully, so import still works. Fix with
  `~/.claude/unlock-keychain.sh` — see the `ssh-keychain-unlock` skill.
- **Never pipe `cswap import`.** `cswap import f | tail -1 && ...` takes its exit status
  from `tail`, masking `import file not found` and continuing as if it worked.
- **`cux`'s npm postinstall soft-fails with exit 0.** It downloads a native binary from
  GitHub releases; on failure `npm install` still reports success. Verify with `cux version`.
- **`cswap import` skips accounts that already exist** unless `--force`, but it *does*
  auto-heal slots quarantined as refresh-token-dead. A "0 imported, 2 skipped" result is
  normal and usually fine; use `--force` only to make the export authoritative.

## Prerequisites per machine

`uv tool install claude-swap` and `npm install -g @inulute/cux` (which needs Node ≥18 —
`brew install node`). `jq` is used when present; otherwise `/usr/bin/python3` is the fallback.

## Options

| Env | Effect |
|---|---|
| `FORCE_INSTALL=1` | Reinstall `~/.local/bin/sync-claude-accounts` even if present (use after editing it) |
| `KEEP_ACCOUNTS_FILE=1` | Leave the credentials file in place instead of deleting it |

Exit codes from the per-machine script: `0` ok, `1` preflight/import failure,
`2` keychain locked (import still succeeded), `3` one or more accounts failed.

## Security

The export holds **unencrypted OAuth credentials**. It is written mode 600 and deleted
after import by default. Encrypted exports are rejected up front.

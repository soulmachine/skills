# Reference — Claude Code auth on a headless Mac over SSH

Detailed material for the [SKILL.md](SKILL.md) workflow. Read this when the user wants the no-stored-password variant, a manual walkthrough, or to tear the setup down.

## Approach B, lighter variant — interactive unlock, no stored password

If the user is fine typing their macOS password once per SSH session (and doesn't want it stored on disk), skip the scripts entirely and add this to `~/.zshrc`:

```bash
# Unlock the login keychain for SSH sessions (Claude Code auth)
if [[ -n "$SSH_CONNECTION" ]]; then
  security unlock-keychain ~/Library/Keychains/login.keychain-db
fi
```

Simple and stores no secret, but prompts on every new SSH session and doesn't cover non-interactive contexts (cron, launchd jobs).

## Approach B, manual walkthrough

What `setup-keychain-unlock.sh` does — for auditing it before trusting it with a password, or doing the setup by hand:

1. **Password file** (`~/.claude/.keychain-password`, perms `600`) — the macOS login password in plaintext. Created under `umask 077` so it is never briefly world-readable.
2. **Unlock script** (`~/.claude/unlock-keychain.sh`, perms `700`):
   ```bash
   #!/bin/bash
   PW_FILE="$HOME/.claude/.keychain-password"
   [ -f "$PW_FILE" ] || exit 1
   exec security unlock-keychain -p "$(cat "$PW_FILE")" "$HOME/Library/Keychains/login.keychain-db"
   ```
3. **LaunchAgent** (`~/Library/LaunchAgents/com.claude.unlock-keychain.plist`) with label `com.claude.unlock-keychain`, `ProgramArguments` = `/bin/bash <unlock-script>`, and `RunAtLoad` true — unlocks at login for non-interactive contexts.
4. **Load it**: `launchctl bootstrap gui/$(id -u) <plist>` (modern) or `launchctl load <plist>` (legacy). A LaunchAgent only runs once the user has a login/Aqua session, so boot-time unlock needs auto-login enabled; the `.zshrc` hook covers the plain SSH-login case regardless.
5. **`.zshrc` hook** so each SSH login unlocks too:
   ```bash
   if [[ -n "$SSH_CONNECTION" && -x "$HOME/.claude/unlock-keychain.sh" ]]; then
     "$HOME/.claude/unlock-keychain.sh" 2>/dev/null
   fi
   ```

## Marker blocks

Everything the setup scripts add to `~/.zshrc` is wrapped in marker comments — `# >>> claude oauth token >>>` / `# >>> claude keychain unlock >>>` (with matching `# <<< … <<<` closers) — so re-runs are idempotent and teardowns surgical. The marker strings are defined once in `scripts/lib.sh` and must never change, or teardown of blocks written by older versions breaks.

## Command quick reference

| Command | Purpose |
|---|---|
| `security show-keychain-info ~/Library/Keychains/login.keychain-db` | Check keychain lock status |
| `security unlock-keychain ~/Library/Keychains/login.keychain-db` | Manually unlock (interactive) |
| `security find-generic-password -s "Claude Code-credentials" …` | Confirm Claude Code creds live in the keychain |
| `claude setup-token` | Mint a ~1-year OAuth token (Approach A) |
| `bash ~/.claude/unlock-keychain.sh` | Test the auto-unlock script (Approach B) |
| `launchctl bootstrap gui/$(id -u) <plist>` / `launchctl bootout gui/$(id -u)/<label>` | Load / unload the LaunchAgent |

## Common mistakes

- **Reaching for `sudo`.** Root can read the encrypted keychain file but can't decrypt it without the password — unlocking is decryption, not a permission check.
- **Wrong permissions on the secret file.** `~/.claude/.keychain-password` and `~/.claude/.oauth-token.zsh` must be `600`. The scripts create them under `umask 077` so they're never momentarily world-readable.
- **Password / token out of sync.** Approach B: update the password file whenever the macOS account password changes. Approach A: re-run `claude setup-token` when the ~1-year token expires.
- **Expecting the LaunchAgent to run with nobody logged in.** LaunchAgents need a login session; without auto-login only the `.zshrc` hook fires (on SSH login).
- **Forgetting `claude --bare`.** It ignores `CLAUDE_CODE_OAUTH_TOKEN`; use `ANTHROPIC_API_KEY` there.

## Teardown / switching approaches

Both directions are scripted; run the new setup first, then the old teardown:

- **B → A**: `teardown-keychain-unlock.sh` unloads the LaunchAgent and deletes the unlock script, plist, **the plaintext password file**, and the marked `~/.zshrc` block.
- **A → B**: `teardown-oauth-token.sh` deletes `~/.claude/.oauth-token.zsh` and its marked `~/.zshrc` block; Claude Code falls back to the keychain.

Hooks added to `~/.zshrc` by hand (without the marker comments) must be removed manually — the teardown scripts only delete their own marked blocks.

---
name: refresh-claude-account
description: Refresh an expired Claude Code account out-of-band — mint a fresh long-lived token with `claude setup-token` and register it with `cswap add-token` — so the machine-global login and every running Claude session stay untouched. Use when `cux status` shows an account as EXPRD, when `cswap list` says "re-login needed — refresh token dead", when the user asks to refresh or re-authenticate an expired Claude account without interrupting running sessions, or when converting an account to a long-lived setup-token so its refresh token can never die again.
---

# Refresh an expired Claude account (out-of-band)

`cux switch` / `cswap switch` rewrite the **machine-global** credentials, so every running
Claude session flips accounts — or starts failing while the target's creds are still dead —
on its next API call. `claude setup-token` instead runs its own OAuth flow in the browser
and only **prints** a token; the live login is never touched. This skill uses that
out-of-band route: running sessions keep working throughout.

## OAuth login vs setup-token

Both are OAuth credentials for the same subscription. The difference is what you receive and what
it is allowed to do.

| | `claude /login` (OAuth login) | `claude setup-token` |
|---|---|---|
| **What you get** | A bundle: `accessToken` + `refreshToken` + `expiresAt` + `scopes` | One bearer token, printed once |
| **Access token life** | ~8 hours | ~1 year |
| **Renewal** | Automatic — Claude Code silently refreshes | None; re-mint when it dies |
| **Scopes** | `user:inference`, `user:profile`, `user:sessions:claude_code`, `user:mcp_servers`, `user:file_upload` | `user:inference` **only** |
| **Storage** | Keychain (`Claude Code-credentials`), rewritten on each refresh | Nowhere — the command only prints it |
| **Shareable across machines** | No — the refresh token rotates | Yes, unlimited |

Three consequences do most of the work:

- **They look identical.** Both start `sk-ant-oat01-` — a normal login's *access* token has the same
  prefix. The prefix proves nothing; the presence of a `refreshToken` is the only reliable tell,
  which is why `cswap list --token-status` reports `refresh token yes/no` instead of inspecting the
  string.
- **Rotation is the durability win.** A refresh token is single-use (see below). A setup-token has
  none, so there is nothing to rotate and nothing to race.
- **Scope is the cost.** `user:inference` buys model calls and nothing else. Verified on a live
  setup-token: `cswap list` reports `usage unavailable (http-403)` — the usage endpoint rejects the
  scope, so **5h/7d percentages are gone and `cswap auto` / `switch --strategy` fly blind** on that
  account. Remote Control (needs `user:sessions:claude_code`) and claude.ai connectors are gone too.
  Inference itself is unaffected.

Rule of thumb: **a setup-token is a durable, dumb API key; an OAuth login is a live, full-featured
session that cannot be shared.** Headless boxes, CI, and fleet sync want the first. An interactive
daily-driver machine usually wants the second — converting it trades away quota visibility
permanently, so confirm with the user before converting an account they actively work in.

## Why the refresh token died

`cswap add` stores a full OAuth credential (`accessToken` + `refreshToken` + `expiresAt`) and
renews it by POSTing `grant_type=refresh_token` to `https://platform.claude.com/v1/oauth/token`.
**The server rotates the refresh token on every use**, so the lineage is single-use: if anything
else spends it — a parallel Claude session, `cux`, a fleet peer that imported the same export —
cswap's stored copy becomes a spent generation and the next refresh returns `invalid_grant`.

That verdict is permanent on the first strike (`AUTH_DEAD_STRIKES = 1`), which is why the account
goes straight to `re-login needed` with no retry. Corroborating symptom in
`~/.claude-swap-backup/claude-swap.log`:

```
Live credential does not belong to Account-N (displaced-live-login) …
Something outside cswap rewrote the live login after the last switch.
```

A setup-token has **no refresh token and no expiry timestamp**, so there is nothing to rotate,
race, or reject — cswap skips the refresh path for these accounts entirely. Registering one also
clears the dead-token quarantine.

**It defers expiry rather than removing it.** A setup-token is a ~1-year credential; re-mint it
annually with the same steps.

### `cswap export` / `import` across machines is the usual killer

Sharing an **OAuth** account between machines this way is self-destructive, because the export
carries the `refreshToken` (`sk-ant-ort01-…`) and that token is single-use:

1. `cswap import` copies it to machine B. Nothing breaks yet — import makes no token call.
2. Whichever machine refreshes **first** — Claude Code on your next message, `cswap auto`
   freshening a target before activating it, or a usage poll on an inactive slot — spends the
   token and receives a rotated replacement.
3. The other machine is still holding the spent generation. Its next refresh gets
   `invalid_grant`, and one strike is fatal: `re-login needed — refresh token dead`.

It is a race, not a hierarchy — the loser can be either machine, and the survivor looks fine, which
is why this reads as random account death. cswap's own README flags the same trap from the other
direction: *"a stale export can carry an already-superseded token."*

**Setup-token accounts are immune and are the correct fleet credential.** With no refresh token
there is nothing to rotate, so the same `sk-ant-oat01-…` works on every machine at once and
`export`/`import` is safe.

Unverified, so plan around it: whether minting a *new* setup-token revokes previously minted ones
for the same account is undocumented. Treat it as if it might — **mint once and distribute that one
token** to the fleet, rather than running `claude setup-token` separately on each machine.

## 1 — Detect

```bash
cux status
```

Collect the email of every account whose STATE is `EXPRD`
(`cswap list --json` cross-references slots ↔ emails when the status table truncates them).
Done when each expired account's full email is known.

Two red herrings in this output:

- An `HTTP 429` warning under the table is the usage probe being rate-limited — transient,
  unrelated to expiry.
- `cux usage refresh` re-fetches quota numbers only; expiry needs a re-auth.

## 2 — Mint a token (the user does this)

`claude setup-token` is interactive (browser OAuth), so hand it to the user — inside a
Claude Code session they can run it as `! claude setup-token`. Tell them, exactly:

1. Run `claude setup-token`.
2. In the browser, **sign in as the expired account's email**. The token belongs to
   whichever account authorizes in the browser and carries no email metadata — a
   wrong-account sign-in mints a wrong-account token that nothing downstream will catch.
3. Paste back the `sk-ant-oat01-...` token.

Requires a Claude subscription on that account. Done when you hold a token the user
confirms was authorized as the target email.

## 3 — Register with cswap

Feed the token via stdin (heredoc) so it stays off argv and out of shell history:

```bash
cswap add-token - --email you@example.com --slot 2 <<'EOF'
sk-ant-oat01-...
EOF
```

Always pass `--email`: setup-tokens carry no email, so without it the entry is named
`setup-token-{slot}@token.local` and step 4 cannot match it to the account.

**Repairing an account that was added with `cswap add`? Pass `--slot N` too.** cswap matches
identity on `(email, organizationUuid)`, and a token account is always registered as *personal*
(`organizationUuid: ""`). An account captured from a real login carries its actual org uuid, so
the match fails and cswap files the token in a **brand-new slot**, leaving the dead one in place.
`--slot N` targets the existing slot instead; cswap prompts `Overwrite slot N? [y/N]` — answer `y`.
The slot's org metadata is replaced by the personal placeholder, which is expected and cosmetic.

`--slot` is unnecessary when refreshing a slot that is *already* a token account — email alone
matches it and the credential is replaced in place.

## 4 — Verify

```bash
cswap list --token-status
```

Done when the target email appears exactly once with `refresh token no` and no
`re-login needed`. If `add-token` created a second slot for an email that already had one,
`cswap remove` the stale slot (`cswap move` renumbers if slot order matters).

`usage unavailable (http-403)` on that line is expected, not a failure — see the scope note
above. Confirm the credential works with a real call instead: `claude -p 'say ok'` (on the
active slot) or `cswap run N -- -p 'say ok'` (any other slot).

Repeat 2–4 for each expired account.

## Converting the currently-active account

Steps 1–4 leave the live login untouched, which is the point — but that also means a token written
to the **active** slot is not yet durable. When cswap switches *away* from an account it backs up
whatever credential is live at that moment over the slot's stored copy, so the next `cswap switch`
would overwrite your new token with the old OAuth credential still in the keychain.

Make it stick by activating it once:

```bash
cswap add-token - --email you@example.com --slot 1 <<'EOF'
sk-ant-oat01-...
EOF
cswap switch 1 --force
```

After that the live bytes and the stored bytes match, so later switches classify the slot as
`own-bytes` and only re-save its config.

Warn the user first — `switch` rewrites the machine-global credential, so every running session
hot-reloads onto the new token mid-flight. **A setup-token is inference-only**: from that point the
account can no longer establish Remote Control sessions (driving this machine from claude.ai or
mobile) or fetch claude.ai connectors. Accounts that need those must stay on a normal login.

## 5 — Export a backup (final step)

Once every account verifies, snapshot them:

```bash
cd ~ && cswap export claude-accounts.json
```

**Write it outside any git repo** — cswap exports credentials in plaintext, so an export dropped in
a working tree is one `git add -A` away from publishing a year of account access. `cd ~` first
rather than exporting into the current directory. cswap writes the file mode `600`; confirm with
`ls -l`.

Confirm the export is rotation-immune before syncing it anywhere — it should contain setup-tokens
only, with no refresh-token lineage to race:

```bash
python3 -c "
import os
s=open(os.path.expanduser('~/claude-accounts.json')).read()
print('refresh tokens present:', 'sk-ant-ort' in s or 'refreshToken' in s)"
```

`False` means every account in the file is a setup-token and the export is safe to `cswap import`
on any number of machines. `True` means at least one account still carries a rotating refresh
token — importing that elsewhere will eventually kill it (see the export/import race above), so
either convert that account too or export selectively with `cswap export --account N`.

## Scope: cux keeps showing EXPRD

cux has no `add-token`; refreshing cux's copy takes the global dance
(`cux switch <expired>` → `claude /login` → `cux add --slot N` → switch back), which swaps
the machine-global login — the exact interruption this skill exists to avoid. Leave the cux
slot as `EXPRD` unless the user explicitly accepts the interruption; if they do, run the
dance at an idle moment, or via `/switch` from inside a cux session so it reconnects with
`--resume`.

## Security

The token is an unencrypted OAuth credential valid for roughly a year, and it cannot be rotated
away by normal use — its blast radius is wider and longer-lived than a refreshable login. Keep it
out of argv and out of your replies (confirm registration without echoing it). cswap stores it in
plaintext, so a `cswap export` file is a year's worth of account access: mode `600`, delete it
after import, never commit it.

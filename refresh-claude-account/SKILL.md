---
name: refresh-claude-account
description: Refresh an expired Claude Code account out-of-band — mint a fresh long-lived token with `claude setup-token` and register it with `cswap add-token` — so the machine-global login and every running Claude session stay untouched. Use when `cux status` shows an account as EXPRD, when the user asks to refresh or re-authenticate an expired Claude account without interrupting running sessions, or when a stored cswap account's OAuth token is expired or revoked.
---

# Refresh an expired Claude account (out-of-band)

`cux switch` / `cswap switch` rewrite the **machine-global** credentials, so every running
Claude session flips accounts — or starts failing while the target's creds are still dead —
on its next API call. `claude setup-token` instead runs its own OAuth flow in the browser
and only **prints** a token; the live login is never touched. This skill uses that
out-of-band route: running sessions keep working throughout.

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
cswap add-token - --email zhiqushi@gmail.com <<'EOF'
sk-ant-oat01-...
EOF
```

Always pass `--email`: setup-tokens carry no email, so without it the entry is named
`setup-token-{slot}@token.local` and step 4 cannot match it to the account.

## 4 — Verify

```bash
cswap list --token-status
```

Done when the target email appears exactly once with a healthy token. If `add-token`
created a second slot for an email that already had one, `cswap remove` the stale slot
(`cswap move` renumbers if slot order matters).

Repeat 2–4 for each expired account.

## Scope: cux keeps showing EXPRD

cux has no `add-token`; refreshing cux's copy takes the global dance
(`cux switch <expired>` → `claude /login` → `cux add --slot N` → switch back), which swaps
the machine-global login — the exact interruption this skill exists to avoid. Leave the cux
slot as `EXPRD` unless the user explicitly accepts the interruption; if they do, run the
dance at an idle moment, or via `/switch` from inside a cux session so it reconnects with
`--resume`.

## Security

The token is an unencrypted long-lived OAuth credential. Keep it out of argv and out of
your replies (confirm registration without echoing it). cswap stores it in plaintext —
treat `cswap export` output accordingly.

---
name: sync-claude-accounts
description: Distributes full OAuth Claude Code credentials (claude-accounts.json) from a single designated refresh-authority machine to the rest of a macOS fleet, importing them into claude-swap and registering each account with cux so unattended sessions keep rotating. Use when syncing or propagating Claude Code logins across Macs or a fleet, when setting up or running the recurring fleet credential push, or when the user mentions claude-accounts.json, accounts.json, cswap import, cux add, claude-swap, refresh authority, or adding multiple Claude accounts to remote machines.
---

# Sync Claude Accounts

Push a claude-swap export to N macOS machines and register every account with cux.
Accounts are **auto-discovered** from the export — no email addresses are hardcoded.

## The model this skill implements

Three decisions hold this together. Changing any one breaks the other two.

1. **Full OAuth credentials only — never setup-tokens.** Automatic rotation is driven by
   usage data. `cswap auto` is *purely usage-polling*, and cux is built around the `/login`
   credential bundle (`accessToken` + `refreshToken` + `expiresAt` + full scopes). A
   setup-token carries `user:inference` alone, so `/api/oauth/usage` answers **403** and the
   account is permanently unmeasurable — invisible to both rotators. Setup-tokens simply do
   not fit the model; the export must contain OAuth accounts.

2. **One machine refreshes; the rest only consume.** An OAuth refresh token is single-use and
   rotates server-side on every use, so N machines sharing an account means N−1 eventually get
   `invalid_grant`. Designating a single **refresh authority** that pushes its live credentials
   to everyone else removes the race at the source — a machine that only spends *access* tokens
   never rotates anything. This is the actual fix and it is independent of which rotator you run.

3. **cux provides unattended session continuation.** `cswap auto` only swaps credentials; it
   never wraps the `claude` process, so it cannot resume a session, retry a failed call, or
   wait out a reset. cux does (`auto_resume`, `auto_message`, `retry_on_api_error`,
   `wait_for_reset`, reactive rate-limit swapping), which is why this skill registers every
   account with cux rather than leaving rotation to cswap. **Do not run `cswap auto` as well** —
   two controllers swapping the same accounts fight each other.

## Where to run this

**On the refresh authority.** This skill and `refresh-claude-account` both belong on that one
machine:

- `refresh-claude-account` repairs a dead account there and emits `claude-accounts.json`.
- this skill distributes that file to the receivers.

Repairing or exporting on a *receiver* is wasted work — the authority's next push overwrites it.
Pick a machine with a GUI session (the keychain is readable without SSH gymnastics, and
interactive re-login is possible when an account needs it).

## Quick start

```bash
scripts/push-claude-accounts ~/claude-accounts.json \
    mac-mini-m2 archs-mac-mini 10.0.0.42
```

Per machine this: uploads the file to `/tmp/claude-accounts.json` (mode 600), installs
`~/.local/bin/sync-claude-accounts` if absent, runs it, and deletes the credentials file.
`127.0.0.1` / `localhost` / `local` / the machine's own hostname are handled with `cp`
and direct execution — no SSH. **Do not list the authority itself as a target**: it is the
source of the export, and importing its own credentials back over itself is at best a no-op.

To run the per-machine step alone (already on the box):

```bash
~/.local/bin/sync-claude-accounts            # defaults to /tmp/claude-accounts.json
```

> **Before you push, check two things.**
> 1. **No dead accounts in the export.** The recurring push uses `IMPORT_FORCE=1`, which
>    overwrites every receiver — so publishing a dead slot destroys working copies elsewhere.
>    `cswap list | grep -c 're-login needed'` must print `0`. Repair with
>    `refresh-claude-account` first.
>
>    **That count is a proxy, not the danger itself.** It reads cswap's *strike flag*, which is
>    permanent once set and says nothing about whether the credential still works. The actual
>    precondition is "no receiver holds a working copy I am about to overwrite." When the count
>    is non-zero, do not stop there — establish both halves directly, because the flag alone
>    will also block the one action that can recover a downed fleet. See "the ABORT interlock
>    can deadlock" below.
> 2. **No setup-tokens in the export.** If every account has an `accessToken` but no
>    `refreshToken`, cswap imports them but **cux cannot register them** — the run stops at the
>    cux step with exit 4, and those accounts would be unrotatable anyway. See point 1 above and
>    "cux cannot hold setup-tokens" below.

> **After you push, verify convergence.** Historically `done: N ok, 0 failed` did **not** mean the
> receivers took the credential — a machine whose active slot was the pushed account kept its old
> one and still reported success. Since 2026-08-19 the per-machine script imports twice and
> checks each slot's live credential against the export, so that case now surfaces as `MISMATCH`
> and exit 3 instead of passing silently.
>
> Spot-check by fingerprint anyway, especially after changing any of this. The in-script check
> confirms each slot at the moment it was made live; an independent read confirms what the
> machine is actually left holding:
>
> ```bash
> security find-generic-password -s "Claude Code-credentials" -w \
>   | /usr/bin/python3 -c 'import json,sys;o=json.load(sys.stdin)["claudeAiOauth"];print(o["accessToken"][-6:],o["expiresAt"])'
> ```
>
> Every machine must print the same value. Any host that differs did not converge; repair it with
> the switch-away/import/switch-back sequence below, then re-check.

## What the per-machine script does

1. Preflight `cswap` + `cux` (including that cux's native binary really downloaded).
2. Classify the export; warn early if it is setup-token-only (cux cannot register those).
3. Unlock the login keychain, *before* any write — cswap degrades to file-only storage if it
   is locked mid-operation, putting the credential where cux cannot see it.
4. Import **twice, around a switch**: switch off the active slot, `cswap import <file>`,
   switch back, import again. A single import cannot update the ACTIVE slot's live login, and
   the switch back clobbers the other slot's store — see the constraint below.
5. Re-probe the keychain, distinguishing `security` rc 36 (locked, retry) from rc 44 (no item
   — which is *not* proof of a setup-token; see below), repairing rc 44 where possible.
6. Discover all accounts via `cswap list --json`.
7. For each: `cswap switch <slot> --force`, **verify the live credential matches the export by
   access-token tail**, then `cux add`. Switch **by slot number, not email** — emails are not
   unique across slots. A mismatch logs `MISMATCH` and sets exit 3 rather than passing silently.
8. Restore whichever account was active before, and delete the credentials file.

## Non-obvious constraints

These are the failure modes this skill exists to encode — do not "simplify" them away:

- **`cux add` only captures the currently logged-in account.** Registering N accounts
  requires making each one live first. There is no flag to feed it credentials directly.
- **`cswap switch` needs `--force`.** Switching to an account that is *already active*
  prints `Already on Account-N` and declines to rewrite the live login from the stored
  backup — so `cux add` would silently capture **stale** credentials. `--force` fixes the
  *refusal*, but not the underlying limitation — see the next bullet, which is the one that
  actually bites on a recurring push.

- **`cswap import --force` cannot update the live login of the ACTIVE slot, and the fix it
  prints does not work.** Import writes each account's *stored* credential. When one of those
  accounts is the machine's current live login, it says so:

  ```
  Note: <email> is your current live login — activate the imported credentials with:
        cswap --switch-to N --force
  ```

  Follow that advice and **nothing changes**: on an already-active slot `cswap switch N --force`
  reports `Activated Account-N` while leaving the live keychain credential untouched. (Mechanism
  inferred, not documented: switch appears to back live→store *before* restoring store→live, so
  the freshly imported credential is overwritten by the stale live one and then restored over
  itself.)

  Consequence: a receiver whose active slot is the account you are pushing **keeps its old
  credential while the per-machine script reports success.** Observed 2026-08-19 — a
  `4 ok, 0 failed` push left mac-mini-m2 and archs-mac-mini on tokens they had minted
  themselves (~1h20m of life) while mac-mini-2018 and mac-studio-m3 correctly took the pushed
  one (7h47m). Nothing in the exit status or the log distinguishes the two outcomes.

  The working sequence — all in **one** ssh invocation, since the keychain re-locks between them:

  ```bash
  cswap switch <other-slot> --force            # target slot is no longer live
  cswap import <file> --force                  # its store now takes the pushed credential
  cswap switch <target-slot> --force           # live := store = pushed credential
  cux add --slot <cux-slot> --alias <alias>    # resync cux's separate backup
  ```

  Read `<cux-slot>`/`<alias>` from that machine's own `~/.cux/state.json`; they differ per host.

  **When you need BOTH slots fresh, that sequence is not enough — you must import TWICE.**
  Step 3's `switch` backs the *current* live credential into the slot it is leaving, and on a
  recovery push that credential is the stale/empty one, so it clobbers the fresh import the
  step-2 import just wrote to that other slot. Verified 2026-08-19 on all four receivers:

  ```bash
  cswap switch <other-slot>  --force   # 1. leave the active slot
  cswap import <file> --force          # 2. active slot's store := pushed
  cswap switch <target-slot> --force   # 3. live := pushed  BUT clobbers <other-slot>'s store
  cswap import <file> --force          # 4. repair <other-slot>'s store (it is not live now)
  ```

  After step 4 every store holds the pushed credential and the live login is correct, so the
  subsequent per-slot `switch` + `cux add` loop only ever backs up *fresh* credentials and is
  safe.

  **As of 2026-08-19 `scripts/sync-claude-accounts` does this itself** — it reads the active
  slot, switches away, imports, switches back, and imports again, so a recovery push no longer
  needs the sequence driven by hand. It also unlocks the keychain *before* the dance rather than
  after: every step here is a cswap write, and cswap silently degrades to
  `~/.claude/.credentials.json` whenever the keychain is unavailable mid-operation, which would
  put the credential exactly where cux cannot see it.

  It now **verifies rather than assumes**. After making each slot live, it compares the live
  access-token tail against the export and logs

  ```
  MISMATCH: slot 1 work@example.com — live ...a1b2c3 but export has ...d4e5f6; credential did not take
  ```

  setting exit 3. That closes the original complaint about this failure — that nothing in the
  exit status or the log distinguished a real push from a silently stale one. Only the
  single-account case is still unprotected: with one slot there is nowhere to switch away *to*,
  so the dance cannot run — but the MISMATCH check still reports the outcome instead of letting
  it pass as success.

- **Verify a push by credential fingerprint, not by cswap's display.** `cswap list
  --token-status` prints `active profile: fresh, refresh token yes` for a credential that is
  perfectly valid but a *different generation* than the one you just pushed — it describes the
  credential's shape, not its identity, so it cannot detect divergence. Compare the live token
  against the export instead:

  ```bash
  security find-generic-password -s "Claude Code-credentials" -w \
    | /usr/bin/python3 -c 'import json,sys;o=json.load(sys.stdin)["claudeAiOauth"];print(o["accessToken"][-6:],o["expiresAt"])'
  ```

  Identical tails across the fleet = converged. **Distinct tails for one account mean each of
  those machines has been refreshing on its own** — the single-use-refresh-token race is
  already running, and the losers are holding spent refresh tokens that will fail on next use.
  Do not try to read `cux-backup` for this: those keychain items are not JSON and do not parse.

- **The dead-token-strike warning tells you whether a repair actually took.** Re-importing a
  credential the strike already condemned prints, indented under the `Overwrote` line:
  `└ this import holds the same credential generation the strike condemned; another permanent
  auth failure will quarantine it again`. Its **absence** on a previously-dead account is the
  confirmation that the export carries a genuinely new generation rather than a re-publication
  of the condemned one.
- **The ABORT interlock can deadlock, because a strike flag is not a dead token.** cswap's
  `re-login needed — refresh token dead` is a permanent verdict about the *refresh* token,
  recorded when one refresh attempt returned `invalid_grant`. The account's **access** token
  is a separate credential and frequently still works for hours afterwards. Both
  `fleet-refresh-credentials` and this skill's preflight gate count that flag
  (`grep -c 're-login needed'`) and refuse to push — so a fleet where every receiver is dead
  and the authority is merely *flagged* enters a stable deadlock: the only machine that can
  seed the fleet refuses to, on the strength of a flag whose credential still works.

  Break the tie with evidence, not inference. Probing an **access** token is read-only and
  consumes nothing single-use (unlike a refresh token, which rotates on every use):

  ```bash
  F=/tmp/claude-accounts.json
  /usr/bin/python3 -c 'import json,sys;[print(a["email"],a["credentials"]["claudeAiOauth"]["accessToken"]) for a in json.load(open(sys.argv[1]))["accounts"]]' "$F" \
  | while read -r email tok; do
      echo "$email -> HTTP $(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $tok" https://api.anthropic.com/api/oauth/usage)"
    done
  ```

  (Deliberately no heredoc and no multi-line Python: this file is read as raw markdown, so a
  snippet whose correctness depends on starting at column 0 breaks when copied out of an
  indented bullet. Every line above is indentation-insensitive.)

  `200` means the credential is usable and pushing it is strictly better than what a receiver
  holding `no credentials` has. Pair it with a per-receiver fingerprint survey to confirm the
  gate's real precondition — that no receiver holds a working copy — and only then override.
  Observed 2026-08-19: authority flagged dead on one account, every receiver empty or
  expired, both exported access tokens returning `200`; the push repaired all four and the
  authority's own strike cleared itself as soon as cswap could poll usage successfully.

  A useful corroborating signal on import: `└ cleared this slot's stored dead-token strike`
  **without** the `same credential generation the strike condemned` warning means the export
  carries a genuinely new generation, so its refresh token is probably healthy too.

- **`keychain unavailable — locked or in use` can be masking `no credentials`.** The message
  reads as transient, so it invites a retry; it is emitted whenever cswap cannot read the item,
  including when the item is an *empty* credential. Re-read with the keychain unlocked in the
  **same** invocation before believing the account is merely locked:

  ```bash
  ssh host '~/.claude/unlock-keychain.sh >/dev/null 2>&1; cswap list'
  ```

  Observed 2026-08-19: mac-mini-m2 and archs-mac-mini both reported `keychain unavailable`, and
  both turned out to hold `no credentials` — a materially different state, since a locked
  keychain needs no repair and an empty credential needs a push.

- **cux slot numbers are independent of cswap slot numbers, and are routinely inverted.** The
  two tools keep separate state with separate numbering; the same account can be cswap slot 1
  and cux slot 2 on one host and the reverse on the next. On 2026-08-19 mac-mini-2018 had
  cswap slot 1 = one account → cux slot 2, while another host had them aligned. **Map by
  email**, reading each machine's own `~/.cux/state.json`, and never carry a slot number across
  from cswap or across hosts:

  ```bash
  /usr/bin/python3 -c 'import json,sys;s=json.load(open(sys.argv[1]));print(next((str(a["slot"])+" "+str(a.get("alias") or "") for a in s.get("accounts",{}).values() if a.get("email")==sys.argv[2]),"not found"))' ~/.cux/state.json <email>
  ```

  (One line on purpose — see the note under the ABORT bullet above.)

- **The macOS login keychain is locked in SSH sessions.** `cux add` reads it directly and
  dies with `security find-generic-password ... exit 36` (`errSecInteractionNotAllowed`).
  It does *not* fall back to `~/.claude/.credentials.json`, and no env var forces file
  mode. `cswap` degrades gracefully, so import still works. Fix with
  `~/.claude/unlock-keychain.sh` — see the `ssh-claude-auth` skill (Approach B). Two refinements to
  this, both learned the hard way, are spelled out below: the unlock only holds *within
  one SSH invocation*, and exit **44** is a different condition that unlocking cannot fix.
- **Never pipe `cswap import`.** `cswap import f | tail -1 && ...` takes its exit status
  from `tail`, masking `import file not found` and continuing as if it worked.
- **`cux`'s npm postinstall soft-fails with exit 0.** It downloads a native binary from
  GitHub releases; on failure `npm install` still reports success. Verify with `cux version`.
- **`cswap import` skips accounts that already exist** unless `--force`, but it *does*
  auto-heal slots quarantined as refresh-token-dead. A "0 imported, 2 skipped" result is
  normal and usually fine; use `--force` only to make the export authoritative.
- **Syncing an OAuth account to N machines eventually kills it on N−1 of them.** The export
  carries a `refreshToken`, and the server rotates that token on every use — it is single-use.
  Once two machines hold the same one, the first to refresh — Claude Code on the next message,
  cux freshening a target before it swaps, or a background usage poll — invalidates every other copy, and the losers get
  `invalid_grant` → `re-login needed — refresh token dead`. One strike is permanent. This is a
  race with no stable winner, so it presents as accounts dying at random days later, not at
  import time.

  **The fix is a single-writer refresh authority, not a different credential.** Designate
  exactly ONE machine as the only one allowed to refresh, and have it push its live credentials
  to the others often enough that no receiver ever reaches its refresh buffer — a machine that
  only *consumes* an access token never rotates anything. See "Recurring use" below.

  Setup-tokens look like an easier answer (no refresh token, so nothing to race) and an earlier
  version of this skill recommended them. **That recommendation is withdrawn**: cux cannot manage
  them and they cannot be measured, so an all-setup-token fleet loses automatic rotation
  entirely — see the next two bullets. When an account has already died, repair it with the
  `refresh-claude-account` skill, which restores a full OAuth login and emits the
  `claude-accounts.json` this skill distributes.

- **cux cannot hold setup-tokens — so the fix above and this skill's cux step are mutually
  exclusive.** Verified against cux 0.3.9 (the current release) on 2026-08-17. cux reads the
  live login *only* from the `Claude Code-credentials` login-keychain item. An OAuth login
  populates that item; a setup-token login does not — it writes `~/.claude/.credentials.json`
  and nothing else. So with a setup-token live:

  ```
  $ cux add --slot 2 --alias arch-dev
  cux: no active Claude Code login found — run `claude login` first    # and exits rc=0
  ```

  Note the **exit 0**: the failure is silent, so a loop that trusts `$?` reports success while
  registering nothing. There is no config key for a credential source (`cux config keys` has
  none) and no `cux add-token` counterpart to `cswap add-token`.

  Practical consequence: you can have cux-managed rotation **or** cross-machine-durable
  setup-tokens, not both. **This skill resolves that in favour of cux and OAuth**, because
  only cux can continue an unattended session through a rate limit — `cswap auto` would
  tolerate setup-tokens as a credential *kind*, but it cannot measure them either (403, next
  bullet but one), so that trade buys nothing and costs session continuity. Keep OAuth, keep
  cux, and repair accounts with the `refresh-claude-account` skill as they die.

- **`security` exit 36 and 44 mean opposite things.** `36` (`errSecInteractionNotAllowed`) is a
  locked keychain — unlock and retry. `44` (`errSecItemNotFound`) means there is no item at all;
  unlocking changes nothing. A probe that only checks "rc != 0" reports the second case as a
  phantom lock failure.

- **rc=44 does NOT mean "setup-token".** It means the credential is not in the keychain, and a
  perfectly good OAuth login can end up there: cswap degrades to writing
  `~/.claude/.credentials.json` whenever the keychain is unavailable mid-operation, and the
  credential then stays in the file where cux cannot see it. Observed 2026-08-17 on a headless
  Mac Studio — `refreshToken` present, full scope set including `user:profile`, no keychain
  item, and the sync failing with exit 4 as though a setup-token were involved.
  **The repair is `cswap switch <active-slot> --force` with the keychain unlocked**, which makes
  cswap write the item back; the per-machine script now attempts this automatically before
  failing. Tell the two causes apart by the credential's own shape — `refreshToken` present and
  `user:profile` in scopes means OAuth and a failed keychain write, not a setup-token.

- **The login keychain re-locks between SSH sessions.** `ssh host 'unlock-keychain.sh'` followed
  by a separate `ssh host 'cux add'` does not work — the second session is locked again. The
  unlock must run in the *same* invocation as the command that needs it.

- **`cswap switch <email>` is ambiguous once two slots share an email**, which happens routinely:
  cswap keys accounts on `organizationUuid`, so an org-less (setup-token) export imported onto a
  machine whose slots carry a real org uuid **appends new slots** rather than matching them.
  `switch` then prompts `Enter account number to switch to:` and, with stdin closed, dies on
  `EOFError`. Always switch by **slot number** — `cswap list --json` gives `.accounts[].number`.

- **`cswap remove` prompts and has no `--force`.** It asks `Are you sure ... [y/N]` and dies on
  `EOFError` if fed `/dev/null`. Answer it with a herestring (`<<<"y"`), not a pipe, so the exit
  status stays cswap's.

- **Back up `~/.cux/state.json` before any `cux remove`.** Observed 2026-08-17: on a state
  holding duplicate emails, `cux remove --force <slot>` emptied `accounts` entirely instead of
  dropping the one slot, taking the surviving labelled entries with it. Rebuilding meant
  re-running `cswap switch` + `cux add --slot N --alias NAME` per account. `~/.cux/accounts/`
  holds no recovery copy, and cux writes no `.bak`.

- **`cswap` verbs take the path BEFORE flags.** argparse maps the `import` verb onto
  `--import`, which consumes the next token as its argument, so `cswap import --force <file>`
  dies with `argument --import: expected one argument`. Write `cswap import <file> --force`.
  Same shape for `cswap export <file> --account <num|email>`.

- **`cux add --slot N --alias NAME` refreshes in place; bare `cux add` appends.** The pinned
  form prints `Refreshed slot N (...)` instead of `Added slot N (...)`, which is what makes a
  *recurring* sync idempotent. Without it, every run appends a fresh unlabelled duplicate.
  Read the mapping from each machine's own `~/.cux/state.json` — slot order and alias strings
  genuinely differ per machine (`arch-dev` on one, `arch-dev-techarchaut` on another, and the
  email→slot mapping is inverted between hosts).

- **cux caches its usage verdict.** A just-healed account keeps showing `EXPRD` with no usage
  until cux re-polls, which makes a successful repair look like a failure and keeps the account
  out of rotation. `cux list --refresh` clears it; the sync script now does this automatically.

- **cux and cswap keep SEPARATE credential backups**, both in the login keychain: services
  `cux-backup` and `claude-swap`. `~/.cux/accounts/*/oauth.json` holds only profile metadata,
  no tokens. Anything that redistributes credentials must refresh **both**, or cux will swap in
  an already-rotated refresh token from its own stale copy.

- **A setup-token CAN live in the keychain.** An earlier note here claimed setup-token logins
  never populate `Claude Code-credentials`; that is not reliably true — on mac-mini-m2 the
  setup-token was in the keychain (so `cux add` worked), while on mac-mini-2018 the same kind of
  login landed only in `~/.claude/.credentials.json` (so `cux add` failed with rc=44). What is
  *always* true is the scope limit: `user:inference` only, so `/api/oauth/usage` returns 403 and
  neither cux nor `cswap auto` can measure the account. Identify a setup-token by
  `refreshToken: false` / `scopes: ['user:inference']`, not by where it is stored.

## Prerequisites per machine

`uv tool install claude-swap` and `npm install -g @inulute/cux` (which needs Node ≥18 —
`brew install node`). `jq` is used when present; otherwise `/usr/bin/python3` is the fallback.

## Options

| Env | Effect |
|---|---|
| `FORCE_INSTALL=1` | Reinstall `~/.local/bin/sync-claude-accounts` even if present (use after editing it) |
| `KEEP_ACCOUNTS_FILE=1` | Leave the credentials file in place instead of deleting it |
| `IMPORT_FORCE=1` | `cswap import <file> --force` — make the export authoritative on receivers instead of skipping accounts that already exist. Required for the recurring single-writer push |
| `SKIP_IF_CUX_BUSY=1` | Exit 5 without touching anything when a cux session is running, rather than swapping the login out from under supervised work |

## Recurring use: the single-writer refresh authority

Why this runs on a schedule rather than by hand (the model is in "The model this skill
implements" above): receivers must be topped up often enough that none of them ever reaches
its own refresh buffer, because the moment one does, it rotates the token and the fleet
starts dying again.

On this fleet that is `~/.local/bin/fleet-refresh-credentials` on the MacBook Air
(LaunchAgent `com.claude.fleet-refresh`, every 15 min), paired with
`~/.local/bin/fleet-health-check` (`com.claude.fleet-health`, hourly). The push script wraps
this skill: it exports, then calls `push-claude-accounts` with `IMPORT_FORCE=1` per host,
deferring any machine with a live cux session unless its token is nearly expired.

**Operating those agents — reading a cycle, what each alert means, changing the cadence — is
the `claude-fleet-health` skill.** This skill covers the push mechanism itself.

Three things that design must respect:

- **Never push from an authority holding a dead account.** `--force` overwrites receivers,
  so publishing a dead slot destroys working copies elsewhere. On 2026-08-17 this machine
  held a dead copy of one account while a single receiver held the only live one — pushing
  would have killed it fleet-wide. `fleet-refresh-credentials` aborts on any `re-login needed` locally.
  Re-seed the authority first with `cswap export <file> --account <email>` from whichever
  machine still has a live copy, then `cswap import <file> --force` — that is Path A of the
  `refresh-claude-account` skill, which is where this repair belongs.

  Caveat, learned 2026-08-19: that abort keys on the *strike flag*, so it also fires when the
  flagged credential still works — and then blocks the only push that could revive a downed
  fleet. Before treating an ABORT as correct, confirm a receiver actually holds a working copy
  worth protecting. See "the ABORT interlock can deadlock" above.
- **Receivers inherit the authority's *remaining* token life**, which sawtooths 8h → 0, so no
  cadence closes the trough completely. A tick landing just before the authority refreshes
  leaves receivers briefly holding a near-expired token. Bound the gap with the interval and
  monitor for it; do not assume it is impossible.

  **This fired on 2026-08-19 and took the whole fleet down.** Timeline, from
  `~/Library/Logs/fleet-refresh.out.log`: the `10:38` cycle correctly HELD (authority had 6m
  of life left — pushing would have synchronised everyone onto one fuse); the authority then
  refreshed at ~`10:40`, rotating the shared refresh token server-side; receivers expired at
  ~`10:45` and refreshed with the now-spent token → `invalid_grant` → permanent strike on all
  four. The next scheduled push was `11:08`, ~23 minutes too late. Every cycle from `11:08`
  onward then ABORTed on the authority's own strike flag — see "the ABORT interlock can
  deadlock", which is what turned a 23-minute gap into a multi-hour outage.

  The interval was cut 30 min → **15 min** on 2026-08-19 in response, and the **proactive
  refresh** below landed the same day. Cadence alone could never have fixed this: the interval
  bounds how long a receiver holds a stale token, but a receiver dies the moment *it* reaches
  its own refresh buffer, which can arrive before the authority's token has even expired.

- **The authority refreshes proactively; that is what makes the design self-sustaining.**
  Nothing used to *drive* the single-writer refresh. claude-swap refreshes only lazily — when a
  token is already inside its 5-minute expiry buffer (`OAUTH_EXPIRY_BUFFER_MS`), and only for a
  slot that is **not** the active one (`oauth.try_fetch_usage_for_account`). So the authority
  coasted to the edge of expiry while receivers held that same token with refresh buffers of
  their own, and whichever got there first rotated the single-use token and struck the rest dead.

  `fleet-refresh-credentials` now mints a fresh token *early* and pushes it in the same cycle:
  once any credential drops below `REFRESH_BELOW` (90m), `proactive_refresh()` exports, calls
  `~/.local/bin/claude-refresh-export` (which uses claude-swap's own
  `oauth.try_refresh_oauth_credentials`), and redistributes. Receivers are handed a fresh ~8h
  token long before anything of theirs comes due, so **no receiver ever has a reason to
  refresh**. A short cadence only made the old race less likely; this makes it unreachable.

  Three things that implementation must respect:

  - **Persist before verifying.** The refresh POST rotates the token server-side, so the
    previous generation is dead the instant it succeeds. `claude-refresh-export` writes the
    result to disk *before* probing it — a credential you hold but could not verify is
    recoverable, one you never persisted is not. An unverified refresh is kept, not discarded.
  - **Sync live → store before exporting.** The export reads *stores*. If the live login is a
    newer generation than the active slot's store, refreshing the store copy POSTs an
    already-spent token and strikes the account dead. `proactive_refresh()` switches away from
    the active slot first, which forces that sync.
  - **`REFRESH_BELOW` must stay ≤ `FORCE_BELOW_SECONDS`.** The moment the authority refreshes,
    every receiver is holding a spent refresh token, so all of them must be overwritten in that
    same cycle. If one instead *defers* for a live cux session and later hits its own expiry, it
    refreshes with the spent token and strikes itself permanently dead. Keeping the refresh
    threshold at or under the force threshold guarantees every receiver is already inside the
    force window whenever a refresh happens. The script checks this and raises
    `FORCE_BELOW_SECONDS` to match rather than proceeding with the thresholds crossed.
- **Only one rotator.** cux is the rotation layer (it is the one that can continue an
  unattended session); `cswap auto` must stay off on every machine. Two controllers swapping
  the same accounts fight, and the resulting swaps look identical to the race this design
  exists to prevent. `cswap auto --once --dry-run --json` is still safe and useful — `--dry-run`
  evaluates without ever switching or writing state, which is what the health check uses.

Exit codes from the per-machine script: `0` ok, `1` preflight/import failure,
`2` keychain locked (import still succeeded), `3` one or more accounts failed — a switch, a
`cux add`, **or a credential that did not take** (`MISMATCH`), `4` imported, but the live login
is a setup-token so cux cannot register it.

`2` and `4` both mean "cswap is fine, cux is not", but only `2` is worth retrying —
`4` is the structural limitation above and will recur on every run.

## Security

The export holds **unencrypted OAuth credentials**. It is written mode 600 and deleted
after import by default. Encrypted exports are rejected up front.

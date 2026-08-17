---
name: claude-fleet-health
description: Operate and monitor the scheduled Claude Code credential automation on a macOS fleet — the com.claude.fleet-refresh and com.claude.fleet-health LaunchAgents, their logs, and the alerts that catch the OAuth refresh-token race before an account is needed. Use when checking whether the fleet is healthy, when an account died or shows EXPRD, when cswap reports null headroom or "re-login needed", when a scheduled push seems to have stopped, or when setting up / auditing the fleet-refresh and fleet-health agents.
---

# Claude fleet health

The operational layer over the two credential skills. `refresh-claude-account` repairs one
account, `sync-claude-accounts` distributes credentials — this skill covers the **scheduled
automation that runs them** and the monitoring that tells you when it has broken.

Everything here runs on the **refresh authority** (the one machine allowed to refresh OAuth
tokens). On this fleet that is the MacBook Air; the receivers are mac-mini-2018, mac-mini-m2,
archs-mac-mini and mac-studio-m3.

## What is running

Two LaunchAgents on the authority, both loaded and verified (`last_exit=0`):

| Agent | Cadence | Does |
|---|---|---|
| `com.claude.fleet-refresh` | 30 min | Exports live credentials, pushes to the 4 receivers with `IMPORT_FORCE=1` |
| `com.claude.fleet-health` | hourly | Alerts on dead slots / null headroom / unreachable hosts |

Backing files:

| Path | Role |
|---|---|
| `~/.local/bin/fleet-refresh-credentials` | The push cycle. `--dry-run` reports what it would do without touching anything |
| `~/.local/bin/fleet-health-check` | The monitor. `NOTIFY=0` suppresses the desktop notification |
| `~/Library/LaunchAgents/com.claude.fleet-refresh.plist` | `StartInterval` 1800, `RunAtLoad` true |
| `~/Library/LaunchAgents/com.claude.fleet-health.plist` | `StartInterval` 3600 |
| `~/Library/Logs/fleet-refresh.log`, `fleet-health.log` | Per-cycle transcripts |
| `…/fleet-refresh.err.log`, `fleet-health.err.log` | Should stay empty; content here means the agent itself is failing |

Check both are alive:

```bash
launchctl list | grep -E 'fleet-refresh|fleet-health'    # 3rd column = label, 2nd = last exit
grep -vE '^\s' ~/Library/Logs/fleet-refresh.log | tail -8
```

## Monitoring (not optional)

`cswap auto --once --dry-run --json` is a safe read-only probe — it evaluates and reports but
never switches or writes state. Schedule it per machine and alert on:

- **`headroomPct` null for an account** → unreadable usage, caught *before* the account is
  needed. Observed in practice: a probe returning `{"1": null, "2": 35.0}` correctly flagged
  slot 1 while slot 2 was still healthy — days before anything tried to use it.
- **A changed `refreshToken` prefix on a receiver** → that machine refreshed, meaning the race
  is live and the design has sprung a leak.

**A single null is not proof of a fault.** The usage endpoint rate-limits (429) under exactly
the load a busy fleet generates, and a rate-limited probe reports null for a perfectly healthy
account. Alerting on the first null produces false alarms — seen 2026-08-17, two machines
alerted while `cswap list --token-status` showed every account `fresh, refresh token yes`. A
monitor that cries wolf gets ignored, and then the real event is missed. So separate the
permanent conditions from the transient one:

| Signal | Meaning | Treatment |
|---|---|---|
| `re-login needed` | Refresh token dead — the race fired | Alert immediately |
| `http-403` | Credential lacks `user:profile` — a setup-token got in | Alert immediately |
| `http-429` / a bare null | Usage endpoint throttled | Note it; alert only if it **persists** |
| Host unreachable | Cannot confirm health at all | Alert — it still holds credentials |

`fleet-health-check` implements this with a per-host streak counter in
`~/.local/state/fleet-health-nulls`: a null increments, a clean run resets, and it alerts once
the streak reaches 3 consecutive runs (~3h hourly, which is no longer plausibly rate limiting).
Early detection survives; the noise does not.

**Measure the account nearest death, not the live one.** The expiry probe driving the
force-vs-defer decision must take the **minimum across all slots** (`cswap list --token-status`
prints one `expires HH:MM in Xh Ym` per slot). Reading only the live login measures the wrong
thing whenever a machine's two accounts have different expiries: seen 2026-08-17, mac-mini-m2
reported "4h" from its live slot while its *other* slot's stored backup sat 60 minutes from
expiry — so it deferred every cycle, and cux swapping onto that slot would have activated a
dead token and rotated it out from under the fleet.

A healthy probe looks like this — two events per tick, and no nulls:

```json
{"event":"poll","active":{"number":2,"email":"…"},"headroomPct":{"1":35.0,"2":41.0},
 "threshold":90.0,"windowsPct":{"2":{"5h":27.0,"7d":65.0}}}
{"event":"no-switch","reason":"below-threshold","detail":"65% < 90%"}
```

Why this is not optional: the failure it catches is **silent and permanent**. A machine that
loses the rotation race looks fine until something actually calls the API — possibly days
later — and the dead-token verdict strikes on the first failure with no retry
(`AUTH_DEAD_STRIKES = 1`). Treat a gap in monitoring as an outage, not an inconvenience.

Run it by hand any time:

```bash
NOTIFY=0 ~/.local/bin/fleet-health-check     # exit 0 = healthy, 1 = alerts raised
```

## Reading a refresh cycle

Each cycle logs one line per host plus a summary:

```
START exported 2 account(s)
  mac-mini-2018: token good for 4h — deferring if cux is busy
  mac-mini-2018: DEFERRED (cux session active)
  archs-mac-mini: token expires in 126m — forcing through any live session
  archs-mac-mini: OK
DONE ok=2 deferred=2 failed=0
```

- **DEFERRED** is normal, not a failure. Registering an account requires making it live, which
  would swap the login out from under a supervised cux session, so a busy machine is skipped —
  *unless* its access token has under 90 minutes left, at which point a momentary swap is
  cheaper than letting it refresh and rotate the token out from under the fleet.
- **A machine deferred every cycle for many hours** is the case to watch. It should get forced
  once its token drops under the threshold; if it never does, the expiry probe is broken.
- **`failed=` non-zero** → SSH or import trouble. Check `fleet-refresh.err.log` first: the agent
  runs without your interactive shell's PATH or ssh-agent, so unattended auth problems show up
  here and not in a manual run.
- **`ABORT`** → the authority itself holds a dead account. It refuses to push rather than
  overwrite healthy copies elsewhere. This is the one that needs you; see below.

## When an alert fires

| Symptom | Meaning | Fix |
|---|---|---|
| `ABORT … dead on the authority` | The authority can no longer seed the fleet | Repair it with `refresh-claude-account` — Path A (re-seed from a machine that still works) before Path B |
| Receiver has dead slots | The race fired on that machine | Usually self-heals on the next push (`cswap import --force` clears the dead-token strike). If it recurs, the single-writer invariant is broken |
| Null headroom, no dead slot | Usage unreadable — often a stray setup-token (403), sometimes transient rate limiting (429) | Confirm with `cswap list --token-status`; `refreshToken: no` means a setup-token got in and cannot rotate |
| Receiver's `refreshToken` prefix diverges | That machine refreshed on its own | Find what refreshed there; a forced push re-converges it, but the cause will repeat |
| Host unreachable | Cannot confirm credential health | Not benign — an unreachable machine still holds credentials and may refresh unobserved |

**Never repair on a receiver.** The authority's next push overwrites it. Repair the authority and
let the cycle distribute the fix.

## The residual gap this monitoring exists for

Receivers inherit the authority's *remaining* access-token life, which sawtooths from ~8h down to
0 and back. No cadence closes that trough completely: a tick landing just before the authority
refreshes leaves receivers briefly holding a near-expired token, and a receiver that runs Claude
Code in that window **will** refresh and rotate the token out from under everyone.

The 30-minute cadence bounds the exposure to roughly one 30-minute window per 8-hour cycle,
versus the permanent N-way race it replaced. It is a mitigation with an operational dependency,
not a structural guarantee — which is exactly why the hourly check runs whether or not anyone is
watching. The structural fixes are more accounts (one per rotating machine) or fewer rotating
machines.

## Changing the schedule

```bash
launchctl unload ~/Library/LaunchAgents/com.claude.fleet-refresh.plist
# edit StartInterval, then:
plutil -lint ~/Library/LaunchAgents/com.claude.fleet-refresh.plist
launchctl load  ~/Library/LaunchAgents/com.claude.fleet-refresh.plist
```

`RunAtLoad` on the refresh agent means loading it fires a cycle immediately — convenient for
testing, but it also means a reboot does not wait out a full interval.

Shortening the interval reduces the residual gap but increases how often busy machines get
forced through a live session; lengthening it does the reverse. Do not add a second rotator:
cux is the rotation layer, and `cswap auto` must stay **off** (only its `--dry-run` probe is
used here) — two controllers swapping the same accounts fight, and the result is
indistinguishable from the race.

## Related

- `refresh-claude-account` — repair a dead account, emit `claude-accounts.json`
- `sync-claude-accounts` — distribute that file; the push cycle wraps it
- `ssh-keychain-unlock` — the keychain re-locks between SSH sessions, which is why every remote
  step unlocks in the same invocation

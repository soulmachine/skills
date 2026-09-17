<!-- AI-maintained, append-only -->

# Decisions

## Q1 — affix-domains/multi-tld — gate-resolution

**Question:** "If the original input word with .com is taken, then extend TLDs" — does the escalation widen the whole affix sweep, or only re-check the seed word across the new TLDs?
**Options considered:** widen the entire sweep / widen only the bare seed / always sweep all 8 TLDs unconditionally
**Chosen:** Two-stage escalation. `<seed>.com` is checked alone first; free → the sweep stays `.com`-only (original contract preserved); taken → every subsequent check runs across all 8 TLDs.
**Decided-by:** agent
**Justification:** The ask names a trigger condition ("if … taken"), so an unconditional 8-TLD sweep would ignore it, and the listed set includes `.com` itself, which reads as the scan set rather than a set of extras. Gating also keeps the common case cheap: ~63 lookups instead of ~500.
**Outcome:** assumed
**Ref:** (pending)

## Q2 — affix-domains/multi-tld — gate-resolution

**Question:** Should the bare seed word itself be swept across the seven non-`.com` TLDs, or only the affixed candidates?
**Options considered:** affixed candidates only (literal reading) / bare seed included
**Chosen:** Include the bare seed in the escalated sweep.
**Decided-by:** agent
**Justification:** Not stated in the ask either way. The seed is the name the user actually wants — an unaffixed `mate.ai` outranks any affixed `.com` — and it costs 8 lookups against a ~500-lookup sweep. Cheapest-to-reverse default: it only ever adds results.
**Outcome:** assumed
**Ref:** (pending)

## Q3 — affix-domains/multi-tld — deviation

**Question:** `.co` publishes no RDAP service, but the skill's stated contract was RDAP-only. Drop `.co`, or break the contract?
**Options considered:** drop `.co` from the set / use an RDAP proxy / fall back to WHOIS for `.co`
**Chosen:** WHOIS against `whois.registry.co`, with free ⇔ `DOMAIN NOT FOUND`.
**Decided-by:** agent
**Justification:** `.co` is absent from the IANA RDAP bootstrap (`data.iana.org/rdap/dns.json`, pub. 2026-07-23) and no candidate RDAP host serves it authoritatively — `rdap.registry.co` resolves but 404s on the registered control `t.co`. `.co` was explicitly requested, so dropping it fails the ask; WHOIS discriminates correctly on both controls. Registry-authoritative is the property that mattered, not the protocol.
**Outcome:** assumed
**Ref:** (pending)

## Q4 — affix-domains/multi-tld — tradeoff

**Question:** Google's `.app` RDAP rate-limits aggressively. How should the sweep pace it?
**Options considered:** lower parallelism / serial + backoff-retry / drop `.app` / accept gaps
**Chosen:** Serial (`-P 1`) with backoff-and-retry on 429, per-TLD parallelism elsewhere.
**Decided-by:** agent
**Justification:** Measured: the quota is rolling, not concurrency-based — 16 requests at `-P 8` and at `-P 4` both yielded 6/16 429s, and `-P 2` after prior bursts yielded 16/16. Only serial-plus-retry recovered. Costs wall-clock on the `.app` leg; the alternative is silently missing available domains.
**Outcome:** assumed
**Ref:** (pending)

## Q5 — affix-domains/multi-tld — deviation

**Question:** Keep the inline `curl` loop in the skill, or add a bundled script?
**Options considered:** inline bash in SKILL.md / bundled `scripts/check_domains.sh`
**Chosen:** Bundled script; SKILL.md documents the endpoint table for human audit.
**Decided-by:** agent
**Justification:** Per-TLD hosts, the `.co` WHOIS special case, and the `.app` retry loop all fail toward *false-available* if hand-rolled wrong — the one error mode that sends the user to buy a taken domain. Matches the sibling `chrome-cdp-setup` skill's convention of scripts invoked by absolute path.
**Outcome:** applied
**Ref:** (pending)

## Q6 — affix-domains/multi-tld — tradeoff

**Question:** An escalated sweep can return several hundred free domains. How should results be presented?
**Options considered:** dump the full name×TLD matrix / rank by best TLD per name / cap the candidate count
**Chosen:** Rank each surviving name by its best available TLD (`.com` > `.ai` > `.io` > `.co` > `.net` > `.org` > `.app` > `.cc`), show the top one or two per name, full matrix on request.
**Decided-by:** agent
**Justification:** No presentation rule was specified. The preference order reflects the reputation ranking discussed with the user this session; capping candidates instead would silently shrink coverage, which is worse than verbose output.
**Outcome:** assumed
**Ref:** (pending)

## Q7 — interactive/chrome-cdp-setup — tradeoff

**Question:** A 2026-09-06 session wrote a ~60-line Node relay to give a human more than Playwright's 30 s to click "Allow remote debugging?" and planned to add it to this skill. Ship it, describe it, or drop it?
**Options considered:** add `scripts/cdp_approval_relay.js` / describe the relay pattern in REFERENCE.md / drop it in favour of the built-in timeout knob
**Chosen:** Drop it. REFERENCE.md documents `PLAYWRIGHT_MCP_CDP_TIMEOUT=0 playwright-cli attach --cdp=chrome` instead.
**Decided-by:** agent
**Justification:** The relay's bridged path was never verified (its upstream handshake timed out with no Allow click) and it hard-codes a machine-local playwright-core path. The env var reaches the attach daemon and `0` removes the deadline — measured live on playwright-cli 0.1.19 (`4000` failed at 4 s, `0` still waiting at 40 s) — so the relay solves a problem the tool already solves.
**Outcome:** applied
**Ref:** 9654b64

## Q8 — interactive/chrome-cdp-setup — deviation

**Question:** The working tree carried uncommitted edits from 2026-07-21 (the "Rosetta trap" fix: `arch -arm64` launcher, `lsregister -u` re-registration, a native-arch check) that a conversation rewind reset to HEAD earlier today, while the live wrapper on this Mac already runs that fix. Rebuild from HEAD, or restore them first?
**Options considered:** restore the July diff (recovered from the session log) and build on it / rewrite from HEAD and re-derive the fix / leave the fix out
**Chosen:** Restore the July diff verbatim with `git apply`, then apply today's changes on top.
**Decided-by:** agent
**Justification:** `/Applications/Google Chrome CDP.app/Contents/MacOS/launcher` on this Mac contains `exec arch -arm64`, so the HEAD script would regress the deployed wrapper on its next run; the diff applied cleanly and is the user's own work.
**Outcome:** applied
**Ref:** 9654b64

## Q9 — interactive/chrome-cdp-setup — deviation

**Question:** The skill directory held two untracked strays: `.playwright-cli/`, 25 console/page snapshots from a real browser session, and a symlink `chrome-cdp-setup/chrome-cdp-setup` pointing at its own parent. The repo is public. Leave them, delete them, or move them out?
**Options considered:** leave / delete / move the dump out of the tree and remove the symlink
**Chosen:** An earlier pass of this session moved the dump to the session scratchpad and removed the symlink; that stands. No repo-level `.gitignore` was added — flagged to the user instead.
**Decided-by:** agent
**Justification:** The snapshots carry content from the user's logged-in tabs, and a self-parenting symlink recurses under any tool that follows links. A move keeps the step reversible; a root-level `.gitignore` is outside the skill and is the user's call.
**Outcome:** applied
**Ref:** 9654b64

## Q10 — interactive/herdr-rename-hook — deviation

**Question:** Moving the skill from `~/.claude/skills/` into this repo: move the files verbatim, or also rewrite the two places where the skill named the old directory as its home (the hook header's "Source of truth" line and SKILL.md's "Another Mac" scp recipe)?
**Options considered:** verbatim move (the old path still resolves through agentstow's link) / rewrite both references to the repo + agentstow flow and re-run install.sh so the deployed hook matches
**Chosen:** Rewrite both references, then re-run the skill's own install.sh so `~/.claude/hooks/herdr-rename-agent.sh` carries the new header (comment-only change).
**Decided-by:** agent
**Justification:** `~/.agents/AGENTS.md §Skills management` makes this repo the single source of truth for self-authored skills and agentstow the per-machine fan-out. A header naming the agent dir as the source, and an scp recipe that copies the directory host to host, would steer a future agent into editing or copying outside git. The ask ("move … and use agentstow to manage it") implies the repo becomes home. The live hook wiring in settings.json / hooks.json points at the installed copy, not the skill dir, so the move itself changed no behaviour.
**Outcome:** applied
**Ref:** 0324140

## Q11 — interactive/fleet-skills-clone — gate-resolution

**Question:** The ask was to "git clone" this repo to `~/github.com` on seven hosts. One (mac-mini-m2) is the machine the session runs on, five already held a clone that was behind origin, and only dev-server-frank-lume had none. Where exactly to clone, and what to do with the existing clones?
**Options considered:** clone literally to `~/github.com/skills` beside the existing clones / re-clone over them / fast-forward the existing clones and clone only where absent
**Chosen:** Path `~/github.com/soulmachine/skills` everywhere; `git pull --ff-only` on the five existing clones; a fresh clone only on dev-server-frank-lume; nothing on mac-mini-m2.
**Decided-by:** agent
**Justification:** `~/.agents/AGENTS.md §Skills management` names that path and every existing clone already used it. All five were clean, on `main`, tracking `origin/main`, strictly behind with no local commits, so a fast-forward was lossless. Every host ended at `15ee6ba`.
**Outcome:** applied
**Ref:** none — host-side only

## Q12 — interactive/fleet-skills-clone — gate-resolution

**Question:** agentstow was absent on mac-mini-2018, macbook-pro-nickel, archs-mac-mini and dev-server-frank-lume, yet the ask needs it there. Install it, or stop and report?
**Options considered:** report and skip those hosts / `brew install agentstow/tap/agentstow` (unbottled; pulls Homebrew's own rust) / `cargo install agentstow` from crates.io (how macbook-air and mac-studio-m3 hold it) / copy a built binary from another host
**Chosen:** `cargo install agentstow` (2.0.5, crates.io) on all four. agentstow 2.0.5 needs rustc ≥ 1.97 and three of the hosts had stable 1.96.0, so `rustup update stable` ran first on those.
**Decided-by:** agent
**Justification:** Every host already had rustup and cargo; two fleet hosts hold agentstow exactly this way (`~/.cargo/.crates.toml`). Homebrew's formula is unbottled and would add a second Rust; a copied binary would be untracked by cargo. Updating the `stable` channel is what that channel is for, and `rustup toolchain install 1.96.0` reverses it.
**Outcome:** applied
**Ref:** none — host-side only

## Q13 — interactive/fleet-skills-clone — gate-resolution

**Question:** "Skills in `~/.claude/skills` that have the same name" — only plain directories sitting directly in `~/.claude/skills`, or also names that resolve through `~/.agents/skills` to a copied real directory in the Commons (installed earlier with the `skills` CLI), plus a hand-made link straight into the repo? And what to do with a copy whose content differs from the repo?
**Options considered:** narrow (real dirs directly in `~/.claude/skills`) / broad (every repo-named entry not already a Sourced link); delete copies outright / keep a backup of any copy that differs
**Chosen:** Broad. Each copy was classified by content: every file's blob had to exist in the repo's history (or equal the pre-edit herdr-rename-hook files from Q10) at a path present in HEAD — then it was removed; anything else would have been moved to `~/.claude/skills.pre-agentstow-20260906/` or `~/.agents/skills.pre-agentstow-20260906/`. Then `agentstow adopt <repo>/<name>` and `agentstow sync`, and the matching `~/.agents/.skill-lock.json` entries were removed (a dated backup of the lock file kept beside it). On archs-mac-mini a hand-made absolute link for ssh-claude-auth in `~/.claude/skills`, which agentstow reports as foreign and never touches, was replaced by the canonical relative link.
**Decided-by:** agent
**Justification:** `~/.agents/AGENTS.md §Skills management`: a real directory in the Store means third-party (skills CLI + lock file), a symlink means self-authored from this repo. mac-studio-m3 and mac-mini-m2 already showed that end state (all Sourced, no lock entries). The blob check makes "stale copy" and "local edit" distinguishable, so nothing edited locally could be deleted. In the event every copy on every host matched history, so nothing was moved and no backup directory was created; only the dated lock-file backups exist.
**Outcome:** applied
**Ref:** none — host-side only

## Q14 — interactive/fleet-skills-clone — deviation

**Question:** Once herdr-rename-hook pointed at the repo, the skill's own `install.sh --check` reported the deployed hook as "drifted" on every host where it is installed, because Q10 changed the script's header comment. Re-run the installer there, or leave it to the user?
**Options considered:** leave it / run `install.sh` only where the hook is already installed / install the hook everywhere
**Chosen:** Ran `install.sh` only where `--check` showed the hook installed with its settings entries ok: macbook-air, mac-studio-m3, dev-server-frank-lume, mac-mini-2018, macbook-pro-nickel and archs-mac-mini (the hook was installed on all six). No new installs.
**Decided-by:** agent
**Justification:** This session's edit caused the drift; the installer is idempotent (settings reported "already"), the change is comment-only, and editing the script does not re-trigger Codex's trust prompt (SKILL.md). Every host afterwards passed `--check`.
**Outcome:** applied
**Ref:** 0324140 (the header change)

## Q15 — apple-design/skill — deviation

**Question:** The reference implementation (dickwu/apple-design-skill) pulls the HIG with a 779-line Node script, keeps only iOS/iPadOS/macOS pages (122), relabels platform headings by device class, and drops tvOS/visionOS/watchOS sections. Mirror that, or pull the whole HIG as Apple publishes it?
**Options considered:** port the Node script as-is / Python port with the same platform filter / Python, all six platforms, Apple's own headings
**Chosen:** Python (stdlib only, ~300 lines), all 158 article pages, Apple's headings and wording unchanged; collections folded into `references/hig-index.md`.
**Decided-by:** agent
**Justification:** The ask names developer.apple.com/design as a whole, and the reference's filter exists to serve Flutter/Electron reviewers; the fleet's own targets (FastSession iOS + macOS, watch/TV/Vision left open) gain nothing from discarding platforms and lose the `Platforms` column as a routing signal. Every fleet host has python3 and not every one has Node 18 on the login PATH. Verified: live pull and cached pull produce identical output; a second run writes nothing; no `doc://` identifiers leak.
**Outcome:** applied
**Ref:** (pending)

## Q16 — apple-design/skill — tradeoff

**Question:** Committing 1.9 MB of Apple-authored HIG text into this public repo, versus fetching pages on demand at task time.
**Options considered:** commit the generated pages / commit only the index and fetch pages live / commit nothing and always fetch
**Chosen:** Commit the generated pages.
**Decided-by:** agent
**Justification:** Offline, deterministic, greppable references are the point of the skill; a live fetch per task costs seconds, needs network on every host, and cannot be cited by stable file › heading. The reference repo publishes the same material the same way. The text stays Apple's (source URL in every file header); nothing is paraphrased as ours.
**Outcome:** assumed
**Ref:** (pending)

## Q17 — apple-design/skill — gate-resolution

**Question:** Skill name: `apple-design` collides with the reference repo's skill name if it is ever installed via the `skills` CLI alongside this one.
**Options considered:** `apple-design` / `apple-hig` / `apple-design-guidelines`
**Chosen:** `apple-design`.
**Decided-by:** agent
**Justification:** The reference is not installed on any fleet host (no `apple-*` entry in `~/.agents/skills` or the lock file), this skill supersedes it here, and `agentstow` refuses a duplicate name rather than silently overwriting.
**Outcome:** applied
**Ref:** (pending)

## Q18 — apple-design/skill — deviation

**Question:** `~/.agents/AGENTS.md §Skills management` says to run `agentstow sync` after adding a skill. Its dry run on mac-mini-m2 lists 10 changes, none about apple-design: it would prune stale `herdr` and `multica-cli` links in `~/.claude/skills` and rewrite the `gmail` and `google-calendar` MCP entries in Claude's config, which drifted from the Commons in `env` and `type` before this session. Run it anyway, or stop at `adopt`?
**Options considered:** run sync as instructed / stop at adopt and report / run sync after excluding the MCP restore (no such flag)
**Chosen:** Stop at `adopt`, which already linked apple-design into claude, pi, and hermes; leave `sync` unrun.
**Decided-by:** agent
**Justification:** The instruction's purpose (fan the new skill out) is met by `adopt`. The extra changes touch an MCP config in use by the running session with a token-bearing `env` whose intended value is unknown to the agent; running it later is one command, undoing an unwanted restore is not.
**Outcome:** assumed
**Ref:** (pending)

## Q19 — herdr-rename-hook/fleet — deviation

**Question:** The skill's own "Another Mac" recipe ends in `agentstow sync`, but Q18 deliberately left `sync` unrun on mac-mini-m2 because it would rewrite the `gmail` and `google-calendar` MCP entries whose `env` carries a credential. Run the recipe as written on the six other hosts, or stop at `adopt` there too?
**Options considered:** run the recipe as written / stop at `adopt` on every host / run sync only where no MCP drift exists
**Chosen:** Ran the full recipe on all six other hosts; mac-mini-m2 still has `sync` unrun.
**Decided-by:** agent, with the user's "go" on the recipe as quoted to them
**Justification:** Checked afterwards: no host except mac-mini-m2 has a `gmail` or `google-calendar` entry in `~/.claude.json` at all, so the Q18 hazard had no object there. The only token-shaped oddity found, `TAILSCALE_API_KEY: ""` on macbook-pro-nickel, has no Commons source (`TAILSCALE_MCP_PRESET` appears nowhere under `~/.agents`), so `sync` did not create it. Sync reported 16-45 changes per host, which is the backlog of every other pending skill change, not this one.
**Outcome:** applied
**Ref:** 8b819b9

## Q20 — herdr-rename-hook/fleet — gate-resolution

**Question:** `agentstow sync` reports the same conflict on 5 of 7 hosts: `~/.gemini/GEMINI.md` and `~/.config/opencode/AGENTS.md` are owned by claude-mem, "move or merge it, then sync again". Resolve it so sync runs clean?
**Options considered:** move the claude-mem file aside and let sync own the path / merge both contents into the path / leave the conflict standing
**Chosen:** Leave it standing. Do not hand those paths to agentstow.
**Decided-by:** agent
**Justification:** agentstow places instruction files as symlinks into the Commons (`~/.codex/AGENTS.md -> ../.agents/AGENTS.md`, `~/.pi/agent/AGENTS.md -> ../../.agents/AGENTS.md`). The files in conflict are 156- and 241-byte claude-mem `<claude-mem-context>` stubs that claude-mem rewrites wholesale. Give it a symlink and its next write lands *inside* `~/.agents/AGENTS.md`, the single source of truth that fans out to every agent on every host. The conflict is the guard, not the bug; a cosmetic warning is the cheaper half of that trade. A real fix belongs upstream: an ignore list in agentstow, or claude-mem appending instead of owning the file.
**Outcome:** assumed
**Ref:** (pending)

## Q21 — herdr-rename-hook/skill — gate-resolution

**Question:** The tab follows its tab's "first" pane. Should "first" mean oldest (creation order) rather than first in layout order?
**Options considered:** layout order / decode creation order from `terminal_id`'s counter / claim-based ownership recorded per tab
**Chosen:** Layout order, `pane layout` -> `.result.layout.panes[0]`.
**Decided-by:** agent
**Justification:** Measured on herdr 0.9.0-preview: `tab get` exposes no root-pane id, `pane list` returns the same geometric traversal as `pane layout`, and pane ids are not monotonic with creation order (`p1Y`, `p1Z`, `p10`, `p21` were created in that order). `pane split` offers only `right` and `down`, so a new pane cannot take the first slot by splitting — the case originally feared is unreachable. Only `pane swap`/`pane move` can reorder, and after a deliberate swap the leftmost pane is what the user calls first, so following it is right. The only signal that does track creation is the undocumented `term_<hex>.<hex>` counter in `terminal_id`, whose format and reset behaviour are not contracted; parsing it would misorder silently if either changed.
**Outcome:** applied
**Ref:** (pending)

## Q22 — interactive/herdr-advisor — gate-resolution

**Question:** The user repeatedly requested edits to herdr-advisor after being told the skill was absent. Create the skill or ask for its location again?
**Options considered:** create it from the existing Advisor Model procedure and the requested additions / repeat the location question
**Chosen:** Create herdr-advisor in this repository, then commit, adopt, and sync it locally. Include the requested same-tab vertical split, worker/advisor glossary, and three-source continuation loop. Leave AGENTS.md unchanged.
**Decided-by:** agent
**Justification:** The continued requests specify the intended skill behavior and imply making that skill available. Creating a new directory is reversible and preserves the existing instructions. The canonical location and installation procedure come from ~/.agents/AGENTS.md, Skills management.
**Outcome:** assumed
**Ref:** herdr-advisor/SKILL.md

## Q23 — herdr-advisor/read-only — gate-resolution

**Question:** The advisor tool doc says the advisor model "runs without tools", so a Herdr advisor should never write. Codex enforces read-only with a macOS seatbelt, which severs herdr's unix socket — how should the Codex advisor be launched?
**Options considered:** keep `--yolo` with the rule stated in the brief only / a `[permissions.herdr-advisor]` profile in `~/.codex/config.toml` on each host plus a short launch flag / the whole profile inline as `-c` flags
**Chosen:** Inline `-c` flags: `-a never -c default_permissions="herdr-advisor"` plus `extends=":read-only"`, `network.enabled=true`, and `network.unix_sockets={"$HERDR_SOCKET_PATH"="allow"}`.
**Decided-by:** user
**Justification:** Measured on codex-cli 0.154.0: `codex sandbox -- herdr agent list` returns `PermissionDenied`, and the same call under a profile carrying the socket allowance returns the full listing while `touch` is refused and no file appears. Inline flags keep the skill self-contained — it is fleet-synced to seven hosts, and a profile living in per-host config would silently fall back to full access wherever the config is missing. Verified in a real session via `codex exec`: `-c default_permissions=` does select the profile.
**Outcome:** applied
**Ref:** herdr-advisor/SKILL.md

## Q24 — herdr-advisor/read-only — gate-resolution

**Question:** Both CLIs ship a "let a model judge the permission prompt" mode — Codex `--approve-for-me`, Claude `--permission-mode auto`. Use either to enforce the advisor's read-only rule?
**Options considered:** Codex auto-review / Claude `auto` classifier / deny-by-default on both sides
**Chosen:** Neither judge. Claude uses `--permission-mode dontAsk` with a deny-list and allowlist; Codex uses the read-only profile.
**Decided-by:** user
**Justification:** Auto-review is "a reviewer swap, not a permission grant" and never reviews "anything already permitted under the active `sandbox_mode`" — it selects workspace-write, where an in-repo edit is already permitted and so never reaches the reviewer. It also aborts the turn after 3 consecutive denials, which an advisor looping on herdr calls would hit. Claude's `auto` is the same shape: a judge, not a boundary. `dontAsk` was measured to deny `touch` and `echo >` outright while leaving `git status`, `herdr agent list`, and `herdr agent prompt`/`send-keys` working. Both choices also satisfy the harder constraint that neither advisor may ever block its unwatched pane on a prompt.
**Outcome:** applied
**Ref:** herdr-advisor/SKILL.md

## Q25 — herdr-advisor/grilling-exclusion — gate-resolution

**Question:** The skill's grilling exclusion said "do not invoke during a Matt Pocock `grill-me` or `grill-with-docs` session" with no end condition, so a worker whose grill had already finished read itself as permanently barred. When does the exclusion lift, and which entry points does it cover?
**Options considered:** leave it unbounded and let the worker judge / bound it with the grilling skill's own completion condition / bound it and also name every grill entry point
**Chosen:** Bound it: the exclusion holds while a grilling session is open and lifts once its frontier is empty. Widened the enumeration from two entry points to four — `grilling` itself plus `grill-me`, `grill-with-docs`, and `batch-grill-me`.
**Decided-by:** human
**Justification:** The user reported agent `agent-sync` blocked after its grill ended with "Frontier is empty" and settled that the skill should be usable there. "Frontier is empty" is not an ad-hoc marker: all four grill skills carry the identical sentence "The session is done when the frontier is empty", so the exclusion now borrows that skill's own completion condition rather than inventing one. The enumeration widening is the agent's call and worth confirming: `grill-me` and `grill-with-docs` are one-line shims that call `grilling`, so an agent mid-session is running `grilling` — which the old text never named — while `batch-grill-me` inlines the same procedure and was missing outright.
**Outcome:** applied
**Ref:** herdr-advisor/SKILL.md

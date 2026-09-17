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

## Q26 — herdr-advisor/next-task-loop — tradeoff

**Question:** A worker often ends a turn inviting continuation on a literal word ("Say go and I'll refactor the parser"). Where does handling that belong among the loop's ordered sources, and what should the advisor send?
**Options considered:** send the exact trigger word as a new source ranked first, above the Claude Code ghost-text suggestion / rank it second, below the ghost text / fold it into the existing "next tasks in the response" source and let the advisor compose its own prompt
**Chosen:** A new source ranked second: send the exact word the worker named, nothing else. Ghost text keeps first place.
**Decided-by:** agent
**Justification:** Kept separate from the task-list source because the action differs in kind — the argument is dictated by the worker, not composed by the advisor — and sending "do 1, 2 and 3" to a worker waiting on "go" invites it to re-plan work it has already planned. Ranked below ghost text rather than above because source 1 already carries the turn-verification machinery and only applies to Claude Code workers with suggestions enabled, and in that overlap the suggestion is near-always the same continuation; reordering would be a larger claim than the reported need supports. Revisit if a ghost-text suggestion is observed diverging from an explicit invitation in the same response.
**Outcome:** applied
**Ref:** herdr-advisor/SKILL.md

## Q27 — herdr-advisor/next-task-loop — gate-resolution

**Question:** Worker evertranscript ended a turn reporting "nothing left within the current authorization" while its input box carried the ghost text "start ticket 03" — the one ticket it had just said the user told it not to start. Should the advisor accept such a suggestion and keep the loop running, or stop?
**Options considered:** refuse the suggestion and stop the loop, treating the worker's "told me not to start it" as binding / accept it and continue, treating that as a scheduling preference rather than a blocker
**Chosen:** Accept and continue. The stop is reserved for the case where every remaining item is a decision only the user can make.
**Decided-by:** user
**Justification:** The agent first shipped the opposite guard in e779e2a ("a suggestion is generated text, not an authorized task"), reasoning that Claude Code's suggestion engine had proposed explicitly withheld work. The user then directed that the loop should continue on suggestions of this shape, which reverses it; per the disagreement rule that reaffirmation settles it. The replacement draws the line at task versus decision — executable work is taken even if the worker was earlier told to hold off, while an adoption call, a threshold, or a preference is relayed to the user. Worth noting for a future reader: the investigation that produced e779e2a stands on its facts (ESC[2m dim ghost text, the worker's own wording), only the conclusion drawn from them was overridden.
**Outcome:** applied
**Ref:** herdr-advisor/SKILL.md

## Q28 — herdr-advisor/watchdog — tradeoff

**Question:** How should an advisor whose next-task loop has ended be restarted, given `herdr agent wait` exists only inside an advisor turn — so once that turn ends, nothing watches the worker and no event can restart it?
**Options considered:** a third-party socket subscriber on `events.subscribe` / an openroutine polling task / a worker-side `Stop` hook that pushes to the advisor
**Chosen:** Worker-side `Stop` hook (`herdr-advisor/stop-hook.sh`, registered through `~/.agents/hooks/Stop.toml` so agentstow renders it into both Claude and Codex). It pokes the paired advisor only when that advisor is `idle` or `done`. Full autonomy — unbounded re-arm — with a burst notification at 5 pokes per 10 minutes and kill switches at global and per-pair scope.
**Decided-by:** human
**Justification:** Seven-round grilling session. The user chose push over a subscriber ("push is better") and full autonomy over the bounded re-arm I recommended. Cost accepted: the hook runs on every Claude Code and Codex turn on the machine, so it is guarded to a cheap silent no-op outside a paired Herdr worker pane and never fails a turn. It does not violate `SKILL.md:166` — that forbids the worker *agent* waiting on the advisor mid-turn, whereas this fires after the turn has ended, so no mutual wait exists.
**Outcome:** applied
**Ref:** (pending)

## Q29 — herdr-advisor/agent-sync-pair — deviation

**Question:** `agent-sync`'s advisor was rebuilt as `claude-fable-5-1`, but the worker is itself a Claude agent — SKILL.md's model table pairs a non-GPT worker with a `gpt-6-astra` codex advisor precisely so the two differ in family.
**Options considered:** keep the codex advisor / wait for quota / pair same-family on Claude
**Chosen:** Same-family Claude pairing, accepted as a temporary deviation.
**Decided-by:** human
**Justification:** The codex advisor was not merely stalled — its pane showed "You've hit your usage limit ... try again at Sep 23rd, 2026 6:20 AM", so the gpt-6-astra option does not exist until then. The user specified the `claude-gw ... --model claude-fable-5-1` command directly. The cost is a weaker check: an advisor sharing the worker's family agrees with it more readily, so the pair is told this about itself in its brief.
**Outcome:** applied
**Ref:** (pending)

## Q30 — herdr-advisor/agent-sync-pair — irreversible-action

**Question:** The worker is offering step 3 — transferring `agentstow/agentstow` to `agent-sync-sh/agent-sync` — on the words "Say go and I'll start it." SKILL.md source 2 instructs the advisor to answer that literal invitation with `go`, which would fire an irreversible repo transfer that deliberately breaks nine OIDC trust entries.
**Options considered:** hand off the standard autonomous loop / carve step 3 out of the brief / do not restart the loop at all
**Chosen:** Restart the advisor as asked, but override source 2 for this pair: the brief forbids sending `go` for step 3 or step 5, and instructs the advisor to relay to the user and stop. Also paused the watchdog for this pair (`~/.config/herdr-advisor/paused.w8Q:p1`), because its generic re-arm nudge does not carry the carve-out and would let a re-armed advisor rediscover source 2 and send `go`.
**Decided-by:** agent
**Justification:** An irreversible, outward-facing transfer is the escalation floor — it is a decision only the user can make, not a task to be taken. Source 2 as written cannot tell an invitation to do reversible work from an invitation to do this; that gap is general and outlives this pair.
**Outcome:** applied
**Ref:** (pending)

## Q31 — herdr-advisor/evertranscript-pair — deviation

**Question:** Same question as Q29, now for the second pair: `evertranscript`'s Codex advisor also hit the usage limit (until Sep 23, 6:21 AM), and had silently degraded to `gpt-5.6-luna medium` rather than the `gpt-6-astra xhigh` SKILL.md specifies.
**Options considered:** leave it stalled until Sep 23 / rebuild it as `claude-fable-5-1`
**Chosen:** Rebuilt as `claude-fable-5-1` via `claude-gw`, same as Q29. Both live pairs are now same-family Claude.
**Decided-by:** human
**Justification:** Same quota outage as Q29; the user asked for the same treatment. Worth recording separately because it means the fleet currently has *no* cross-family advisor at all, so the independent-check property SKILL.md's model table exists to provide is absent everywhere until the quota resets. Each advisor's brief tells it this about itself.
**Outcome:** applied
**Ref:** (pending)

## Q32 — herdr-advisor/hold-primitive — gate-resolution

**Question:** SKILL.md told the advisor to "pause and relay" without defining what pausing is, leaving only loop-or-stop as real options. How should a hold be performed?
**Options considered:** end the turn / hold open inside the turn on a resolvable `herdr agent wait` condition / a bounded sleep-and-recheck
**Chosen:** End the turn, and say so explicitly — plus a named prohibition on re-arming `herdr agent wait` to stay alive.
**Decided-by:** agent
**Justification:** Observed failure, not theory: `agent-sync-advisor` improvised a hold as `herdr agent wait agent-sync --until working --timeout 590000`, re-armed it for over an hour, and reached 2% from auto-compact without advancing past turn 5. No wait condition fixes this — an idle worker only becomes `working` when a human prompts it, so any wait on worker activity resolves only after the awaited event has already happened, while the spin spends the context that would have let the advisor act on it. An ended turn costs nothing while it waits. The `Stop` hook is named as what resumes it, hedged with "where one is installed" because the watchdog is undocumented in this skill, is deployed on one host, and is paused for the pair that produced this bug.
**Outcome:** applied
**Ref:** (pending)

## Q33 — herdr-advisor/advisor-tool-surface — tradeoff

**Question:** Should the advisor launch with MCP tools disabled, and if so by what mechanism in each column?
**Options considered:** drop all MCP / keep a `serena` + `claude-mem` allowlist / keep MCP and fix the machine's global config instead
**Chosen:** Drop all. Claude: `--strict-mcp-config` alone. Codex: one `-c mcp_servers.<n>.enabled=false` per server that host declares, derived at launch, never hardcoded.
**Decided-by:** user
**Justification:** Measured, not assumed. Claude loads 114 MCP tools (~33k tokens) and a full advisor session called none of them — 54 `Bash`, 4 `Read`, 1 `Grep`, 0 MCP. The warrant is tool-list noise, not token budget: an A/B of `claude -p` counting `mcp__`-prefixed tools gave 142 without flags and 23 with, and those 23 proved to be the harness's own wrapper namespace for built-in tools, so the real MCP count reaches zero. The token argument was explicitly rejected — 33k against the 1M window the same change introduces is 3.3%, so the earlier draft's claim that MCP definitions "consume most of the context" was false by an order of magnitude and does not appear in SKILL.md. An allowlist was rejected as a maintained list that drifts on plugin reinstall and re-pays a fraction of the cost forever; global MCP hygiene was rejected as outside a skill's remit, though it remains the larger prize.

Two corrections to the draft this replaces. First, `--mcp-config '{"mcpServers":{}}'` was redundant: `--strict-mcp-config` alone already drops every scope including plugin-provided servers (142 -> 23 vs 24, within counting noise), and the empty map was the fragile half — inline JSON, single quotes that must survive zsh, through a launch path that already rewrites argv. Second, the draft concluded "a codex advisor still pays the MCP tax" from two true premises — `-c mcp_servers='{}'` merges rather than replaces (proven with a marker key that *added* a server), and `--strict-config` is validation only. The conclusion was false: per-server `enabled=false` takes codex from 248 tools (~55k tokens, of which `tailscale` alone is 126 tools / 25k) to 21. The search had stopped at "no flag shaped like claude's exists". Codex is also the default column — the table routes every non-GPT worker to it — so the draft fixed the rare column and declared the common, costlier one unfixable.

The derivation is per-host because the failure is fatal, not cosmetic: `-c mcp_servers.<name>.enabled=false` for a server that host does not declare in `[mcp_servers.*]` aborts config loading with `invalid transport`. A hardcoded list passes every test on the machine that wrote it and breaks the launch on the first host that differs. Known ceiling: plugin-injected servers (`cua_repl`, `mcp-search`, `mermaid`) cannot be overridden by the same route, so codex floors at ~21 tools where claude reaches zero. `--disable plugins` does clear them (verified: with it plus the per-server overrides, `codex mcp list` shows nothing enabled and a `RUST_LOG=codex_rmcp_client=trace` run logs zero server launches) but it is a blunt switch — it also drops every plugin skill (112 SKILL.md files under `~/.codex/plugins/cache`) and plugin hook (SessionStart fired 3 times instead of 8, losing claude-mem's capture), so the ~21-tool floor is accepted over that trade.

Not adopted, deliberately: no global MCP hygiene work item; no `CLAUDE_CODE_DISABLE_ADVISOR_TOOL=1` on the launch line, since `advisorModel` is currently unset and the inheritance trap only arms when it is set; no rename, despite the name colliding with Claude Code's first-party `--advisor` tool — a one-line disambiguation covers it, and the two are disjoint anyway (the native advisor is a server-side consultant with no tools, so it cannot drive a worker, and its pairing table is same-vendor only, which the cross-family rule here requires it not be).
**Outcome:** applied
**Ref:** 17735e8

## Q34 — herdr-advisor/verification-budget — gate-resolution

**Question:** The next-task loop bounded the advisor's writes and its holds but never its reading. How much may an advisor investigate before it must prompt the worker?
**Options considered:** bound verification as a spot-check and route surviving doubt to the worker / a hard tool-call or wall-clock cap per turn / leave the depth to advisor judgment
**Chosen:** A spot-check against the journal and the worker's own report, with no re-derivation from source, no re-fetching what the worker already verified, and no parsing its session transcript. A doubt that survives the spot-check **is** the next task and goes to the worker. The pre-task `herdr agent wait` is pinned at its 60-second timeout.
**Decided-by:** user
**Justification:** Observed failure, not theory. `evertranscript-advisor` held turn 0 for 26 minutes and 48 tool calls — 23 `Bash`, 18 `Read`, 5 `Grep`, 2 `WebFetch` — with **zero** `herdr agent prompt` or `send-keys` among them: it never touched the worker at all. 10m04s of that was one blocking `herdr agent wait --timeout 600000`, which reports the advisor as `working` while it does nothing. The rest was a genuine audit of `f9ff073` at `--effort max`: six source files, two HuggingFace re-fetches to byte-compare an artifact the worker had already checked, and three python passes over the worker's 83 MB session JSONL to recover the user's original prompt. Meanwhile the worker completed turn 151 — driven by the user, not the advisor — and sat idle for the last 11 minutes.

The advisor was not disobeying. Q30's quota clause tells a same-family advisor to "verify the worker's claims against the code" and the handoff brief made that verification a gate on task selection; neither bounded it, so an advisor at the top of its effort ladder had no stopping rule but its own satisfaction. The loop is also strictly serialized — wait, read, select, prompt `--wait` — so advisor time *is* worker idle time by construction. SKILL.md guarded the opposite deadlock ("avoids the worker waiting for the advisor while the advisor waits for the worker") and never this direction.

A hard cap was rejected as arbitrary: a legitimate spot-check can need several reads, and a counter invites gaming the count rather than the behaviour. Leaving the depth to judgment was rejected because that is precisely what produced the bug. The budget binds the loop's own reading, not a bounded consultation the worker requested — `agent-sync-advisor` was mis-interrupted during exactly such a consult on the same night, and the correction deadlocked its worker, which was waiting on the answer. Routing doubt to the worker is the cheaper fix *and* the correct role — an advisor that suspects a commit should have the worker re-verify it, which is what "it never edits; it tells the worker what to change" already meant.

A second defect surfaced in the same advisor's next turn, and source 1 now guards it: it read `^[[2m` on the worker's `register the migrations` suggestion, correctly identified it as ghost text, and declined to accept it *for that reason* — inverting the trigger into the refusal. The user overruled the hold and the suggestion was taken.

Known ceiling: nothing enforces this. It is prose in the loop, like the hold rule Q32 added. The `Stop`-hook watchdog cannot rescue it either — it fires on the worker's turn end and pokes only when the advisor's loop is *gone*; here it fired at 02:35:51 PDT and correctly logged `skipped-advisor-busy`, because a loop stuck inside a turn is indistinguishable from a healthy one. Recovery stayed manual: `herdr agent send-keys <advisor> esc`.
**Outcome:** applied
**Ref:** 98ff90c

## Q35 — herdr-advisor/wait-tick-cost — tradeoff

**Question:** The next-task loop's `herdr agent wait` timeout is a ceiling, not a duration, so a long worker turn is a series of re-armed ticks. How long is a tick, and what does the advisor do on each timeout?
**Options considered:** keep 60s and read output every tick (Q34) / raise to 10 minutes to cut tool calls / 110s with `agent get` only on timeout, output read only on a state change
**Chosen:** `--timeout 110000` for the loop wait and the three continuation prompts; on timeout, `agent get` alone and re-arm. The 60s bounded-consultation wait is a different path and is unchanged.
**Decided-by:** user
**Justification:** The tick count was not the cost. A timed-out wait returns only `{"error":{"code":"timeout"}}` — no state — so the follow-up `agent get` is necessary and ~200 tokens; the "fresh output" the old wording also asked for is the ~5k-token read block, and an hour-long worker turn at 60s ticks spent ~300k tokens re-reading a pane that had not changed, which walks the advisor into the compaction Q32 names as what kills a hold. Dropping the read cuts that 25×. 10 minutes was rejected on three grounds: it exceeds the Bash tool's 120s default, so it only works if the advisor also passes a per-call `timeout`; it blows the 5-minute prompt-cache window, so every re-arm re-reads the context uncached; and the tick is the advisor's worst-case latency to a queued prompt — the 26-minute deafness of `agent-sync-advisor` on 2026-09-17 was exactly one long wait. 110s stays under both limits: 33 ticks/hour, cache warm, ~7k tokens/hour while idling.
**Outcome:** applied
**Ref:** 53add85
**Supersedes:** Q34 — only its 60-second pin; the verification budget stands.

## Q36 — herdr-advisor/stop-condition — gate-resolution

**Question:** The next-task loop stopped on the worker's first "nothing left". Should one report end the loop, or should the advisor probe once before believing it?
**Options considered:** stop on the first "nothing left" (Q27) / send a bare `what's next` once and stop only on a second consecutive "nothing left" / probe N times or with a leading "check for follow-ups, tests, docs" prompt / cap probe→task→probe cycles
**Chosen:** A flat "nothing left" — no named task, no decision for the user — triggers one literal `what's next`; a second consecutive flat "nothing left" is the stop, and the advisor's last message quotes both answers. Any turn in which the advisor sent work, from any source, resets the count. The probe fires only on the flat shape: a report that names an unblocked item already has its next task (Q27), and one that turns on a user decision is a hold. "Every remaining item is a decision only the user can make" moves from stop to hold, so stop now means only "goal complete, nothing to wait for" and hold means "waiting on a human".
**Decided-by:** user
**Justification:** Grilling session, all recommendations accepted. Source 4 already sends `what's next` when a turn ends without an invitation or task list, so the loop was asymmetric: it probed vagueness but not completion, and a worker's first "done" is the least-considered answer it gives. Two identical answers to the same bare question is the evidence the stop rests on; that is why the probe stays literal — a leading prompt invites the worker to manufacture work, which is what the stop exists to avoid — and why it fires once, since a third probe adds cost and no information. No re-poke loop follows the stop: the worker's final turn fires the Stop hook while the advisor is still in its `--wait` (`skipped-advisor-busy`), and the advisor's own turn end self-hunts `…-advisor-advisor`.

Known ceiling: a make-work worker can ping-pong — "nothing left" → probe → trivial task → "nothing left" → probe — and every taken task resets the count, so it never stops. No cap on cycles, for the reason Q34 gave against counters: it invites gaming the count rather than the behaviour. The bare wording is the guard.
**Outcome:** applied
**Ref:** 384749f
**Supersedes:** Q27 — only its stop clause; accepting a suggestion that names withheld-but-unblocked work stands.

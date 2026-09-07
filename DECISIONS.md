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
**Ref:** (pending)

## Q8 — interactive/chrome-cdp-setup — deviation

**Question:** The working tree carried uncommitted edits from 2026-07-21 (the "Rosetta trap" fix: `arch -arm64` launcher, `lsregister -u` re-registration, a native-arch check) that a conversation rewind reset to HEAD earlier today, while the live wrapper on this Mac already runs that fix. Rebuild from HEAD, or restore them first?
**Options considered:** restore the July diff (recovered from the session log) and build on it / rewrite from HEAD and re-derive the fix / leave the fix out
**Chosen:** Restore the July diff verbatim with `git apply`, then apply today's changes on top.
**Decided-by:** agent
**Justification:** `/Applications/Google Chrome CDP.app/Contents/MacOS/launcher` on this Mac contains `exec arch -arm64`, so the HEAD script would regress the deployed wrapper on its next run; the diff applied cleanly and is the user's own work.
**Outcome:** applied
**Ref:** (pending)

## Q9 — interactive/chrome-cdp-setup — deviation

**Question:** The skill directory held two untracked strays: `.playwright-cli/`, 25 console/page snapshots from a real browser session, and a symlink `chrome-cdp-setup/chrome-cdp-setup` pointing at its own parent. The repo is public. Leave them, delete them, or move them out?
**Options considered:** leave / delete / move the dump out of the tree and remove the symlink
**Chosen:** An earlier pass of this session moved the dump to the session scratchpad and removed the symlink; that stands. No repo-level `.gitignore` was added — flagged to the user instead.
**Decided-by:** agent
**Justification:** The snapshots carry content from the user's logged-in tabs, and a self-parenting symlink recurses under any tool that follows links. A move keeps the step reversible; a root-level `.gitignore` is outside the skill and is the user's call.
**Outcome:** applied
**Ref:** (pending)

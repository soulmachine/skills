# Reference: swe-workflow

Detailed notes on each stage. Read this when something feels off, not on every invocation.

## Stage 0: `/setup-matt-pocock-skills` — How is this repo set up?

**Trigger**: a fresh repo (or one that hasn't adopted swe-workflow), with no `## Agent skills` block in `AGENTS.md`/`CLAUDE.md` and no `docs/agents/` directory.

One-time per-repo bootstrap. It wires the toolchain into a specific repo by writing:

- `## Agent skills` block in `AGENTS.md` (or `CLAUDE.md` if that's where the team keeps agent instructions) — declares which skills this repo uses and points at their per-repo docs.
- `docs/agents/` directory — repo-local agent documentation: which issue tracker is in use (GitHub or local markdown), the triage label vocabulary, and the layout for domain docs (`CONTEXT.md`, ADRs, `FEATURES.md`).

Downstream skills read this to know the repo's conventions: `/triage` learns which labels are valid here, stage 5 bootstrap learns where to fetch issues from (overriding the auto-detect in [Tracker selection](#tracker-selection)), `/grill-with-docs` learns whether `CONTEXT.md` should live at the root or under `src/<bounded-context>/`.

**Skip this stage** when the repo already has the `## Agent skills` block and `docs/agents/` populated — running it again would clobber existing config. This is a *per-repo* bootstrap, not *per-feature*; once it's run, you don't run it again.

**Not the same as spec-kit's "constitution" stage.** This is *tooling configuration* (where to fetch, what labels exist, where domain docs go), not *architectural invariants* (which patterns to follow, what the system must do). Those live in `CONTEXT.md` and ADRs and are produced by stage 1 — see the [framework comparison](#how-this-differs-from-spec-kit-class-frameworks) for why the distinction matters.

## Stage 1: `/grill-with-docs` — What do I want?

**Trigger**: vague language, fuzzy boundaries, no shared vocabulary yet.

The session interviews you about every branch of the design tree, one question at a time. Outputs:

- `CONTEXT.md` (project root or `src/<bounded-context>/`) — pure glossary, no implementation details
- `docs/adr/NNNN-*.md` — only for substantive architectural decisions

If a `CONTEXT-MAP.md` exists at repo root, the project uses multiple bounded contexts; each has its own `CONTEXT.md`.

**Re-runnable until quiet — or until you call it.** `/grill-with-docs` isn't one-shot: run it repeatedly, each pass sharpening `CONTEXT.md` (and possibly adding ADRs). Two things end the loop — a run surfaces **no more interview questions** (terminology has stabilized), or **you abort the interview** (you've heard enough). Either way, what's already in `CONTEXT.md`/ADRs stands; aborting forfeits only the unasked questions, not captured decisions.

**Skip this stage** when the terminology is settled and no new concepts are being introduced.

## Stage 2: `/to-features` — What features does this break into?

The **product→engineering bridge**, formerly a manual filesystem action, now a dedicated skill. `/to-features` reads `CONTEXT.md` + `docs/adr/*.md`, then enumerates the user-facing features the domain implies, and writes them to `FEATURES.md` at the repo root.

See the [`/to-features` skill](../../to-features/SKILL.md) for the full process and file format.

### Discipline: strike through, don't delete

When a feature ships, mark its line in `FEATURES.md` with strikethrough + a shipped reference (issue number / PR). **Never delete the line.** Strikethrough preserves:

- **Institutional memory** — what HAS shipped, not just what's pending
- **Traceability** — link from `FEATURES.md` to the issue/PR that completed it
- **Drift resistance** — you can't quietly drop a feature; dropping requires explicitly marking it out of scope (and writing the reason to `.out-of-scope/`)

Format:
- Pending: `- [ ] user-can-reset-password — A user can reset a forgotten password`
- Shipped: `- [x] ~~user-can-reset-password~~ — ~~A user can reset a forgotten password~~ (shipped: #42)`

### Optional: stub the filesystem alongside

For local-markdown teams, you can also stub the per-feature directories that downstream stages will fill:

```bash
mkdir -p .scratch/<feature-slug>/issues
```

This follows mattpocock's `.scratch/<feature>/` layout (see [`trackers/local-markdown.md`](../trackers/local-markdown.md)). The directory layout becomes a parallel view of the feature backlog: `ls .scratch/` shows what's actively being worked; absence of `PRD.md` in a stub means "not yet specced."

### When to skip this stage

When using GitHub/Linear/Multica/GitLab and your team handles feature enumeration in those tools (epics, projects, etc.), skip `/to-features` — use the external source of truth and pass features directly to `/to-prd`. Stage 2 fills the seam for local-markdown teams (or solo devs) who'd rather keep feature tracking in the repo alongside the code.

## Stage 3: `/to-prd` — What does done look like?

**Trigger**: glossary is stable, but no spec exists yet.

Synthesizes the conversation + codebase into a PRD without re-interviewing the user. The PRD contains:

- Problem Statement / Solution (user perspective)
- User Stories (extensive, numbered)
- Implementation Decisions (modules, interfaces, schemas — NO file paths)
- Testing Decisions (which modules get tested, prior art)
- Out of Scope

Published as a parent issue with `ready-for-agent` triage label.

**Common mistake**: putting file paths or line numbers in the PRD. Those rot. Describe interfaces and behavior instead.

## Stage 4: `/to-issues` — What are the units of work?

**Trigger**: PRD exists but is too big for any single agent to grab.

Breaks the PRD into **tracer-bullet** issues — thin vertical slices that cut through every layer (schema → API → UI → tests). For each slice:

- Title, type (HITL/AFK), blocked-by chain, user stories covered
- Issue body: parent reference, what-to-build (behavioral), acceptance criteria, blocked-by

You'll be quizzed before publishing: is the granularity right? Are dependencies correct? Are the right slices marked HITL vs AFK?

- **HITL** (human-in-the-loop) — needs architectural decision or design review during build.
- **AFK** (away-from-keyboard) — fully specified, agent can complete unattended.

Prefer AFK when possible. HITL is for genuine judgment calls, not for "I want to review every PR."

## Parallel concern: `/triage` — What's actionable for external issues?

**`/triage` is NOT a sequential stage in the chain.** `/to-prd` and `/to-issues` auto-apply the `ready-for-agent` label on the issues they create — those issues skip triage entirely and go straight to stage 5. `/triage` exists for issues filed *outside* the chain: user bug reports, external contributions, ad-hoc feature requests.

**Trigger**: an external issue arrives in the tracker without a triage label, OR an existing labeled issue needs re-evaluation after new info.

A small state machine: every issue carries one **category** (bug / enhancement) and one **state** (needs-triage, needs-info, ready-for-agent, ready-for-human, wontfix).

Outputs to issues:
- `ready-for-agent` → AGENT-BRIEF comment (the durable execution contract); from here the issue enters stage 5 like any chain-created issue
- `ready-for-human` → same structure, with rationale for why agents can't handle it
- `needs-info` → triage notes with specific outstanding questions
- `wontfix` (enhancement) → entry in `.out-of-scope/<concept>.md` before closing

Every triage comment starts with `> *This was generated by AI during triage.*`

`/triage` and the chain share vocabulary (`ready-for-agent` etc.) but not invocation — they're independent entry points into the same issue tracker.

## Stage 5: worktree + `/planning-with-files` — Build it

The skill is **instructions-only** — there are no scripts. The agent performs the bootstrap manually, adapting to the team's issue tracker (see [trackers/](../trackers/)).

### Bootstrap procedure (the agent performs each step)

1. **Pick a tracker** for this repo (see [Tracker selection](#tracker-selection)).
2. **Fetch the issue** per the relevant `trackers/<name>.md` doc — extract title, body, labels, AGENT-BRIEF.
3. **Derive paths**:
   - slug = title → lowercase → non-alphanumerics → `-` → truncate to 40 chars
   - branch = `issue-<id>-<slug>` (use the tracker's native ID format; Linear's `TEAM-123` passes through literally)
   - worktree = `../<repo>-issue-<id>/`
4. **Create the worktree**: `git worktree add ../<repo>-issue-<id> -b issue-<id>-<slug>`
5. **`cd` in and seed** the three planning files:
   - `task_plan.md` — Goal = title; Phases = AC checkboxes. Structured fields only.
   - `findings.md` — Raw issue body + AGENT-BRIEF pasted verbatim. Safe sink for external content.
   - `progress.md` — Initial session log entry.
6. **Invoke `/planning-with-files:plan`** (Stage 5) with this prompt:

   > /planning-with-files:plan Interview me about this issue, then write task_plan.md to implement it. The plan must use /tdd (tests first: red → green → refactor) for writing code and tests, and apply /karpathy-guidelines (surgical, simple changes) for code quality — and it must name both skills explicitly in task_plan.md so they're used when the plan is executed.

   The interview refines the seeds into the real plan. `task_plan.md` is the **core artifact** — it's what `/planning-with-files:plan-goal` reads in Stage 6. The final clause matters: instructing the planner to **write `/tdd` and `/karpathy-guidelines` into `task_plan.md`** is what makes them survive into execution — `plan-goal` inherits "build test-first, keep changes surgical" from the plan itself rather than needing to be re-told.
7. **Invoke `/planning-with-files:plan-goal`** (Stage 6) to execute — reads `task_plan.md` and drives each phase as a goal via Claude Code's goal command. Because the plan already calls for `/tdd` and `/karpathy-guidelines`, `plan-goal` just carries them out.

The split enforces the **security boundary**: `task_plan.md` is re-injected by hooks every tool call, so it gets only structured fields; raw external content (issue body, fetched docs) goes to `findings.md` instead.

### Tracker selection

Priority order:

1. `$SWE_WORKFLOW_TRACKER` env var (explicit override)
2. `tracker=<name>` line in `.swe-workflow.conf` at the repo root
3. Auto-detect from project signals:
   - `.scratch/` directory → `local-markdown` (mattpocock's `.scratch/<feature>/` convention)
   - github remote + `gh` installed → `github`
   - gitlab remote + `glab` installed → `gitlab`
   - `.linear/` directory → `linear`
   - `$MULTICA_WORKSPACE_ID` set → `multica` (no project-level signal — Multica config is user-level)
4. Still ambiguous → ask the user.

Per-tracker fetch commands and conventions live in [`trackers/<name>.md`](../trackers/) — one file per supported tracker. To add a new tracker, write a new doc following the same shape; nothing else changes.

### Inner loop: `/tdd` within each code-producing phase

`/planning-with-files:plan-goal` is the outer loop; `/tdd` is the inner loop. For each phase in `task_plan.md` that produces testable code:

1. Mark the phase `in_progress` in `task_plan.md`.
2. Invoke `/tdd`:
   - **RED** — write the failing test for this phase's behavior
   - **GREEN** — minimal code to pass
   - **REFACTOR** (optional)
3. Log the cycle outcome in `progress.md`.
4. Mark the phase `complete` in `task_plan.md`.
5. Move to the next phase.

**Nuances:**

- **Not every phase needs `/tdd`.** Exploration, `.gitignore` updates, config tweaks, infra changes have no behavior to test — just do them and log.
- **A single phase can contain multiple `/tdd` cycles** if the AC bundles sub-behaviors. Often a sign the AC was too coarse — note it in `task_plan.md` so the next `/to-issues` run can slice finer.
- **Decisions discovered mid-`/tdd`** (e.g., the public interface needs to change) land in `task_plan.md`'s Decisions table before continuing.
- **Errors during RED or GREEN** go in `task_plan.md`'s Errors table — same 3-strike protocol as any other error. Never silently retry a failed test in the same form.
- **`/tdd`'s own per-phase planning step is light** (interface confirmation, test list, prior-art lookup). It's not a duplicate of `/planning-with-files:plan`'s issue-level interview — just a quick check-in at the top of each phase.

**Mental shorthand**: `/planning-with-files` is the project manager keeping the calendar; `/tdd` is the engineer at the keyboard. One PM, many keyboard sessions per issue.

### When to skip stage 5 bootstrapping

For trivial AFK issues (rename a flag, fix a typo, bump a version), just do it. The hook overhead of `/planning-with-files` is unjustified for <5 tool calls.

### HITL execution

If the issue is `ready-for-human` or the AGENT-BRIEF flags HITL checkpoints:
- Don't let the planning-with-files Stop hook auto-finish you.
- Pause at the documented checkpoint, surface the decision, wait for direction.
- Resume by re-invoking `/planning-with-files` after the human responds — it re-reads the updated `task_plan.md`.

### Teardown after PR merge

From the **main checkout** (NOT inside the worktree):

```bash
# 1. Verify no uncommitted changes
git -C ../<repo>-issue-<id> status --porcelain    # output must be empty

# 2. Remove the worktree
git worktree remove ../<repo>-issue-<id>

# 3. Delete the branch only if merged into the default branch
default_branch=$(git symbolic-ref refs/remotes/origin/HEAD | sed 's@^refs/remotes/origin/@@')
if git branch --merged "$default_branch" | grep -qE "^[[:space:]]*\*?[[:space:]]*issue-<id>-<slug>$"; then
  git branch -d "issue-<id>-<slug>"
fi
```

Don't run this from inside the worktree being removed — git rejects that.

If you want the planning files as a post-mortem record, commit them on the branch BEFORE the teardown — the PR will carry them. Default is to discard.

## Completion signals

Four levels of "done"; the toolchain provides explicit semantics for three of them and deliberately stays out of the fourth.

### Phase

A phase in `task_plan.md` is done when its `/tdd` cycle lands green (or, for non-code phases, when the work is logged in `progress.md`). Recorded as a ticked checkbox in `task_plan.md`. Local to the worktree — dies at teardown.

### Issue

All phases in `task_plan.md` ticked **and** PR merged into the default branch. The merge event is the durable signal — `task_plan.md` itself is ephemeral. The tracker carries the persistent "closed/merged" status.

### Feature

Every issue produced by `/to-issues` on the feature's PRD has merged. Workflow:

1. **Detect**: walk from the PRD to its child issues (via the parent reference each issue body carries) and confirm all closed.
   - **GitHub**: `gh issue list --search "parent:<PRD#> state:open"` returns empty.
   - **Local-markdown**: every file in `.scratch/<feature-slug>/issues/` has a terminal `Status:` (e.g., `closed`).
   - **Linear / GitLab / Multica**: tracker-specific child-issue query.
2. **Mark**: strike through the `FEATURES.md` line and append shipped refs:
   ```
   - [x] ~~user-can-reset-password~~ — ~~A user can reset a forgotten password~~ (shipped: #42, #43, #44)
   ```
3. **Never delete the line** (see [Stage 2 discipline](#discipline-strike-through-dont-delete)) — strike-through preserves institutional memory and prevents quiet scope drift.

### Project

No native concept. The toolchain has `FEATURES.md` (per-repo backlog) but deliberately no `PROJECT.md`. Reasons:

- **Software projects rarely "complete".** Features keep getting added; the planned scope is always shifting.
- **Project completion is policy, not a fact.** "Are we done?" depends on release cadence, business commitments, and milestone definitions — none of which the toolchain has visibility into.

If you need a hard project-level signal, layer it on top of your tracker (GitHub milestones, Linear cycles, release tags) and define "project complete" as that milestone closing. The closest signal the toolchain itself provides is the state of `FEATURES.md` at a moment in time — zero `- [ ]` lines = every currently-enumerated feature has shipped — but this is a snapshot, not a guarantee. Adding a line resets it.

The asymmetry is intentional: phase/issue/feature completion is a **fact** the toolchain can verify; project completion is a **judgment call** that lives outside.

## Gotchas

- **Don't re-litigate PRD decisions in `task_plan.md`.** Architecture choices ("Postgres not Redis") are upstream. The `task_plan.md` Decisions table is only for *new* decisions made during execution (e.g., "extracted a CronExpression validator").
- **Don't `/to-issues` an issue you've already started executing.** That forks state. If a `ready-for-agent` issue turns out to need decomposition, send it back to triage as `needs-info` or split it via a new `/to-issues` run on the PRD parent.
- **Worktree path collisions.** If `../<repo>-issue-<id>/` already exists, the bootstrap aborts. Either you didn't tear down a previous attempt, or someone else is on the same issue. Resolve before retrying.
- **Tracker auth.** Each tracker has its own auth (`gh auth status`, `glab auth status`, `linear auth`, `multica` config, etc.). Verify before bootstrap — the fetch step fails fast if auth is missing.
- **`tp` skill conflict.** If you have the `tp` skill loaded, it overlaps with `/planning-with-files` at the execution layer. Pick one. This workflow assumes `/planning-with-files`.
- **Teardown location.** Run the teardown commands from the main checkout, NOT from inside the worktree being removed — git rejects removing the worktree you're currently in.

## How this differs from spec-kit-class frameworks

swe-workflow shares the "idea → PRD → issues → implement" arc with github/spec-kit, BMAD-METHOD, and GSD. The difference is structural:

| | swe-workflow | spec-kit-class frameworks |
|---|---|---|
| Composition | Chain of small skills (each = one markdown file) | Monolithic framework |
| Context control | You decide what enters each stage's context | Framework manages context flow |
| Modifiability | Edit any skill's markdown to change behavior | Configure within the framework's surface |
| Debuggability | Every input/output is a readable artifact | Internal state often opaque |
| Time decay | Per-issue planning files die at PR merge | Spec/plan files accumulate over time |
| LLM stance | Probabilistic reasoning partner | Tries to coerce determinism via guardrails |

A [community survey (~2000 AI coding course participants, April 2026, by Matt Pocock)](https://x.com/mattpocockuk/status/2044029094942159126) flagged **framework opacity** as the dominant failure mode for spec-kit-class tools: debugging is hard when you can't see what went into context. Specific failure reports from the same thread:

- *"Spec Kit outright ruined the process at the last place at the point we needed to ship the most"*
- *"Most of these frameworks optimize for demos, not debugging. The moment context goes wrong, everything falls apart"*
- *"The moment you hand context over to a 'workflow' the output drifts within days"*

This rules out some patterns from spec-kit-class even when they look useful:

- **A spec-kit-style "constitution" stage** (a dedicated step for project-level *architectural* invariants — patterns to follow, rules the system must obey) was considered and rejected. Architectural invariants already live in `CONTEXT.md` and `docs/adr/` (produced by `/grill-with-docs`); a separate constitution stage would import the framework opacity this chain claims to fight. swe-workflow's own [Stage 0](#stage-0-setup-matt-pocock-skills--how-is-this-repo-set-up) is a different beast — pure *tooling configuration* (tracker name, label vocabulary, doc layout), orthogonal to architectural rules.
- **Framework-driven implementation** (like `/speckit.implement`) is replaced by the layered worktree + `/planning-with-files` + `/tdd` execution stage. More moving pieces, but each is observable.
- **Long-lived spec artifacts in the repo** are avoided. Planning files (`task_plan.md`, `findings.md`, `progress.md`) live in worktrees and die at PR merge. Only the issue tracker and `CONTEXT.md`/ADRs survive across features.

## Source skills

- `grill-with-docs`, `to-prd`, `to-issues`, `triage` — https://github.com/mattpocock/skills
- `planning-with-files` — https://github.com/OthmanAdi/planning-with-files

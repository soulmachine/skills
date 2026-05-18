---
name: swe-workflow
description: Orchestrates the full five-stage flow from raw idea to shipped PR — grill-with-docs → to-prd → to-issues → triage → worktree+planning-with-files. Each stage answers one question (What do I want? / What does done look like? / What are the units of work? / What's actionable? / Build it). Use when the user has an idea but no spec yet, wants to plan a feature end-to-end, says "let's PRD this," asks "how do I start on this idea?", or grabs a ready-for-agent issue to implement.
---

# SWE Workflow

The idiomatic software-engineer pipeline: clarify the idea → spec it → slice it → triage it → ship it. Five stages, each with a dedicated skill and a durable artifact that feeds the next.

## The pipeline

```
┌────────────────────── SPEC LAYER (mattpocock) ──────────────────────┐
│                                                                      │
│  1. What do I want?                                                  │
│     /grill-with-docs ──► CONTEXT.md, ADRs                            │
│              (resolve domain language; capture decisions)            │
│                                                                      │
│  2. What does done look like?                                        │
│     /to-prd ──► PRD (GitHub issue)                                   │
│              (Problem / Solution / User Stories /                    │
│               Implementation Decisions / Testing Decisions / Scope)  │
│                                                                      │
│  3. What are the units of work?                                      │
│     /to-issues ──► N tracer-bullet issues                            │
│              (vertical slices, HITL/AFK, blocked-by chain, AC)       │
│                                                                      │
│  4. What's the state of each unit?                                   │
│     /triage ──► state machine + AGENT-BRIEF                          │
│              (needs-info / ready-for-agent /                         │
│               ready-for-human / wontfix)                             │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘
                                  │
                  (Agent grabs ONE `ready-for-agent` issue)
                                  │
                                  ▼
┌────────── EXECUTION LAYER (worktree + planning-with-files) ──────────┐
│                                                                      │
│  5. How do I ship each unit?                                         │
│     Fetch issue (per tracker) ──► worktree + branch + seed files     │
│              (task_plan.md, findings.md, progress.md from AC)        │
│                                                                      │
│     /planning-with-files:plan ──► interview → refine the plan        │
│              (sharpens phases, key questions, decisions to make)     │
│                                                                      │
│     /planning-with-files:start ──► implement → commit                │
│              (outer loop: phases, decisions, errors, findings)       │
│                                                                      │
│     /tdd ──► red → green → refactor (per code-producing phase)       │
│              (inner loop: one failing test → one minimal fix)        │
│                                                                      │
│     progress.md highlights ──► PR body / closing comment             │
│              (the session log IS the PR narrative — don't rewrite)   │
│                                                                      │
│     Teardown ──► git worktree remove + branch -d if merged           │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘
```

## Where to enter the chain

Don't always start at stage 1 — jump to where the chain actually breaks.

| Entry signal | Start at |
|--------------|----------|
| Vocabulary fights, fuzzy terms, no glossary yet | 1 |
| Glossary settled, no spec exists | 2 |
| PRD exists but is one mega-issue | 3 |
| Issues exist, nobody knows which to grab | 4 |
| Picked a `ready-for-agent` issue, ready to implement | 5 |

## Stage 5: worktree + planning-with-files

The skill is **instructions-only** — there are no scripts. The agent performs each step manually, adapting to the team's issue tracker.

### Bootstrap

1. **Pick the tracker.** See [Tracker selection](#tracker-selection) below.
2. **Fetch the issue** per [`trackers/<name>.md`](trackers/) — extract title, body, labels, AGENT-BRIEF.
3. **Derive paths**:
   - slug = title → lowercase → non-alphanumerics replaced with `-` → truncate to 40 chars
   - branch = `issue-<id>-<slug>` (Linear's `TEAM-123` passes through literally)
   - worktree = `../<repo>-issue-<id>/`
4. **Create the worktree**: `git worktree add ../<repo>-issue-<id> -b issue-<id>-<slug>`
5. **`cd` in and seed** three planning files:

   | File | Contents |
   |---|---|
   | `task_plan.md` | Goal = title; Phases = AC checkboxes. **Structured fields only** (hook re-injection risk). |
   | `findings.md` | Raw issue body + AGENT-BRIEF pasted verbatim. Safe sink for external content. |
   | `progress.md` | Initial session log entry with bootstrap timestamp. |

6. **Invoke `/planning-with-files:plan`** to refine seeds via interview, then `/planning-with-files:start` to execute.

### Tracker selection

Priority order:

1. **`$SWE_WORKFLOW_TRACKER`** env var (explicit override)
2. **`tracker=<name>`** line in `.swe-workflow.conf` at the repo root
3. **Auto-detect** from project signals:
   - `.issues/` directory → `local-markdown`
   - github remote + `gh` installed → `github`
   - gitlab remote + `glab` installed → `gitlab`
   - `.linear/` directory → `linear`
   - `$MULTICA_WORKSPACE_ID` set → `multica` (no project-level signal — Multica config is user-level)
4. Still ambiguous → ask the user.

Per-tracker fetch commands and conventions: [`trackers/<name>.md`](trackers/). To add a new tracker, write a new doc following the same shape — nothing else changes.

### Inner loop: `/tdd` for code-producing phases

`/planning-with-files:start` is the **outer loop** (phases, state, errors); `/tdd` is the **inner loop** (one failing test → one minimal fix). For each phase in `task_plan.md` that produces testable code:

```
Mark phase in_progress  →  /tdd (red → green → refactor)  →  log to progress.md  →  Mark phase complete
```

Not every phase needs `/tdd` — exploration, config tweaks, and infra changes skip it. See [REFERENCE.md](REFERENCE.md#inner-loop-tdd-within-each-code-producing-phase) for the full nuances (multiple cycles per phase, decision/error capture, when `/tdd`'s own planning step duplicates vs. complements the issue-level plan).

### Teardown (after PR merges)

From the **main checkout** (NOT inside the worktree):

```bash
# Verify no uncommitted changes
git -C ../<repo>-issue-<id> status --porcelain

# Remove worktree
git worktree remove ../<repo>-issue-<id>

# Delete branch only if merged into the default branch
default_branch=$(git symbolic-ref refs/remotes/origin/HEAD | sed 's@^refs/remotes/origin/@@')
git branch --merged "$default_branch" \
  | grep -qE "^[[:space:]]*\*?[[:space:]]*issue-<id>-<slug>$" \
  && git branch -d "issue-<id>-<slug>"
```

## Critical handoff rules

1. **PRD uses the glossary from stage 1.** If `to-prd` introduces terms that conflict with `CONTEXT.md`, loop back to `/grill-with-docs`.
2. **Issues are tracer bullets, not horizontal layers.** Each is a thin vertical slice (schema → API → UI → tests). "Backend issue" + "frontend issue" is a smell — re-slice.
3. **Triage is the spec→execution gate.** Nothing reaches stage 5 without `ready-for-agent` + an AGENT-BRIEF comment.
4. **One issue = one worktree = one `task_plan.md`.** Filesystem isolation for parallel AFK agents. No exceptions.

## Don't double-track

| Lives in… | Don't also put in… |
|-----------|--------------------|
| PRD (immutable arch decisions) | `task_plan.md` (would rot; the spec is authoritative) |
| AGENT-BRIEF (durable contract) | `task_plan.md` (copy only AC + key interfaces; raw brief goes in `findings.md`) |
| `task_plan.md` (execution-time decisions, errors hit) | The issue (don't litter the spec with build noise) |
| `progress.md` (session log) | A hand-written PR summary (the log IS the summary) |

## Security boundary

`planning-with-files` re-injects `task_plan.md` into context on every tool call. Any text in `task_plan.md` is an amplified prompt-injection target.

- Raw issue bodies, fetched docs, web content → `findings.md` only.
- `task_plan.md` gets only **structured fields** the executor wrote (Goal, Phases from AC, Decisions, Errors).

The bootstrap procedure ([Stage 5](#stage-5-worktree--planning-with-files)) enforces this split.

## When to skip this skill

- Single-file edits (no spec, no plan needed)
- Bug fixes where the AGENT-BRIEF is one paragraph — just do it, skip stage 5 bootstrap
- Exploration / prototypes — use the `prototype` skill instead

## Further reading

- [REFERENCE.md](REFERENCE.md) — per-stage detail, HITL vs AFK execution, gotchas
- Source skills: `grill-with-docs`, `to-prd`, `to-issues`, `triage` (mattpocock/skills), `planning-with-files` (OthmanAdi/planning-with-files)

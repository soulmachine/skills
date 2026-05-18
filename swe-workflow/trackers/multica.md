# Tracker: Multica

**CLI**: `multica` — see the `multica-cli` skill for setup. Auth via `multica login`.
**Config location**: user-level (`~/.multica/config.json`), not project-level.
**ID format**: dual — UUID (`bb3166b2-...`) AND human-friendly `identifier` (`ARC-47`, project-prefix + number).

## Fetch the issue

Issue details and comments are **separate calls** (like GitLab):

```bash
multica issue get <id-or-uuid> --output json
multica issue comment list <id-or-uuid> --output json
```

`issue get` defaults to JSON; `comment list` defaults to table — pass `--output json` explicitly there.

Pass whatever ID form the user gave (UUID, hex prefix ≥4 chars, or `ARC-47`-style identifier). The CLI documents UUID prefix support; identifier support is best-effort — fall back to UUID if it rejects.

## Confirmed JSON shape

Example output of `multica issue get`:

```json
{
  "id": "bb3166b2-177a-4c5b-8c75-b7bd5ecfeda0",
  "identifier": "ARC-47",
  "number": 47,
  "title": "Verify ACVMax Books?gbId={2,4} field-parity ...",
  "description": "## Parent\n\n... (full markdown body)",
  "labels": [
    {"id": "...", "name": "ready-for-human", "color": "#3b82f6", ...}
  ],
  "status": "todo",
  "priority": "high",
  "parent_issue_id": "...",
  ...
}
```

## Mapping to the normalized schema

| Normalized field | Multica source |
|---|---|
| title | `.title` |
| body | `.description` (**not** `.body` — naming differs from `gh`) |
| labels | `[.labels[].name]` (label objects → extract `.name`) |
| agent brief | First try `multica issue comment list`; filter for `## Agent Brief`. **If no such comment, the brief IS `.description` itself** — see next section. |

## Where the AGENT-BRIEF lives

Either of:

1. **As a comment** with `## Agent Brief` heading (mattpocock's canonical convention).
2. **As the issue body itself.** Multica issues often use a structured body (`## Parent` / `## Context` / `## What to investigate` / `## Acceptance criteria` / `## Blocked by` / `## References`). The whole `.description` IS the brief.

Detection logic:
- Fetch comments first.
- If a comment body matches `## Agent Brief` (case-insensitive), use that.
- Otherwise, treat `.description` as the brief.

AC extraction (`- [ ]` checkbox lines) works either way — the regex doesn't care where the brief lives.

## ID handling

Use `.identifier` (e.g., `ARC-47`) for branch and worktree names — far better than UUID prefixes:

- Branch: `issue-ARC-47-<slug>` (e.g., `issue-ARC-47-verify-acvmax-books`)
- Worktree: `../<repo>-issue-ARC-47/`

After `multica issue get`, read `.identifier` from the response and use it for downstream naming — regardless of which ID form the user originally typed.

## Auto-detect signal

No reliable project-level signal — Multica config is user-level (`~/.multica/`). Detection candidates:

1. `$MULTICA_WORKSPACE_ID` env var is set
2. `tracker=multica` line in `.swe-workflow.conf` at the repo root (preferred when mixing trackers across repos in the same workspace)

For workspaces where most repos use Multica, set `MULTICA_WORKSPACE_ID` once in shell init and the auto-detect picks it up.

## Workspace selection

Multica uses workspaces, set via:
- `MULTICA_WORKSPACE_ID` env var
- `--workspace-id` flag (passed on every command)
- `multica config set`

The bootstrap inherits whatever workspace is active when commands run.

## Status / priority labels

Multica carries `.status` (`todo`, in-progress, etc.) and `.priority` (`high`, etc.) as first-class fields, NOT as labels. mattpocock's triage state vocabulary (`needs-triage`, `ready-for-agent`, `ready-for-human`, `wontfix`) appears in `.labels[].name` if the team has adopted that convention on top of Multica's native status.

If a team uses both: trust `.labels` for triage state (matches mattpocock's chain), use `.status` for tracker-native state.

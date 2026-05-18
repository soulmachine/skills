# Tracker: Linear

**CLI**: [`linear`](https://linear.app/changelog) (official) or community alternatives.
**Auth**: API key via `linear auth login` (or env var per the CLI version in use).
**ID format**: `TEAM-123` (e.g., `ENG-42`). **String, not integer.**

## Fetch the issue

```bash
linear issue view TEAM-123 --json
```

Map to the normalized schema:

| Normalized field | Linear field |
|---|---|
| title | `.title` |
| body | `.description` |
| labels | `[.labels[].name]` |
| agent brief | last `.comments[]` whose body matches `## Agent Brief` (case-insensitive) |

## Where the AGENT-BRIEF lives

Linear has a comment thread — use the same `## Agent Brief` comment-heading pattern as GitHub.

## ID handling

The `TEAM-123` form is passed through literally:

- Branch: `issue-ENG-42-<slug>`
- Worktree: `../<repo>-issue-ENG-42/`

Do not strip the team prefix or convert to a number.

## Auto-detect signal

`.linear/` directory at the repo root, OR `~/.config/linear/` exists and the project has a Linear team configured.

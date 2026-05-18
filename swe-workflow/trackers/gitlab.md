# Tracker: GitLab Issues

**CLI**: [`glab`](https://gitlab.com/gitlab-org/cli) — requires `glab auth login` once.
**ID format**: integer (e.g., `123`).

## Fetch the issue

```bash
glab issue view <id> --output json
```

Note: `glab` field names differ from `gh`. Map them carefully:

| Normalized field | glab field |
|---|---|
| title | `.title` |
| body | `.description` (not `.body`) |
| labels | `.labels` (already a flat string array) |
| agent brief | Fetch separately: `glab issue note list <id>` then filter for `## Agent Brief` (case-insensitive) |

## Where the AGENT-BRIEF lives

Same `## Agent Brief` heading pattern as GitHub, but posted as an issue **note** (GitLab's term for a comment).

## Auto-detect signal

`glab` is in `PATH` **AND** `git config --get remote.origin.url` contains `gitlab.com`.

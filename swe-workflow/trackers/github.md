# Tracker: GitHub Issues

**CLI**: [`gh`](https://cli.github.com/) — requires `gh auth login` once.
**ID format**: integer (e.g., `123`).

## Fetch the issue

```bash
gh issue view <id> --json title,body,labels,comments
```

From the returned JSON, extract:

| Normalized field | jq expression |
|---|---|
| title | `.title` |
| body | `.body` |
| labels | `[.labels[].name]` |
| agent brief | `[.comments[] \| select(.body \| test("## Agent Brief"; "i"))] \| last \| .body` |

Last match wins — `/triage` may post multiple briefs on long-running issues.

## Where the AGENT-BRIEF lives

A comment with the `## Agent Brief` heading, posted by `/triage` when the issue moves to `ready-for-agent`. See mattpocock's `triage/AGENT-BRIEF.md` for the template.

## Auto-detect signal

`gh` is in `PATH` **AND** `git config --get remote.origin.url` contains `github.com`.

# Tracker: Local Markdown Files

**CLI**: none — just files on disk.
**ID format**: derived from filename. Default convention: `.issues/<id>.md`.

## Repo layout

```
.issues/
├── 1.md
├── 2-truncate-descriptions.md
└── ...
```

`<id>` can be an integer or a slug — whatever the team prefers. The agent passes whatever the user typed straight through.

## File format

```markdown
---
labels: [bug, ready-for-agent]
---

# Truncate descriptions at word boundary

When descriptions exceed 1024 chars, they truncate mid-word, producing
broken output like "Use when the user wants to confi".

## Agent Brief

**Category:** bug
**Summary:** Word-boundary truncation for description field.

**Acceptance criteria:**
- [ ] Descriptions under 1024 chars are unchanged
- [ ] Over 1024 chars truncated at last word boundary
- [ ] Truncated descriptions end with "..."
```

## Extracting fields

| Normalized field | How to extract |
|---|---|
| title | First H1 (`# …`) in the file |
| body | Everything between the H1 and the `## Agent Brief` heading (exclusive of the brief heading) |
| labels | YAML frontmatter `labels:` list (omit if no frontmatter) |
| agent brief | The `## Agent Brief` section through to end of file |

There's no comment thread, so the AGENT-BRIEF lives in the body. When normalizing, return it as a single-element comments array: `[{"body": "<brief content>"}]`.

## Auto-detect signal

A `.issues/` directory exists at the repo root.

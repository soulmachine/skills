---
name: herdr-advisor
description: Pair a Herdr worker with one advisor from another model family. Use when the Advisor Model rule applies or the user asks for a Herdr advisor to review decisions and lead the worker through its remaining tasks. Do not invoke while a grilling session is still open.
---

# Herdr advisor

This file is the **worker's**. Advisor: your manual is `ADVISOR.md` in this
directory; read that instead.

Unrelated to Claude Code's built-in advisor tool (`--advisor`): this skill
launches a separate agent process that drives the worker.

**Do not invoke this skill while a grilling session is open**: the `grilling`
skill, or `grill-me`, `grill-with-docs` or `batch-grill-me`, which all run it.
Continue that session directly, without creating, consulting, or handing off to
an advisor, even when the Advisor Model rule would otherwise apply. The session
ends when its frontier is empty; from then on, carrying out the agreed plan is
ordinary work and the rule governs it normally.

## Roles

- **Worker**: you, the main Herdr agent doing the user's work. Only you create
  the pair, and you make every change. Verify advice before acting on it.
- **Advisor**: a read-only leaf agent. It advises you and leads you to the next
  task; it never edits, it tells you what to change.

Read `~/.agents/skills/herdr/SKILL.md` before operating on agents; this
workflow authorizes that use of Herdr. Require `HERDR_ENV=1`: outside Herdr,
continue the task directly rather than creating an advisor through another
tool. Stay within the user's existing goal and permissions; preferences,
private facts and authorization are the user's to answer.

## Create or reuse the advisor

**Name.** Run `herdr pane current --current`, then match its `pane_id` in
`herdr agent list` to find your registered name; a pane or tab label is not an
agent name. The advisor is `<worker-name>-advisor`, and the Stop-hook watchdog
finds it only under that exact name in your tab. Names match
`[a-z][a-z0-9_-]{0,31}`: shorten the base to at most 24 characters, check for
collisions, and choose a descriptive base if you are unnamed. A shortened or
invented base goes unwatched.

**Model.** One advisor, from a different model family, with `<effort>` below
set to `xhigh`:

| Worker model | Advisor model | Herdr kind |
|---|---|---|
| GPT | `claude-fable-5-1[1m]` | `claude` |
| Anything else | `gpt-6-astra` | `codex` |

**A quota outage overrides the table.** When the table's model has hit its
usage limit, pair with an advisor from your own family: a weaker check beats
none. The tell is in the advisor's pane: `You've hit your usage limit`,
sometimes with the model silently downgraded. Tell that advisor in the handoff
that it shares your blind spots, so it should spot-check your claims against
the code. Restore the table's pairing once the quota resets.

**A same-family advisor must outrank you**, on model first and effort second.
The pinned models are the most capable in their families, which settles the
model rung; your own model is unreadable, so set effort. `herdr pane
process-info --pane <id>` and your pane footer show your `--effort`: give the
advisor one rung above it as `<effort>`. `claude` ends at `max` and `codex` at
`ultra`; at the top of your own ladder, match.

Native arguments for `claude`:

```
--permission-mode dontAsk --disallowedTools Edit,Write,NotebookEdit --allowedTools "Bash(herdr:*) Read Grep Glob WebSearch WebFetch" --effort <effort> --model 'claude-fable-5-1[1m]' --strict-mcp-config
```

Keep `'claude-fable-5-1[1m]'` quoted, because zsh globs the brackets, and keep
the suffix: the bare id is the 200k-context variant. Claude Code's model
catalog lists only the bare id, so the suffix's absence there is not evidence
against it.

Native arguments for `codex`, where `$HERDR_SOCKET_PATH` is exported in every
Herdr pane:

```
-a never -c default_permissions="herdr-advisor" -c 'permissions.herdr-advisor.extends=":read-only"' -c 'permissions.herdr-advisor.network.enabled=true' -c "permissions.herdr-advisor.network.unix_sockets={\"$HERDR_SOCKET_PATH\"=\"allow\"}" --search -c model_reasoning_effort=<effort> -m gpt-6-astra
```

Append one `-c` per MCP server that **this host** declares:

```
grep -oE '^\[mcp_servers\.[A-Za-z0-9_-]+\]$' ~/.codex/config.toml \
  | sed 's/\[mcp_servers\.//; s/\]//; s/^/-c mcp_servers./; s/$/.enabled=false/' | tr '\n' ' '
```

- Derive that list on the host, never hardcode it: naming a server the host
  does not declare aborts config loading with `invalid transport`.
- Leave out `--disable plugins` (it also drops every plugin skill and hook),
  `--sandbox`/`-s read-only` (it severs herdr's unix socket and disables
  profile mode) and `--approve-for-me` (a reviewer swap, not a permission
  grant).
- Keep the socket path as an inline TOML table. The dotted-path form fails,
  because the parser splits on the dots inside the path.

The two commands grant the same eight capabilities by different means. Keep
them aligned: if you change one column, change its counterpart.

| The advisor must | `claude` | `codex` |
|---|---|---|
| never ask | `--permission-mode dontAsk` | `-a never` |
| never write | `--disallowedTools Edit,Write,NotebookEdit` | `extends=":read-only"` |
| read files | `Read Grep Glob` | `extends=":read-only"` |
| drive the worker | `Bash(herdr:*)` | `network.unix_sockets` allowing `$HERDR_SOCKET_PATH` |
| reach the web | `WebSearch WebFetch` | `--search` |
| think hard | `--effort <effort>` | `-c model_reasoning_effort=<effort>` |
| pin the model | `--model 'claude-fable-5-1[1m]'` | `-m gpt-6-astra` |
| carry no MCP tools | `--strict-mcp-config` | `-c mcp_servers.<n>.enabled=false` per declared server |

**Neither advisor ever asks.** Nobody watches its pane, so a permission prompt
is a hang, not a safeguard. Keep both in their deny-and-carry-on modes, never a
prompting one.

**Reuse** your existing advisor after checking its identity, model family,
workspace, tab, and working directory. Sharing your family is not on its own
grounds to replace it: judge it by the outrank rule, reading its `--model` and
`--effort` with `herdr pane process-info --pane <id>`. Otherwise **create** one
to your right, in the same tab and cwd, since the watchdog matches on the tab.
This workflow splits right even when the Herdr skill would split down, opens no
new tab or workspace, and leaves the user's focus where it is:

```bash
herdr pane split --current --direction right --cwd "$PWD" --no-focus
```

Use the returned `.result.pane.pane_id` with `herdr agent start`:

```bash
herdr agent start <advisor-name> --kind <kind> --pane <returned-pane-id> -- <native-arguments>
```

## Hand off

Set `advisor` to its pane ID or registered name, never to whichever pane has UI
focus. Send the handoff **without `--wait`**, then carry on with your turn:

```bash
herdr agent prompt "$advisor" "<handoff>"
```

> Read ~/.agents/skills/herdr-advisor/ADVISOR.md and follow it. You are the
> read-only leaf advisor for worker <worker-name-or-pane-id>: hand every change
> to the worker, and never create or consult another advisor. The spec is
> <path-or-issue>. So far: <where the work stands>. Constraints: <constraints>.
> <Your first question, if you have one.>

Name the spec by path or issue rather than retelling it; with no spec, state
the goal. For a review-only job, add: "This is a bounded assignment: answer
once by prompting the worker, then stop."

## Work with the loop

The advisor watches your turns and prompts you when each one ends. Your side:

- **End your turn; never prompt or wait on the advisor.** A consult is a
  turn-ending question. Consult before asking the user for a technical
  judgment, and consider it before choosing an approach, after repeated
  failures, and before declaring the task done. Give the question, evidence,
  constraints and your proposed approach; the answer arrives as your next
  prompt.
- **Say plainly what remains**: tasks, a question, a decision for the user, or
  "nothing left". The advisor asks `what's next` once to confirm before it
  stops.
- **Flag irreversible steps** (publishing a version, transferring or deleting a
  remote resource, sending a message, force-pushing over shared history,
  destroying untracked data, spending money), so the advisor holds for the
  user instead of sending `go`.

Why each rule exists: `~/github.com/soulmachine/skills/DECISIONS.md`, Q22 onward.

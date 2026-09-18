---
name: herdr-advisor
description: Pair a Herdr worker with one advisor, a stronger model that answers questions on the user's behalf to unblock the worker and leads it to its next task, by accepting its prompt suggestion or sending it text: a worker "still waiting on your go" gets `go`. Invoked by the user only.
disable-model-invocation: true
---

# Herdr advisor

Invoked by the user only (`/herdr-advisor`); never on your own judgment.

This file is the **worker's**. Advisor: your manual is `ADVISOR.md` in this
directory; read that instead.

Unrelated to Claude Code's built-in advisor tool (`--advisor`): this skill
launches a separate agent process that drives the worker.

## Roles

- **Worker**: you, the main Herdr agent doing the user's work. Only you create
  the pair, and you make every change. Verify advice before acting on it.
- **Advisor**: a read-only leaf agent. It answers your questions on the user's
  behalf to unblock you, and leads you to your next task by accepting your
  prompt suggestion or sending you text; it never edits, it tells you what to
  change.

Read `~/.agents/skills/herdr/SKILL.md` before operating on agents; this
workflow authorizes that use of Herdr. Require `HERDR_ENV=1`: outside Herdr,
tell the user and stop. Stay within the user's existing goal and permissions.
Only a fact or act the user alone has (a one-time code, a password, a
physical step) is the user's to answer; everything else, the advisor answers.

## Choose the advisor

Two files in this directory settle the choice: `MODELS.md` ranks the models
and says which are eligible for your worker; `HARNESS-CLIS.md` says how each
coding-agent CLI launches one, with the effort rung and the arguments.

**Your own model.** `herdr pane process-info --pane <your-pane-id>` shows your
command line; read your model and effort from it by the flags in your CLI's
`HARNESS-CLIS.md` row. Unreadable: you are the top row of your family.

**Ask the user**, in one `AskUserQuestion` dialog with two questions:

1. *Advisor model*: the eligible rows from `MODELS.md`, best first, at most
   four; the first is your recommendation, the other-family row of highest
   rank, marked "(Recommended)".
2. *Harness CLI*: the model family's own CLI first, marked "(Recommended)",
   then `pi`, then the installed CLIs and shell aliases that run the model,
   found with `command -v` and `zsh -ic alias` against the `HARNESS-CLIS.md`
   rows and its alias table; at most four. The dialog cannot make these
   options depend on the first answer, so each option names the model it
   would run (`codex: gpt-6-astra`), and a harness option that names a
   different model than the one chosen in question 1 is the user's answer
   to both.

On a harness without that tool, write the same two questions as numbered
options in plain text and end your turn; continue on the user's answer.

**A quota outage overrides the choice.** When the advisor's model has hit its
usage limit, the tell in its pane is `You've hit your usage limit`, sometimes
with the model silently downgraded. Re-create it on the next eligible row,
telling it in the handoff when it shares your family, so it should spot-check
your claims against the code. Restore the chosen pairing once the quota
resets.

## Create or reuse the advisor

**Name.** Run `herdr pane current --current`, then match its `pane_id` in
`herdr agent list` to find your registered name; a pane or tab label is not an
agent name. The advisor is `<worker-name>-advisor`: the watchdog planted
below keeps its loop alive only under a name with that suffix. Names match
`[a-z][a-z0-9_-]{0,31}`: shorten the base to at most 24 characters, check for
collisions, and choose a descriptive base if you are unnamed.

**Reuse** your existing advisor after checking its identity, model, workspace,
tab, and working directory (`herdr pane process-info --pane <id>` shows its
command line). Otherwise **create** one to your right, in the same tab and
cwd. This workflow splits right even when the Herdr skill would split down,
opens no new tab or workspace, and leaves the user's focus where it is:

```bash
herdr pane split --current --direction right --cwd "$PWD" --no-focus   # → .result.pane.pane_id
herdr pane run <pane-id> "python3 ~/.agents/skills/herdr-advisor/watchdog.py <pane-id> &"
sleep 3
herdr agent start <advisor-name> --kind <kind> --pane <pane-id> -- <native arguments>
```

`<kind>` and `<native arguments>` are the CLI's row in `HARNESS-CLIS.md`,
with `<model-id>` and `<effort>` filled in; a row that needs environment
passes it as `--env KEY=VALUE` on `pane split`. The watchdog must be planted
before the agent starts. `agent_pane_busy` from `agent start` is transient,
the shell's ownership check, and fires about half the time even after the
3 s: wait 2 s and retry.

**The advisor never asks.** Nobody watches its pane, so a permission prompt is
a hang, not a safeguard. Every row runs in a deny-and-carry-on mode; keep it
there.

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
the goal.

## Work with the loop

The advisor watches your turns and prompts you when each one ends. Nobody
prompts the advisor: it never waits on the user, and it answers for the user.
Your side:

- **End your turn; never prompt or wait on the advisor.** A consult is a
  turn-ending question. Consult before asking the user for anything, and
  consider it before choosing an approach, after repeated failures, and before
  declaring the task done. Give the question, evidence, constraints and your
  proposed approach; the answer arrives as your next prompt. Ask in that text,
  never with `AskUserQuestion` or another dialog, which the advisor cannot
  answer.
- **Say plainly what remains**: tasks, a question, a fact or act only the user
  can supply, or "nothing left". The advisor asks `what's next` once to
  confirm before it ends.
- **Flag irreversible steps** (publishing a version, transferring or deleting a
  remote resource, sending a message, force-pushing over shared history,
  destroying untracked data, spending money), so the advisor decides them
  knowingly.
- **Journal the advisor's answers.** Where the project keeps a `DECISIONS.md`,
  record each call the advisor made for the user with `Decided-by: advisor`.

## Stop the advisor

The watchdog re-prompts every turn the advisor ends while its name carries the
`-advisor` suffix, up to eight an hour, leaving alone a new turn started
within 10 s; past the cap it releases the advisor and notifies the user. So
`Esc` in its pane is not a stop. To end it, on the user's say-so, by pane ID,
since the name is gone after the first command:

```bash
herdr agent rename <advisor-pane-id> --clear
herdr agent send-keys <advisor-pane-id> esc
```

The watchdog lets that turn end stand and exits, within a minute when the
advisor was already idle; close the pane when the user wants it gone. An
ended pair is re-created by the user's next `/herdr-advisor`, not by you.

Why each rule exists: `~/github.com/soulmachine/skills/DECISIONS.md`, Q22 onward.

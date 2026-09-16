---
name: herdr-advisor
description: Pair a Herdr worker with one advisor from another model family. Use when the Advisor Model rule applies or the user asks for a Herdr advisor to review decisions and lead the worker through its remaining tasks. Do not invoke during Matt Pocock's grill-me or grill-with-docs sessions.
---

# Herdr advisor

Do not invoke this skill during a Matt Pocock `grill-me` or `grill-with-docs`
session, even when the Advisor Model rule would otherwise apply. Continue that
session directly without creating, consulting, or handing off to an advisor.

## Roles and scope

- **Worker:** the main Herdr agent doing the user's work.
- **Advisor:** the Herdr agent that advises the worker and leads it to the next task.

Only the worker creates the pair. The advisor is a leaf agent: never create another
advisor, delegate a review, or ask the worker to advise you. The assignment defines
the role even without an `-advisor` name. The worker verifies advice before acting.

Read `~/.agents/skills/herdr/SKILL.md` before operating on agents. This workflow
authorizes that use of Herdr. Require `HERDR_ENV=1`; outside Herdr, continue the
task directly without creating an advisor through another tool.

Continue tasks within the user's existing goal and permissions. Questions about
user preferences, private facts, or authorization still go to the user.

## Create or reuse the advisor

Run `herdr pane current --current`, then match its `pane_id` in `herdr agent list`
to find the worker's registered name. A pane or tab label is not an agent name.
Use `<worker-name>-advisor`; shorten the base to at most 24 characters and check
for collisions. If the worker is unnamed, choose a descriptive base. Agent names
must match `[a-z][a-z0-9_-]{0,31}`.

Use one advisor from a different model family:

| Worker model | Advisor model | Herdr kind | Native arguments |
|---|---|---|---|
| GPT | `claude-fable-5-1` | `claude` | `--dangerously-skip-permissions --effort xhigh --model claude-fable-5-1` |
| Anything else | `gpt-6-astra` | `codex` | `--yolo -c model_reasoning_effort=xhigh -m gpt-6-astra` |

Reuse the worker's existing advisor after checking its identity, model family,
workspace, tab, and working directory. Otherwise create a **vertical split**,
with the advisor to the right of the worker in the **same Herdr tab** and cwd:

```bash
herdr pane split --current --direction right --cwd "$PWD" --no-focus
```

Use the returned `.result.pane.pane_id` with `herdr agent start`:

```bash
herdr agent start <advisor-name> --kind <kind> --pane <returned-pane-id> -- <native-arguments>
```

Keep the user's focus unchanged. Do not create a new tab or workspace for the
advisor. This workflow uses a right split even when the general Herdr skill
would choose a down split based on pane dimensions.

## Consult and hand off

Consult the advisor before asking the user for a technical judgment. Consider a
consult before choosing an approach, after repeated failures, and before declaring
the task done. Include the question, evidence, constraints, and proposed approach.

In the commands below, set `worker` and `advisor` to their discovered pane IDs or
registered names. Never target whichever pane happens to have UI focus.

For a bounded consultation, wait until the advisor is `idle` or `done`, then use
`herdr agent prompt "$advisor" "<brief>" --wait --timeout 60000` and read its reply.
Start the brief with:

> You are the leaf advisor for worker <worker-name-or-pane-id>. Answer directly
> without delegating or consulting other agents. This is a bounded consultation;
> reply with your advice and wait for a continuation handoff.

After setup and any initial consultation, hand off continuation with
`herdr agent prompt "$advisor" "<handoff>"` **without `--wait`**. Include the worker's
pane ID, goal, remaining context, and this instruction:

> Read ~/.agents/skills/herdr-advisor/SKILL.md. You are the advisor for worker
> <worker-name-or-pane-id>. Follow its next-task loop until the worker says there
> is nothing left. Do not create or consult another advisor. The worker is doing
> <goal>, with these constraints: <constraints>.

The worker finishes its current turn without waiting for the continuation loop.
This avoids the worker waiting for the advisor while the advisor waits for the
worker. The advisor keeps its loop running across worker turns rather than ending
its own turn after each prompt.

While continuation is active, the worker must not prompt or wait for the advisor.
Put any technical question in the worker's response and finish the turn;
the advisor answers that question before selecting another task. Keep bounded
review-only assignments bounded when the user requests them.

## Lead the worker to the next task

Wait for the worker to finish its current turn. Read its latest response and
current input box before selecting the next task:

```bash
herdr agent wait "$worker" --timeout 60000
herdr agent get "$worker"
herdr agent read "$worker" --source recent-unwrapped --lines 120
herdr agent read "$worker" --source visible --format ansi
```

If the worker says there is nothing left for the current goal, stop the loop.
Check this before following suggestions. If the response needs the user's
preferences, private facts, or authorization, pause and relay that question even
if Herdr reports `idle`. Answer technical questions from the worker directly.
Otherwise use these sources in order:

1. **Claude Code prompt suggestion.** If the worker is Claude Code and its input
   box is otherwise empty and shows grayed-out next-prompt ghost text, send Right
   arrow to accept it:

   ```bash
   herdr agent send-keys "$worker" right
   herdr agent read "$worker" --source visible --format ansi
   ```

   Verify that the intended suggestion is now editable input rather than dim
   ghost text, with no user draft added. Record the current worker turn, submit,
   and wait for evidence that the new turn started:

   ```bash
   herdr agent get "$worker"
   herdr agent send-keys "$worker" enter
   herdr agent wait "$worker" --until working --until blocked --timeout 10000
   ```

   If the turn finishes too quickly to observe `working`, verify a newer completed
   turn with `agent get`. If neither is observed, inspect the UI without resending
   or advancing the loop. Then use the normal settled-state wait.

   Right arrow accepts the suggestion; Enter starts the next turn. See the
   [Claude Code prompt-suggestion documentation](https://code.claude.com/docs/en/interactive-mode#prompt-suggestions).
   If suggestions are absent or disabled, continue to the next source.

2. **Next tasks in the response.** If there is no suggestion and the worker lists
   remaining tasks, send a prompt selecting those tasks, for example:

   ```bash
   herdr agent prompt "$worker" "do 1, 2 and 3" --wait --timeout 60000
   ```

   Use the actual task numbers from the latest response, or name the tasks if
   they are not numbered. Select tasks that can be done together, not mutually
   exclusive alternatives presented for a decision.

3. **Ask what remains.** If there is no suggestion and no task list, send:

   ```bash
   herdr agent prompt "$worker" "what's next" --wait --timeout 60000
   ```

After each submission, wait for that worker turn to finish and repeat. Keep asking
what remains when neither of the first two sources is available, until the worker
says there is nothing left.

## Input and wait handling

- Send input only when the intended worker is `idle` or `done` at its normal
  prompt. Preserve user-typed drafts; do not append to, submit, or erase them.
- If the worker is `blocked`, inspect the UI and surface the question or approval
  to the user. A blocked worker is not a completed task. Never send continuation
  keys into an approval dialog. If its state is `unknown`, inspect it first.
- After Right arrow and Enter, verify that a new turn started before treating an
  idle state as completion. `agent send-keys` confirms key delivery, not execution.
  Use `agent get` turn/state evidence and fresh output; do not blindly resend.
- On a timeout or stalled prompt, inspect `agent get` and fresh output. If still
  working, wait again without resubmitting. Use `--wait` without `--until idle`;
  both `idle` and `done` are ready states.
- Names can expire. On `agent_not_running` or `agent_not_found`, rediscover the
  pair with `herdr agent list` before sending anything else.
- If the latest response is truncated, follow the Herdr skill's output-recovery
  procedure before deciding that no task list or completion statement exists.

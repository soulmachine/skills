---
name: herdr-advisor
description: Pair a Herdr worker with one advisor from another model family. Use when the Advisor Model rule applies or the user asks for a Herdr advisor to review decisions and lead the worker through its remaining tasks. Do not invoke during Matt Pocock's grill-me or grill-with-docs sessions.
---

# Herdr advisor

Do not invoke this skill during a Matt Pocock `grill-me` or `grill-with-docs`
session, even when the Advisor Model rule would otherwise apply. Continue that
session directly without creating, consulting, or handing off to an advisor.

## Roles and scope

- **Worker:** the main Herdr agent doing the user's work. It makes every change.
- **Advisor:** the read-only Herdr agent that advises the worker and leads it to
  the next task. It never edits; it tells the worker what to change.

The read-only rule follows the advisor model itself, which "runs without tools
and without context management" so that "only the advice text reaches the
executor" — see the [advisor tool
documentation](https://platform.claude.com/docs/en/agents-and-tools/tool-use/advisor-tool).

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

Use one advisor from a different model family. The advisor is **read-only**: it
reads, searches, and drives the worker through `herdr`, but never creates,
edits, or deletes a file. Every change is the worker's to make.

| Worker model | Advisor model | Herdr kind |
|---|---|---|
| GPT | `claude-fable-5-1` | `claude` |
| Anything else | `gpt-6-astra` | `codex` |

Native arguments for `claude`:

```
--permission-mode dontAsk --disallowedTools Edit,Write,NotebookEdit --allowedTools "Bash(herdr:*) Read Grep Glob WebSearch WebFetch" --effort xhigh --model claude-fable-5-1
```

Native arguments for `codex`, where `$HERDR_SOCKET_PATH` is exported in every
Herdr pane:

```
-a never -c default_permissions="herdr-advisor" -c 'permissions.herdr-advisor.extends=":read-only"' -c 'permissions.herdr-advisor.network.enabled=true' -c "permissions.herdr-advisor.network.unix_sockets={\"$HERDR_SOCKET_PATH\"=\"allow\"}" --search -c model_reasoning_effort=xhigh -m gpt-6-astra
```

The two commands grant the same seven capabilities by different means. Keep
them aligned: if you change one column, change its counterpart.

| The advisor must | `claude` | `codex` |
|---|---|---|
| never ask | `--permission-mode dontAsk` | `-a never` |
| never write | `--disallowedTools Edit,Write,NotebookEdit` | `extends=":read-only"` |
| read files | `Read Grep Glob` | `extends=":read-only"` |
| drive the worker | `Bash(herdr:*)` | `network.unix_sockets` allowing `$HERDR_SOCKET_PATH` |
| reach the web | `WebSearch WebFetch` | `--search` |
| think hard | `--effort xhigh` | `-c model_reasoning_effort=xhigh` |
| pin the model | `--model claude-fable-5-1` | `-m gpt-6-astra` |

The enforcement differs in strength, not in intent: Claude denies in its
permission engine, Codex in a macOS seatbelt. So a Codex advisor cannot write
even from inside a subprocess, while a Claude advisor is held by tool and
command classification. Both are further bound by the read-only rule in their
brief.

**Neither advisor ever asks.** An advisor sits in a pane nobody is watching, so
a permission prompt is a hang, not a safeguard. Both commands deny and carry on
instead: `dontAsk` refuses anything not pre-approved rather than prompting, and
`-a never` generates no approval request at all, returning a blocked action to
the model as an error. Do not relax either to a prompting mode to let it ask.

For `claude`, `dontAsk` auto-allows read-classified commands, so the allowlist
only has to name the herdr surface the advisor drives the worker with, plus the
web tools. Writes are denied twice over: `--disallowedTools` removes the editing
tools, and `dontAsk` refuses write-classified Bash, so the advisor cannot route
around the deny-list with `echo >`.

For `codex`, the permissions profile is what makes read-only compatible with
herdr. Do not add `--sandbox`/`-s read-only`: on its own it severs herdr's unix
socket and strands the advisor, and passing it disables profile mode entirely.
Do not add `--approve-for-me` either: [auto-review](https://learn.chatgpt.com/docs/sandboxing/auto-review)
is "a reviewer swap, not a permission grant", and it never reviews "anything
already permitted under the active `sandbox_mode`". `--search` gives web access
server-side, so it survives the sandbox. Keep the socket path as an inline TOML
table — the dotted-path form
`-c '...unix_sockets."/path/herdr.sock"="allow"'` fails, because the parser
splits on the dots inside the path.

Reuse the worker's existing advisor after checking its identity, model family,
workspace, tab, and working directory; if you cannot confirm it was launched
read-only, restate the read-only rule in the first prompt you send it.
Otherwise create a **vertical split**,
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
> without delegating or consulting other agents. You are read-only: do not
> create, edit, or delete files, and do not run commands that change the
> repository or the working tree. This is a bounded consultation; reply with
> your advice and wait for a continuation handoff.

After setup and any initial consultation, hand off continuation with
`herdr agent prompt "$advisor" "<handoff>"` **without `--wait`**. Include the worker's
pane ID, goal, remaining context, and this instruction:

> Read ~/.agents/skills/herdr-advisor/SKILL.md. You are the read-only advisor
> for worker <worker-name-or-pane-id>. Follow its next-task loop until the worker
> says there is nothing left. Do not create or consult another advisor, and hand
> every change to the worker rather than making it yourself. The worker is doing
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

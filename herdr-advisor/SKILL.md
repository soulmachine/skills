---
name: herdr-advisor
description: Pair a Herdr worker with one advisor from another model family. Use when the Advisor Model rule applies or the user asks for a Herdr advisor to review decisions and lead the worker through its remaining tasks. Do not invoke while a grilling session is still open.
---

# Herdr advisor

Unrelated to Claude Code's built-in advisor tool (`--advisor`) — a server-side
consultant with no tools of its own. This skill launches a separate agent
process that drives the worker.

Do not invoke this skill while a grilling session is still open — the `grilling`
skill, or Matt Pocock's `grill-me`, `grill-with-docs`, or `batch-grill-me`, which
all run it. Continue that session directly without creating, consulting, or
handing off to an advisor, even when the Advisor Model rule would otherwise apply.

A grilling session ends when its frontier is empty, which is that skill's own
completion condition. Once it does, this exclusion no longer applies: carrying
out the agreed plan is ordinary work, and the Advisor Model rule governs it
normally.

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
| GPT | `claude-fable-5-1[1m]` | `claude` |
| Anything else | `gpt-6-astra` | `codex` |

**A quota outage overrides the table.** When the table's advisor model has hit
its usage limit, pair the worker with an advisor from its own family: a weaker
check beats none. The tell is in the advisor's own pane — `You've hit your
usage limit`, sometimes with the model silently downgraded from the one you
asked for. Say so in that advisor's first prompt: it shares the worker's blind
spots and will find its reasoning congenial, so have it verify the worker's
claims against the code — the spot-check the next-task loop bounds, not an
audit. Restore the table's pairing once the quota resets.

**A same-family advisor must outrank its worker.** Rank on model first, effort
second. The pin settles the model rung: the advisor models the table names are
the most capable in their families, so a pinned advisor starts at least its
worker's equal. That matters because a worker's model is unreadable — it passes
no `--model`, and neither Herdr nor the pane reports one. Effort you read and
set, because effort is readable where the model is not:
`herdr pane process-info --pane <id>` shows the worker's `--effort`, and the
worker's pane footer names the same value. Give the advisor one rung above the
worker's and substitute it for `<effort>` below. The ladders differ by a rung —
`claude` ends at `max`, `codex` continues to `ultra` — and a worker already at
the top of its own ladder is the one case where the advisor matches rather than
outranks it.

When the table's models look stale, the vendors' own catalogs rank them: the
newest `~/.claude/cache/model-catalog/*-cc.json` by `fetchedAt` lists the Claude
models in capability order, and `~/.codex/models_cache.json` ranks the OpenAI
ones by an integer `priority`. Fall back to the table if neither is readable.

Native arguments for `claude`:

```
--permission-mode dontAsk --disallowedTools Edit,Write,NotebookEdit --allowedTools "Bash(herdr:*) Read Grep Glob WebSearch WebFetch" --effort <effort> --model 'claude-fable-5-1[1m]' --strict-mcp-config
```

`[1m]` must stay quoted — zsh globs the brackets — and pins the 1M-context
variant; the bare id gets the 200k one, which `autoCompactWindow` cannot lift.
The model catalog lists only the bare id, so the suffix's absence there is not
evidence against it.

`--strict-mcp-config` alone leaves the advisor with no MCP tools: 114 definitions
it never called across a 59-call session. This is context economy, not a
permission boundary — `--dangerously-skip-permissions` is prepended upstream, so
the allowlist gates nothing. See `DECISIONS.md` Q33.

Native arguments for `codex`, where `$HERDR_SOCKET_PATH` is exported in every
Herdr pane:

```
-a never -c default_permissions="herdr-advisor" -c 'permissions.herdr-advisor.extends=":read-only"' -c 'permissions.herdr-advisor.network.enabled=true' -c "permissions.herdr-advisor.network.unix_sockets={\"$HERDR_SOCKET_PATH\"=\"allow\"}" --search -c model_reasoning_effort=<effort> -m gpt-6-astra
```

Codex has no single flag for the MCP tool surface. Derive one `-c` per server
**that host** declares, and append the result to the codex arguments above:

```
grep -oE '^\[mcp_servers\.[A-Za-z0-9_-]+\]$' ~/.codex/config.toml \
  | sed 's/\[mcp_servers\.//; s/\]//; s/^/-c mcp_servers./; s/$/.enabled=false/' | tr '\n' ' '
```

Only servers declared in `[mcp_servers.*]` may be overridden. Naming any other —
a plugin-injected server, or one this host lacks — aborts config loading with
`invalid transport`, so never hardcode one machine's list. Plugin-injected
servers therefore survive: codex floors at ~21 tools where claude reaches zero.
`--disable plugins` would remove those too, but it also drops every plugin
skill and hook — including claude-mem's capture — so it is not used here.

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
workspace, tab, and working directory. Sharing the worker's family is not on
its own grounds to replace it — judge it against the same-family rule above,
reading its `--model` and `--effort` with `herdr pane process-info --pane <id>`,
the only surface that shows them. If you cannot confirm it was launched
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
herdr agent wait "$worker" --timeout 110000
herdr agent get "$worker"
herdr agent read "$worker" --source recent-unwrapped --lines 120
herdr agent read "$worker" --source visible --format ansi
```

Verification is a spot-check, not an audit. Read the journal and the worker's
own report; do not re-derive its result from source, re-fetch what it already
verified, or parse its session transcript. This bounds the loop's own reading;
a bounded consultation the worker requested is answered in full, since the
worker is waiting on it. When a doubt survives the spot-check,
the doubt **is** the next task: send it to the worker to check, which is cheaper
and is the worker's job anyway. Keep the wait above at its 110-second timeout — a
longer one reports the advisor as `working` while it does nothing at all, and
this one still fits under the Bash tool's 120-second default and the 5-minute
prompt-cache window, so a re-armed tick is cheap.

The loop is serialized, so every minute you spend investigating is a minute the
worker is idle. An advisor told to verify a same-family worker's claims was
observed spending 26 minutes and 48 tool calls on a single turn — six source
files, two artifact re-fetches, and three passes over the worker's 83 MB session
transcript — without once prompting the worker, which sat idle for the last 11.

A flat "nothing left" — no named task, no decision for the user — is not yet
the stop. Send the literal `what's next` from source 4, once. If that turn also
ends in a flat "nothing left", stop the loop, quoting both answers in your last
message so the pane reader can see the goal was probed rather than abandoned.
Any turn in which you sent the worker work, from any source, resets the count.
Keep the probe bare: a leading prompt invites the worker to invent work to
satisfy it, and two identical answers to the same bare question are the
evidence the stop rests on.

"Nothing left within the current authorization" is not that stop while the worker
also names work that is technically unblocked — that work is the next task, so
take it. Check this before following suggestions. If the response needs the
user's preferences, private facts, or authorization, or every remaining item is
a decision only the user can make, **hold**: relay that question and end your
turn, even if Herdr reports `idle`.

Holding means ending the turn, not staying alive inside it. Do not re-arm
`herdr agent wait` to keep a hold open. The worker is idle, and only a human
prompt turns it `working`, so a wait on worker activity cannot resolve until the
thing you are waiting for has already happened; each re-arm spends context until
you compact and the hold dies anyway. An ended turn waits for free. What resumes
you is the worker's next turn, which a `Stop` hook re-arms the advisor on where
one is installed, or the user prompting you directly. Name what you are holding
for in your last message, so whoever reads the pane can see what would unblock
it.

Answer technical questions from the worker directly. Otherwise use these sources
in order:

1. **Claude Code prompt suggestion.** If the worker is Claude Code and its input
   box is otherwise empty and shows grayed-out next-prompt ghost text, send Right
   arrow to accept it:

   ```bash
   herdr agent send-keys "$worker" right
   herdr agent read "$worker" --source visible --format ansi
   ```

   Dim ghost text before Right is this source's trigger, not grounds to
   refuse it — an advisor was observed reading `^[[2m` on a suggestion,
   correctly, and declining to accept it for that reason. The dimness check
   belongs after Right: verify that the intended suggestion is now editable
   input rather than dim ghost text, with no user draft added. Record the current worker turn, submit,
   and wait for evidence that the new turn started:

   ```bash
   herdr agent get "$worker"
   herdr agent send-keys "$worker" enter
   herdr agent wait "$worker" --until working --until blocked --timeout 10000
   ```

   If the turn finishes too quickly to observe `working`, verify a newer completed
   turn with `agent get`. If neither is observed, inspect the UI without resending
   or advancing the loop. Then use the normal settled-state wait.

   Take a suggestion that names executable work, even when the worker said it had
   been told not to start it. A worker reporting "nothing left within the current
   authorization" was observed carrying the suggestion "start ticket 03", the
   ticket it had just called technically unblocked; that is the next task, not a
   trap to refuse. An earlier instruction to hold off is a scheduling preference,
   and the loop exists to keep the worker moving.

   The line is task versus decision. Leave to the user only what an agent cannot
   answer — an adoption call, a threshold, a preference — and relay that instead
   of guessing at it.

   Right arrow accepts the suggestion; Enter starts the next turn. See the
   [Claude Code prompt-suggestion documentation](https://code.claude.com/docs/en/interactive-mode#prompt-suggestions).
   If suggestions are absent or disabled, continue to the next source.

2. **Explicit invitation to continue.** If the worker offers to proceed on a
   literal word — "Say go and I'll ...", "Say the word and I'll ..." — send that
   exact word and nothing else:

   ```bash
   herdr agent prompt "$worker" "go" --wait --timeout 110000
   ```

   The worker has already planned the work and is waiting on the trigger it
   named. Restating the task invites it to re-plan instead, and a paraphrase may
   not read as the trigger at all. An offer between alternatives is a decision,
   not an invitation: do not answer that with a trigger word.

3. **Next tasks in the response.** If there is no invitation and the worker lists
   remaining tasks, send a prompt selecting those tasks, for example:

   ```bash
   herdr agent prompt "$worker" "do 1, 2 and 3" --wait --timeout 110000
   ```

   Use the actual task numbers from the latest response, or name the tasks if
   they are not numbered. Select tasks that can be done together, not mutually
   exclusive alternatives presented for a decision.

4. **Ask what remains.** If there is no invitation and no task list, send:

   ```bash
   herdr agent prompt "$worker" "what's next" --wait --timeout 110000
   ```

After each submission, wait for that worker turn to finish and repeat. Keep asking
what remains when none of the earlier sources applies, until the worker says there
is nothing left twice in a row.

## Input and wait handling

- Send input only when the intended worker is `idle` or `done` at its normal
  prompt. Preserve user-typed drafts; do not append to, submit, or erase them.
- If the worker is `blocked`, inspect the UI and surface the question or approval
  to the user. A blocked worker is not a completed task. Never send continuation
  keys into an approval dialog. If its state is `unknown`, inspect it first.
- After Right arrow and Enter, verify that a new turn started before treating an
  idle state as completion. `agent send-keys` confirms key delivery, not execution.
  Use `agent get` turn/state evidence and fresh output; do not blindly resend.
- On a timeout, run `agent get` only — a timed-out wait returns no state. If
  still `working`, wait again without resubmitting or reading output: the read
  block above costs about 5k tokens a tick, and an hour-long worker turn is 33
  ticks. Read output when the state changes. On a stalled prompt, inspect
  `agent get` and fresh output. Use `--wait` without `--until idle`; both `idle`
  and `done` are ready states.
- Names can expire. On `agent_not_running` or `agent_not_found`, rediscover the
  pair with `herdr agent list` before sending anything else.
- If the latest response is truncated, follow the Herdr skill's output-recovery
  procedure before deciding that no invitation, task list, or completion statement
  exists.

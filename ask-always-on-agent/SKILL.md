---
name: ask-always-on-agent
description: Reach Frank on his phone through an always-on paseo agent (coding-agent or personal-agent). Use when a question to the user has had no answer for 15 minutes, or when the user says to send a message, ask, or hand off work to the coding-agent, the personal-agent, or "the always-on agent".
---

# ask-always-on-agent

A coding CLI session lives in a terminal; Frank cannot see it from his phone. The always-on paseo
agents can be seen there: paseo's app runs on mobile, and a question an agent asks shows up in it.
So when Frank is away from the terminal, a CLI session reaches him by sending its question to an
always-on agent, which re-asks it in paseo. The always-on agent is a relay: it shows, it does not
judge or answer.

## When to use it

- **Unanswered question.** Your question tool returned with no answer (timeout, cancel, headless
  run), or the question has waited 15 minutes. This is the only time you message an always-on
  agent on your own.
- **Explicit hand-off.** The user says to ask, tell, message or hand work to one of the agents.

## Which agent

| Agent | Topic | Runs on |
|---|---|---|
| `coding-agent` | engineering, coding, the fleet, products | mac-mini-m2, mac-mini-m6, dev-server-frank-lume, archs-mac-mini |
| `personal-agent` | Frank's personal life | mac-mini-m2 only |

For an **unanswered question**, pick by folder: a session under `~/personal-agent` sends to
`personal-agent`; any other folder sends to `coding-agent`. For an **explicit hand-off**, pick by
topic; when the topic is unclear or mixed, ask the user which agent before sending.

The script finds the agent by its label `keepalive=<name>` on this host's paseo daemon, and
follows the name to its home host (`ssh://mac-mini-m2` or `ssh://mac-mini-m6`) when it is not
here. It prints one stderr line when it does. Pass `--host <endpoint>` to choose the daemon
yourself; then it never falls back.

## The script

```bash
~/.agents/skills/ask-always-on-agent/scripts/ask-always-on-agent [--host <endpoint>] <name> [paseo send options] [prompt]
```

Everything after `<name>` goes to `paseo send` unchanged. The script waits until the agent is idle
again, through any question the agent asks in paseo, then prints the agent's last text entry: the
reply. There is no timeout. `--prompt-file <path>` sends a long message; `--image <path>` attaches a
screenshot; `--behavior interrupt` cuts into a busy agent (default `steer` queues behind its
current turn); `--no-wait` returns at once, then `paseo logs -f <id>` shows the reply.

## Escalate an unanswered question

1. Write the message from this template, with the question and its options verbatim:

   ```
   Show Frank this question with your AskUserQuestion tool, verbatim with these options.
   Do not answer it yourself. Reply with only his answer.

   Context: <what this session is doing, in one or two sentences>. Folder: <cwd>.
   My recommended option: <label>.

   Question: <the question>
   Options:
   - <label>: <description>
   - <label>: <description>
   ```

2. Send it, with `--prompt-file` for a long one:

   ```bash
   ~/.agents/skills/ask-always-on-agent/scripts/ask-always-on-agent coding-agent --prompt-file /tmp/question.md
   ```

   The command returns when Frank answers in paseo; that can take hours. Wait.

3. Take the reply as Frank's answer and continue. Your next message to the user says, in full:
   the question waited 15 minutes, so it was relayed through `<agent>` on `<host>`; Frank
   answered it through paseo (mobile); and this is the answer you are acting on.

4. If the command fails or the reply is empty, stop and keep waiting for the user. Do not take
   your own recommended option.

## Hand off a task

Send the task as a plain message, no relay wording. The agent runs in `bypassPermissions` and
acts on it. Relay its reply to the user as written, with one line naming the agent and host. A
Claude Code session on the same machine also puts its own session name in the message (the first
line of `ListAgents` shows it), so the agent can reach it later over the reverse channel.

## Reverse channel

`paseo send` goes one way. The always-on agent reaches a CLI session only through Claude Code's
peer messaging: the agent is itself a Claude Code session, listed by `ListAgents` under a derived
name such as `coding-agent-d3`, and it has `SendMessage` too. Verified both ways on mac-mini-m6,
2026-10-28.

- Same machine only: the channel is a local socket. For another host, the CLI session must send
  with `paseo send` and take the reply.
- Claude Code sessions only. codex, pi and opencode are not peers; their only inbound path is the
  reply to a message they sent.
- A peer in a different permission mode gets the message held for the user's approval.
- The agent's peer name changes when the keepalive job recreates it. Pick it from `ListAgents` by
  working directory (`~/coding-agent` or `~/personal-agent`), never from memory.

As the always-on agent: to answer a session that named itself, `SendMessage` to that name; when
a message arrives as a cross-session message, reply to its `from` address.

## If it fails

- `no agent labelled keepalive=<name>`: the keepalive job is not loaded on that host
  (`launchctl list | grep keepalive`), or the daemon is down (`paseo daemon status`). See
  `~/coding-agent/devops/paseo-keepalive/README.md`.
- `more than one agent labelled`: the job made a duplicate; archive one by hand, same README.
- `Cannot connect to daemon` with `--host`: the endpoint must be `host:port`, `ssh://host`, or
  a pairing URL.

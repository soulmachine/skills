# Harness CLIs

How to launch an advisor in each coding-agent CLI. A row exists for every CLI
that Herdr can start (`herdr agent start --kind`) and that was installed on the
reference host when the table was written; check `command -v` before
launching. Which model to run is a separate choice: `MODELS.md`.

Every row aims at the same eight capabilities: never ask (nobody watches the
pane, so a prompt is a hang); never write; read files; run `herdr` and nothing
else; reach the web; think at `<effort>`; pin `<model-id>`; carry no MCP tools.
Where a CLI's flags cannot deliver one, the **Gaps** list says so; the row is
still launchable, and the worker chooses knowing it.

`<model-id>` is the id from `MODELS.md` in the CLI's own spelling. `<effort>`
is the row's effort, or the CLI's top rung when it ends lower; the Effort
column names that rung, `id` when the CLI bakes effort into the model id
(`claude-opus-5-xhigh`), `mode` when the CLI's own knob is not a rung ladder,
`none` when it has no knob. `<provider>` is the CLI's own name for the
model's provider; both spellings are in the closing *Model spellings*
paragraph. `†` marks a row not yet launched from this skill (copilot: no
working login on the reference host); the launch is `harness/launch-test.sh`,
one live row per run. `‡` marks a top rung the CLI's docs do not state.

The launch recipe is in `SKILL.md`; a row supplies its `<kind>` and `<native
arguments>`.

| CLI | Herdr kind | Effort | Native arguments |
|---|---|---|---|
| Amp | `amp` | mode | `--mode <mode>` |
| Antigravity | `agy` | `high` | `--effort <effort> --model <model-id>` |
| Claude Code | `claude` | `max` | `--permission-mode dontAsk --disallowedTools Edit,Write,NotebookEdit --allowedTools "Bash(herdr:*) Read Grep Glob WebSearch WebFetch" --effort <effort> --model '<model-id>' --strict-mcp-config` |
| Cline | `cline` | `xhigh` | `--auto-approve true -m <model-id> -P <provider> --thinking <effort>` with `CLINE_COMMAND_PERMISSIONS='{"allow":["herdr *"]}'` in the pane's environment |
| Codex | `codex` | `max` | `-a never -c default_permissions="herdr-advisor" -c 'permissions.herdr-advisor.extends=":read-only"' -c 'permissions.herdr-advisor.network.enabled=true' -c "permissions.herdr-advisor.network.unix_sockets={\"$HERDR_SOCKET_PATH\"=\"allow\"}" --search -c model_reasoning_effort=<effort> -m <model-id>` plus one `-c mcp_servers.<name>.enabled=false` per server in `~/.codex/config.toml` (see below) |
| Copilot † | `copilot` | `max` | `--allow-all-tools --deny-tool write --deny-tool memory --excluded-tools task --no-ask-user --disable-builtin-mcps --reasoning-effort <effort> --model <model-id>` |
| Cursor | `cursor` | id | `--mode=ask --model <model-id>` |
| Devin | `devin` | id | `--config ~/.agents/skills/herdr-advisor/harness/devin.json --model <model-id>` |
| Grok Build | `grok` | `high` ‡ | `--permission-mode dontAsk --allow 'Bash(herdr *)' --allow Read --allow Grep --allow WebSearch --allow WebFetch --deny Edit --deny MCPTool --reasoning-effort <effort> -m <model-id>` |
| Hermes | `hermes` | `ultra` | `--reasoning <effort> chat --yolo -t terminal,web --provider <provider> -m <model-id>` |
| Kimi Code | `kimi` | config | `--auto --agent-file ~/.agents/skills/herdr-advisor/harness/kimi.md -m <model-id>` |
| Kiro (one turn only, see Gaps) | `kiro` | `max` | `chat --agent herdr-advisor --effort <effort>`, after copying `harness/kiro.json` to `~/.kiro/agents/herdr-advisor.json` with its `model` field set to `<model-id>` (no model flag; the agent file carries it) |
| oh-my-pi | `omp` | `max` | `--approval-mode write --config ~/.agents/skills/herdr-advisor/harness/omp.yml --tools read,grep,glob,bash,web_search --no-extensions -e ~/.omp/agent/extensions/herdr-omp-agent-state.ts --thinking=<effort> --model <model-id>` |
| OpenCode | `opencode` | none | `-m <provider>/<model-id>` with `OPENCODE_CONFIG=~/.agents/skills/herdr-advisor/harness/opencode.json` in the pane's environment |
| pi | `pi` | `max` | `--tools read,grep,find,ls,bash --no-extensions --thinking <effort> --model <provider>/<model-id>` |
| Qoder | `qodercli` | `max` | `--permission-mode dont_ask --tools Read,Grep,Glob,Bash,WebSearch,WebFetch --allowed-tools 'Bash(herdr:*)' --strict-mcp-config --reasoning-effort <effort> -m <model-id>` |

Environment for a row: `herdr pane split ... --env KEY=VALUE` (repeatable)
reaches the launched shell, so the CLI inherits it.

## Launch notes

**Amp modes.** Amp has no model flag; `--mode` picks it: `ultra` →
`claude-fable-5-1` high, `high` → `gpt-6-astra` medium, `medium` → `gpt-5-6-sol`
medium, `low` → `glm-5-3-flash` high. Pick the mode whose model is the row you
chose.

**Codex MCP servers.** Name only the servers this host declares; naming one it
does not aborts config loading with `invalid transport`:

```bash
grep -oE '^\[mcp_servers\.[A-Za-z0-9_-]+\]$' ~/.codex/config.toml \
  | sed 's/\[mcp_servers\.//; s/\]//; s/^/-c mcp_servers./; s/$/.enabled=false/' | tr '\n' ' '
```

Splice the result in unquoted: in zsh a `$MCP` variable is one word, and Codex
then fails with `expected a boolean in mcp_servers.<name>.enabled`; use
`${=MCP}`.

Leave out `--disable plugins` (drops every plugin skill and hook), `-s
read-only` (severs the herdr socket) and `--approve-for-me` (a reviewer swap).
Keep the socket path as an inline TOML table: the dotted form splits on the
dots in the path.

**Claude Code.** Keep `'<model-id>'` quoted: zsh globs the `[1m]` suffix.

**Cline.** Its first run on a host shows a one-time "Cline Desktop" notice
that holds the start until a key is pressed (`agent start` times out); any
interactive run dismisses it for good
(`~/.cline/data/settings/cli-notices.json`).

**Copilot.** On the reference host it does not start: with a classic
`GITHUB_TOKEN` (`ghp_`) in the environment it refuses the token, and without
one the organization's Copilot policy denies access.

**Devin.** `--model` needs a paid plan: on a free account every listed id,
even `swe-1-6`, exits with `Upgrade to Pro to access this model`, so drop the
flag there and take the account's default.

**Kimi Code and oh-my-pi** need their Herdr integration (`herdr integration
install kimi`, `… omp`, a one-time per-host setup the user runs; `herdr
integration status` shows it). Without it they stay `idle` at `turn` 0 in
`herdr agent get` however much they work, so the watchdog sees no turn end
and never re-prompts: the loop ends at the advisor's first early turn end.
omp's integration is an extension, and the row's `--no-extensions` drops it
with the rest, hence the explicit `-e` path. Both verified on the reference
host.

**OpenCode** still loads the user's global plugins under `OPENCODE_CONFIG`;
on the reference host oh-my-openagent drops an `.omo/` directory and a
`.codegraph` symlink into the advisor's cwd. Delete them before committing.

## Gaps

- **Amp** never asks and never refuses: it has no permission system, no model
  flag, and its only settings file (`--settings-file`) replaces the user's own,
  so the advisor can write and run anything.
- **Antigravity** has no read-only mode: a file edit inside the workspace is
  auto-allowed, a deny needs the user's `~/.gemini/antigravity-cli/settings.json`,
  which this skill never edits; `read_url` defaults to Ask, so a web fetch
  hangs; commands run unprompted only inside its sandbox (workspace and temp,
  no network), which may not reach the herdr socket.
- **Cline** cannot refuse writes; `--auto-approve true` approves them.
- **Copilot** cannot confine the shell to `herdr`: a deny rule beats every
  allow, so the shell is open (`--allow-all-tools`) and only writes are denied.
- **Cursor** `--mode=ask` is read-only and still runs `herdr` (verified);
  without `-f`, any other shell command prompts and hangs.
- **Devin** has no mode that both refuses edits and skips prompts: a `deny`
  on `exec` would also block `herdr`, so a shell command other than `herdr`
  prompts and hangs; `harness/devin.json` denies edits and MCP, allows reads
  and fetches.
- **Hermes** drops the `file` toolset, but the terminal can still write and
  runs any command; `--yolo` skips the dangerous-command prompt, which would
  otherwise hang, so like amp, cline, kimi and copilot the row chooses
  never-ask over never-write.
- **Kimi Code** `--auto` approves everything the agent file leaves enabled, so
  the shell is open; effort is config-only (`[thinking] effort`), not a flag.
- **Kiro** has no Herdr integration to install, so `turn` stays 0 in `herdr
  agent get`, the watchdog never re-prompts, and the loop lasts exactly one
  turn. Offer it last.
- **OpenCode** has no effort knob in its interactive command: `--variant` is
  `opencode run` only, and passing it at the top level prints the help and
  exits (`agent_kind_mismatch`).
- **pi**'s shell is open: its `bash` tool takes no command filter, so the
  advisor can run anything; and it has no web tool, so it cannot reach the
  web. It never prompts and has no MCP, by design.

## Aliases and wrappers

A shell alias or wrapper is a launch recipe (environment plus arguments) and
belongs here, under the CLI it wraps; MODELS.md stays a rank table. To use
one, resolve it to its CLI and arguments, drop every flag that widens
permissions (`--dangerously-skip-permissions`, `--yolo`, `--auto-approve`,
`--approve`, `--trust-all-tools`), keep its environment through `pane split
--env`, and append the row's arguments. An alias that sets only permission
flags and effort (`claude-yolo`, `codex-yolo`, `pi-yolo`, …) is its bare CLI
row. Detected on the reference host with more than that:

| Alias / wrapper | CLI | Sets | Model |
|---|---|---|---|
| `claude-gw` | Claude Code | `ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN` → cliproxy | inherits |
| `codex-gw` | Codex | `-p cliproxy` profile | `claude-opus-5` via cliproxy |
| `kimi-gw` | Kimi Code | `-m cliproxy/opus5` | `claude-opus-5` via cliproxy |
| `omp-yolo-gpt` | oh-my-pi | `--thinking=max --model gpt-6-astra` | `gpt-6-astra` |
| `omp-yolo-kimi` | oh-my-pi | `--thinking=max --model k3` | `kimi-k3` |
| `pi-yolo-kimi` | pi | `--thinking max --model k3` | `kimi-k3` |

Model spellings per CLI: pi and omp take `provider/id` or a fuzzy id (`k3`,
`opus`), but through the cliproxy gateway spell Claude ids out in full
(`claude-haiku-4-5-20251001`): a fuzzy `haiku` resolves to the undated alias,
which the gateway rejects with `unknown provider for model`; kimi takes a
`[models."..."]` alias from `~/.kimi-code/config.toml`; opencode takes
`provider/model`; hermes a `--provider` plus the provider's id; kiro's go in
the agent file's `model` field; cursor, agy and devin list theirs with
`--list-models`, `agy models`, `devin models list`, all after a login, and
cursor's carry the effort (`claude-sonnet-5-max`; the bracket form
`'<id>[effort=high]'` is for the few listed without one).

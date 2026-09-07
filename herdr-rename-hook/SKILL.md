---
name: herdr-rename-hook
description: Install the hook that renames the Herdr agent, pane and tab to match a Claude Code or Codex session renamed with /rename.
disable-model-invocation: true
---

# Herdr rename hook

One installed script, `~/.claude/hooks/herdr-rename-agent.sh`, serves both Claude Code and Codex. Whatever notices the rename, the mirroring onto the calling pane is the same three commands: `herdr agent rename` (the title slugified to Herdr's agent-name rules), then `herdr pane rename` and `herdr tab rename` (the title as typed, whitespace collapsed; the tab is looked up live from the pane). The bundled `scripts/herdr-rename-agent.sh` is the source of truth — its header carries the mechanism, the slug and collision rules; edit there and re-run `install.sh`.

**Claude Code** has no hook event for `/rename`, but `/rename` writes the session's `custom-title.json` sidecar. A `SessionStart` hook registers that file as a `FileChanged` watch path (`hookSpecificOutput.watchPaths`); the `FileChanged` hook does the renaming.

**Codex** has no `FileChanged` event at all and no watchable sidecar — `/rename` only appends `{"id","thread_name","updated_at"}` to `~/.codex/session_index.jsonl` (append-only, last line for an id wins). So its `SessionStart` hook spawns a detached watcher that polls that file for its own session id. Two Codex facts shape it:
- `SessionStart` fires on the session's **first turn**, not at TUI launch, so the watcher starts a turn late and syncs whatever name the session already has.
- Codex **auto-titles** a new thread itself on that first turn (one or two appends within seconds, never again), and those are indistinguishable from a typed `/rename`. So a change seen within 60 s of the watcher starting fills in blanks only; after that window a change overwrites, exactly like Claude Code's `/rename`.
The watcher exits when the pane stops hosting that session, when a newer watcher claims the pane (claim file `~/.cache/herdr-rename/<pane>.watch`), or after 24 h.

Behaviour worth telling the user:
- A tab takes the title of whichever session in it renamed last; single-pane tabs, the usual layout, simply follow their session.
- Filling in only what is blank — an unnamed agent gets the slug, an unlabelled pane and its tab get the title, anything already set stays — is what happens on Claude `SessionStart` with an existing title (resume, or an old session in a fresh pane) and on Codex's first-turn auto-title.
- Clearing the title (`/rename` with no name) changes nothing in Herdr.
- Codex needs `[features] hooks = true` in `~/.codex/config.toml` (the installer reports it if missing), and asks you to trust a new or changed hook the next time it starts — pick "Trust all and continue". Editing the hook's *command string* re-triggers that prompt; editing the script it points at does not.

## Install
1. Run the installer: sh ~/.claude/skills/herdr-rename-hook/scripts/install.sh
   (copies the hook; merges one SessionStart entry and one FileChanged group into ~/.claude/settings.json and one SessionStart group into ~/.codex/hooks.json — Herdr's own managed entries are left alone; self-checks inside a Herdr pane; done when both `self-check: OK` lines and `installed` print; idempotent — re-run it after editing the hook. Codex absent prints `codex: not installed, skipped`.)
   - Another Mac: the skill lives in git (~/github.com/soulmachine/skills), so on that host: cd ~/github.com/soulmachine/skills && git pull && agentstow adopt ~/github.com/soulmachine/skills/herdr-rename-hook && agentstow sync && sh ~/.claude/skills/herdr-rename-hook/scripts/install.sh && sh ~/.claude/skills/herdr-rename-hook/scripts/install.sh --check (adopt is a no-op once the skill is already linked).
2. Tell the user: running Claude sessions open /hooks once or restart; Codex asks to trust the hook at its next start; every rename is logged at ~/Library/Logs/herdr-rename-agent.log.
## Check or remove: install.sh --check (exit 0 = installed), install.sh --uninstall
## Prove it end to end
Only when asked, or after editing the hook. The proof relabels a tab, so use a throwaway tab of your own, never the user's: `herdr tab create --workspace "$HERDR_WORKSPACE_ID" --cwd "$PWD" --label hooktest --no-focus`, read `.result.root_pane.pane_id` and `.result.tab.tab_id`, then `herdr agent start hooktest --kind claude --pane <pane> --timeout 120000`, `herdr agent prompt <pane> "/rename e2e check"`, and poll `herdr agent get <pane>` until `.result.agent.name` is `e2e-check`; then `herdr pane get <pane>` must show `.result.pane.label` and `herdr tab get <tab>` must show `.result.tab.label` both equal to `e2e check`. Address the agent by pane id. Finish by sending `/exit`, `herdr tab close <tab>`, and deleting only that session's transcript and folder under `~/.claude/projects/`.
For Codex, same shape with `--kind codex` and four differences: a fresh pane stops on a directory-trust prompt and (after any hook change) a hook-trust prompt — clear them with `herdr pane send-keys <pane> enter` and `… down` + `… enter`, reading the pane with `herdr pane read <pane>` to see which is up; `herdr agent prompt` types but does not submit for Codex, so always follow it with `herdr pane send-keys <pane> enter`; send one throwaway prompt first, because that first turn is what starts the watcher (the log line is `codex watch: session=…`); and only rename **more than 60 s** after that line, or the settle window will treat it as Codex's own auto-title and fill blanks instead of overwriting. Then `/rename e2e codex` and assert `e2e-codex` / `e2e codex` as above. Finish with `/exit` (send-keys enter), `herdr tab close <tab>`, and remove the `[projects."<throwaway dir>"]` trust_level stanza the run added to ~/.codex/config.toml.

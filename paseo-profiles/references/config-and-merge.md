# Config and merge reference

The transfer is a key-scoped merge into a live config file, not a copy. This is what that
means in detail: where a profile sits on disk, what the export envelope carries, how each
incoming profile resolves against what the target already has, and how the reload report is
read afterwards.

Reach for it when a merge did something unexpected, when adding a key to the synced set, or
when the envelope version has to change. For flags, run `paseo-profiles.py --help` — they
live in the parser, not here.

## Where profiles live

A profile is one object in the JSON array at `daemon.agentProfiles` in `~/.paseo/config.json`.
Observed fields:

| Field | Notes |
|---|---|
| `id` | Stable identity; the primary merge key. |
| `name` | Display name; the secondary merge key. |
| `provider` / `model` | e.g. `claude` / `claude-opus-5`. |
| `modeId` | Provider-specific (`bypassPermissions`, `auto-review`, `full-access`). Absent on providers with no modes. |
| `thinkingOptionId` | `medium`, `high`, `xhigh`. |
| `icon` | Optional. |
| `notes` | The "when to use" text an orchestrating agent reads before delegating. |

paseo exposes no command that writes them — `paseo agent` manages running agents, not
templates — which is why this script edits the file directly.

## The export envelope

`export` and `push` both emit one envelope; `import` consumes it on stdin or from a file.

```json
{ "version": 1, "source": "<hostname>", "exportedAt": "<UTC ISO 8601>",
  "profiles": [ ... ], "settings": { "<dotted.path>": <value> } }
```

`import` rejects any `version` other than `ENVELOPE_VERSION` (currently 1) rather than
guessing at an older shape. The envelope is versioned by this tool alone — nothing guards
against paseo changing `daemon.agentProfiles` underneath it, so a paseo upgrade is worth a
`--dry-run` first.

Settings carrying `None` are dropped at export, and on import any path outside the synced set
is ignored, so an envelope from a newer version cannot write keys this one does not know.
`SKILL.md` lists that set; `SYNCED_SETTINGS` in the script is its source of truth.

## Merge resolution

Each incoming profile takes the first branch that matches:

1. **`id` matches** an existing profile → replace in place. Counted as `updated` only when the
   content actually differs, which is what makes a repeat import a no-op.
2. **`name` matches** under a different `id` → replace that slot, incoming `id` wins. Counted
   `replaced`. Without this, importing "Software Engineer" onto a host that made its own would
   leave two profiles of that name.
3. **Neither** → append. Counted `added`.

Profiles the target has and the envelope does not are never deleted. Ordering follows the
target's existing array, with appends at the end.

When the merged config is byte-identical to what was there, the script prints `no changes` and
skips the write and the reload entirely — so re-running after a partial fleet push costs
nothing on hosts already current. `selftest` asserts exactly these properties, idempotence
included.

## Writing

`save_config` copies the current file to `config.json.bak-<UTC>` first, then writes through a
temp file in the same directory at mode `0600` and `os.replace`s it into position — atomic, and
never leaving a half-written config, which matters because the real file holds secrets on hosts
with a daemon password. A target with no config at all is created as `{"version": 1}` rather
than treated as an error, which is the fresh-install path.

## Reading the reload report

After a write the script runs `paseo daemon reload --json` and reports honestly rather than
claiming success:

| Situation | What it prints |
|---|---|
| No `paseo` binary found | `restart the daemon to apply` |
| Reload exits non-zero (daemon stopped) | `profiles load on next start` |
| A synced path under `restartRequiredPaths` | tells you to run `paseo daemon restart` |
| A synced path under `overrideControlledPaths` | **warns the edit may be ignored** — a launch-time flag outranks the file |

Paths are matched with `touches()`, which treats either side as a possible parent, so a daemon
reporting the whole of `daemon` is recognised as covering `daemon.agentProfiles`.

Binary resolution is `shutil.which("paseo")` first, then `PASEO_FALLBACKS` in order: the mise
shim, the two Homebrew paths, the Paseo.app bundle. The list is deliberately long because
`paseo` is missing from the non-interactive ssh PATH on several hosts, and because a fleet
mid-migration is mixed — hosts on the npm CLI resolve the shim, hosts still on the desktop app
resolve the bundle.

## Push and exit codes

`push` stages this script at `/tmp/paseo-profiles-$(id -u).py` on each target (per-uid, so a
shared host has no permission clash) and runs it there with `python3`, feeding the envelope on
stdin. The target therefore needs `python3` on its ssh PATH — true on macOS with Command Line
Tools or mise.

One host failing does not abort the rest; the run continues and exits `1` at the end. `0` is a
clean run, `2` is a usage or data error (`die`).

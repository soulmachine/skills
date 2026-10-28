---
name: imsg-permissions
description: Grant the imsg CLI its macOS privacy permissions (Full Disk Access, Automation → Messages, Contacts) and prove each one from every parent that runs imsg. Use when setting up imsg on a Mac, after `brew upgrade imsg` or a node upgrade, or when imsg fails with "unable to open database file", "Not authorized to send Apple events" or "(Contacts unavailable)".
---

# imsg-permissions

imsg (openclaw/imsg, Homebrew) needs three macOS privacy grants; upstream lists them in
[docs/permissions.md](https://github.com/openclaw/imsg/blob/main/docs/permissions.md). How TCC
grants work, and the backup-first steps for a `TCC.db` edit, are in
[macos-tcc.md](~/.agents/docs/macos-tcc.md). Read it before step 3.

The work centres on the **grant table**: one row per parent that runs imsg, one column per gate.
A cell is ✅ only when a real command from that real parent passed.

| Parent | Full Disk Access | Automation → Messages | Contacts |
|---|---|---|---|
| SSH | | | |
| Terminal.app, Ghostty, iTerm2 (each one installed) | | | |
| launchd `node` (paseo daemon) | | | |
| imsg as its own process (LaunchAgent) | | | |

## Scripts

- `probe.sh <own-address> [--keep-ssh]` tests all three gates from the parent that runs it, and
  sends nothing. `--keep-ssh` only in the SSH row.
- `as-imsg.sh [--tty] <imsg args…>` runs imsg once as its own process (a one-shot gui
  LaunchAgent) and prints its output and exit code. `--tty` puts a tty on stdin.

## Steps

1. **Fill the rows.** Keep the terminal apps installed on this host. Find paseo's node with
   `ps -axo command | grep 'paseo daemon run'` and resolve it with `readlink -f`. Done when each
   row names a real parent.
2. **Test every cell** with `probe.sh` (`<own-address>` is the user's iMessage address) from its
   parent:
   - SSH: run it in this shell with `--keep-ssh`.
   - Terminal: a `.command` file that runs it, via `open -a Terminal <file>`.
   - Ghostty: `open -na Ghostty --args -e <file>`.
   - node: `launchctl submit -l <label> -o <log> -- <node> -e '…execFileSync("<probe.sh>", …)'`,
     then `launchctl remove <label>`.
   - imsg itself: `as-imsg.sh chats --limit 1 --json` and `as-imsg.sh nickname --local --address
     <own-address> --json`. Its Automation cell waits for step 5.

   Write output to files and read them back. Done when every cell holds pass or fail with output.
3. **Grant each failing cell.**
   - Full Disk Access: System Settings **+**, adding the parent app, or for imsg itself the real
     binary `/opt/homebrew/Cellar/imsg/<ver>/libexec/imsg` (`bin/imsg` is a bash wrapper).
   - Automation: rerun the parent's probe. When "<parent> wants access to control Messages.app"
     shows, click **Allow** with System Events, as macos-tcc.md shows.
   - Contacts: imsg asks only with a TTY on stdin and no `SSH_CONNECTION`/`SSH_CLIENT`;
     `chats` and `history` never ask. For imsg itself, run `as-imsg.sh --tty nickname --local
     --address <own-address> --json`. A terminal app asks only when its own code asks.

   When no prompt shows, read tccd's log (macos-tcc.md). Done when each cell passes, or tccd names
   why it cannot.
4. **Take each blocked cell to the user**, with tccd's reason and the options: leave it, change the
   host, or a direct `TCC.db` edit. Do the edit only on the user's yes, by macos-tcc.md's steps.
5. **Test imsg's own Automation only on the user's yes.** It needs a real send: ask for the
   recipient, then `as-imsg.sh send --to <address> --text "imsg permission test (ignore)"` once,
   and click **Allow** on the prompt. On `may_have_completed … retry is not safe`, find the
   message before any retry (gotchas).
6. **Re-test the whole table.** Remove test files, and quit apps you started. Done when every cell
   is ✅, or marked with its blocker and the user's choice.
7. **Report the table**, and log each grant and each `TCC.db` edit with `log-decisions` in the
   repo you work from.

## Gotchas

- **SSH needs no Contacts grant.** Over SSH, imsg reads the AddressBook SQLite files through
  sshd's Full Disk Access. Judge Contacts by `contacts_unavailable`; `source` says
  `local-addressbook` either way.
- **`open` from SSH leaks `SSH_*`** into the app, and imsg then takes the SSH path. `probe.sh`
  unsets them.
- **Terminal.app never asks for Contacts.** Its `Info.plist` has no `NSContactsUsageDescription`.
  Its Contacts cell needs a `TCC.db` row (macos-tcc.md).
- **"Policy disallows prompt."** On mac-mini-m2 (SIP off) tccd refused every Contacts prompt, for
  every parent. All four Contacts cells there came from `TCC.db` rows (personal-agent Q254, Q255).
  On every host, `node` gets the same refusal: its hardened runtime lacks the Contacts
  entitlement, so the node row's Contacts cell needs a `TCC.db` row (m6 test, 2026-10-27). That
  row is possible only with SIP off; with SIP on (m6) the cell stays blocked.
- **A self-send can land in the phone-number thread.** A send to the user's email address was
  filed under their phone number, so imsg exited 1 with `may_have_completed … retry is not safe`,
  though the message went out. Find it with `imsg chats --limit 5` (newest `last_message_at`)
  and `imsg history --chat-id <id>`; send again only if it is missing (personal-agent Q256).
- **Upgrades drop path grants.** Grants on `libexec/imsg` and on mise's `node` match by path, so
  `brew upgrade imsg` or a new node version needs this skill again.
- **Typing indicators and read receipts** need SIP off and imsg's injected dylib (`imsg status`).
  They are not privacy grants and are out of scope.

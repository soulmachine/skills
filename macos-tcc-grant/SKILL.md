---
name: macos-tcc-grant
description: Grant a macOS privacy permission (TCC: Full Disk Access, Automation, Contacts) to a CLI or app, and prove it from every parent that launches it. Use when asked to grant a tool its permissions, or when a tool fails on a privacy gate ("unable to open database file", "Not authorized to send Apple events", "Contacts unavailable", "Operation not permitted").
---

# macos-tcc-grant

Facts, commands and gotchas live in [macos-tcc.md](~/.agents/docs/macos-tcc.md). Read it in full
before step 1; the steps below cite it and do not repeat it.

The work centres on the **grant table**: one row per parent that launches the tool, one column per
gate the tool's own docs name. A cell is ✅ only when a real command from that real parent passed.

## Steps

1. **Build the grant table.** Rows: every parent the tool runs from in real use (SSH, each
   terminal app on the host, launchd jobs such as paseo's `node`, the tool as its own LaunchAgent).
   Columns: the gates from the tool's permissions doc. Resolve wrappers to the real binary. Done
   when every row and column is named.
2. **Test every cell** from its real parent, with a read-only command per gate:
   - SSH: run it in this shell.
   - A terminal app: a `.command` script via `open -a <App>`, or `open -na <App> --args -e` for
     Ghostty. Unset `SSH_*` first and write output to a file.
   - launchd: `launchctl submit -l <label> -- <binary> …`, or a gui-domain LaunchAgent for the
     tool as its own process.

   Done when every cell holds pass or fail with the output that shows it.
3. **Grant each failing cell** the documented way: System Settings for Full Disk Access; for
   Automation and Contacts, raise the prompt from that parent and click **Allow** with System
   Events; `tccutil reset` for a stored denial. When no prompt appears, read tccd's log. Done when
   each cell passes, or tccd's log names why it cannot (e.g. "Policy disallows prompt", or an app
   with no usage string).
4. **Escalate a blocked cell to the user.** Show the reason from tccd and the options: leave it,
   change the host (SIP), or a direct `TCC.db` edit. Do the edit only on the user's yes, with the
   doc's backup-first steps.
5. **Gate a sending test on the user's yes.** A cell testable only by an outbound action (a real
   `imsg send`) waits for the user to name the recipient. Send once; on an unclear result, find the
   message before any retry.
6. **Re-test the whole table**, then remove test jobs, plists, scripts and screenshots, and quit
   apps you started. Done when every cell is ✅, or marked with the blocker and the user's choice.
7. **Report the table** to the user, and log each grant and each `TCC.db` edit with
   `log-decisions` in the repo you work from. Add any new gotcha to macos-tcc.md.

# Retiring local Dropbox / Google Drive in favour of the mounts

Reached from step 5 of [SKILL.md](SKILL.md). Precondition: the server runs the sync clients and shares `~/Library/CloudStorage/<domain>`, and step 4 passed on the client. The server keeps its clients: it is the sync source.

## 1. Measure what is really local

`du -shx ~/Library/CloudStorage/<domain>` — a FileProvider tree of placeholders is tens of KB, and only the app caches (`~/Library/Application Support/Dropbox`, `…/Google/DriveFS`, `~/.dropbox`) are worth reclaiming. A legacy real directory (`~/Dropbox` that is a folder, not a symlink, from an unlinked client) can hold GB of genuine files and must pass the next step before deletion.

## 2. Prove every local file exists on the server

Snapshot both trees (`find . -type f | sort`) and `comm -23` them. Treat the result as **candidates, not losses**: `find` on a FileProvider tree returns partial listings while enumeration is still in flight, so most "missing" files are artifact. For each candidate, on the server: `ls` its parent directory (forces enumeration), then `test -e` the path. Survivors are usually renames — same size, then `md5 -q` on both — or 0-byte placeholders.

Done when every candidate is present, a checksum-identical rename, or empty. Anything else is real data: copy it to the server's share before going on.

## 3. Unlink, then remove

Unlink inside each app first so the FileProvider domain is torn down cleanly (deleting a still-linked app strands a domain that cannot be removed later): Dropbox → Preferences → Account → **Unlink this Dropbox**; Google Drive → Preferences → ⚙ → **Disconnect account**. Done when the domain is gone from `~/Library/CloudStorage` and `~/Library/Application Support/FileProvider`.

Then remove, as the login user unless noted:

```
/Applications/Dropbox.app                  /Applications/Google Drive.app   (Google Drive is root-owned: sudo)
~/Library/Application Support/Dropbox      ~/Library/Application Support/Google/DriveFS   (only DriveFS — Chrome lives beside it)
~/.dropbox                                 ~/Library/Group Containers/*getdropbox*
~/Library/Containers/com.getdropbox.*      ~/Library/Containers/com.google.drivefs.*
~/Library/Preferences/com.getdropbox.*     ~/Library/Preferences/com.google.drivefs.*
~/Library/LaunchAgents/com.dropbox.*       (launchctl bootout each first)
/Library/DropboxHelperTools                (sudo)
~/Library/CloudStorage/Dropbox             (Dropbox leaves an empty shell with a .Trash: sudo rm -rf)
```

Keep `com.google.keystone.*`, `com.google.GoogleUpdater.wake.plist` and `/Library/Application Support/Google/GoogleUpdater` whenever Chrome, Docs, Sheets or Slides are installed: they share that updater. Remove the apps' stale Login Items (`osascript -e 'tell application "System Events" to delete login item "Dropbox"'`). Finish by repointing `~/Dropbox` and `~/Google Drive` at `/Volumes/<share>` so existing paths keep working.

Done when `pgrep -lf "Dropbox|DriveFS"` matches nothing you did not start, both symlinks resolve through the mounts, and reading a known file through `~/Dropbox` checksums identically to the server's copy.

## What changes for the user

Disk returned is less than `du` promised — app bundles share APFS clone blocks. Spotlight does not index SMB mounts, so content search across these folders stops. Google supports SMB access to its DriveFS folder (`smb_allowed=on` in the running process); Dropbox does not officially, and its auto-updates on the server take the share offline for a while, which the agent rides out. Availability now depends on the server and Tailscale rather than the cloud.

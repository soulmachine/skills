# Authentication: the Apple-ID path, and every way it fails

Reached from step 2 of [SKILL.md](SKILL.md) when the first mount prompts, hangs, or is rejected.

## How a silent mount authenticates

`NetAuthSysAgent` asks `sharingd` for the Apple ID and its identity certificate (`CN=com.apple.idms.appleid.prd.<id>`), then does Kerberos PKINIT against the server's local KDC (`WELLKNOWN:COM.APPLE.LKDC`). The server maps that certificate to the local account through `AltSecurityIdentities`, which is why step 1 checks it on both sides. The result is a 10-hour ticket in a per-GUI-session cache, re-minted on demand — no password, no keychain item, and `security find-internet-password -s <host> -r "smb "` is expected to find nothing.

Diagnose any failure from the client's log, then match the branch below:

```
sudo log show --last 1h --predicate 'subsystem == "com.apple.AppleIDAuth" OR category == "MechTypes"'
```

Healthy signature: `CopyAppleIDs: Deferring to sharingd` → `CopySecIdentity: Deferring to sharingd` → `Adding 1 certificates to the MechType session info` → `MechTypes were acquired`. sharingd's line `Caller not properly entitled to receive AppleID info … com.apple.sharing.appleidauthentication required` appears on healthy Macs too, interleaved with successful lookups; judge by whether `CopySecIdentity` follows, not by that line.

## Branches

**A "Connect As" dialog with no `CopyAppleIDs` line at all; `NetAuthSysAgent` logs `isKnownServer 0`** — the client has never connected to this server, so NetAuth asks how to connect instead of trying the Apple ID (seen on a fresh macOS 27 client, 2026-10-08; restarting `sharingd` did not help). `pkill NetAuthAgent`, write the known-server entry NetAuth itself writes after a first connect, then repeat step 2; the log then shows `isKnownServer 1` followed by the healthy signature:
```
h=<host>; f=~/Library/Group\ Containers/group.com.apple.NetworkAuthorization.ServerMarkers/serverMarkers.plist
[ -e "$f" ] || { plutil -create xml1 "$f" && plutil -insert _migrationVersion -integer 2 "$f"; }
plutil -insert "${h//./\\.}" -bool true "$f"    # plutil key paths split on dots
```

**Stops after `CopyAppleIDs`, then a password prompt** — stale `sharingd` (seen after 22 days of uptime). `sudo killall sharingd` (auto-relaunched; a reboot does the same), then repeat step 2. The first successful mount mints the cache and the agent's normal URLs work from then on.

**`mount_smbfs: server rejected the connection: Authentication error` with a password you know is right** — confirm the password on the server: `dscl /Local/Default -authonly <user> '<pw>'`. If valid, the server account has no SMB-NT hash: `sudo dscl . -read /Users/<user> AuthenticationAuthority` shows `HASHLIST:<SALTED-SHA512-PBKDF2,SRP-…>` without `SMB-NT`, so the server accepts SMB by Kerberos only. That is fine as long as the Apple-ID branch works; fix the client side first. Enabling password SMB on the server (System Settings → General → Sharing → File Sharing → ⓘ → Options → tick the account) is the last resort: it stores a weaker NT hash and applies to every client.

**The client has no Apple-ID identity** (different Apple ID, or `AltSecurityIdentities` missing on either account) — password path. Prefer a dedicated non-admin server account that does nothing but SMB, so the weaker NT hash belongs to that account alone.

1. **Server: give the account an SMB-NT hash.** Use the File Sharing checkbox above, or headless: `sudo pwpolicy -u <user> -sethashtypes SMB-NT on`, then set the password again (`sudo dscl . -passwd /Users/<user> '<pw>'`). The hash is computed only when the password is set. Done when `AuthenticationAuthority` lists `SMB-NT`.
2. **Client: let NetAuth save the credential itself.** Do not create the item with `security add-internet-password`. NetFS matches the item on the share's path (`path=<share>`) as well as server, account and protocol. A hand-made item has no path, so it never matches, with or without `-t dflt`, and every mount hangs on a password dialog. Instead, from the client's GUI session, start a mount (`osascript -e 'mount volume "smb://<user>@<host>/<share>"'` in the background, through `launchctl asuser <uid> sudo -u <login-user>`). Fill NetAuthAgent's "Enter your name and password" dialog once: Registered User, the name and password, and "Remember this password in my keychain" ticked. You can do this by hand or with System Events, feeding the script on stdin so the password stays out of argv. Done when `security find-internet-password -a <user> -s <host>` shows `"path"<blob>="<share>"`.

Then `scripts/verify.sh` must pass. The login keychain must be unlocked in the GUI session; if it locks, mounts wait on a dialog. A changed password means saving the item again through the dialog. Move the password machine-to-machine (from a password manager or another Mac's keychain, piped) rather than through the conversation. `pkill NetAuthAgent` clears dialogs left over from failed attempts.

**`kinit <user>@LKDC:…` says "unable to reach any KDC"** — expected. LKDC is negotiated in-band over the SMB connection; there is no KDC to reach and this route is closed.

**Mounted as `//com.apple.idms…@<host>/<user>` at `/Volumes/<user>` with `acct = "No user account"` in the keychain** — the Finder → Network path. It works but lands at different mount points and goes stale; connect by hostname so the mounts match the agent's.

**Credential cache looks empty** — you are looking from SSH. The cache is per GUI session: `sudo launchctl asuser <uid> sudo -u <user> -i klist --list-all`.

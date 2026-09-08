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

**Stops after `CopyAppleIDs`, then a password prompt** — stale `sharingd` (seen after 22 days of uptime). `sudo killall sharingd` (auto-relaunched; a reboot does the same), then repeat step 2. The first successful mount mints the cache and the agent's normal URLs work from then on.

**`mount_smbfs: server rejected the connection: Authentication error` with a password you know is right** — confirm the password on the server: `dscl /Local/Default -authonly <user> '<pw>'`. If valid, the server account has no SMB-NT hash: `sudo dscl . -read /Users/<user> AuthenticationAuthority` shows `HASHLIST:<SALTED-SHA512-PBKDF2,SRP-…>` without `SMB-NT`, so the server accepts SMB by Kerberos only. That is fine as long as the Apple-ID branch works; fix the client side first. Enabling password SMB on the server (System Settings → General → Sharing → File Sharing → ⓘ → Options → tick the account) is the last resort: it stores a weaker NT hash and applies to every client.

**The client has no Apple-ID identity** (different Apple ID, or `AltSecurityIdentities` missing on either account) — password path: enable password SMB on the server as above, then store the credential on the client from its GUI session, because SSH sessions refuse keychain writes even with the keychain unlocked:
```
sudo launchctl asuser <uid> sudo -u <user> -i security add-internet-password -A \
  -a <server-account> -s <host> -r "smb " -l "<host> SMB" -w '<pw>'
```
Move the password machine-to-machine (read it from another Mac's keychain into a shell variable and pipe it) rather than through the conversation.

**`kinit <user>@LKDC:…` says "unable to reach any KDC"** — expected. LKDC is negotiated in-band over the SMB connection; there is no KDC to reach and this route is closed.

**Mounted as `//com.apple.idms…@<host>/<user>` at `/Volumes/<user>` with `acct = "No user account"` in the keychain** — the Finder → Network path. It works but lands at different mount points and goes stale; connect by hostname so the mounts match the agent's.

**Credential cache looks empty** — you are looking from SSH. The cache is per GUI session: `sudo launchctl asuser <uid> sudo -u <user> -i klist --list-all`.

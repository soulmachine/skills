# Reference — ASUS ASMB12 (AMI SP-X gen13) firmware APIs

Validated 2026-06-06 on ESC8000-E12P, BMC 1.29.1→1.37.1, BIOS 0603→0804.

## Discovering versions (Redfish, basic auth)

```
GET /redfish/v1/Managers                  -> Members[0] e.g. /redfish/v1/Managers/BMC_0
GET /redfish/v1/Managers/BMC_0            -> FirmwareVersion
GET /redfish/v1/Systems                   -> Members[0] e.g. /redfish/v1/Systems/System_0
GET /redfish/v1/Systems/System_0          -> BiosVersion, PowerState
GET /redfish/v1/UpdateService             -> Oem.BMC.DualImageConfigurations (Image1/2 + active)
```
`*/Self` paths return errors on this build. `BiosVersion` is stale while host is off; it
refreshes mid-POST after a BIOS flash.

## Latest versions from ASUS

```
GET https://www.asus.com/support/api/product.asmx/GetPDBIOS?website=global&model=<MODEL>&cpu=&osid=
```
Returns BIOS + BMC entries with versions, dates, and `dlcdnets.asus.com` zip URLs.

## BMC firmware update (Redfish multipart) — host-safe

1. Snapshot manager/network config (GET the resources to files).
2. Preserve config (defaults are FALSE → flash would reset network/users!):
   `PATCH /redfish/v1/UpdateService` with `If-Match: <ETag>`:
   `{"Oem":{"AMIUpdateService":{"PreserveConfiguration":{<all 14 keys>: true}}}}`
   Keys: Authentication EXTLOG FRU IPMI KVM NTP Network REDFISH SDR SEL SNMP SSH Syslog WEB.
3. Upload (multipart/form-data, exactly three parts):
   - `UpdateParameters` (json): `{"Targets":["/redfish/v1/UpdateService/FirmwareInventory/BMCImage1"],"@Redfish.OperationApplyTime":"Immediate"}`
   - `OemParameters` (json): `{"ImageType":"HPM"}`   ← "BMC"/"BIOS"/"FlashType" are all rejected
   - `UpdateFile` (octet-stream): the `.hpm`
   Response 202 + Task URI.
4. Poll Task + `UpdateService.Oem.AMIUpdateService.FlashPercentage` (e.g. "88% done", "Complete").
5. Task `Completed` → BMC reboots itself (~2–4 min down). Verify FirmwareVersion + auth after.
6. Old firmware stays in the inactive image slot (DualImageConfigurations) as rollback.

## BIOS update (HPM wizard API) — chassis must be OFF

Session: `POST /api/session` form `username=&password=` → cookies + `CSRFToken` (send back as
`X-CSRFTOKEN` header on every call). All wizard calls are `/api/maintenance/...`.

| # | Call | Notes |
|---|------|-------|
| 0 | `GET /api/chassis-status` | require `power_status: 0` |
| 1 | `PUT firmware/biosSaveSetting {"EnableSaveBIOS":1,"Ctrl":2}` | preserve BIOS settings; non-fatal |
| 2 | `PUT hpm/updatemode {}` | → `{unique_id}` = FWUPDATEID. **Danger zone begins** |
| 3 | `PUT hpm/preparecomponents {FWUPDATEID, COMPONENT_ID, PRODUCT_ID:0, MANAFACTURE_ID:0, HPM_FLAG:1, COMPONENT_DATA_LEN, IS_MMC:0}` | all 7 keys required (`cc:8` if missing) |
| 4 | `POST hpm/oemfw` multipart, field `oemimage` = component data slice | 200 `{cc:0}`; ~20 s on LAN |
| 5 | `PUT hpm/flash {COMPONENT_ID, COMPONENT_DATA_LEN, FWUPDATEID, SECTION_FLASH:0}` | **THE step everyone misses** — actually starts the flash |
| 6 | poll `GET hpm/upgradestatus?COMPONENT_ID=&FWUPDATEID=` | `PROGRESS` 0→100; `-1` = failed; 500s may appear before step 5 ran |
| 7 | `PUT hpm/verifyimage {COMPONENT_ID, COMPONENT_DATA_LEN, FWUPDATEID}` then poll `GET hpm/verifyimagestatus?COMPONENT_ID=` | `PROGRESS` →100 |
| 8 | `PUT hpm/activatecomponents {FWUPDATEID, COMPONENT_ID}` | |
| 9 | `PUT hpm/exitupdatemode {FWUPDATEID}` | ALWAYS reach this (success or failure) |

**Escape hatch:** step 9 works from any admin session that knows FWUPDATEID — recoverable
even if the original session dies (unlike the interactive wizard).

### HPM file slicing (what to upload in step 4)

PICMG HPM.1 container: 8-byte sig `PICMGFWU`, header (devid@9, manuf 3B LE @10, prod 2B LE @13,
oemlen 2B LE @32), first action at `34+oemlen+1`. Action: type(1) comp-bitmask(1) cksum(1);
type 2 = upload: +version(6) +desc(21) +len(4 LE) +data. Upload the `data[offset:offset+len]`
slice verbatim. Trailing 16 bytes of file = MD5 of everything before (verify before flashing!).
Component bitmask→wizard COMPONENT_ID: 0x04 BIOS→2, 0x08 MMC→1, 0x10 OEM→4 (ESC8000-E12P BIOS
ships as OEM 0x10 with internal image-type 42 = BIOS capsule), 0x20 CPLD→11.

## Error/symptom table

| Symptom | Meaning | Fix |
|---|---|---|
| login `code 1348` "Could not login" / "Firmware update in progress" banner, Redfish 503, ports 22/623/5900 closed, web 200 | BMC latched in flash mode; no timeout exists | AC drain 30 s (only fix when no session survives) |
| `upgradestatus` 500 `code 1442` "Error in HPM Finish Firmware Upload" | upload staged but `hpm/flash` never sent | send step 5 (works cross-session with FWUPDATEID) |
| `preparecomponents` 400 `cc:8` "Required Variable Not Found" | payload missing one of the 7 keys | send all 7 |
| Redfish upload 400 "OemParameters ... missing" / "ImageType ... not valid" | wrong multipart shape | `{"ImageType":"HPM"}`; BIOS can't go via Redfish upload on this build |
| Redfish 400 "BiosUpdateMethod is missing" then "not a valid parameter" everywhere | dead end by design | use HPM wizard API instead |
| `ipmitool hpm upgrade` → `compcode=0xd5` at block 0, or ~3 KB/s | HPM-over-LAN unusable | use wizard API |
| `Manager.Reset GracefulRestart` rejected | wrong enum | use `ForceRestart` on `Managers/BMC_0` |
| Host turns ON by itself after BMC reset | power-restore policy | shut host down AFTER any BMC reset, then flash BIOS |
| BMC API quiet/5xx mid-flash | normal during SPI write | keep polling; don't abort after step 5 |

## Order of operations for a full upgrade

1. Check versions; download zips; verify HPM MD5 trailer.
2. BMC update (host running OK). Wait for BMC back + verify.
3. If BMC was reset/updated: host probably bounced ON → graceful shutdown, confirm Off.
4. BIOS update via wizard script. Power on. Wait for POST (5–15 min) → BiosVersion flips → OS up.
5. Record versions; old BMC remains in standby image slot for rollback.

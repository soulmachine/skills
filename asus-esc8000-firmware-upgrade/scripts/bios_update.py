#!/usr/bin/env python3
"""BIOS update for ASUS ASMB12 (AMI SP-X gen13) BMCs via the HPM wizard API.

Mirrors the web UI firmware-update wizard call-for-call, including the
hpm/flash trigger the wizard fires after upload (omitting it leaves the BMC
holding staged data and upgradestatus returns 500 code 1442).

Usage:
    BMC_PASSWORD='...' python3 bios_update.py --ip 10.50.5.165 --file Z14PG-D32-ASUS-0804.HPM

Requirements: chassis powered OFF (script enforces). Exits update mode on any
pre-flash failure. After success, power the host on and wait through POST.
"""
import argparse, hashlib, json, os, ssl, sys, time, uuid, urllib.request, urllib.parse, urllib.error
from http.cookiejar import CookieJar

# HPM.1 component bitmask -> wizard COMPONENT_ID (from BMC web app constants)
BITMASK_TO_CID = {0x04: 2, 0x08: 1, 0x10: 4, 0x20: 11}   # BIOS, MMC, OEM(BIOS capsule on ESC8000), CPLD


def parse_hpm(path):
    """Return (data_offset, data_len, version, desc, component_id) of the first upload action."""
    f = open(path, "rb").read()
    if f[:8] != b"PICMGFWU":
        sys.exit(f"not an HPM.1 file: {path}")
    md5_ok = hashlib.md5(f[:-16]).digest() == f[-16:]
    if not md5_ok:
        sys.exit("HPM image MD5 trailer mismatch - corrupt download, refusing to flash")
    oemlen = int.from_bytes(f[32:34], "little")
    off = 34 + oemlen + 1
    while off < len(f) - 20:
        atype, comp = f[off], f[off + 1]
        if atype in (0, 1):
            off += 3
        elif atype == 2:
            ver = f[off + 3:off + 9]
            desc = f[off + 9:off + 30].split(b"\x00")[0].decode(errors="replace")
            ln = int.from_bytes(f[off + 30:off + 34], "little")
            cid = BITMASK_TO_CID.get(comp)
            if cid is None:
                sys.exit(f"unsupported HPM component bitmask 0x{comp:02x} - extend BITMASK_TO_CID")
            print(f"HPM ok: comp=0x{comp:02x}->CID {cid} ver={ver[0]}.{ver[1]:02x} desc={desc} "
                  f"data=[{off+34}:{off+34+ln}] md5=verified")
            return off + 34, ln, ver, desc, cid
        else:
            sys.exit(f"unknown HPM action type {atype} at {off}")
    sys.exit("no upload action found in HPM file")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ip", required=True)
    ap.add_argument("--file", required=True)
    ap.add_argument("--username", default=os.environ.get("BMC_USERNAME", "admin"))
    args = ap.parse_args()
    password = os.environ.get("BMC_PASSWORD") or sys.exit("set BMC_PASSWORD env var")

    data_off, data_len, _ver, _desc, cid = parse_hpm(args.file)

    ctx = ssl.create_default_context(); ctx.check_hostname = False; ctx.verify_mode = ssl.CERT_NONE
    opener = urllib.request.build_opener(
        urllib.request.HTTPSHandler(context=ctx), urllib.request.HTTPCookieProcessor(CookieJar()))
    state = {"csrf": None}

    def log(m): print(f"[{time.strftime('%H:%M:%S')}] {m}", flush=True)

    def call(method, path, body=None, raw=None, ctype="application/json", timeout=30, quiet=False):
        data = raw if raw is not None else (json.dumps(body).encode() if body is not None else None)
        req = urllib.request.Request(f"https://{args.ip}{path}", data=data, method=method)
        if data is not None: req.add_header("Content-Type", ctype)
        if state["csrf"]: req.add_header("X-CSRFTOKEN", state["csrf"])
        try:
            with opener.open(req, timeout=timeout) as r:
                t = r.read().decode(errors="replace")
                try: return r.status, json.loads(t) if t.strip() else {}
                except json.JSONDecodeError: return r.status, {"_raw": t[:200]}
        except urllib.error.HTTPError as e:
            t = e.read().decode(errors="replace")[:300]
            if not quiet: log(f"  HTTP {e.code} {method} {path}: {t}")
            return e.code, {"_err": t}
        except Exception as e:
            if not quiet: log(f"  EXC {method} {path}: {e!r}")
            return 0, {"_exc": repr(e)}

    def bail(fwid, why):
        log(f"ABORT: {why} -> exitupdatemode")
        st, r = call("PUT", "/api/maintenance/hpm/exitupdatemode", {"FWUPDATEID": fwid}, timeout=60)
        log(f"  exitupdatemode -> {st} {r}")
        sys.exit(1)

    def poll(path, label, max_quiet, max_total, fwid):
        t0, fails = time.time(), 0
        while True:
            st, r = call("GET", path, timeout=20, quiet=True)
            prog = r.get("PROGRESS") if st == 200 else None
            if st == 200 and prog is not None:
                fails = 0
                log(f"  {label} PROGRESS={prog}")
                p = int(prog)
                if p == -1: bail(fwid, f"{label} reported failure (-1)")
                if p >= 100: return
            else:
                fails += 1
                if fails % 6 == 1: log(f"  ({label} quiet/{st}; {int(time.time()-t0)}s)")
                if fails > max_quiet: bail(fwid, f"{label}: no response too long")
            if time.time() - t0 > max_total: bail(fwid, f"{label} exceeded time cap")
            time.sleep(10)

    # login
    st, r = call("POST", "/api/session",
                 raw=urllib.parse.urlencode({"username": args.username, "password": password}).encode(),
                 ctype="application/x-www-form-urlencoded")
    if st != 200: sys.exit(f"login failed: {st} {r}")
    state["csrf"] = r.get("CSRFToken"); log("logged in")

    # hard gate: chassis must be off
    st, r = call("GET", "/api/chassis-status")
    log(f"chassis-status -> {st} {r}")
    if st != 200 or r.get("power_status") != 0:
        sys.exit("ABORT: chassis not powered off (BIOS flash requires host OFF)")

    st, r = call("PUT", "/api/maintenance/firmware/biosSaveSetting", {"EnableSaveBIOS": 1, "Ctrl": 2})
    log(f"biosSaveSetting(1,2) -> {st}")

    st, r = call("PUT", "/api/maintenance/hpm/updatemode", {})
    if st != 200 or "unique_id" not in r: sys.exit(f"updatemode failed: {st} {r}")
    fwid = r["unique_id"]; log(f"update mode entered, FWUPDATEID={fwid}")

    st, r = call("PUT", "/api/maintenance/hpm/preparecomponents",
                 {"FWUPDATEID": fwid, "COMPONENT_ID": cid, "PRODUCT_ID": 0, "MANAFACTURE_ID": 0,
                  "HPM_FLAG": 1, "COMPONENT_DATA_LEN": data_len, "IS_MMC": 1 if cid == 1 else 0}, timeout=60)
    log(f"preparecomponents -> {st} {r}")
    if st != 200: bail(fwid, "preparecomponents rejected")

    blob = open(args.file, "rb").read()[data_off:data_off + data_len]
    field = {4: "oemimage", 2: "hpmbios", 1: "mmc", 11: "hpmcpld"}[cid]
    url = {4: "oemfw", 2: "oemfw", 1: "mmcfw", 11: "cpldfw"}[cid]
    log(f"uploading {len(blob)} bytes -> hpm/{url} (field {field})")
    bnd = uuid.uuid4().hex
    body = (f'--{bnd}\r\nContent-Disposition: form-data; name="{field}"; '
            f'filename="{os.path.basename(args.file)}"\r\n'
            f'Content-Type: application/octet-stream\r\n\r\n').encode() + blob + f"\r\n--{bnd}--\r\n".encode()
    st, r = call("POST", f"/api/maintenance/hpm/{url}", raw=body,
                 ctype=f"multipart/form-data; boundary={bnd}", timeout=600)
    log(f"upload -> {st} {r}")
    if st != 200: bail(fwid, f"upload failed ({st})")

    # THE step the wizard fires after upload - without it nothing flashes
    st, r = call("PUT", "/api/maintenance/hpm/flash",
                 {"COMPONENT_ID": cid, "COMPONENT_DATA_LEN": data_len,
                  "FWUPDATEID": fwid, "SECTION_FLASH": 0}, timeout=90)
    log(f"hpm/flash (start) -> {st} {r}")
    if st != 200: bail(fwid, f"hpm/flash rejected ({st})")

    qs = urllib.parse.urlencode({"COMPONENT_ID": cid, "FWUPDATEID": fwid})
    poll(f"/api/maintenance/hpm/upgradestatus?{qs}", "upgrade", 240, 3600, fwid)

    st, r = call("PUT", "/api/maintenance/hpm/verifyimage",
                 {"COMPONENT_ID": cid, "COMPONENT_DATA_LEN": data_len, "FWUPDATEID": fwid}, timeout=60)
    log(f"verifyimage -> {st} {r}")
    poll(f"/api/maintenance/hpm/verifyimagestatus?COMPONENT_ID={cid}", "verify", 120, 1800, fwid)

    st, r = call("PUT", "/api/maintenance/hpm/activatecomponents",
                 {"FWUPDATEID": fwid, "COMPONENT_ID": cid}, timeout=120)
    log(f"activatecomponents -> {st} {r}")
    st, r = call("PUT", "/api/maintenance/hpm/exitupdatemode", {"FWUPDATEID": fwid}, timeout=120)
    log(f"exitupdatemode -> {st} {r}")
    log("=== FLASH COMPLETE - power the host on and wait through POST (5-15 min) ===")


if __name__ == "__main__":
    main()

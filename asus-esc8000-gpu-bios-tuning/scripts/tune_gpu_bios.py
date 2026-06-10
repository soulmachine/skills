#!/usr/bin/env python3
"""Apply the GPU-serving BIOS profile to an ASUS ESC8000 (ASMB12/AMI BMC) over Redfish.

Dry-run by default. Sources: a stored profile JSON (default) or a live template host.

    export BMC_PASSWORD='...'
    tune_gpu_bios.py --target 10.0.0.5                       # dry-run diff
    tune_gpu_bios.py --target 10.0.0.5 --apply               # stage only (reversible, no reboot)
    tune_gpu_bios.py --target 10.0.0.5 --apply --reboot      # stage + reboot + verify
    tune_gpu_bios.py --target NEW --from-host TUNED --apply --reboot   # copy live from a tuned box

Gentle/paced (single connection) to avoid wedging the AMI BMC's auth/session pool.
"""
import argparse, json, os, ssl, sys, time, urllib.request, urllib.error, base64

def log(m): print(f"[{time.strftime('%H:%M:%S')}] {m}", flush=True)

class BMC:
    def __init__(self, ip, pw, user="admin"):
        self.base = f"https://{ip}/redfish/v1"
        self.sys  = f"{self.base}/Systems/System_0"
        self.bios = f"{self.sys}/Bios"
        self.auth = base64.b64encode(f"{user}:{pw}".encode()).decode()
        self.ctx  = ssl.create_default_context(); self.ctx.check_hostname=False; self.ctx.verify_mode=ssl.CERT_NONE
    def req(self, method, url, body=None, hdrs=None, timeout=25):
        h={"Authorization":"Basic "+self.auth}
        if hdrs: h.update(hdrs)
        r=urllib.request.Request(url, method=method,
            data=json.dumps(body).encode() if body else None, headers=h)
        if body: r.add_header("Content-Type","application/json")
        try:
            with urllib.request.urlopen(r, timeout=timeout, context=self.ctx) as resp:
                return resp.status, dict(resp.headers), resp.read().decode()
        except urllib.error.HTTPError as e:
            return e.code, dict(e.headers), e.read().decode()
        except Exception as e:
            return 0, {}, repr(e)
    def attrs(self):
        st,_,b = self.req("GET", self.bios)
        return json.loads(b).get("Attributes",{}) if st==200 else {}
    def power(self):
        st,_,b = self.req("GET", self.sys)
        try: return json.loads(b).get("PowerState")
        except: return None

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--target", required=True, help="BMC IP to tune")
    ap.add_argument("--from-host", help="copy live token values from this already-tuned BMC IP")
    ap.add_argument("--profile", default=os.path.join(os.path.dirname(__file__),"gpu_serving_profile.json"))
    ap.add_argument("--user", default=os.environ.get("BMC_USERNAME","admin"))
    ap.add_argument("--apply", action="store_true", help="stage settings (writes /Bios/SD)")
    ap.add_argument("--reboot", action="store_true", help="with --apply: reboot and verify active")
    args = ap.parse_args()
    pw = os.environ.get("BMC_PASSWORD") or sys.exit("set BMC_PASSWORD")

    prof = json.load(open(args.profile))
    labels = prof.get("labels",{})
    tune, baseline = dict(prof["tune"]), dict(prof["baseline_verify"])

    tgt = BMC(args.target, pw, args.user)
    cur = tgt.attrs()
    if not cur: sys.exit("could not read target BIOS attributes (BMC unreachable / auth?)")

    # desired values: from template host (robust to token drift) or the stored profile
    if args.from_host:
        tmpl = BMC(args.from_host, pw, args.user); time.sleep(3)
        ta = tmpl.attrs()
        if not ta: sys.exit("could not read template host BIOS attributes")
        for k in list(tune):     tune[k]     = ta.get(k, tune[k])
        for k in list(baseline): baseline[k] = ta.get(k, baseline[k])
        log(f"using live tokens from template {args.from_host}")

    # diff
    todo, base_diff = {}, {}
    print("=== TUNING PROFILE — target vs desired ===")
    for k,v in tune.items():
        c=cur.get(k,'<none>'); mark='OK' if c==v else 'CHANGE'
        if c!=v: todo[k]=v
        print(f"  [{mark:6}] {labels.get(k,k):26} {k:26} {c!r} -> {v!r}")
    print("=== BASELINE (should already hold) ===")
    for k,v in baseline.items():
        c=cur.get(k,'<none>'); mark='OK' if c==v else 'DIFF!'
        if c!=v: base_diff[k]=v
        print(f"  [{mark:6}] {labels.get(k,k):26} {k:26} {c!r} (want {v!r})")
    if base_diff:
        print(f"  NOTE: {len(base_diff)} baseline attr(s) differ — including in change set: {list(base_diff)}")
        todo.update(base_diff)

    if not todo:
        log("target already matches the profile — nothing to do"); return
    print(f"\n{len(todo)} attribute(s) would change.")
    if not args.apply:
        log("dry-run (no --apply) — no writes performed"); return

    # ---- stage (wait out post-boot 503) ----
    log("staging to /Bios/SD ...")
    staged=False
    for _ in range(20):
        st,h,b = tgt.req("GET", tgt.bios+"/SD")
        if st!=200: time.sleep(45); continue
        et = h.get("ETag") or json.loads(b).get("@odata.etag","")
        time.sleep(2)
        st,h,b = tgt.req("PATCH", tgt.bios+"/SD", {"Attributes":todo}, {"If-Match":et} if et else {})
        if st in (200,204): staged=True; log(f"  PATCH accepted ({st})"); break
        if st==503: log("  503 (host booting/inventory); retry 45s"); time.sleep(45); continue
        log(f"  PATCH {st}: {b[:200]}"); time.sleep(45)
    if not staged: sys.exit("ABORT: could not stage settings")
    time.sleep(5)
    sd = json.loads(tgt.req("GET", tgt.bios+"/SD")[2]).get("Attributes",{})
    miss=[k for k,v in todo.items() if sd.get(k)!=v]
    log(f"staged {len(todo)-len(miss)}/{len(todo)} " + ("OK" if not miss else f"MISSING {miss}"))
    if miss: sys.exit("ABORT: staging incomplete")
    if not args.reboot:
        log("staged. Reboot the host to activate (re-run with --reboot, or power-cycle)."); return

    # ---- reboot to apply (no GracefulRestart on this build) ----
    if tgt.power()=="On":
        log("GracefulShutdown..."); tgt.req("POST", tgt.sys+"/Actions/ComputerSystem.Reset", {"ResetType":"GracefulShutdown"})
        off=False
        for _ in range(32):
            time.sleep(15)
            if tgt.power()=="Off": off=True; break
        if not off:
            log("graceful timed out -> ForceOff"); tgt.req("POST", tgt.sys+"/Actions/ComputerSystem.Reset", {"ResetType":"ForceOff"})
            for _ in range(8):
                time.sleep(15)
                if tgt.power()=="Off": off=True; break
            if not off: sys.exit("ABORT: cannot power off")
    time.sleep(8); log("powering On...")
    for _ in range(5):
        tgt.req("POST", tgt.sys+"/Actions/ComputerSystem.Reset", {"ResetType":"On"}); time.sleep(20)
        if tgt.power()=="On": break

    # ---- verify active ----
    log("waiting for POST + BIOS inventory (verify)...")
    for _ in range(50):
        time.sleep(30)
        a=tgt.attrs()
        good=sum(1 for k,v in todo.items() if a.get(k)==v)
        if good==len(todo):
            log(f"*** VERIFIED {good}/{len(todo)} active ***")
            for k,v in todo.items(): log(f"    {k} = {a.get(k)}")
            return
        log(f"  {good}/{len(todo)} active (host still booting)")
    sys.exit("WARN: verification incomplete; re-check manually")

if __name__=="__main__":
    main()

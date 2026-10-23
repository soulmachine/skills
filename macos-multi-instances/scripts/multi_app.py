#!/usr/bin/env python3
"""Make an independent copy of a macOS app: WeChat.app -> WeChat2.app, WeChat3.app, ...

Each copy gets bundle ID <original>N, so macOS gives it its own sandbox container
and it runs alongside the original under a second login.

  multi_app.py [APP]            make the next copy (default /Applications/WeChat.app)
  multi_app.py --refresh [APP]  rebuild every existing copy from the current APP
"""
import argparse
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

# An ad-hoc signature cannot carry these: they need Apple's provisioning profile.
RESTRICTED = ("com.apple.application-identifier", "com.apple.developer.team-identifier")
GROUPS = "com.apple.security.application-groups"


def copy_numbers(names, stem):
    return {int(m[1]) for n in names if (m := re.fullmatch(re.escape(stem) + r"(\d+)\.app", n))}


def next_number(names, stem):
    n = 2
    while n in copy_numbers(names, stem):
        n += 1
    return n


def run(*cmd, **kw):
    return subprocess.run(cmd, check=True, capture_output=True, **kw)


def entitlements(app):
    out = run("codesign", "-d", "--entitlements", "-", "--xml", str(app)).stdout
    return plistlib.loads(out) if out.strip() else {}


def main_exe(app):
    with open(app / "Contents/Info.plist", "rb") as f:
        return app / "Contents/MacOS" / plistlib.load(f)["CFBundleExecutable"]


def running(app):
    pattern = "^" + re.escape(str(main_exe(app))) + "( |$)"
    return subprocess.run(["pgrep", "-f", pattern], capture_output=True).returncode == 0


def launches(app, timeout=15):
    """Open the app; True if its main process is up and still alive 3 s later."""
    run("open", str(app))
    deadline = time.time() + timeout
    while time.time() < deadline:
        if running(app):
            time.sleep(3)
            return running(app)
        time.sleep(1)
    return False


def sign_sandboxed(app, ents, n):
    """Option B: keep the sandbox, so the copy lives in its own container."""
    run("codesign", "--force", "--deep", "--sign", "-", str(app))
    kept = {k: v for k, v in ents.items() if k not in RESTRICTED}
    # WeChat registers Mach services under "<group>N.*", which the sandbox denies
    # unless the copy holds that group; the renamed group also gets its own container.
    if GROUPS in kept:
        kept[GROUPS] = [f"{g}{n}" for g in kept[GROUPS]]
    # Main bundle only: nested helpers inherit the sandbox from the process that spawns them.
    with tempfile.NamedTemporaryFile(suffix=".plist") as f:
        plistlib.dump(kept, f)
        f.flush()
        run("codesign", "--force", "--sign", "-", "--entitlements", f.name, str(app))


def sign_plain(app):
    """Option A, the classic recipe: no entitlements, so no sandbox."""
    run("codesign", "--force", "--deep", "--sign", "-", str(app))


def build(src, n, ents):
    """(Re)build copy N of src. Returns True if it runs sandboxed, False if plain."""
    stem = src.stem
    dst = src.with_name(f"{stem}{n}.app")
    if dst.exists():
        shutil.rmtree(dst)  # the bundle holds no user data; that lives in the container
    run("ditto", str(src), str(dst))
    # Share/FileProvider extensions would register twice under the original's IDs.
    shutil.rmtree(dst / "Contents/PlugIns", ignore_errors=True)
    info = dst / "Contents/Info.plist"
    with open(info, "rb") as f:
        plist = plistlib.load(f)
    plist["CFBundleIdentifier"] = f"{plist['CFBundleIdentifier']}{n}"
    plist["CFBundleName"] = plist["CFBundleDisplayName"] = f"{stem}{n}"
    with open(info, "wb") as f:
        plistlib.dump(plist, f)

    sign_sandboxed(dst, ents, n)
    if launches(dst):
        print(f"{dst}: {plist['CFBundleIdentifier']}, sandboxed, running")
        return True
    sign_plain(dst)
    if not launches(dst):
        sys.exit(f"{dst}: does not launch with either signature")
    print(f"{dst}: {plist['CFBundleIdentifier']}, running WITHOUT a sandbox "
          "(the sandboxed signature did not launch)")
    return False


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("app", nargs="?", default="/Applications/WeChat.app", type=Path)
    p.add_argument("--refresh", action="store_true", help="rebuild every existing copy from APP")
    a = p.parse_args()
    src = a.app.resolve()
    if not (src / "Contents/Info.plist").is_file():
        sys.exit(f"{src}: not an app bundle")
    ents = entitlements(src)
    names = [x.name for x in src.parent.iterdir()]

    if not a.refresh:
        build(src, next_number(names, src.stem), ents)
        return
    numbers = sorted(copy_numbers(names, src.stem))
    if not numbers:
        sys.exit(f"no copies of {src.name} to refresh")
    for n in numbers:
        dst = src.with_name(f"{src.stem}{n}.app")
        if running(dst):
            print(f"{dst}: running, skipped; quit it and rerun --refresh")
            continue
        was_sandboxed = "com.apple.security.app-sandbox" in entitlements(dst)
        if not build(src, n, ents) and was_sandboxed:
            print(f"{dst}: was sandboxed, now is not, so it no longer sees its old data; log in again")


if __name__ == "__main__":
    main()

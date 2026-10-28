"""Pair apwcli's daemon with Apple Passwords with nobody at the screen.

Requests the pairing challenge through apwlib, reads the 6-digit PIN that macOS shows in
PasswordManagerBrowserExtensionHelper's "Verification Code" window through Accessibility
(System Events), and submits it. Run with apwcli's own interpreter (the `apwcli-pair` wrapper
beside this file does that), so `apwlib` imports.

Exit: 0 paired or already paired, 1 PIN rejected, 2 apwcli error, 3 no PIN visible.
"""

from __future__ import annotations

import re
import subprocess
import sys
import time

# Measured 2026-10-28 on macOS 26: the window is "Verification Code"; the PIN is the one static
# text inside its group, formatted "123 456". The other static texts are the explanatory
# sentences, which carry no digits.
_PIN_QUERY = (
    'tell application "System Events" to tell process "PasswordManagerBrowserExtensionHelper" '
    "to get value of every static text of group 1 of window 1"
)
_WAIT_SECONDS = 15.0


def extract_pin(text: str) -> str | None:
    """The 6 digits in the group's text, or None."""
    digits = re.sub(r"\D", "", text)
    return digits if len(digits) == 6 else None


def read_pin(wait: float = _WAIT_SECONDS) -> str | None:
    deadline = time.monotonic() + wait
    while time.monotonic() < deadline:
        r = subprocess.run(["osascript", "-e", _PIN_QUERY], capture_output=True, text=True)
        pin = extract_pin(r.stdout) if r.returncode == 0 else None
        if pin:
            return pin
        time.sleep(0.5)
    return None


def selftest() -> None:
    assert extract_pin("123 456") == "123456"
    assert extract_pin("Enter this code, 987654") == "987654"
    assert extract_pin("no digits") is None
    assert extract_pin("12 34") is None
    print("selftest ok")


def main(argv: list[str]) -> int:
    if "--selftest" in argv:
        selftest()
        return 0
    verbose = "--verbose" in argv
    from apwlib import ApwError, Daemon

    try:
        d = Daemon()
        if d.status().get("paired"):
            print("already paired")
            return 0
        d.request_challenge()
        pin = read_pin()
        if pin is None:
            print(
                "no PIN visible: is the Mac logged in and unlocked, and does the process running "
                "this (sshd-keygen-wrapper over ssh) have Accessibility?",
                file=sys.stderr,
            )
            return 3
        if verbose:
            print(f"pin {pin}")
        if d.verify_challenge(pin):
            print("paired")
            return 0
        print("pairing failed: helper rejected the PIN", file=sys.stderr)
        return 1
    except ApwError as exc:
        print(f"apwcli error: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

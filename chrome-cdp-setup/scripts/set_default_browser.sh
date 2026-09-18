#!/bin/bash
# Make the CDP wrapper the default web browser, so a link click with Chrome closed
# launches the CDP instance instead of a flag-less default-profile Chrome.
# Usage: set_default_browser.sh [--revert]
#
# macOS gates this behind its own "change your default web browser?" dialog, and one
# answer covers http, https and .html together — so this asks once, then waits for
# the click. Leave the click to the user: it is their consent gate.
set -euo pipefail

APP="/Applications/Google Chrome CDP.app"
[ -d "$APP" ] || { echo "ERROR: wrapper not built; run setup_chrome_cdp.sh first" >&2; exit 1; }
[ "${1:-}" = "--revert" ] && APP="/Applications/Google Chrome.app"
BID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")
NAME=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$APP/Contents/Info.plist" 2>/dev/null || basename "$APP" .app)

osascript -l JavaScript - "$BID" "$NAME" <<'JS'
function run([bid, name]) {
    ObjC.import('CoreServices');
    const kLSRolesAll = 0xFFFFFFFF;
    const str = ref => { try { return ObjC.castRefToObject(ref).js || ''; } catch (e) { return ''; } };
    const current = () => ({
        'http': str($.LSCopyDefaultHandlerForURLScheme($('http'))),
        'https': str($.LSCopyDefaultHandlerForURLScheme($('https'))),
        'public.html': str($.LSCopyDefaultRoleHandlerForContentType($('public.html'), kLSRolesAll)),
    });
    const done = got => Object.values(got).every(v => v.toLowerCase() === bid.toLowerCase());
    const show = got => Object.entries(got).forEach(([k, v]) => console.log(`    ${k.padEnd(11)} -> ${v}`));

    let got = current();
    if (done(got)) { show(got); return `==> ${name} is already the default web browser`; }
    // One call, for http only: every LSSetDefaultHandlerForURLScheme call raises its own
    // dialog, and the answer to one covers http, https and public.html together.
    $.LSSetDefaultHandlerForURLScheme($('http'), $(bid));
    console.log(`==> macOS is asking: click “Use ${name}” in its dialog (it may sit behind other windows)`);
    for (let waited = 0; waited < 120 && !done(got = current()); waited++) delay(1);
    show(got);
    if (!done(got)) throw new Error('no change after 120 s: dialog unanswered or declined. Retry, or pick it in System Settings ▸ Desktop & Dock ▸ Default web browser.');
    return `==> Default web browser now ${name}`;
}
JS

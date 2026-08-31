// Commit com.apple.smb.server settings through SCPreferences so the
// com.apple.smb.preferences launchd event fires and the change reaches smbd.
// Usage: sudo swift smb-prefs.swift Key=true|false|delete|<string> ...
// Follow with: sudo launchctl kickstart -k system/com.apple.smbd

import SystemConfiguration
import Foundation

let args = Array(CommandLine.arguments.dropFirst())
guard !args.isEmpty else {
    print("usage: sudo swift smb-prefs.swift Key=true|false|delete|<string> ...")
    exit(64)
}
guard let prefs = SCPreferencesCreate(nil, "smb-prefs" as CFString, "com.apple.smb.server.plist" as CFString) else {
    print("SCPreferencesCreate failed (run with sudo)")
    exit(1)
}
for arg in args {
    let parts = arg.split(separator: "=", maxSplits: 1).map(String.init)
    guard parts.count == 2, !parts[0].isEmpty else {
        print("bad argument: \(arg)")
        exit(64)
    }
    let key = parts[0] as CFString
    switch parts[1] {
    case "true": SCPreferencesSetValue(prefs, key, kCFBooleanTrue)
    case "false": SCPreferencesSetValue(prefs, key, kCFBooleanFalse)
    case "delete": SCPreferencesRemoveValue(prefs, key)
    default: SCPreferencesSetValue(prefs, key, parts[1] as CFString)
    }
}
let committed = SCPreferencesCommitChanges(prefs)
let applied = SCPreferencesApplyChanges(prefs)
print("commit=\(committed) apply=\(applied)")
exit(committed && applied ? 0 : 1)

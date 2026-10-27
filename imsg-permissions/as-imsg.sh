#!/bin/zsh
# Run imsg once as its own responsible process (a one-shot gui-domain LaunchAgent), so a TCC
# prompt names "imsg". --tty puts a tty the user owns on stdin; imsg asks for Contacts only then.
# Usage: as-imsg.sh [--tty] <imsg args...>    Prints imsg's output and exit code.
set -u
stdin=""
if [[ ${1:-} == --tty ]]; then
  shift
  stdin=$(ls -l /dev/ttys* | awk -v u="$(id -un)" '$3==u{print $NF; exit}')
  [[ -n $stdin ]] || { echo "no tty owned by $(id -un)" >&2; exit 2; }
fi
bin=$(readlink -f /opt/homebrew/bin/imsg)
real=$(sed -n 's/^exec "\([^"]*\)".*/\1/p' "$bin")  # bin/imsg is a bash wrapper around libexec/imsg
[[ -x ${real:-} ]] || real=$bin
label=imsg-permissions.$$ dir=$(mktemp -d) uid=$(id -u)
{
  print '<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
  print "<plist version=\"1.0\"><dict><key>Label</key><string>$label</string><key>ProgramArguments</key><array>"
  for a in "$real" "$@"; do print "<string>${${a//&/&amp;}//</&lt;}</string>"; done
  print "</array><key>StandardOutPath</key><string>$dir/out</string><key>StandardErrorPath</key><string>$dir/out</string>"
  [[ -n $stdin ]] && print "<key>StandardInPath</key><string>$stdin</string>"
  print '<key>RunAtLoad</key><true/></dict></plist>'
} > "$dir/job.plist"
launchctl bootstrap gui/$uid "$dir/job.plist" || exit 2
# Wait up to 120 s: a TCC prompt holds the job until someone answers it.
for i in {1..120}; do
  code=$(launchctl print gui/$uid/$label 2>/dev/null | sed -n 's/.*last exit code = //p' | head -1)
  [[ $code == <-> ]] && break
  sleep 1
done
cat "$dir/out"; echo "exit=$code"
launchctl bootout gui/$uid/$label 2>/dev/null; rm -rf "$dir"

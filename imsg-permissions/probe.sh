#!/bin/zsh
# Test imsg's three privacy gates from whatever parent runs this script. Reads only; sends nothing.
# Usage: probe.sh <own-address> [--keep-ssh]
addr=${1:?usage: probe.sh <own-address> [--keep-ssh]}
# Outside SSH, imsg must not see SSH_* (leaked by `open` from an SSH shell), or it takes the SSH path.
[[ $2 == --keep-ssh ]] || unset SSH_CONNECTION SSH_CLIENT SSH_TTY
imsg=/opt/homebrew/bin/imsg
fda=$($imsg chats --limit 1 --json 2>&1 | grep -q '"id"' && echo ok || echo FAIL)
auto=$(osascript -e 'tell application "Messages" to count of chats' 2>&1)
contacts=$($imsg nickname --local --address "$addr" --json 2>&1 \
  | grep -o '"contacts_unavailable":[a-z]*\|"local_contact_name":"[^"]*"' | tr '\n' ' ')
echo "FDA=$fda AUTOMATION=$auto CONTACTS=$contacts"

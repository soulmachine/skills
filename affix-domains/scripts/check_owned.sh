#!/usr/bin/env bash
# check_owned.sh — which candidate domains are already in the user's own registrar accounts.
#
#   ./check_owned.sh bitchat matebuddy
#   printf 'a\nb\n' | ./check_owned.sh --stdin
#
# Prints one TAB-separated line per owned domain whose bare name is a candidate,
# any TLD: <domain>\tOWNED. Sources: Cloudflare through `cf`, GoDaddy through
# `gddy`. A source that is not installed or not logged in is skipped with one
# line on stderr, so its domains keep the registry's TAKEN. Exit 0 always.
set -uo pipefail

NAMES=()
READ_STDIN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --stdin) READ_STDIN=1; shift ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) NAMES+=("$1"); shift ;;
  esac
done
(( READ_STDIN )) && while IFS= read -r l; do [[ -n "$l" ]] && NAMES+=("$l"); done
[[ ${#NAMES[@]} -eq 0 ]] && { echo "no names given" >&2; exit 0; }

owned() {
  # Cloudflare: the zones list, not `registrar registrations list`. That one caps at 50 and hides
  # its cursor; Cloudflare Registrar needs the zone on the same account, so zones cover it.
  local page=1 got=0 out n
  while out=$(cf zones list --per-page 50 --page "$page" 2>/dev/null) && [[ -n "$out" ]]; do
    n=$(jq -r 'if type=="array" then . else .result end | .[].name' <<<"$out" 2>/dev/null) || break
    got=1; printf '%s\n' "$n"
    (( $(wc -l <<<"$n") < 50 )) && break
    (( page++ ))
  done
  (( got )) || echo "check_owned: cf skipped, not logged in" >&2
  gddy domain list -o json 2>/dev/null | jq -r '.data[].domain' 2>/dev/null \
    || echo "check_owned: gddy skipped, not logged in" >&2
}

owned | awk -F. -v names="${NAMES[*]}" '
  BEGIN { split(names, a, " "); for (i in a) want[a[i]] = 1 }
  NF >= 2 && ($1 in want) { print $0 "\tOWNED" }'
exit 0

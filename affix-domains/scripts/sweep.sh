#!/usr/bin/env bash
# sweep.sh — run every lane of one affix-domains sweep at once, then merge.
#
#   ./sweep.sh com RUN_DIR         # .com-only mode
#   ./sweep.sh escalated RUN_DIR   # full TLD set
#
# RUN_DIR/names holds the candidates, one per line, in rank order. A lane is one
# rate-limit pool, run as a background job over every name: com,net · cc · org ·
# ai,io · app · co (com alone in .com-only mode) · GitHub · X. Each lane re-runs
# its UNKNOWN lookups once, per TLD, as soon as it ends, unless most of that TLD
# came back UNKNOWN: that is a quota block, and a retry inside the session does
# not clear it. Prints merge.sh's table; lane files stay in RUN_DIR.
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
mode="${1:-}"; RUN="${2:-}"
case "$mode" in
  com)       tld_lanes=(com) ;;
  escalated) tld_lanes=(com,net cc org ai,io app co) ;;
  *) sed -n '2,12p' "$0"; exit 1 ;;
esac
[[ -s "$RUN/names" ]] || { echo "sweep: $RUN/names is missing or empty" >&2; exit 1; }

retry() {   # $1=lane file, $2=suffix to strip ("" for name lanes), rest=checker command
  local f=$1 s=$2 names; shift 2
  names=$(awk -F'\t' -v s="$s" -v lane="${f##*/}" '
    substr($1, length($1) - length(s) + 1) == s {
      n++; if ($2 == "UNKNOWN") { u++; l = l substr($1, 1, length($1) - length(s)) "\n" }
    }
    END {
      if (u * 2 > n) printf "sweep: %s %d of %d UNKNOWN, a quota block; not retried\n", (s == "" ? lane : s), u, n > "/dev/stderr"
      else printf "%s", l
    }' "$f")
  [[ -n "$names" ]] && printf '%s\n' "$names" | "$@" --stdin >> "$f"
}

domain_lane() {   # $1=comma-separated TLDs sharing one pool
  local out="$RUN/dom-$1.tsv" t
  "$here/check_domains.sh" --tlds "$1" --stdin < "$RUN/names" > "$out"
  for t in ${1//,/ }; do retry "$out" ".$t" "$here/check_domains.sh" --tlds "$t"; done
}

name_lane() {   # $1=output file, $2=checker
  "$2" --stdin < "$RUN/names" > "$1"
  retry "$1" "" "$2"
}

for t in "${tld_lanes[@]}"; do domain_lane "$t" & done
name_lane "$RUN/github.tsv" "$here/check_github.sh" &
name_lane "$RUN/x.tsv"      "$here/check_x.sh" &
wait
"$here/merge.sh" "$RUN"

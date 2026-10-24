#!/usr/bin/env bash
# merge.sh — pivot one sweep's lane outputs into one line per name, in rank order.
#
#   ./merge.sh RUN_DIR
#
# Reads RUN_DIR/names (candidates, rank order), RUN_DIR/dom-*.tsv (check_domains.sh
# output), RUN_DIR/github.tsv and RUN_DIR/x.tsv; a missing lane file reads as "-".
# Prints: <name>\t<FREE TLDs, best first>\t<UNKNOWN TLDs>\t<github>\t<x>
#
# A lane may append re-run lines to its file: a definite verdict replaces an
# earlier UNKNOWN, and an UNKNOWN never replaces a definite verdict.
set -uo pipefail

d="${1:?usage: merge.sh RUN_DIR}"
files=("$d/names")
for f in "$d"/dom-*.tsv "$d/github.tsv" "$d/x.tsv"; do [[ -e "$f" ]] && files+=("$f"); done

awk -F'\t' '
  FILENAME ~ /\/names$/ { if ($1 != "") order[++n] = $1; next }
  {
    if (FILENAME ~ /\/github\.tsv$/)  k = $1 SUBSEP "gh"
    else if (FILENAME ~ /\/x\.tsv$/)  k = $1 SUBSEP "x"
    else { i = index($1, "."); k = substr($1, 1, i - 1) SUBSEP substr($1, i + 1) }
    if (!(k in v) || $2 != "UNKNOWN") v[k] = $2
  }
  END {
    split("com ai io app co net org cc", pref, " ")
    for (j = 1; j <= n; j++) {
      nm = order[j]; f = ""; u = ""
      for (t = 1; t <= 8; t++) {
        s = v[nm, pref[t]]
        if (s == "FREE")    f = f (f == "" ? "" : " ") pref[t]
        if (s == "UNKNOWN") u = u (u == "" ? "" : " ") pref[t]
      }
      gh = ((nm, "gh") in v) ? v[nm, "gh"] : "-"
      x  = ((nm, "x")  in v) ? v[nm, "x"]  : "-"
      printf "%s\t%s\t%s\t%s\t%s\n", nm, (f == "" ? "-" : f), (u == "" ? "-" : u), gh, x
    }
  }' "${files[@]}"

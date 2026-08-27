#!/usr/bin/env bash
# check_domains.sh — registry-authoritative availability for the affix-domains TLD set.
#
#   ./check_domains.sh --tlds com,ai,co  teammate matebuddy getmate
#   printf 'a\nb\n' | ./check_domains.sh --tlds com --stdin
#
# Prints one TAB-separated line per lookup: <domain>\t<FREE|TAKEN|UNKNOWN>
# Exit 0 always; UNKNOWN means "could not determine" and must never be
# reported to the user as available.
set -uo pipefail

TLDS="com"
NAMES=()
READ_STDIN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tlds)  TLDS="$2"; shift 2 ;;
    --stdin) READ_STDIN=1; shift ;;
    -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
    *) NAMES+=("$1"); shift ;;
  esac
done
(( READ_STDIN )) && while IFS= read -r l; do [[ -n "$l" ]] && NAMES+=("$l"); done

[[ ${#NAMES[@]} -eq 0 ]] && { echo "no names given" >&2; exit 0; }

# --- verified 2026-08-27 against known-taken + known-free controls -----------
rdap_base() {
  case "$1" in
    com) echo "https://rdap.verisign.com/com/v1/domain/" ;;
    net) echo "https://rdap.verisign.com/net/v1/domain/" ;;
    cc)  echo "https://tld-rdap.verisign.com/cc/v1/domain/" ;;
    org) echo "https://rdap.publicinterestregistry.org/rdap/domain/" ;;
    ai|io) echo "https://rdap.identitydigital.services/rdap/domain/" ;;
    app) echo "https://pubapi.registry.google/rdap/domain/" ;;
    co)  echo "" ;;   # no RDAP service exists — WHOIS only
    *)   echo "" ;;
  esac
}
# Google's .app budget is a rolling quota, not a concurrency cap: go serial.
par_for() { case "$1" in app) echo 1 ;; co) echo 2 ;; ai|io) echo 6 ;; *) echo 8 ;; esac; }

check_rdap() {   # $1=domain $2=base
  local code
  for attempt in 1 2 3 4; do
    code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 15 "${2}${1}")
    case "$code" in
      404) printf '%s\tFREE\n'  "$1"; return ;;
      200) printf '%s\tTAKEN\n' "$1"; return ;;
      429|500|502|503|504|000) sleep $(( attempt * 2 )) ;;   # transient: back off
      *) break ;;
    esac
  done
  printf '%s\tUNKNOWN\n' "$1"
}

check_whois_co() {   # $1=domain  (.co has no RDAP; whois.registry.co is authoritative)
  local out
  for attempt in 1 2 3; do
    out=$(whois -h whois.registry.co "$1" 2>&1)
    if grep -qiE 'DOMAIN NOT FOUND|No Data Found|^NOT FOUND' <<<"$out"; then
      printf '%s\tFREE\n' "$1"; return
    elif grep -qiE '^[[:space:]]*Domain Name:' <<<"$out"; then
      printf '%s\tTAKEN\n' "$1"; return
    fi
    sleep $(( attempt * 2 ))
  done
  printf '%s\tUNKNOWN\n' "$1"
}

export -f check_rdap check_whois_co

IFS=',' read -ra TLD_ARR <<<"$TLDS"
for tld in "${TLD_ARR[@]}"; do
  base=$(rdap_base "$tld"); par=$(par_for "$tld")
  domains=(); for n in "${NAMES[@]}"; do domains+=("${n}.${tld}"); done
  if [[ "$tld" == "co" ]]; then
    printf '%s\n' "${domains[@]}" | xargs -P "$par" -I{} bash -c 'check_whois_co "$@"' _ {}
  elif [[ -n "$base" ]]; then
    printf '%s\n' "${domains[@]}" | xargs -P "$par" -I{} bash -c 'check_rdap "$@"' _ {} "$base"
  else
    for d in "${domains[@]}"; do printf '%s\tUNKNOWN\n' "$d"; done
  fi
done

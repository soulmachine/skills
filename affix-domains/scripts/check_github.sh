#!/usr/bin/env bash
# check_github.sh — is this name free as a GitHub org/user?
#
#   ./check_github.sh teammate matebuddy getmate
#   printf 'a\nb\n' | ./check_github.sh --stdin
#
# Prints one TAB-separated line per name: <name>\t<FREE|TAKEN|RESERVED|INVALID|UNKNOWN>
# Exit 0 always. Only FREE means registrable; everything else does not.
#
# Users and orgs share ONE namespace, so a name taken by either is unavailable.
#
# Verified 2026-09-16 against controls: github (org) 200, soulmachine (user) 200,
# agentsyncaroo (free) 404, settings/new (reserved) 302.
#
# Why the web endpoint and not api.github.com/users/<name>: the API returns 404
# for RESERVED names (settings, new, about, explore...), which would be reported
# as available. The web endpoint 302-redirects them instead, so it is the only
# one of the two that can tell "free" from "reserved". It also needs no token
# and is not bound by the API's 60/hr unauthenticated budget.
set -uo pipefail

NAMES=()
READ_STDIN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --stdin) READ_STDIN=1; shift ;;
    -h|--help) sed -n '2,7p' "$0"; exit 0 ;;
    *) NAMES+=("$1"); shift ;;
  esac
done
(( READ_STDIN )) && while IFS= read -r l; do [[ -n "$l" ]] && NAMES+=("$l"); done

[[ ${#NAMES[@]} -eq 0 ]] && { echo "no names given" >&2; exit 0; }

check_gh() {   # $1=name
  # GitHub account names: alphanumerics and single hyphens, no leading/trailing
  # hyphen, max 39 chars. An invalid name also 404s, so screen it first or it
  # gets reported FREE.
  if [[ ${#1} -gt 39 || ! "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9]|-[A-Za-z0-9])*$ ]]; then
    printf '%s\tINVALID\n' "$1"; return
  fi
  local code
  for attempt in 1 2 3 4; do
    code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 15 "https://github.com/$1")
    case "$code" in
      404)     printf '%s\tFREE\n'     "$1"; return ;;
      200)     printf '%s\tTAKEN\n'    "$1"; return ;;
      301|302) printf '%s\tRESERVED\n' "$1"; return ;;
      429|500|502|503|504|000) sleep $(( attempt * 2 )) ;;   # transient: back off
      *) break ;;
    esac
  done
  printf '%s\tUNKNOWN\n' "$1"
}
export -f check_gh

printf '%s\n' "${NAMES[@]}" | xargs -P 8 -I{} bash -c 'check_gh "$@"' _ {}

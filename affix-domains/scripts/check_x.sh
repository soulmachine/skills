#!/usr/bin/env bash
# check_x.sh — is this name free as an X (Twitter) handle?
#
#   ./check_x.sh teammate matebuddy getmate
#   printf 'a\nb\n' | ./check_x.sh --stdin
#
# Prints one TAB-separated line per name: <name>\t<FREE|TAKEN|RESERVED|INVALID|UNKNOWN>
# Exit 0 always. Only FREE means registrable; everything else does not.
#
# Two stages. Stage 1 asks twitter-cli (`twitter user <name>`) on the user's
# own logged-in Chrome session: a profile is TAKEN, and so is a hollow one
# (ok:true with an empty id — X's UserUnavailable shape for a suspended,
# deactivated or withheld account; the handle is held). Stage 2 sends the
# names stage 1 could not confirm taken — no profile, or any twitter-cli
# error — to X's sign-up availability check, unauthenticated. It is the only
# endpoint that separates FREE from RESERVED: X refuses route
# words (home, settings), anything containing twitter/admin, and a held set
# of ordinary-looking handles (matearoo, evermate) that show no profile page
# yet can never be claimed. A profile miss alone is therefore never FREE.
#
# twitter-cli missing: installed with `uv tool install twitter-cli`. Not
# logged in on this host (no Chrome session, keychain not granted, stale
# cookies): one stderr line, and stage 2 runs over every name instead. A
# second sweep inside fifteen minutes trips stage 1's session limit; those
# names fall through to stage 2 after twitter-cli's own 5/10/20 s retries,
# so that sweep runs slower, not emptier. Handles are case-insensitive:
# letters, digits, underscore; 5–15 chars, screened locally before any
# request. After the sweep every FREE is re-queried once, serially, and the
# re-check verdict is what prints: a FREE that does not repeat is not FREE.
#
# Verified 2026-09-18. Stage 1 controls: x taken (the preflight's own call, past
# the local screen), soulmachine hollow=taken, agentsyncaroo/matearoo not_found. Stage 2 controls: agentsyncaroo available,
# explore is_banned_word, twitteradmin contains_banned_word, get-mate
# improper_format, abc / abcdefghijklmnop invalid_username (the last three
# never leave the local screen).
#
# Stage 2 quota (measured): ~250 requests per IP, then HTTP 429 for minutes;
# fifteen quiet minutes clears it. For a few ordinary-looking names its
# answer flickers between available and is_banned_word across serial
# queries on a calm endpoint (mateora, quickmate); hence the FREE re-check.
# Stage 1's session limit is community-reported at ~95 per 15 minutes; a
# 429 there is retried by twitter-cli itself (5/10/20 s) before surfacing.
set -uo pipefail
export PATH="$HOME/.local/bin:$PATH"   # where `uv tool install` puts `twitter`

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

# --- stage 1: twitter-cli profile lookup --------------------------------------
check_profile() {   # $1=name → TAKEN | NOPROFILE | UNKNOWN; only TAKEN is decided here
  local out
  out=$(twitter -c user "$1" --json 2>/dev/null)
  if   [[ "$out" =~ \"ok\":[[:space:]]*true ]];           then echo TAKEN      # any profile, hollow included
  elif [[ "$out" =~ \"code\":[[:space:]]*\"not_found\" ]]; then echo NOPROFILE
  else echo UNKNOWN; fi                                                        # rate_limited, network_error, not_authenticated… → stage 2 decides
}

# --- stage 2: X's sign-up availability check ----------------------------------
check_signup() {   # $1=name → FREE | TAKEN | RESERVED | INVALID | UNKNOWN
  local body code reason
  for attempt in 1 2 3 4; do
    body=$(curl -s -w '\n%{http_code}' --max-time 15 \
      "https://api.x.com/i/users/username_available.json?username=$1")
    code="${body##*$'\n'}"
    case "$code" in
      200)
        reason="${body#*\"reason\":\"}"; reason="${reason%%\"*}"
        case "$reason" in
          available)                            echo FREE;     return ;;
          taken)                                echo TAKEN;    return ;;
          is_banned_word|contains_banned_word)  echo RESERVED; return ;;
          invalid_username|improper_format)     echo INVALID;  return ;;
          *) break ;;   # unknown reason or no JSON: never guess
        esac ;;
      429|500|502|503|504|000) sleep $(( attempt * 2 )) ;;   # transient: back off
      *) break ;;
    esac
  done
  echo UNKNOWN
}

check_x() {   # $1=name
  local n="${1#@}" v
  if [[ ! "$n" =~ ^[A-Za-z0-9_]{5,15}$ ]]; then printf '%s\tINVALID\n' "$1"; return; fi
  if (( STAGE1 )); then
    v=$(check_profile "$n")
    if [[ "$v" == TAKEN ]]; then printf '%s\tTAKEN\n' "$1"; return; fi   # anything else falls through
  fi
  printf '%s\t%s\n' "$1" "$(check_signup "$n")"
}
export -f check_profile check_signup check_x

# --- preflight ----------------------------------------------------------------
STAGE1=1
if ! command -v twitter >/dev/null 2>&1 && command -v uv >/dev/null 2>&1; then
  if uv tool install twitter-cli >/dev/null 2>&1; then
    echo "check_x: installed twitter-cli (uv tool install twitter-cli)" >&2
  fi
fi
if ! command -v twitter >/dev/null 2>&1; then
  echo "check_x: twitter-cli is not installed and could not be installed (needs uv); running X's sign-up check only" >&2
  STAGE1=0
elif ! twitter status 2>/dev/null | grep -q 'authenticated: true' || [[ "$(check_profile x)" != TAKEN ]]; then
  echo "check_x: twitter-cli is not logged in on this host (sign into x.com in Chrome here, or set TWITTER_AUTH_TOKEN and TWITTER_CT0); running X's sign-up check only" >&2
  STAGE1=0
fi
export STAGE1

# --- sweep, then re-check every FREE once, serially, nothing else in flight ---
out=$(printf '%s\n' "${NAMES[@]}" | xargs -P 2 -I{} bash -c 'check_x "$@"' _ {})
while IFS=$'\t' read -r name verdict; do
  [[ -z "$name" ]] && continue
  if [[ "$verdict" == FREE ]]; then
    printf '%s\t%s\n' "$name" "$(check_signup "${name#@}")"   # the re-check verdict prints, whatever it is
  else
    printf '%s\t%s\n' "$name" "$verdict"
  fi
done <<<"$out"

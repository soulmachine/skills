#!/bin/sh
# Self-test for ask-always-on-agent with a stubbed paseo and hostname; touches no daemon.
set -u
here=$(cd "$(dirname "$0")" && pwd)
stub=$(mktemp -d); export LOG=$stub/log STUB_SENT=$stub/sent
cat > "$stub/paseo" <<'STUB'
#!/bin/sh
echo "$*" >> "$LOG"
case $1 in
  ls) case " $* " in *" --host "*) printf '%s\n' "$STUB_REMOTE" ;; *) printf '%s\n' "$STUB_LOCAL" ;; esac ;;
  send) { for a; do [ -f "$a" ] && cat "$a"; done; echo "$*"; } > "$STUB_SENT" ;;
  wait) st=$(sed -n 1p "$STUB_WAITS" 2>/dev/null); tail -n +2 "$STUB_WAITS" > "$STUB_WAITS.t" 2>/dev/null && mv "$STUB_WAITS.t" "$STUB_WAITS"
        [ "$st" = broken ] && { echo "mise ERROR" >&2; exit 1; }; printf '{"status":"%s"}\n' "${st:-idle}" ;;
  logs) tag=$(grep -o '\[r[0-9a-f]*\]' "$STUB_SENT" | head -1); [ "${STUB_UNTAGGED:-}" = 1 ] && tag=
        printf '[User] noise\nolder reply\n%s pong\nsecond line\n[Thought] later\n' "$tag" ;;
esac
STUB
printf '#!/bin/sh\necho "$STUB_HOST"\n' > "$stub/hostname"
printf '#!/bin/sh\n' > "$stub/sleep"
chmod +x "$stub/paseo" "$stub/hostname" "$stub/sleep"
export PATH="$stub:$PATH" STUB_LOCAL= STUB_REMOTE= STUB_HOST=some-mac STUB_WAITS=$stub/waits
run() { : > "$LOG"; : > "$STUB_SENT"; out=$("$here/ask-always-on-agent" "$@" 2>&1); rc=$?; }
fail=0
check() { [ "$1" = "$2" ] || { echo "FAIL $3: got [$1]"; fail=1; }; }

STUB_LOCAL=aaa run coding-agent --no-wait hello
check "$(grep -c '^logs' "$LOG")" 0 "no logs call after --no-wait"
check "$(sed -n 2p "$LOG")" "send aaa --no-wait hello" "local id reaches send"
check "$(grep -c 'Begin your reply with \[r[0-9a-f]*\]' "$STUB_SENT")" 1 "prompt carries the reply tag"

STUB_LOCAL=aaa run coding-agent hello
check "$out" "pong
second line" "waited send prints the tagged reply to the end, minus User and Thought lines"

STUB_UNTAGGED=1 STUB_LOCAL=aaa run coding-agent hello
check "$out" "" "no tagged entry prints nothing"
STUB_UNTAGGED=  # a prefix on a function call persists in a POSIX shell

printf 'from file' > "$stub/p"; STUB_LOCAL=aaa run coding-agent --prompt-file "$stub/p"
check "$out" "pong
second line" "prompt file reply"
check "$(head -1 "$STUB_SENT")" "from file" "prompt file content is sent"
check "$(cat "$stub/p")" "from file" "caller's prompt file is untouched"

printf 'permission\npermission\n' > "$STUB_WAITS"; STUB_LOCAL=aaa run coding-agent hello
check "$(grep -c '^wait' "$LOG")" 3 "keeps waiting while a question is pending"
check "$(printf '%s' "$out" | head -1)" "pong" "prints the reply after the question is answered"

printf 'broken\npermission\n' > "$STUB_WAITS"; STUB_LOCAL=aaa run coding-agent hello
check "$(grep -c '^wait' "$LOG")" 3 "a failed wait is retried"
check "$(printf '%s' "$out" | head -1)" "pong" "prints the reply after a failed wait"

STUB_LOCAL= STUB_REMOTE=bbb run coding-agent hello
check "$(printf '%s' "$out" | head -2)" "ask-always-on-agent: coding-agent not found locally, using ssh://mac-mini-m6
pong" "fallback host reaches send and logs"
check "$(sed -n 3p "$LOG")" "send --host ssh://mac-mini-m6 bbb hello" "fallback host reaches send"

STUB_LOCAL= STUB_REMOTE=bbb STUB_HOST=mac-mini-m6 run coding-agent hello
check "$rc" 1 "no fallback on the home host"
check "$(grep -c ls "$LOG")" 1 "one lookup on the home host"

STUB_LOCAL="a
b" run coding-agent hello
check "$rc" 1 "two ids fail"

STUB_LOCAL=zzz STUB_REMOTE= run --host ssh://other coding-agent hello
check "$rc" 1 "explicit --host with no match fails"
check "$(grep -c ls "$LOG")" 1 "explicit --host never falls back"

rm -rf "$stub"
[ $fail = 0 ] && echo "selftest: all pass"
exit $fail

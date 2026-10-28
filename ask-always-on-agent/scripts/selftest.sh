#!/bin/sh
# Self-test for ask-always-on-agent with a stubbed paseo and hostname; touches no daemon.
set -u
here=$(cd "$(dirname "$0")" && pwd)
stub=$(mktemp -d); export LOG=$stub/log
cat > "$stub/paseo" <<'STUB'
#!/bin/sh
echo "$*" >> "$LOG"
case $1 in
  ls) case " $* " in *" --host "*) printf '%s\n' "$STUB_REMOTE" ;; *) printf '%s\n' "$STUB_LOCAL" ;; esac ;;
  send) : ;;
  logs) shift; echo "logs:$*" ;;
esac
STUB
printf '#!/bin/sh\necho "$STUB_HOST"\n' > "$stub/hostname"
chmod +x "$stub/paseo" "$stub/hostname"
export PATH="$stub:$PATH" STUB_LOCAL= STUB_REMOTE= STUB_HOST=some-mac
run() { : > "$LOG"; out=$("$here/ask-always-on-agent" "$@" 2>&1); rc=$?; }
fail=0
check() { [ "$1" = "$2" ] || { echo "FAIL $3: got [$1]"; fail=1; }; }

STUB_LOCAL=aaa run coding-agent --no-wait hello
check "$(grep -c . "$LOG")" 2 "no logs call after --no-wait"
check "$(tail -1 "$LOG")" "send aaa --no-wait hello" "local id reaches send"

STUB_LOCAL=aaa run coding-agent hello
check "$out" "logs:aaa --tail 1 --filter text" "waited send prints the reply"

STUB_LOCAL= STUB_REMOTE=bbb run coding-agent hello
check "$out" "ask-always-on-agent: coding-agent not found locally, using ssh://mac-mini-m6
logs:--host ssh://mac-mini-m6 bbb --tail 1 --filter text" "fallback host reaches send and logs"
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

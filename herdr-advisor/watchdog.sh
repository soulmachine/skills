#!/bin/sh
# Keep a Herdr advisor's loop alive from outside its harness.
#
# ADVISOR.md makes the advisor's whole life one turn. Models end turns early
# anyway, and of the sixteen harnesses the skill launches, three cannot gate a
# turn end at all and the rest each do it differently, so this runs beside the
# advisor instead: planted in its pane before `herdr agent start`, it watches
# the pane through herdr and re-prompts every turn that ends while the pane
# still holds an `*-advisor` name. The advisor ends by clearing that name
# (`herdr agent rename "$HERDR_PANE_ID" --clear`), and so can the user.
#
# Usage: sh watchdog.sh <pane-id>    (from the advisor pane's own shell, backgrounded)

PANE=$1
LOG=$HOME/Library/Logs/herdr-advisor.log
SKILL='~/.agents/skills/herdr-advisor/ADVISOR.md'
MAX_BLOCKS=8; WINDOW_S=3600; GRACE_S=10; START_S=300
REASON="Re-read $SKILL first, then resume. Your loop has not met its end condition, so this turn may not end: start the next pass from \`herdr agent get\` and continue."

# name status turn, or "- gone -1" once the pane or agent is gone.
state() {
    herdr agent get "$PANE" 2>/dev/null | python3 -c '
import json, sys
t = sys.stdin.read()
try:
    a = json.loads(t[t.index("{"):])["result"]["agent"]
    print(a.get("name") or "-", a.get("agent_status") or "-", a.get("turn") if a.get("turn") is not None else -1)
except Exception:
    print("- gone -1")'
}

advisor() {  # exit once the pane no longer holds an advisor's name: the end signal
    case "$1" in *-advisor) ;; *) log allowed-end; exit 0 ;; esac
}

log() {  # log ACTION [blocks]
    printf '{"ts":"%s","unix":%s,"pane":"%s","action":"%s","blocks":%s}\n' \
        "$(date +%Y-%m-%dT%H:%M:%S%z)" "$(date +%s)" "$PANE" "$1" "${2:-0}" >> "$LOG" 2>/dev/null
}

# Blocks this pane has taken inside the window since it last did anything else.
consecutive_blocks() {
    tail -n 400 "$LOG" 2>/dev/null | python3 -c '
import json, sys, time
pane, cutoff, n = sys.argv[1], time.time() - float(sys.argv[2]), 0
for line in reversed(sys.stdin.readlines()):
    try: r = json.loads(line)
    except Exception: continue
    if r.get("pane") != pane: continue
    if r.get("action") != "blocked" or float(r.get("unix", 0)) < cutoff: break
    n += 1
print(n)' "$PANE" "$WINDOW_S"
}

mkdir -p "$(dirname "$LOG")" 2>/dev/null

# Planted before `agent start`, so the pane holds no agent yet and every herdr
# call errors at once; give the advisor START_S seconds to register.
i=0
while :; do
    set -- $(state)
    case "$1" in *-advisor) break ;; esac
    [ "$((i += 1))" -gt "$START_S" ] && { log no-advisor; exit 0; }
    sleep 1
done

last=0   # turn counts completed turns; 0 until the handoff's turn ends
while :; do
    herdr agent wait "$PANE" --until working --until blocked --timeout 60000 >/dev/null 2>&1
    herdr agent wait "$PANE" --timeout 60000 >/dev/null 2>&1
    set -- $(state); advisor "$1"; name=$1; status=$2; turn=$3
    [ "$status" = blocked ] && { sleep 5; continue; }   # a dialog is the user's; wait it out
    [ "$turn" -le "$last" ] && continue                  # nothing new since the last pass
    sleep "$GRACE_S"                                     # a user may be typing, or stopping it, after an Esc
    set -- $(state); advisor "$1"; [ "$3" = "$turn" ] && [ "$2" != working ] || continue
    last=$turn
    n=$(consecutive_blocks)
    if [ "$n" -ge "$MAX_BLOCKS" ]; then
        log allowed-cap "$n"
        herdr notification show "Herdr advisor released" --body "$name ended early ${n}x in an hour; its worker is now unwatched." >/dev/null 2>&1
        exit 0
    fi
    log blocked "$((n + 1))"
    herdr agent prompt "$PANE" "$REASON" >/dev/null 2>&1
done

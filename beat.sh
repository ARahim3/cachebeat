#!/bin/sh
# cachebeat watcher. Runs as a Claude Code background shell task: it stays silent while the
# session is active, and EXITS when there is something to say — the exit is what wakes Claude.
#
# usage: sh beat.sh <idle_minutes> <max_hours>
# exit:  0  beat — session sat idle <idle_minutes>; the wake-up refreshed the cache -> re-arm
#        3  auto-stop deadline reached
#        4  the last beat came back uncached (cache TTL shorter than the threshold) -> stop
#        5  cannot store the deadline
#
# A re-arm is the EXACT same command as the fresh arm, on purpose: Claude Code's "don't ask
# again" approval matches the literal command string, and re-arms happen while the user is
# away. The script tells the two apart itself — a beat leaves a marker in the state file, and
# a start that finds a recent marker is a re-arm.
N=${1:-50}; H=${2:-8}
SID="$CLAUDE_CODE_SESSION_ID"
STATE="${TMPDIR:-/tmp}/cachebeat-${SID:-nosid}.end"
REARM_WINDOW=900   # a start within 15 min of a beat is that beat's re-arm

# Pin THIS session's transcript by its id (not "newest file", which another session in the
# same folder could hijack). Fall back to newest — correct at arm time, Claude is mid-turn.
F=$(ls "$HOME/.claude/projects"/*/"$SID".jsonl 2>/dev/null | head -1)
[ -z "$F" ] && F=$(ls -t "$HOME/.claude/projects/$(pwd | tr '/._' '---')"/*.jsonl 2>/dev/null | head -1)

# State file: line 1 = auto-stop deadline (absolute epoch), line 2 = time of the last beat, if
# one is awaiting its re-arm. The deadline is fixed on the fresh arm, so a re-arm can never
# extend it (and Claude never has to carry it).
MODE=fresh; END=
if [ -r "$STATE" ]; then
  { read -r END; read -r BEAT; } < "$STATE"
  case "$END$BEAT" in ''|*[!0-9]*) BEAT= ;; esac
  [ -n "$BEAT" ] && [ $(( $(date +%s) - BEAT )) -lt "$REARM_WINDOW" ] && MODE=rearm
fi
[ "$MODE" = fresh ] && END=$(( $(date +%s) + H*3600 ))
{ echo "$END" > "$STATE"; } 2>/dev/null || { echo "CACHEBEAT_NOSTATE cannot write $STATE"; exit 5; }

# Self-check (re-arms only): right now the newest usage record is the request that woke Claude
# after the idle gap. If that one came back mostly uncached, the beat arrived after the cache
# had already died — no threshold this long can help.
if [ "$MODE" = rearm ]; then
  CR=$(tail -n 400 "$F" 2>/dev/null | grep -oE '"cache_read_input_tokens":[0-9]+' | tail -1 | grep -oE '[0-9]+')
  CC=$(tail -n 400 "$F" 2>/dev/null | grep -oE '"cache_creation_input_tokens":[0-9]+' | tail -1 | grep -oE '[0-9]+')
  if [ -n "$CC" ] && [ -n "$CR" ] && [ "$CC" -gt "$CR" ]; then
    echo "CACHEBEAT_WARN beat re-read uncached: cache_creation=$CC > cache_read=$CR"
    rm -f "$STATE"; exit 4
  fi
fi

PREV=__init__; LAST=$(date +%s)
while [ "$(date +%s)" -lt "$END" ]; do
  sleep 30
  # Activity signal = timestamp of the last transcript line. It changes only on a real turn —
  # a bare file-mtime bump (recap rewrite, atomic save) does NOT fool it. No timestamp parsing.
  SIG=$(tail -n 1 "$F" 2>/dev/null | grep -oE '"timestamp":"[^"]+"' | tail -1)
  [ -z "$SIG" ] && SIG=$(wc -c < "$F" 2>/dev/null)
  if [ "$SIG" != "$PREV" ]; then PREV="$SIG"; LAST=$(date +%s); fi   # new turn -> reset clock
  IDLE=$(( $(date +%s) - LAST ))
  if [ "$IDLE" -ge $(( N*60 )) ]; then
    echo "CACHEBEAT_BEAT idle=${IDLE}s $(date +%T)"
    printf '%s\n%s\n' "$END" "$(date +%s)" > "$STATE"   # marker: the next start is a re-arm
    exit 0
  fi
done
echo CACHEBEAT_EXPIRED
rm -f "$STATE"; exit 3

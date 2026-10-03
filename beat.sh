#!/bin/sh
# cachebeat watcher: an inactivity timer that Claude Code runs as this skill's Stop hook (SKILL.md
# frontmatter, `asyncRewake: true`) — in the background, at the end of every turn, hook JSON on stdin.
# It stays silent while the session is active. Once the session has sat idle for the threshold it
# writes one line to stderr and exits 2: Claude Code wakes Claude with that line, and the wake-up
# request re-reads the conversation from the prompt cache, which restarts the cache TTL. Claude's
# one-character reply ends a turn, the Stop hook starts the next timer, and so on — Claude never
# re-arms anything, and nothing asks for permission. The newest timer wins; older ones exit.
#
# exit 0  nothing to say: not armed, stopped, superseded, or the cache is already cold
# exit 2  wake Claude: a heartbeat, or a one-line notice for the user (stopped itself / deadline)
#
# The arguments come from the newest /cachebeat in the transcript (typed, or Claude's Skill call):
# [minutes] [hours], or "stop". State: $TMPDIR/cachebeat-<session> holds "<arm id> <N> <end>" plus,
# after a beat, "<newest reply then> <beat time>"; or "<arm id> stop". <session>.pid = newest timer.
# The hook's `timeout: 90000` in SKILL.md is load-bearing: Claude Code kills an asyncRewake hook at its
# timeout, 10 min by default, which would end every timer before a 50-minute beat.
# Test knobs: CACHEBEAT_UNIT (seconds per "minute", default 60), CACHEBEAT_TICK (poll seconds,
# default 30), CACHEBEAT_LOG (debug log file).

# Started the pre-hook way — `sh beat.sh <minutes> <hours>` as a background command, by a session that
# loaded the old SKILL.md. Its instructions re-arm on exit 0, so answering 0 would loop; exit 5 means
# "tell the user, do not re-arm" there.
if [ $# -gt 0 ]; then echo "cachebeat was updated: run /cachebeat again to re-arm it."; exit 5; fi

# On exit 2 Claude sees everything the hook wrote to stderr, so only the note may go there (fd 3).
exec 3>&2 2>/dev/null
IN=$(cat)
field() { printf '%s' "$IN" | grep -oE "\"$1\" *: *\"[^\"]*\"" | head -1 | sed 's/.*"\([^"]*\)"$/\1/'; }
SID=$(field session_id); F=$(field transcript_path)
[ -n "$SID" ] || exit 0
U=${CACHEBEAT_UNIT:-60}; TICK=${CACHEBEAT_TICK:-30}; TTL=$((60*U))   # the 1-hour cache TTL
S="${TMPDIR:-/tmp}/cachebeat-$SID"
log() { [ -n "$CACHEBEAT_LOG" ] && echo "$(date +%T) [$$] $*" >> "$CACHEBEAT_LOG"; }

# SessionEnd (/clear, /resume, exit): a wake-up goes to the Claude Code process, not to a session, so a
# timer left running would beat into the next conversation. Disarm; the timer exits on its next tick.
if [ "$(field hook_event_name)" = SessionEnd ]; then rm -f "$S" "$S.pid"; log "session end"; exit 0; fi
[ -r "$F" ] || exit 0

# --- the newest /cachebeat: a typed command, or Claude's Skill tool call ------------------------------
# Structural JSON only (bare quotes): text that merely quotes these lines is escaped (\") in the file.
NAME=$(sed -n 's/^name: *//p' "$(dirname "$0")/SKILL.md" | tr -d '\r ' | head -1)
NAME=${NAME:-cachebeat}; P="[A-Za-z0-9_./-]+:"
INV=$(grep -E "\"role\":\"user\",\"content\":\"<command-message>[^<]*</command-message>\\\\n<command-name>/?($P)?$NAME</command-name>|\"name\":\"Skill\",\"input\":\\{\"skill\":\"($P)?$NAME\"" "$F" | tail -1)
int() { printf '%s' "$1" | tr -cd 0-9 | cut -c1-4 | sed 's/^0*//'; }   # digits only, never octal
if [ -n "$INV" ]; then
  ID=$(printf '%s' "$INV" | grep -oE '"uuid":"[^"]+","timestamp":"[^"]+"' | tail -1 | cut -d'"' -f4)
  { read -r CUR _; } < "$S"
  if [ -n "$ID" ] && [ "$ID" != "$CUR" ]; then          # a /cachebeat not acted on yet
    ARGS=$(printf '%s' "$INV" | grep -oE '<command-args>[^<]*</command-args>|"args":"[^"]*"' | tail -1 \
           | sed -e 's/<[^>]*>//g' -e 's/^"args":"//' -e 's/"$//')
    N=; H=; STOP=
    for t in $ARGS; do
      case "$t" in
        [Ss][Tt][Oo][Pp]|[Oo][Ff][Ff]) STOP=1 ;;
        *[0-9][hH]*) H=$(int "$t") ;;
        *[0-9]*) if [ -z "$N" ]; then N=$(int "$t"); elif [ -z "$H" ]; then H=$(int "$t"); fi ;;
      esac
    done
    if [ -n "$STOP" ]; then
      echo "$ID stop" > "$S"; log "stop"
    else
      N=${N:-50}; H=${H:-8}   # clamp: past ~55 min the 1-hour TTL can lapse before a beat lands
      [ "$N" -lt 5 ] && N=5; [ "$N" -gt 55 ] && N=55; [ "$H" -lt 1 ] && H=1; [ "$H" -gt 24 ] && H=24
      echo "$ID $N $(( $(date +%s) + H*60*U ))" > "$S" || exit 0; log "arm N=$N H=$H"
    fi
  fi
fi
{ read -r ID N END CHECK BEAT_AT; } < "$S"
case "$N$END" in ''|*[!0-9]*) exit 0 ;; esac            # not armed, or stopped
echo $$ > "$S.pid"                                      # the newest timer wins

# The last real model response: a main-chain assistant entry that Claude Code didn't synthesize itself
# (usage-limit and API-error notices). Only a request refreshes the cache — bookkeeping lines
# (queue-operation, mode, away_summary …) are written without one, so they must not reset the clock.
recent() { tail -n 400 "$F" | grep '"isSidechain":false' | grep -v '"model":"<synthetic>"'; }
last_resp() { recent | grep -E '"type":"assistant","uuid":"' | tail -1; }
sig() { printf '%s' "$1" | grep -oE '"type":"assistant","uuid":"[^"]+"' | tail -1 | cut -d'"' -f8; }
num() { printf '%s' "$1" | grep -oE "\"$2\":[0-9]+" | head -1 | grep -oE '[0-9]+$'; }

sleep 2   # the hook can start a moment before Claude Code has written the turn's last entries
PREV=$(sig "$(last_resp)"); LAST=$(date +%s)
while :; do
  sleep "$TICK"
  [ "$(cat "$S.pid")" = $$ ] || { log "superseded"; exit 0; }
  kill -0 "$PPID" || { log "Claude Code is gone"; exit 0; }
  { read -r ID2 N END _; } < "$S"
  [ "$ID2" = "$ID" ] || { log "re-armed or stopped"; exit 0; }
  case "$N$END" in ''|*[!0-9]*) log "stopped"; exit 0 ;; esac
  NOW=$(date +%s)
  if [ "$NOW" -ge "$END" ]; then
    echo "$ID stop" > "$S"; log "deadline"
    echo "cachebeat reached its auto-stop time and is now off. Tell the user that in one short line; nothing else." >&3
    exit 2
  fi
  L=$(last_resp); SIG=$(sig "$L")
  if [ -n "$SIG" ] && [ "$SIG" != "$PREV" ]; then PREV=$SIG; LAST=$NOW; fi  # a new request: reset

  # After a beat (CHECK = the newest reply when it fired): once the next reply has landed, did it read
  # the conversation from cache? If not, this session's cache expires too soon for a heartbeat to help.
  if [ -n "$CHECK" ] && [ -n "$SIG" ] && [ "$SIG" != "$CHECK" ]; then
    CHECK=; echo "$ID $N $END" > "$S"
    [ $((NOW - ${BEAT_AT:-0})) -le $((10*U)) ] || L=   # that reply came much later: proves nothing
    CR=$(num "$L" cache_read_input_tokens); CC=$(num "$L" cache_creation_input_tokens)
    W5=$(num "$L" ephemeral_5m_input_tokens); W1=$(num "$L" ephemeral_1h_input_tokens)
    log "after beat: cache_read=$CR cache_creation=$CC (5m=$W5 1h=$W1)"
    # (A compaction rebuilds the cache whatever the TTL, so it proves nothing either.)
    if [ -n "$L" ] && ! tail -n 400 "$F" | grep -q '"subtype":"compact_boundary"' &&
       { [ "${W5:-0}" -gt 0 ] && [ "${W1:-0}" -eq 0 ] || [ "${CC:-0}" -gt "${CR:-0}" ]; }; then
      echo "$ID stop" > "$S"
      echo "cachebeat stopped itself: its heartbeat came back uncached (cache_read=$CR, cache_creation=$CC), so this session's prompt cache expires too soon for a heartbeat to help. Tell the user that in one short line; nothing else." >&3
      exit 2
    fi
  fi

  # A tool still running (its tool_use is the newest main-chain entry; this includes one waiting on a
  # permission prompt): the session is busy, and a wake-up couldn't land before it returns anyway.
  recent | grep -E '"type":"assistant","uuid":"|"role":"user","content":\[\{"tool_use_id":"' | tail -1 \
    | grep -q '"content":\[{"type":"tool_use"' && LAST=$NOW
  IDLE=$((NOW - LAST))
  if [ "$IDLE" -ge $((TTL - U)) ]; then    # e.g. the machine slept through the TTL: a beat now would
    log "idle ${IDLE}s, cache already cold: standing down"; exit 0   # only pay to rebuild it
  fi
  if [ "$IDLE" -ge $((N*U)) ]; then
    echo "$ID $N $END ${SIG:-none} $NOW" > "$S"; log "beat idle=${IDLE}s"   # marker for the next run
    echo "idle heartbeat to keep the prompt cache warm. Reply with exactly . and nothing else; no tools." >&3
    exit 2
  fi
done

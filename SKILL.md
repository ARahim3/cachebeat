---
name: cachebeat
description: Keep the Anthropic prompt cache warm by firing a tiny heartbeat only after N minutes of true session inactivity (any exchange resets the clock), so the next real turn reads the conversation at cached price / cached quota instead of a full uncached re-read. Use when the session may sit idle (training runs, CI, downloads, the user stepping away) longer than the cache TTL. Args - idle threshold in minutes (default 50), optional max hours (default 8), or "stop".
---

# cachebeat — prompt-cache keepalive heartbeat

## What you do when invoked

Parse the arguments: `/cachebeat [minutes] [max_hours]` or `/cachebeat stop`.

- `minutes`: heartbeat interval. Default **50**. Clamp to **5–55** — above ~55 the 1-hour
  cache TTL expires between beats and the heartbeat is pointless.
- `max_hours`: auto-stop deadline. Default **8**. Clamp to 1–24. This is the abandoned-session
  guard: every beat costs a small cached-price request, so a forgotten heartbeat must kill itself.
- `stop`: stop the running cachebeat monitor with TaskStop. Its description is
  `cachebeat keepalive`; if its task ID is no longer in your context, list running background
  tasks (TaskList or equivalent) to find it. Confirm in one short line. Do nothing else.

## Arming (single Monitor, never Bash-sleep loops you must re-arm by hand)

The heartbeat is an **inactivity timer, not a metronome**: it fires only when the session has been
quiet for N minutes. Any real turn — a user message, one of your replies, a background event you
answered — resets the clock, because it already refreshed the cache.

Idle is measured from the **timestamp of the last entry in this session's transcript**, not from
the transcript file's mtime. This distinction is the whole point: a `.jsonl` file's mtime advances
on background rewrites (recap regeneration, atomic saves) that add no turn, so keying off mtime can
hide real idle minutes and make the beat fire *late* — after the TTL — so the beat itself becomes
the full-price uncached re-read it was meant to prevent. The monitor also pins **this** session's
transcript via `$CLAUDE_CODE_SESSION_ID` instead of "newest file in the folder", so other sessions
sharing the project folder can't hijack the clock.

Start ONE persistent Monitor exactly like this (substitute N = minutes, H = max_hours):

```
Monitor(
  command: "SID=\"$CLAUDE_CODE_SESSION_ID\"; F=$(ls \"$HOME/.claude/projects\"/*/\"$SID\".jsonl 2>/dev/null | head -1); [ -z \"$F\" ] && { DIR=\"$HOME/.claude/projects/$(pwd | tr '/._' '---')\"; F=$(ls -t \"$DIR\"/*.jsonl 2>/dev/null | head -1); }; END=$(( $(date +%s) + H*3600 )); PREV=__init__; LAST=$(date +%s); while [ $(date +%s) -lt $END ]; do sleep 60; SIG=$(tail -n 1 \"$F\" 2>/dev/null | grep -oE '\"timestamp\":\"[^\"]+\"' | tail -1); [ -z \"$SIG\" ] && SIG=$(wc -c < \"$F\" 2>/dev/null); if [ \"$SIG\" != \"$PREV\" ]; then PREV=\"$SIG\"; LAST=$(date +%s); fi; IDLE=$(( $(date +%s) - LAST )); if [ $IDLE -ge $((N*60)) ]; then echo \"HEARTBEAT idle=${IDLE}s $(date +%T)\"; sleep 300; CR=$(tail -n 400 \"$F\" 2>/dev/null | grep -oE '\"cache_read_input_tokens\":[0-9]+' | tail -1 | grep -oE '[0-9]+'); CC=$(tail -n 400 \"$F\" 2>/dev/null | grep -oE '\"cache_creation_input_tokens\":[0-9]+' | tail -1 | grep -oE '[0-9]+'); [ -n \"$CC\" ] && [ -n \"$CR\" ] && [ \"$CC\" -gt \"$CR\" ] && echo \"CACHEBEAT_WARN beat re-read uncached: cache_creation=$CC > cache_read=$CR\"; fi; done; echo CACHEBEAT_EXPIRED",
  description: "cachebeat keepalive",
  persistent: true
)
```

How it works, piece by piece:
- **Which file:** `$CLAUDE_CODE_SESSION_ID` names this exact conversation, so `.../projects/*/<id>.jsonl`
  is its transcript no matter how many other sessions share the project folder. If that variable is
  ever empty, it falls back to the newest transcript in the folder — correct at arm time because you
  are mid-turn writing this very exchange.
- **The idle signal** is the last line's `timestamp` string, compared for change against the monitor's
  own wall clock (`date +%s`). A genuine new turn changes it and resets the clock; a bare mtime bump
  with no new line does not. No timestamp parsing, so it stays portable across macOS/Linux/WSL.
- **`sleep 300`** after a beat gives your reply time to land so one idle period never double-fires.
- **Self-check:** after the reply lands it compares the beat's `cache_creation` vs `cache_read`; if the
  beat came back mostly uncached it emits `CACHEBEAT_WARN` — the signal that the session's TTL is too
  short for any heartbeat to help.

Then confirm to the user in ONE line: interval, auto-stop time, and how to stop
(`/cachebeat stop`). Nothing more.

## On each heartbeat event

Reply with a few words only (e.g. "Okay, still here."). Do NOT summarize, do NOT run tools,
do NOT re-arm anything — the monitor repeats by itself. If a real task of yours is also running,
you may append its one-line status, nothing more. Minimal output is the entire point: every extra
token you emit is added to the context that each future beat re-reads.

On `CACHEBEAT_WARN …`: the last beat fired on schedule but still re-read the context uncached, so
the keepalive is not paying off. In one line, tell the user their session likely has the short
(5-minute) cache TTL — or the interval is longer than their TTL — so no practical heartbeat helps,
and offer to stop it. Do not re-arm.

On `CACHEBEAT_EXPIRED`: tell the user the heartbeat reached its auto-stop deadline and is off,
one line. Re-arm only if they ask.

## Rules

- Never run more than one cachebeat monitor; if asked to arm while one runs, stop the old one first.
- If the user reports beats arriving but bills still showing uncached input, tell them their
  session likely has the short (5-minute) cache TTL, where no practical heartbeat interval helps —
  stop the monitor rather than waste money.
- This skill changes nothing about the work itself; it only pays ~10% cached-read price per beat
  to avoid paying 100% uncached price once. If the user does not plan to return to the session,
  advise stopping it.

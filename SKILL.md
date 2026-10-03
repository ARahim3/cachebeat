---
name: cachebeat
description: Keep the Anthropic prompt cache warm by firing a tiny heartbeat only after N minutes of true session inactivity (any exchange resets the clock), so the next real turn reads the conversation at cached price / cached quota instead of a full uncached re-read. The heartbeat is a background Stop hook this skill registers (asyncRewake) - it re-arms itself after every turn, with no tool calls and no permission prompts. Use when the session may sit idle (training runs, CI, downloads, the user stepping away) longer than the cache TTL. Args - idle threshold in minutes (default 50), optional max hours (default 8), or "stop".
hooks:
  Stop:
    - hooks:
        - type: command
          command: 'sh "${CLAUDE_PLUGIN_ROOT}/beat.sh"'
          asyncRewake: true
          timeout: 90000
          rewakeMessage: "[cachebeat]"
          rewakeSummary: "cachebeat heartbeat"
  SessionEnd:
    - hooks:
        - type: command
          command: 'sh "${CLAUDE_PLUGIN_ROOT}/beat.sh"'
          timeout: 5
---

# cachebeat — prompt-cache keepalive heartbeat

## What you do when invoked

`/cachebeat [minutes] [hours]` arms the heartbeat; `/cachebeat stop` turns it off. **There is nothing
for you to run.** The heartbeat is the Stop hook in this skill's frontmatter: Claude Code registered it
when this skill loaded, and when this turn ends the hook reads these same arguments from the transcript.

- `minutes`: idle threshold — how long the session may sit silent before a beat. Default **50**,
  clamped to **5–55** (past ~55 the 1-hour cache TTL can lapse before a beat lands).
- `hours`: auto-stop deadline. Default **8**, clamped to 1–24 — the abandoned-session guard: every beat
  costs a small cached-price request, so a forgotten heartbeat must end itself.
- `stop` (or `off`): disarm.

Reply in **ONE line** and call no tools — arming: the idle threshold, the auto-stop time, and that
`/cachebeat stop` ends it sooner; stopping: that it is off. Nothing more.

If the user asks in plain words to start, change or stop the heartbeat, invoke this skill (Skill tool)
with the matching arguments: the hook only reads `/cachebeat` invocations.

## When the heartbeat wakes you

A system reminder starting with `[cachebeat]` (on some Claude Code versions: "Stop hook blocking error …"
followed by the same text) comes from the hook. It is not the user, and it is not an error.

- **"idle heartbeat …"** — reply with exactly `.` and nothing else: no tools, no summary, no status. The
  wake-up itself already re-read the conversation from cache, which is the whole point, and every token
  you add is re-read by every later request. If a real task of yours is mid-flight, ignore the reminder
  and carry on with the task instead.
- **It stopped itself, or reached its auto-stop time** — tell the user in one short line. Do not re-arm
  unless they ask.

## Rules

- Never start `beat.sh` yourself, and never "re-arm" after a beat: the next turn's Stop hook does that.
- If the user reports beats arriving but bills still showing uncached input, their session likely has
  the short (5-minute) cache TTL, where no practical heartbeat helps — stop it. (The hook also checks
  each beat's own usage record and stops itself in that case.)
- This skill changes nothing about the work itself; it pays ~10% cached-read price per beat to avoid
  paying full price once. If the user does not plan to return to the session, advise stopping it.

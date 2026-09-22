---
name: cachebeat
description: Keep the Anthropic prompt cache warm by firing a tiny heartbeat only after N minutes of true session inactivity (any exchange resets the clock), so the next real turn reads the conversation at cached price / cached quota instead of a full uncached re-read. Runs the bundled beat.sh as a silent background shell task that exits when the session has been idle N minutes; you re-arm it on each beat. Use when the session may sit idle (training runs, CI, downloads, the user stepping away) longer than the cache TTL. Args - idle threshold in minutes (default 50), optional max hours (default 8), or "stop".
---

# cachebeat — prompt-cache keepalive heartbeat

## What you do when invoked

Parse the arguments: `/cachebeat [minutes] [max_hours]` or `/cachebeat stop`.

- `minutes`: idle threshold — how long the session may sit silent before a beat. Default **50**.
  Clamp to **5–55** — above ~55 the 1-hour cache TTL expires between beats and the heartbeat is
  pointless.
- `max_hours`: auto-stop deadline. Default **8**. Clamp to 1–24. This is the abandoned-session
  guard: every beat costs a small cached-price request, so a forgotten heartbeat must kill itself.
- `stop`: stop the running cachebeat task with TaskStop. Its description is
  `cachebeat keepalive`; if its task ID is no longer in your context, list running background
  tasks (TaskList or equivalent) to find it. Confirm in one short line. Do nothing else.

## Arming (background Bash running beat.sh, NOT Monitor)

The heartbeat is an **inactivity timer, not a metronome**: it fires only when the session has been
quiet for N minutes. Any real turn — a user message, one of your replies, a background event you
answered — resets the clock, because it already refreshed the cache.

**Why a background Bash task and not Monitor:** Claude Code kills every Monitor after at most 30
minutes, and each expiry wakes you — so a Monitor can never stay silent for 50. A Bash command
started with `run_in_background: true` has no such cap: it runs silently for as long as it likes
and wakes you **once, when it exits**. So the watcher exits on the beat, and you re-arm it. That
wake-up turn re-reads the conversation at cached price, which **restarts the cache TTL** — the beat
*is* the turn; nothing else is needed.

The watcher is `beat.sh`, which sits next to this file. `<DIR>` below is this skill's base directory
(shown to you when the skill loads). Start ONE background task exactly like this, substituting
`<N>` (= minutes) and `<H>` (= max_hours):

```
Bash(
  command: "sh <DIR>/beat.sh <N> <H>",
  description: "cachebeat keepalive",
  run_in_background: true
)
```

What `beat.sh` does (read it if you need details — do not inline or rewrite it):
- Pins **this** session's transcript via `$CLAUDE_CODE_SESSION_ID`, so other sessions sharing the
  project folder can't hijack the clock.
- Every 30 s it compares the **timestamp of the last transcript entry** for change — not the file's
  mtime, which advances on background rewrites that add no turn and would make the beat fire late,
  after the TTL.
- Fixes the auto-stop deadline once, on the fresh arm, and keeps it in a small state file — so a
  re-arm can never extend it, and you never have to carry it.
- Tells a re-arm from a fresh arm **by itself**: a beat leaves a marker in the state file, and a
  start that finds a recent marker (< 15 min) is that beat's re-arm. So the re-arm command is the
  exact same string as the fresh arm — which matters, because the user's "don't ask again"
  approval matches the literal command, and re-arms happen while they are away.
- Prints nothing while it waits. Its **exit code** is the message.

Then confirm to the user in ONE line: idle threshold, auto-stop time, and how to stop
(`/cachebeat stop`). Nothing more.

## When the cachebeat task exits

You are woken by a task notification for `cachebeat keepalive`. **The exit code in the notification
tells you everything — do NOT read the output file.**

- **exit 0 — beat.** The session sat idle N minutes and this very turn just refreshed the cache.
  **Silently re-arm as your first and only tool call:** repeat the arming Bash call **character
  for character** — same `sh <DIR>/beat.sh <N> <H>` command string (same path spelling, same
  numbers, nothing appended), same description, same `run_in_background: true`. Any difference in
  the command string can trigger a permission prompt nobody is there to answer. Then end the
  turn with a single `.` and nothing else. Do NOT summarize, do NOT run other tools. If a real task
  of yours is also running, you may append its one-line status, nothing more. Minimal output is the
  entire point: every extra token you emit is added to the context that each future beat re-reads.
- **exit 4 — uncached beat.** The last beat fired on schedule but still re-read the context
  uncached, so the keepalive is not paying off. In one line, tell the user their session likely has
  the short (5-minute) cache TTL — or the threshold is longer than their TTL — so no practical
  heartbeat helps. It has already stopped; do not re-arm.
- **exit 3 — deadline.** Tell the user the heartbeat reached its auto-stop deadline and is off,
  one line. Re-arm only if they ask.
- **exit 5 — no state.** The watcher could not store its deadline (unwritable temp dir). Tell the
  user in one line; do not re-arm.
- **Anything else (killed, other codes) when the user did not ask to stop it** — Claude Code can
  reap background shells under critical memory pressure: re-arm once with the same command (it
  will start a new deadline — acceptable here). If that one also dies abnormally, tell the user
  and stop.

## Rules

- Never run more than one cachebeat task; if asked to arm while one runs, stop the old one first.
- Fresh arm and re-arm are the same command; `beat.sh` decides which it is. Never add arguments
  to steer it, and never re-run it "just in case" outside of a beat.
- On a fresh arm, write one short line **before** the Bash call: if Claude Code asks for approval,
  choose **"Yes, and don't ask again"** — a plain "Yes" means the first re-arm will wait on a
  prompt while they are away and the keepalive dies. (The prompt appears before the command runs,
  so saying this afterwards is too late.) Never say it on a re-arm.
- If the user reports beats arriving but bills still showing uncached input, tell them their
  session likely has the short (5-minute) cache TTL, where no practical heartbeat interval helps —
  stop the task rather than waste money.
- This skill changes nothing about the work itself; it only pays ~10% cached-read price per beat
  to avoid paying 100% uncached price once. If the user does not plan to return to the session,
  advise stopping it.

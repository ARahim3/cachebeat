<div align="center">

# cachebeat 🫀

**Stop paying full price to say "I'm back" to your own Claude Code session.**

</div>

A tiny Claude Code skill that keeps your prompt cache warm while a session sits idle — so your
next message reads the conversation from cache instead of re-billing it from scratch. Anthropic
bills cache reads at **0.1× the input rate** (published ratio, every model) — an uncached return
costs ~10× more.

**This is not just an API-billing thing.** On Pro/Max subscriptions the same accounting drains
your **5-hour window and weekly usage limit**: come back to a long session cold, and one "how's
it going?" can eat a visible chunk of your quota that a warm cache would barely have touched.

## Why this exists

It was born in a real session: a **multi-day model fine-tune babysat by Claude** — training runs
that took hours, checkpoints landing overnight, a human who occasionally sleeps. Every time the
session went quiet for longer than the cache window, the next "how's it going?" re-billed the
**entire conversation history at full input price**. On a long, tool-heavy session that's hundreds
of thousands of tokens, re-billed every single time you stepped away too long.

One inactivity-triggered heartbeat later, it didn't.

## The problem, concretely

Claude is stateless: your whole conversation is re-sent to the API on every turn. Anthropic's
prompt caching makes this affordable — cached input costs **~10 %** of the normal rate — but the
cache expires after a TTL (up to 1 hour on long-TTL sessions). The failure mode:

1. You run something long (training, CI, a big download) or just step away.
2. The session is silent past the TTL. The cache dies.
3. You come back, type one line — and the **entire history is re-processed uncached**: ~10× the
   tokens a cached read would have counted. On the API that's money; on a subscription that's
   your 5-hour window and weekly limit draining for nothing.

Do that a few times a day on a long-running session and the "idle tax" quietly becomes the
biggest line in your bill — or the reason you hit your usage limit by mid-week.

## The fix

`/cachebeat` arms a silent background watcher inside your session. **It's an inactivity timer, not a
metronome**: it fires only when the session has been truly silent for N minutes — any message, reply,
or answered background event already refreshed the cache and resets the clock. On firing, Claude
wakes, answers with a single `.`, and the cache TTL restarts. The next timer starts by itself.

**Break-even math:** going cold once costs as much as **ten** heartbeats. Come back to the session
even once and the heartbeat has paid for itself many times over — and the bigger the session, the
bigger the absolute savings (the 10× ratio is flat; the token count isn't).

It also kills itself after a deadline (default 8 h), so an abandoned session doesn't drip-bill forever.

> **Note (Oct 2026):** Claude Code 2.1.285 put a lifetime on background shell commands (30 min by
> default, 2 h at most) and tells Claude not to restart one that hit the 2 h cap. The previous
> cachebeat ran as exactly such a command, so it was killed before its first 50-minute beat (or at
> 2 h on a busy session) and never came back ([#1](https://github.com/ARahim3/cachebeat/issues/1)).
> cachebeat now runs as an **`asyncRewake` Stop hook** declared in the skill itself: no lifetime cap,
> no re-arm tool call, no permission prompt, and one request per beat instead of two. **Upgrading?**
> Copy both files again (see [Install](#install)), then run `/cachebeat` once in each session you want
> covered. A session still running the old instructions stops at its next re-arm instead of looping.

## Install

User-level (all projects):

```bash
mkdir -p ~/.claude/skills/cachebeat
cp SKILL.md beat.sh ~/.claude/skills/cachebeat/
```

Or project-level: copy both files into `<your-project>/.claude/skills/cachebeat/`.

That's the whole setup — two small files: the skill, and the watcher script its hook runs. Then in any
Claude Code session, type `/cachebeat` and you're done. There is nothing to approve: hooks don't ask
for permission, and Claude never runs a command for it.

Requirements: a recent Claude Code (tested on 2.1.288) with hooks enabled — skill-frontmatter hooks and
`asyncRewake` are standard features, but an organization policy that disables hooks
(`disableAllHooks`, `allowManagedHooksOnly`) also disables cachebeat.

## Usage

```
/cachebeat            # fire after 50 min of inactivity, auto-stop after 8 h
/cachebeat 40         # custom idle threshold in minutes (clamped to 5–55)
/cachebeat 40 4       # custom threshold + auto-stop after 4 h
/cachebeat stop       # stop it
```

You can also just ask Claude ("keep the cache warm while this trains") — it invokes the skill for you.

## Verifying it's working

You don't have to take it on faith — you can watch the cache stay warm.

- **The heartbeat itself.** When a beat fires you'll see a `⏺ cachebeat heartbeat` line and Claude
  answering `.` — proof the timer is alive and resetting the TTL. If instead Claude tells you
  cachebeat stopped itself, the beat fired on schedule but the cache had *still* expired: your
  session's TTL is too short for any heartbeat to bridge.
- **The status line.** Claude Code's token readout looks like `tok:312.0k/0.0k` — *total / served
  from cache*. When you return to an idle session, the second number should be a large fraction of
  the first (warm). If it reads `…/0.0k`, the whole context was re-read uncached — the cache had
  died. With cachebeat armed on a long-TTL session, it should stay warm across your idle gaps.
- **The transcript (exact numbers).** Every assistant reply records what it cost. Run this inside the
  session (prefix a shell command with `!`):

  ```bash
  F=$(ls ~/.claude/projects/*/"$CLAUDE_CODE_SESSION_ID".jsonl 2>/dev/null | head -1)
  echo "cache_read:     $(tail -n 400 "$F" | grep -oE '"cache_read_input_tokens":[0-9]+'     | tail -1 | grep -oE '[0-9]+')"
  echo "cache_creation: $(tail -n 400 "$F" | grep -oE '"cache_creation_input_tokens":[0-9]+' | tail -1 | grep -oE '[0-9]+')"
  ```

  A **warm** turn shows a big `cache_read` and a tiny `cache_creation`. A **cold** turn is the
  reverse — a large `cache_creation` means the context was rebuilt from scratch at full price.

## How it works

The skill's frontmatter declares a **Stop hook** with `asyncRewake: true`. Claude Code registers it when
you invoke `/cachebeat`, and from then on runs [`beat.sh`](beat.sh) **in the background at the end of
every turn**. Each run is one inactivity timer. If the hook exits with code 2, Claude Code wakes Claude
and shows it what the hook printed:

1. A turn ends → the Stop hook starts a timer (and any older timer notices and exits).
2. Every 30 s the timer checks **when the last real model response was written** to the session
   transcript (`~/.claude/projects/<slug>/<session-id>.jsonl`). A new response resets the clock.
3. After N idle minutes it prints a one-line heartbeat note and exits 2 → Claude wakes, reads the
   conversation from cache (that read *is* the heartbeat), and answers `.`.
4. That reply ends a turn → step 1. Claude never re-arms anything.

The heart of it:

```bash
while :; do
  sleep 30
  [ "$(cat "$S.pid")" = $$ ] || exit 0                  # a newer turn started a newer timer
  SIG=$(sig "$(last_resp)")                             # the last real model response
  [ "$SIG" != "$PREV" ] && { PREV=$SIG; LAST=$NOW; }    # new request -> reset the clock
  IDLE=$((NOW - LAST))
  [ "$IDLE" -ge $((N*60)) ] && { echo "idle heartbeat …" >&2; exit 2; }   # exit 2 wakes Claude
done
```

| exit | meaning | what Claude does |
|---|---|---|
| `0` | nothing to say: not armed, stopped, superseded, or the cache is already cold | nothing — no wake-up |
| `2` + "idle heartbeat" | the session sat idle for the threshold | replies `.` (the reply's turn starts the next timer) |
| `2` + "stopped itself" | the last beat *still* came back uncached — TTL too short to bridge | tells you, stays off |
| `2` + "auto-stop" | the deadline passed | tells you, stays off |

Details that keep it honest:

- **Arguments without a tool call.** The hook reads them from the newest `/cachebeat` in the transcript
  (typed, or Claude's own Skill call) and keeps them, with the auto-stop deadline, in
  `$TMPDIR/cachebeat-<session-id>`. Invoking `/cachebeat` again re-arms with the new values; `/cachebeat
  stop` disarms. The match is on raw JSON structure, so a transcript that merely *quotes* those lines
  (say, while debugging cachebeat) can't arm it.
- **Only real requests count as activity.** Claude Code also appends lines without any model request —
  `queue-operation` entries when a Workflow's agents finish background commands, `mode`,
  `away_summary`, its own `"model":"<synthetic>"` notices for usage limits and API errors. Those don't
  refresh the cache, so they don't reset the clock (they used to, and a busy Workflow could keep the
  old watcher from ever firing while the cache died).
- **Never mid-tool.** While a tool is still running (or waiting on a permission prompt), the timer
  doesn't fire: a wake-up couldn't be delivered before the tool returns anyway.
- **Every beat is audited.** After a beat, the next timer reads that beat's own usage record. A large
  `cache_creation` (or 5-minute-TTL cache writes) means the cache had already expired, so it stops
  and tells you instead of pretending to help.
- **No beat into a cold cache.** If the machine slept past the TTL, the cache is already gone and a beat
  would only pay to rebuild it — the timer stands down until you're back.
- **No beat into the wrong conversation.** A wake-up goes to the Claude Code process, not to a session,
  so the skill also registers a `SessionEnd` hook: `/clear`, `/resume` and exit disarm the timer before
  it can beat into the next conversation. If Claude Code dies outright, the timer notices its parent is
  gone and exits.
- **The hook's `timeout` matters.** Claude Code kills an `asyncRewake` hook at its `timeout` — 10 minutes
  unless set — so the skill sets `timeout: 90000` (25 h, past the longest deadline). Without it every
  timer would die before a 50-minute beat, which is the old failure all over again.
- **Nothing on stderr but the note.** On exit 2, Claude sees everything the hook wrote to stderr; the
  script sends all other stderr to `/dev/null` so stray errors can't leak into the conversation.

> **Why a hook, and not a background command, a monitor, or a cron job?** The wake-up needs something
> that can stay silent for ~50 minutes and then make Claude take a turn:
>
> | mechanism | lifetime | why not |
> |---|---|---|
> | Monitor | ≤ 30 min | every expiry wakes Claude: forced ~28-min metronome, idle or not |
> | background Bash (`run_in_background`) | 30 min default, 2 h max (since 2.1.285) | killed before a 50-min beat unless re-armed with `timeout`; at the 2 h cap Claude is told not to restart it |
> | CronCreate | 7 days | wall-clock metronome; under 60 min apart means ≥ 2 beats an hour, +10% jitter, even while you're chatting |
> | **Stop hook + `asyncRewake`** | hook's own `timeout` (we set 25 h) | — re-armed by Claude Code itself on every turn end; no tool call, no permission prompt |

## Compatibility

Linux, WSL2, and macOS. The watcher uses only portable tools — `tail`, `grep`, `sed`, `cut`, `tr`,
`date +%s` — with no `stat`, no `jq` and no timestamp parsing, so there are no GNU-vs-BSD differences to
trip over (tested with bash-as-`sh`, dash and ksh). Native Windows (non-WSL) is untested — the watcher
assumes a POSIX shell.

It reads Claude Code's session transcript (the path comes from the hook's input) — an internal format
rather than a documented API, so a future Claude Code change could require an update here.

## Honest caveats

- **Only helps on sessions with the long (1-hour) cache TTL.** Some sessions run a 5-minute TTL; no
  practical heartbeat can bridge that. cachebeat detects it on the first beat and stops itself.
- Each beat costs one small cached-read request plus a few output tokens, and each beat's exchange is
  appended to the context that later requests re-read. Cheap, not free.
- **Resuming a session** (`claude --resume`) doesn't bring the hook back — run `/cachebeat` again.
- If a beat's own request fails (API error, usage limit), the timer is not restarted until your next
  message — nothing can warm the cache while requests fail anyway.
- A wake-up can't be delivered while a long *foreground* tool is running (e.g. a subagent Claude is
  waiting on); if that takes over an hour, the cache expires regardless.
- The idle threshold must stay **under** the TTL — the default 50 min leaves ~10 min of margin
  against the 1-hour TTL.
- If you're *not* coming back to the session, any heartbeat is pure waste. That's what the
  auto-stop deadline is for.

## License

MIT — do whatever you like with it.

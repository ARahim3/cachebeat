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

`/cachebeat` arms a single background monitor inside your session. **It's an inactivity timer,
not a metronome**: it fires only when the session has been truly silent for N minutes — any
message, reply, or answered background event already refreshed the cache and resets the clock.
On firing, Claude wakes, answers with a few words, and the cache TTL restarts.

**Break-even math:** going cold once costs as much as **ten** heartbeats. Come back to the
session even once and the heartbeat has paid for itself many times over — and the bigger the
session, the bigger the absolute savings (the 10× ratio is flat; the token count isn't).

It also kills itself after a deadline (default 8 h), so an abandoned session doesn't drip-bill
forever.

## Install

User-level (all projects):

```bash
mkdir -p ~/.claude/skills/cachebeat
cp SKILL.md ~/.claude/skills/cachebeat/
```

Or project-level: copy `SKILL.md` into `<your-project>/.claude/skills/cachebeat/`.

That's the whole setup — copy one file. Then in any Claude Code session, type `/cachebeat` and
you're done; there's nothing to configure. (It just needs a Claude Code that runs background
tasks, which is the default.)

## Usage

```
/cachebeat            # fire after 50 min of inactivity, auto-stop after 8 h
/cachebeat 40         # custom idle threshold in minutes (clamped to 5–55)
/cachebeat 40 4       # custom threshold + auto-stop after 4 h
/cachebeat stop       # stop it
```

## Verifying it's working

You don't have to take it on faith — you can watch the cache stay warm.

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
- **The heartbeat itself.** When a beat fires you'll see Claude answer with a few words ("Okay, still
  here.") — proof the monitor is alive and resetting the TTL. If instead you see `CACHEBEAT_WARN`,
  the beat fired on schedule but *still* came back uncached: your session's TTL is too short for any
  heartbeat to bridge, so stop it.

## How it works

Claude Code writes every exchange to a session transcript (`~/.claude/projects/<slug>/<session-id>.jsonl`).
The skill starts one persistent background monitor that, once a minute, checks **when the last real
turn happened** and how long ago that was:

```bash
# Pin THIS session's transcript by its id (not "newest file", which another
# session in the same folder could hijack). Fall back to newest at arm time.
SID="$CLAUDE_CODE_SESSION_ID"
F=$(ls "$HOME/.claude/projects"/*/"$SID".jsonl 2>/dev/null | head -1)
[ -z "$F" ] && F=$(ls -t "$HOME/.claude/projects/$(pwd | tr '/._' '---')"/*.jsonl | head -1)

END=$(( $(date +%s) + HOURS*3600 )); PREV=__init__; LAST=$(date +%s)
while [ $(date +%s) -lt $END ]; do
  sleep 60
  # Activity signal = timestamp of the last transcript line. It changes only on a
  # real turn — a bare file-mtime bump (recap rewrite, atomic save) does NOT fool it.
  SIG=$(tail -n 1 "$F" | grep -oE '"timestamp":"[^"]+"' | tail -1)
  [ -z "$SIG" ] && SIG=$(wc -c < "$F")
  [ "$SIG" != "$PREV" ] && { PREV="$SIG"; LAST=$(date +%s); }   # new turn -> reset clock
  IDLE=$(( $(date +%s) - LAST ))
  if [ $IDLE -ge $((MINUTES*60)) ]; then
    echo "HEARTBEAT idle=${IDLE}s"                 # wakes Claude -> tiny reply -> cache refreshed
    sleep 300                                      # let the reply land; avoids double-fire
    # Self-check: if the beat itself came back uncached, the TTL is too short to bridge.
    CR=$(tail -n 400 "$F" | grep -oE '"cache_read_input_tokens":[0-9]+' | tail -1 | grep -oE '[0-9]+')
    CC=$(tail -n 400 "$F" | grep -oE '"cache_creation_input_tokens":[0-9]+' | tail -1 | grep -oE '[0-9]+')
    [ -n "$CC" ] && [ -n "$CR" ] && [ "$CC" -gt "$CR" ] && echo "CACHEBEAT_WARN uncached beat"
  fi
done
echo CACHEBEAT_EXPIRED
```

Every emitted line wakes Claude; the skill instructs it to reply with a few words only, because
every extra token gets re-read by all future requests. `CACHEBEAT_WARN` flags a session whose cache
TTL is too short for any heartbeat to help; `CACHEBEAT_EXPIRED` ends it.

> **Why the timestamp, not the file mtime?** The mtime of a `.jsonl` advances whenever Claude Code
> rewrites the file for its own reasons (recap regeneration, atomic saves) — no turn, no cache
> refresh. Measuring idle from mtime therefore *undercounts* idle time and fires the beat late,
> past the TTL, so the beat lands as a full-price uncached re-read: the exact failure this is meant
> to prevent. The last line's `timestamp` only moves on a genuine turn, so it can't be fooled.

## Compatibility

Linux, WSL2, and macOS. The monitor uses only portable tools — `tail`, `grep`, `wc`, `date +%s` —
with no `stat` and no timestamp parsing, so there are no GNU-vs-BSD differences to trip over.
Native Windows (non-WSL) is untested — the monitor assumes a POSIX shell.

It reads Claude Code's session transcript at `~/.claude/projects/<slug>/<session-id>.jsonl` (found
via `$CLAUDE_CODE_SESSION_ID`, else the newest transcript in the folder) — the default layout, but
an internal one rather than a documented API, so a future Claude Code change could require an update
here.

## Honest caveats

- **Only helps on sessions with the long (1-hour) cache TTL.** Some sessions run a 5-minute TTL;
  no practical heartbeat can bridge that. If your bills stay uncached despite beats, stop it.
- Each beat costs a small cached-read request plus a few output tokens, and each beat's exchange
  is appended to the context that later requests re-read. Cheap, not free.
- The idle threshold must stay **under** the TTL — the default 50 min leaves ~10 min of margin
  against the 1-hour TTL.
- If you're *not* coming back to the session, any heartbeat is pure waste. That's what the
  auto-stop deadline is for.

## License

MIT — do whatever you like with it.

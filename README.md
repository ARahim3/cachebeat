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

`/cachebeat` arms a single silent background watcher inside your session. **It's an inactivity
timer, not a metronome**: it fires only when the session has been truly silent for N minutes — any
message, reply, or answered background event already refreshed the cache and resets the clock.
On firing, Claude wakes, quietly re-arms the watcher, and the cache TTL restarts.

**Break-even math:** going cold once costs as much as **ten** heartbeats. Come back to the
session even once and the heartbeat has paid for itself many times over — and the bigger the
session, the bigger the absolute savings (the 10× ratio is flat; the token count isn't).

It also kills itself after a deadline (default 8 h), so an abandoned session doesn't drip-bill
forever.

> **Note (Sept 2026):** cachebeat used to run as one *persistent* background monitor. A Claude Code
> update capped monitors at 30 minutes with no persistent option — which would force a wake-up every
> ~28 min, idle or not. cachebeat now runs as a **background shell task** instead, which has no such
> cap: it stays silent for the full idle threshold (50 min by default), exits to deliver the beat,
> and Claude re-arms it. Same inactivity timer, different plumbing. **Upgrading?** The watcher now
> lives in a second file — copy `beat.sh` next to `SKILL.md` (see [Install](#install)). Details in
> [How it works](#how-it-works).

## Install

User-level (all projects):

```bash
mkdir -p ~/.claude/skills/cachebeat
cp SKILL.md beat.sh ~/.claude/skills/cachebeat/
```

Or project-level: copy both files into `<your-project>/.claude/skills/cachebeat/`.

That's the whole setup — two small files: the skill, and the watcher script it runs. Then in any
Claude Code session, type `/cachebeat` and you're done. (It just needs a Claude Code that runs
background tasks, which is the default.)

**One thing to do on first use:** unless you run in auto mode or with permissions bypassed, Claude
Code will ask before running `sh …/cachebeat/beat.sh 50 8`. Pick **"Yes, and don't ask again for:
sh …/beat.sh 50 8"** — not the plain "Yes". The watcher is re-started after every beat, and those
beats happen precisely when you're *away*; a permission prompt nobody is there to answer would
silently end the keepalive. That approval matches the exact command, which is why cachebeat re-arms
with the *identical* command every time (and why a different threshold, e.g. `/cachebeat 40`, asks
once more). To allow every variant up front, add this to your Claude Code settings instead:

```json
{ "permissions": { "allow": ["Bash(sh /Users/you/.claude/skills/cachebeat/beat.sh:*)"] } }
```

Use the absolute path exactly as it appears in the approval prompt — the rule is matched against
the literal command.

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
- **The heartbeat itself.** When a beat fires you'll see the `cachebeat keepalive` task finish and
  Claude quietly start it again, answering with just `.` — proof the watcher is alive and resetting
  the TTL. If instead Claude tells you a beat came back uncached (the watcher exited `4`), the beat
  fired on schedule but the cache had *still* died: your session's TTL is too short for any
  heartbeat to bridge, and it stops on its own.

## How it works

Claude Code writes every exchange to a session transcript (`~/.claude/projects/<slug>/<session-id>.jsonl`).
The skill starts [`beat.sh`](beat.sh) as one **background shell task** (Bash with
`run_in_background`). Every 30 seconds it checks **when the last real turn happened** and how long
ago that was. It prints nothing while it waits; it exits only when there's something to say — and a
background task's exit is what wakes Claude. The heart of it:

```bash
PREV=__init__; LAST=$(date +%s)
while [ "$(date +%s)" -lt "$END" ]; do
  sleep 30
  # Activity signal = timestamp of the last transcript line. It changes only on a
  # real turn — a bare file-mtime bump (recap rewrite, atomic save) does NOT fool it.
  SIG=$(tail -n 1 "$F" | grep -oE '"timestamp":"[^"]+"' | tail -1)
  [ -z "$SIG" ] && SIG=$(wc -c < "$F")
  [ "$SIG" != "$PREV" ] && { PREV="$SIG"; LAST=$(date +%s); }   # new turn -> reset clock
  IDLE=$(( $(date +%s) - LAST ))
  [ "$IDLE" -ge $(( MINUTES*60 )) ] && exit 0    # exit wakes Claude -> cache refreshed -> re-arm
done
exit 3                                           # auto-stop deadline reached
```

The **exit code is the whole message**, so Claude never has to read anything back:

| exit | meaning | what Claude does |
|---|---|---|
| `0` | beat — the session sat idle for the threshold | re-runs the identical command, replies `.` |
| `3` | auto-stop deadline reached | tells you it's off |
| `4` | the last beat *still* came back uncached — TTL too short to bridge | tells you, stops |
| `5` | couldn't store the deadline (unwritable temp dir) | tells you, stops |

On a beat, the wake-up turn itself re-reads the conversation at cached price — that read is the
heartbeat. The skill instructs Claude to do exactly one thing in that turn: start the watcher again
and answer with a single `.`, because every extra token gets re-read by all future requests. The
auto-stop deadline is fixed on the first arm and kept in a small state file
(`$TMPDIR/cachebeat-<session-id>.end`), so re-arming can never extend it. A beat also leaves a
marker there; a start that finds a fresh marker knows it is that beat's re-arm, keeps the deadline,
and checks the usage record of the beat that just woke Claude: a large `cache_creation` means the
cache had already died, and it exits `4` instead of pretending to help.

> **Why a script file, and why is the re-arm the identical command?** The watcher is restarted
> after every beat. A one-line `sh beat.sh 50 8` costs a few dozen output tokens per beat instead of
> ~600 and keeps the long command out of the context every later request re-reads. And Claude
> Code's "don't ask again" approval matches the *literal* command: an inline script full of `$(…)`
> isn't offered that option at all, and even one extra argument on the re-arm would count as a new
> command — prompting you exactly when you're not there. One unchanging command, one approval.

> **Why a shell task instead of a monitor?** Claude Code kills every Monitor after at most 30
> minutes, and each expiry wakes Claude — so a monitor-based keepalive is forced into a ~28-minute
> metronome that beats even while you're actively chatting. A background shell task has no lifetime
> cap, so the watcher can sit silent for the whole idle threshold and beat only when it's needed:
> roughly half the beats on a fully idle session, and **zero** on an active one.

> **Why the timestamp, not the file mtime?** The mtime of a `.jsonl` advances whenever Claude Code
> rewrites the file for its own reasons (recap regeneration, atomic saves) — no turn, no cache
> refresh. Measuring idle from mtime therefore *undercounts* idle time and fires the beat late,
> past the TTL, so the beat lands as a full-price uncached re-read: the exact failure this is meant
> to prevent. The last line's `timestamp` only moves on a genuine turn, so it can't be fooled.

## Compatibility

Linux, WSL2, and macOS. The watcher uses only portable tools — `tail`, `grep`, `wc`, `date +%s` —
with no `stat` and no timestamp parsing, so there are no GNU-vs-BSD differences to trip over.
Native Windows (non-WSL) is untested — the watcher assumes a POSIX shell.

It reads Claude Code's session transcript at `~/.claude/projects/<slug>/<session-id>.jsonl` (found
via `$CLAUDE_CODE_SESSION_ID`, else the newest transcript in the folder) — the default layout, but
an internal one rather than a documented API, so a future Claude Code change could require an update
here.

## Honest caveats

- **Only helps on sessions with the long (1-hour) cache TTL.** Some sessions run a 5-minute TTL;
  no practical heartbeat can bridge that. If your bills stay uncached despite beats, stop it.
- Each beat costs two small cached-read requests (the wake-up and the re-arm) plus a few output
  tokens, and each beat's exchange is appended to the context that later requests re-read. Cheap,
  not free.
- Under **critical memory pressure** Claude Code may reap background shells in a long-idle session.
  The skill tells Claude to re-arm if the watcher dies unexpectedly, but on a machine that's
  swapping hard, a beat can be missed.
- The idle threshold must stay **under** the TTL — the default 50 min leaves ~10 min of margin
  against the 1-hour TTL.
- If you're *not* coming back to the session, any heartbeat is pure waste. That's what the
  auto-stop deadline is for.

## License

MIT — do whatever you like with it.

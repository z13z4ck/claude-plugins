# pause-resume — freeze a running agent, come back later

Stop a Claude Code agent mid-task without losing it. Move between locations,
lose the network, shut the laptop, then pick up exactly where you left off with
the full conversation intact.

```
/plugin marketplace add z13z4ck/claude-plugins
/plugin install pause-resume@z13z4ck-plugins
/pause-resume:install-cli     # run this — pausing works from outside the session
```

## The idea

You cannot pause an agent mid-API-call. But an agent spends most of its life
*between* tool calls, and Claude Code runs a `PreToolUse` hook before each one
and waits for it to finish.

So the hook simply does not finish.

While it blocks, nothing runs: no tool executes, no follow-up request goes to
the API, and the entire conversation stays resident in the CLI process. The
agent is not stopped and restarted — it is held. When you clear the flag, the
hook exits, the pending tool call proceeds, and the agent carries on with every
byte of context it had before, unaware anything happened.

That is why this survives things that normally destroy a session. During a
freeze there is no network traffic to drop, so losing connectivity costs
nothing. Suspending the machine suspends the poll loop with it; on wake it
carries on counting from the wall clock. Nothing to reconnect, nothing to
replay.

## Using it

Pause from **another terminal** — that is the whole point, since the agent you
want to stop is busy:

```bash
agent-pause pause -r "boarding the train"   # freeze at the next tool call
agent-pause resume                          # continue
agent-pause status                          # what is held, and where
```

The pause takes effect at the agent's next tool call. Anything already
executing runs to completion — you never get a half-finished write.

### Auto-thaw when the network returns

For the moving-between-places case, do not bother resuming by hand:

```bash
agent-pause pause --until-online
```

The gate polls connectivity while frozen and releases itself the moment the API
is reachable again. Pause before you close the laptop, open it at the other
end, and the agent resumes on its own once wifi connects.

### Arm a pause for later

When you know you are leaving soon but want the agent to keep working until
then:

```bash
agent-pause pause --in 10m -r "leaving for the airport"
```

An armed pause shows up in `agent-pause status` with its fire time, and
`agent-pause resume` cancels it before it fires. The timer is a plain
process: a reboot kills it and the pause never fires — `status` detects and
reports that case instead of leaving a silent gap.

### From inside the session

```
/pause-resume:pause in 5m running out the door
/pause-resume:status
/pause-resume:checkpoint        # write a rich resume brief before disconnecting
/pause-resume:recover           # rebuild state from a session that was cut off
/pause-resume:resume
```

## What happens when you did not get to pause in time

The tunnel arrives before you do. The session dies with no warning.

Claude Code appends every turn to `~/.claude/projects/<slug>/<session>.jsonl`
as it happens, so the history is already durable — it just was not summarised.
This plugin turns that back into something usable:

- **On a clean exit**, the `SessionEnd` hook writes a resume brief and queues
  it. The next session started in that directory is handed it automatically at
  startup, with instructions to summarise and ask rather than charge ahead.
- **After a hard kill**, no hook ran, so nothing was saved. Run
  `/pause-resume:recover` and the brief is reconstructed from the transcript
  after the fact.

Either way you get the last instruction, where the agent had got to, the task
list with the in-flight item marked, files touched, and recent actions. A
truncated final line — a transcript caught mid-write by a kill — is skipped
rather than fatal.

For anything important, `/pause-resume:checkpoint` beats both: the agent writes
the brief itself, so it can record intent, decisions already settled, and
approaches already ruled out. The automatic ones only see what happened, not
why.

## The honest limitations

**A frozen session cannot process slash commands.** The process is blocked
inside a hook, so anything you type there queues until it unblocks — including
`/pause-resume:resume`. Resume from another terminal. This is inherent to
blocking the process, not an oversight, and it is why `install-cli` matters.

**Granularity is one tool call.** A pause lands at the next tool boundary. If
the agent is midway through generating a long response with no tool calls in
it, the freeze waits for the next one.

**A pause is not a checkpoint.** Freezing keeps a *live process* alive. Kill the
terminal and the context is gone regardless. If you are going to shut the
machine down rather than suspend it, write a checkpoint too.

**Local state only.** Flags live on the machine running the agent. Pausing from
your phone means SSHing to that machine.

**The online probe can be fooled.** `--until-online` prefers an HTTPS round
trip to the API host, which captive portals fail closed (staying paused —
safe). But when `curl` is absent it falls back to ping, and a portal that
answers ping can thaw the agent onto a network that still blocks the API. The
result is a failed API call, not lost work.

## Failing safe

The design assumes the pause mechanism itself will sometimes break, because the
failure that matters is asymmetric: a pause that refuses to release is an
annoyance, but a tool call that runs while you believe the agent is stopped is
the thing this plugin exists to prevent.

When Claude Code kills a `PreToolUse` hook that overran its timeout, it
**allows** the tool call. A naive implementation would therefore un-pause
itself silently after the timeout, and run a command into a session nobody is
watching. Three things prevent that:

- The gate clamps its own deadline below the configured hook timeout, so it
  exits deliberately — blocking the pending call with an explanation — rather
  than being killed.
- A gate that exits cleanly removes its own marker file. A marker whose owning
  process is gone is therefore proof of a kill, and the next tool call is
  **denied** rather than allowed. One caveat is unavoidable: the platform
  allows the single tool call whose gate it killed, so a kill can leak that
  one call before the denial kicks in. The deadline clamp exists to make
  being killed rare, and the deny message reports how long the dead gate had
  held so a platform cap lower than the configured timeout is visible rather
  than silent.
- When a pause deadline genuinely expires, the block tells the agent not to
  retry and to report to the user, so it does not thrash against the gate.

A stale global flag is the other way to get stuck — pause everything, lose the
session, and every future agent freezes on its first tool call for no visible
reason. `SessionStart` clears an orphaned global flag when no live session is
left to own it, and says so.

## Cost

The gate runs before every tool call, so its fast path exits before even
reading stdin: a directory glob, no subprocess, no `jq`. Measured at ~7 ms per
tool call on an M-series Mac, essentially all of it shell startup.

## Configuration

| Variable | Default | Purpose |
|---|---|---|
| `CLAUDE_PAUSE_HOME` | `~/.claude/pause-resume` | State directory |
| `CLAUDE_PAUSE_POLL_INTERVAL` | `2` | Seconds between flag checks while frozen |
| `CLAUDE_PAUSE_MAX_WAIT` | `43200` | Default pause ceiling (12h) |
| `CLAUDE_PAUSE_HOOK_TIMEOUT` | `86400` | Must mirror `timeout` in `hooks/hooks.json` |

If your platform caps hook timeouts below 24h, lower
`CLAUDE_PAUSE_HOOK_TIMEOUT` to match. The gate uses it to decide when to exit
on its own terms instead of waiting to be killed.

## Layout

```
bin/agent-pause          CLI — pause/resume from outside the session
bin/pause-gate.sh        PreToolUse hook — the freeze itself
bin/session-start.sh     SessionStart — register, clean up, deliver briefs
bin/session-end.sh       SessionEnd — save a brief on the way out
bin/make-checkpoint.py   Rebuild a brief from a transcript
bin/lib.sh               Shared state layout and helpers
hooks/hooks.json         Hook registration
commands/                Slash commands
tests/run-tests.sh       59 tests, isolated state, no network
```

```bash
bash tests/run-tests.sh
```

Covers the freeze/release cycle, deadline expiry, killed-gate detection,
concurrent gates, session targeting, orphaned-flag cleanup and its live-gate
veto, mid-freeze re-pause (`--until-online` picked up by a frozen gate), the
per-OS ping fallback, armed-pause visibility and cancellation, checkpoint
rendering against a deliberately corrupted transcript (subagent sidechains
excluded), and brief delivery.

## License

[MIT](../../LICENSE) © Aziz (z13z4ck)

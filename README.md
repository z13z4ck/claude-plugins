# z13z4ck-plugins — Claude Code plugin marketplace

```
/plugin marketplace add z13z4ck/claude-plugins
```

| Plugin | What it does |
|---|---|
| [pause-resume](plugins/pause-resume/README.md) | Freeze a running agent between tool calls and thaw it later with context intact — for moving locations, losing connectivity, or sleeping the laptop mid-task |
| [advisor-select](plugins/advisor-select/README.md) | Pick which model advises this session (`opus`, `sonnet`, `haiku`, `fable`) — e.g. main conversation on Sonnet, second opinions from Opus |
| [fable-advisor](plugins/fable-advisor/README.md) | A read-only second-opinion advisor, always on Fable 5 at `xhigh` effort, with a labeled Opus fallback |

# pause-resume — stop an agent mid-task and come back to it

You cannot pause an agent mid-API-call, but an agent spends most of its life
*between* tool calls — and Claude Code waits for a `PreToolUse` hook to finish
before each one. So the hook doesn't finish. Nothing runs, no request goes to
the API, and the whole conversation stays resident in the process. Clear the
flag and the agent carries on with every byte of context it had, unaware
anything happened.

```
/plugin install pause-resume@z13z4ck-plugins
/pause-resume:install-cli          # pausing has to come from outside the session
```

```bash
agent-pause pause --until-online   # freeze now, thaw itself when wifi returns
agent-pause pause --in 10m         # keep working, freeze when I leave
agent-pause resume                 # continue
agent-pause status                 # what is held, at which tool, for how long
```

Because a freeze makes no network traffic, there is no connection to drop;
because it is a sleeping poll loop, suspending the machine suspends it too.
When a session dies before you could pause it, `/pause-resume:recover` rebuilds
a resume brief from the transcript Claude Code was writing to disk all along.
Full details, including how it fails safe when the hook itself is killed:
[plugins/pause-resume](plugins/pause-resume/README.md).

# advisor-select — pick which model advises your session

Run your main conversation on any model and choose, per session, which model
serves as your read-only second-opinion advisor. The canonical setup: main
session on Sonnet (fast, cheap), advisor on Opus (deep judgment on the calls
that matter).

```
/plugin install advisor-select@z13z4ck-plugins
/advisor-select:use opus            # this session's advisor (opus | sonnet | haiku | fable)
/advisor-select:health              # confirm the selected model actually answers
/advisor-select:consult <question>  # get a second opinion (--model <alias> to override once)
/advisor-select:review-plan         # critique the current plan before executing it
```

`/advisor-select:use` with no argument shows the current selection and asks
interactively. The choice is stored per session ID, so it survives context
compaction and resets automatically in a new session (default: Opus). If the
selected model is unavailable, the consultation retries once on a fallback
and labels the verdict "ADVISOR RUNNING DEGRADED" — and every verdict opens
with a MODEL line, so a silently substituted model can't pass as your
selection. Full details, including proactive (no-command) invocation and a
CLAUDE.md policy snippet: [plugins/advisor-select](plugins/advisor-select/README.md).

# fable-advisor — a Fable 5 second-opinion agent for Claude Code

Run your session on any model (Opus recommended). Consult a read-only Fable 5
advisor — running at `xhigh` reasoning effort, since consultations are rare
and high-stakes — for architectural decisions, plan reviews, and stalled
debugging. Built as a replacement path for sessions where Claude Code's
built-in advisor tool reports "Advisor unavailable": this plugin dispatches
Fable through the standard subagent mechanism instead, and degrades to Opus
with a clear label if Fable itself is refused.

```
/plugin install fable-advisor@z13z4ck-plugins
/fable-advisor:health               # run this FIRST — confirms Fable is reachable
/fable-advisor:consult <question>   # second opinion (--model <alias> to override once)
/fable-advisor:review-plan          # critique the current plan before executing it
```

Every verdict opens with a MODEL line, so a silently substituted model can't
pass as Fable — the health check treats "answered as another model" as
degraded, not operational. A failed dispatch retries once on a fallback and
labels the verdict "ADVISOR RUNNING DEGRADED". Full details, including
proactive (no-command) invocation and a CLAUDE.md policy snippet:
[plugins/fable-advisor](plugins/fable-advisor/README.md).

## License

[MIT](LICENSE) © Aziz (z13z4ck)

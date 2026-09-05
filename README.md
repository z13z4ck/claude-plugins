# z13z4ck-plugins — Claude Code plugin marketplace

```
/plugin marketplace add z13z4ck/claude-plugins
```

| Plugin | What it does |
|---|---|
| [fable-advisor](plugins/fable-advisor/README.md) | A read-only second-opinion advisor, always on Fable (the `fable` alias — Fable 5.1 today) at `high` effort, with a labeled Opus fallback — and hooks that enforce consultation: policy injected every session, `ExitPlanMode` gated, unadvised multi-file turns held for review |
| [advisor-select](plugins/advisor-select/README.md) | Pick which model advises this session (`opus`, `sonnet`, `haiku`, `fable`) — e.g. main conversation on Sonnet, second opinions from Opus |
| [pause-resume](plugins/pause-resume/README.md) | Freeze a running agent between tool calls and thaw it later with context intact — for moving locations, losing connectivity, or sleeping the laptop mid-task |

# fable-advisor — a Fable second-opinion agent for Claude Code

Run your session on any model. Consult a read-only Fable advisor — dispatched
through the `fable` alias, so Fable 5.1 on current Claude Code, running at
`high` reasoning effort, with `xhigh` a one-line opt-up — for
architectural decisions, plan reviews, and stalled debugging. Built as a
replacement path for sessions where Claude Code's built-in advisor tool is
not attached (a Fable 5.1 main model accepts only a Fable 5.1 advisor, so a
saved Opus advisor silently stops applying): this plugin dispatches Fable
through the standard subagent mechanism instead, and degrades to Opus with a
clear label if Fable itself is refused. If the session is already on Fable,
the advisor is the same model and the value is a fresh-context, file-grounded
second look rather than a capability jump.

```
/plugin install fable-advisor@z13z4ck-plugins
/fable-advisor:health               # run this FIRST — confirms Fable is reachable
/fable-advisor:consult <question>   # second opinion (--model <alias> to override once)
/fable-advisor:review-plan          # critique the current plan before executing it
/fable-advisor:status               # consultations this session, unreviewed edits, active hooks
```

Consultation is enforced, not just suggested. Hooks put the advisor policy in
context at every session start and after every compaction, flag prompts that
call for advice as they arrive, deny `ExitPlanMode` until the plan has been
sent to the advisor, nudge once four distinct files have been edited without
a consultation (Bash heredocs and `sed -i` count), and hold a turn that
edited four or more files unadvised once at its end, instructing the model to
get a verification review before it finishes. `FABLE_ADVISOR_ENFORCE=nudge`
keeps the reminders and drops the gates.

Every verdict opens with a MODEL line, so a silently substituted model can't
pass as Fable — including when Claude Code's own safety-classifier fallback
or `fallbackModel` chain re-runs the subagent on Opus. The health check
treats "answered as another model" as degraded, not operational. A failed
dispatch retries once on a fallback and labels the verdict "ADVISOR RUNNING
DEGRADED". Full details, including the hook table, configuration and a
CLAUDE.md policy snippet:
[plugins/fable-advisor](plugins/fable-advisor/README.md).

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

## License

[MIT](LICENSE) © Aziz (z13z4ck)

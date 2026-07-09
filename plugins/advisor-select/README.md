# advisor-select — pick which model advises your session

Run your main conversation on any model and choose, per session, which model
serves as your read-only second-opinion advisor. The canonical setup: main
session on Sonnet (fast, cheap), advisor on Opus (deep judgment on the calls
that matter). Same advisor workflow as [fable-advisor](../fable-advisor), but
the advisor model is a session-scoped choice instead of being fixed to Fable.

## Components

| Component | Purpose |
|---|---|
| `agents/advisor.md` | Read-only advisor agent. Defaults to Opus; the dispatching session passes the selected model per invocation. Every verdict starts with a MODEL line so a silently substituted model can't pass as your selection. |
| `/advisor-select:use <alias>` | Set the advisor model for this session: `opus`, `sonnet`, `haiku`, or `fable`. No argument shows the current selection and asks interactively. |
| `/advisor-select:consult <question>` | Deterministic consultation using the session-selected model. `--model <alias>` overrides per call. |
| `/advisor-select:review-plan` | Critique the session's current plan before execution. |
| `/advisor-select:health` | Show the current selection and verify that model actually answers as itself. |

## Install

```
/plugin marketplace add z13z4ck/claude-plugins
/plugin install advisor-select@z13z4ck-plugins
/advisor-select:use opus       # pick your advisor for this session
/advisor-select:health         # confirm the selected model is reachable
```

## How session-scoped selection works

`/advisor-select:use` writes your chosen alias to a small state file keyed by
the session ID (`$TMPDIR/claude-advisor-model-$CLAUDE_CODE_SESSION_ID`). The
consult, review-plan, and health commands read that file before dispatching
and pass the alias as the agent's model parameter. Because the file is keyed
by session:

- the selection **survives context compaction** (it's on disk, not in the
  conversation), and
- it **resets automatically in a new session** — a fresh session falls back
  to the default, Opus, until you select again.

Only the four aliases `opus`, `sonnet`, `haiku`, `fable` are accepted — they
are what the Agent tool's model parameter takes, and each alias tracks the
newest model of its tier.

## Fallback and substitution detection

If the selected model is unavailable or refused, the commands retry once on
`opus` (or `sonnet`, if your selection already was `opus`) and label the
verdict "ADVISOR RUNNING DEGRADED" — a degraded verdict is never presented as
coming from your selected model. A dispatch that *succeeds* on the wrong
model is caught by the MODEL line the advisor prints at the top of every
verdict.

## Proactive invocation (no command needed)

The agent's `description` frontmatter carries the same explicit trigger
conditions as fable-advisor ("MUST BE USED before any architectural decision,
plans touching >3 files, after two failed fix attempts...") plus a dispatch
rule telling the session to read the selection file before delegating. To
make consultation near-mandatory, add to your project's `CLAUDE.md`:

```markdown
## Advisor policy
Before any architectural decision, any plan touching more than 3 files, or
after two failed attempts at the same bug, consult the
advisor-select:advisor agent (pass the model recorded by
/advisor-select:use, default opus) and present its verdict. Do not proceed
on major decisions without either an advisor verdict or an explicit note
that the advisor could not be reached.
```

## advisor-select vs fable-advisor

- **fable-advisor**: the advisor is always Fable 5, with Opus as a labeled
  degraded fallback. Choose it when you specifically want top-tier judgment
  and nothing else.
- **advisor-select**: the advisor is whatever you pick per session. Choose
  it when you want to tune the cost/quality of second opinions to the task
  at hand — including selecting `fable` manually.

Installing both is fine; their commands and agents are namespaced.

## License

[MIT](../../LICENSE) © Aziz (z13z4ck)

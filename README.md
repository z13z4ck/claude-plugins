# fable-advisor — a Fable 5 second-opinion agent for Claude Code

Run your session on any model (Opus recommended). Consult a read-only Fable 5
advisor for architectural decisions, plan reviews, and stalled debugging.
Built as a replacement path for sessions where Claude Code's built-in advisor
tool reports "Advisor unavailable": this plugin dispatches Fable through the
standard subagent mechanism instead, and degrades to Opus with a clear label
if Fable itself is refused.

## Components

| Component | Purpose |
|---|---|
| `agents/advisor.md` | Read-only advisor, `model: fable`, `effort: high`. Reads files itself instead of trusting summaries. Every verdict starts with a MODEL line so a silently substituted model can't pass as Fable. |
| `/fable-advisor:consult <question>` | Deterministic consultation. `--model <id>` overrides the advisor model per call. |
| `/fable-advisor:review-plan` | Critique the session's current plan before execution. |
| `/fable-advisor:health` | Verify Fable is actually reachable; reports exact errors and whether Opus fallback works. |

## Install

```
/plugin marketplace add z13z4ck/claude-plugins
/plugin install fable-advisor@z13z4ck-plugins
/fable-advisor:health        # run this FIRST — confirms Fable is reachable on your account
```

## How proactive invocation works (no command needed)

Claude Code decides on its own when to delegate to an agent by reading the
agent's `description` frontmatter. This plugin's description uses explicit
trigger conditions ("MUST BE USED before any architectural decision, plans
touching >3 files, after two failed fix attempts..."), which is the supported
mechanism for autonomous consultation. The slash commands exist only as
deterministic triggers when you don't want to leave it to judgment.

Description-driven triggering is real but not guaranteed. To make
consultation near-mandatory, add this to your project's `CLAUDE.md`:

```markdown
## Advisor policy
Before any architectural decision, any plan touching more than 3 files, or
after two failed attempts at the same bug, consult the fable-advisor:advisor
agent and present its verdict. If the built-in advisor tool is unavailable,
use the fable-advisor:advisor agent — do not skip consultation because the
built-in tool refused. Do not proceed on major decisions without either an
advisor verdict or an explicit note that both advisor paths failed.
```

Three layers, in increasing reliability: agent description (autonomous),
CLAUDE.md policy (strongly steered), slash command (deterministic).

## About the "Advisor unavailable" error

The built-in advisor tool and this plugin use different dispatch paths. If
the built-in tool is gated for your session, this plugin may still reach
Fable via the Agent tool — `/fable-advisor:health` tells you which case you
are in. If Fable is blocked at the account/model-access level, no plugin can
conjure it; the fallback keeps the advisory workflow alive on Opus and labels
every degraded verdict so you never mistake Opus judgment for Fable judgment.
Degradation is detected two ways: a failed dispatch triggers the labeled Opus
retry, and a dispatch that *succeeds* on the wrong model is caught by the
MODEL line the advisor prints at the top of every verdict.

## License

[MIT](LICENSE) © Aziz (z13z4ck)

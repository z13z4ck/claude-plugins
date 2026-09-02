# fable-advisor — a Fable second-opinion agent for Claude Code

Run your session on any model. Consult a read-only Fable advisor for
architectural decisions, plan reviews, and stalled debugging. The advisor is
dispatched through the `fable` alias, so it tracks Claude Code's newest Fable
release — Fable 5.1 on Claude Code 2.1.257 or later, Fable 5 on older
versions and in Claude apps gateway sessions. Built as a replacement path for
sessions where Claude Code's built-in advisor tool is not attached: this
plugin dispatches Fable through the standard subagent mechanism instead, and
degrades to Opus with a clear label if Fable itself is refused. Same advisor
workflow as [advisor-select](../advisor-select), but the advisor model is
fixed to Fable instead of being a session-scoped choice.

## Components

| Component | Purpose |
|---|---|
| `agents/advisor.md` | Read-only advisor, `model: fable`, `effort: xhigh` — consultations are rare and high-stakes, so each one buys the deepest reasoning tier short of `max`. Reads files itself instead of trusting summaries. Every verdict starts with a MODEL line so a silently substituted model can't pass as Fable. |
| `/fable-advisor:consult <question>` | Deterministic consultation. `--model <alias>` overrides the advisor model per call. |
| `/fable-advisor:review-plan` | Critique the session's current plan before execution. Takes the same `--model <alias>` override as consult. |
| `/fable-advisor:health` | Verify Fable actually answers as itself and report which Fable version did; detects both failed dispatches and silent substitution, and reports whether the Opus fallback works. |

Effort is set in the agent's frontmatter because the Agent tool has no
per-invocation effort override (unlike `model`) — changing it means editing
`agents/advisor.md`. `xhigh` is valid on Fable 5.1 and on the Opus and
Sonnet fallbacks. Fable 5.1 deliberately takes longer turns at higher
effort, so a real consultation that reads several files can run for
minutes — that is the advisor working, not a hang. If that is too slow for
your workflow, `high` is the next step down and still ahead of what earlier
models reached at `xhigh`.

## Install

```
/plugin marketplace add z13z4ck/claude-plugins
/plugin install fable-advisor@z13z4ck-plugins
/fable-advisor:health        # run this FIRST — confirms Fable is reachable on your account
```

Fable 5.1 needs Claude Code 2.1.255 or later, and the `fable` alias resolves
to it from 2.1.257 (`claude update`). On plans where Fable bills to usage
credits, accept the one-time consent by running `/model fable` once before
the first consultation — otherwise a dismissed consent prompt hands the
dispatch to your default model (see below).

## When your session already runs on Fable

The advisor is a second opinion, not necessarily a stronger one. If your main
session is on Opus or Sonnet, the advisor escalates to Fable. If your main
session is itself on Fable 5.1, the advisor is the same model — what you get
is a fresh-context, read-only, file-grounded review with none of the
session's accumulated assumptions, which Anthropic's Fable guidance rates
above self-critique. That is still worth it before large plans; just don't
expect a capability jump.

## Fallback and substitution detection

If Fable is unavailable or refused, the commands retry once on `opus` (or
`sonnet`, if the model that failed was already `opus` via a `--model`
override) and label the verdict "ADVISOR RUNNING DEGRADED" — a degraded
verdict is never presented as Fable judgment. A dispatch that *succeeds* on
the wrong model is caught by the MODEL line the advisor prints at the top of
every verdict, and `/fable-advisor:health` treats "answered as another
model" as degraded, not as operational.

Since Claude Code 2.1.247 a successful-but-substituted dispatch is the
common failure, not the rare one, because Claude Code itself re-routes
subagents in several documented situations:

- **Safety-classifier fallback.** Fable 5.1 and Fable 5 run safety
  classifiers, most often on cybersecurity and biology content. A flagged
  request is re-run automatically — cyber on Opus 4.8, bio on Opus 5 — with
  a notice in the transcript. Security-flavored consultations are the
  likeliest trigger.
- **`fallbackModel` chain.** If you configure one, an overloaded or
  unavailable model no longer ends the subagent; it continues on the next
  model in the chain.
- **Usage-credits consent.** On plans where Fable bills to usage credits,
  dismissing the consent prompt continues the turn on your default model.
- **Forced subagent model.** `CLAUDE_CODE_SUBAGENT_MODEL` no longer
  overrides an agent's `model:` (since 2.1.251); only
  `CLAUDE_CODE_SUBAGENT_MODEL_FORCE` does.

In all four cases the MODEL line is the signal. `/tasks` also shows the
model and effort each subagent actually ran on, which is a useful
cross-check when a verdict looks off.

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

## About the built-in advisor being unavailable

Claude Code's built-in advisor tool and this plugin use different dispatch
paths. The built-in tool is silently *not attached* — `/advisor` and a
notification say so — when its pairing check fails, and the most common
reason since Fable 5.1 shipped is the pairing itself: a Fable 5.1 main
model accepts only a Fable 5.1 advisor, so a saved `advisorModel` of `opus`
or `sonnet` stops applying the moment you switch the session to Fable. The
other documented reasons are an organization `availableModels` allowlist
that excludes the advisor, the Fable usage-credits consent not yet
accepted, feature-flag fetching turned off (for example by
`DISABLE_TELEMETRY`), `CLAUDE_CODE_DISABLE_ADVISOR_TOOL=1`, and providers
other than the Anthropic API (Bedrock, Vertex, Foundry, and gateways that
don't forward the request intact).

This plugin sidesteps the pairing check, because a subagent's own model is
never paired against the session's. Two things to know if you keep both
paths: subagents inherit a configured `advisorModel` and re-run the pairing
check against their own model, so with `advisorModel: fable` set, the
plugin's Fable advisor may itself consult the built-in advisor mid-verdict
(`/advisor off` gives you one consultation per verdict). And if Fable is
blocked at the account level, no plugin can conjure it — the two hard blocks
are a model-access limit on the account, and zero data retention: Fable 5.1
and Fable 5 require 30-day retention and return a 400 to ZDR organizations
unless Anthropic has expressly authorized them. In both cases the fallback
keeps the advisory workflow alive on Opus and labels every degraded verdict
so you never mistake Opus judgment for Fable judgment.

## License

[MIT](../../LICENSE) © Aziz (z13z4ck)

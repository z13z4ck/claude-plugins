# fable-advisor — a Fable second-opinion agent for Claude Code

Run your session on any model. Consult a read-only Fable advisor for
architectural decisions, plan reviews, stalled debugging, and verification of
a change set before you finish. The advisor is dispatched through the `fable`
alias, so it tracks Claude Code's newest Fable release — Fable 5.1 on Claude
Code 2.1.257 or later, Fable 5 on older versions and in Claude apps gateway
sessions. Built as a replacement path for sessions where Claude Code's
built-in advisor tool is not attached: this plugin dispatches Fable through
the standard subagent mechanism instead, and degrades to Opus with a clear
label if Fable itself is refused.

Since 1.6.0 the plugin also **enforces** consultation. Hooks inject the
advisor policy into every session, gate `ExitPlanMode` on a consultation,
nudge when unreviewed edits pile up, and hold a turn that edited four or more
files without advice once at its end, with an instruction to get the change
set reviewed before finishing. No CLAUDE.md snippet is needed. Same advisor workflow as
[advisor-select](../advisor-select), but the advisor model is fixed to Fable
and the consultation is enforced rather than left to judgment.

## Components

| Component | Purpose |
|---|---|
| `agents/advisor.md` | Read-only advisor, `model: fable`, `effort: high` — enforcement makes consultation routine rather than rare, so the default buys a deep tier at a per-call cost you can afford one or two times a turn; `xhigh` is a one-line opt-up. Reads files itself instead of trusting summaries. Every verdict starts with a MODEL line so a silently substituted model can't pass as Fable. |
| `hooks/hooks.json` + `bin/` | Five enforcement hooks (below). Transcript-driven, fail-open, silent inside subagents. |
| `/fable-advisor:consult <question>` | Deterministic consultation. `--model <alias>` overrides the advisor model per call. |
| `/fable-advisor:review-plan` | Critique the session's current plan before execution. Takes the same `--model <alias>` override as consult. |
| `/fable-advisor:status` | How many consultations this session, which edits are still unreviewed, which hooks are active, and the last hook events. |
| `/fable-advisor:health` | Verify Fable actually answers as itself and report which Fable version did; detects both failed dispatches and silent substitution, and reports whether the Opus fallback works. |

Effort is set in the agent's frontmatter because the Agent tool has no
per-invocation effort override (unlike `model`) — changing it means editing
`agents/advisor.md`. The default is `high`. It was `xhigh` through 1.6.x,
when consultations were rare and opt-in; the enforcement hooks made them
routine — one or two per substantive turn — and at that cadence the
per-call cost is what matters, so 1.7.0 moved the default down one tier.
Fable 5.1 deliberately takes longer turns at higher effort, so even at
`high` a real consultation that reads several files can run for minutes —
that is the advisor working, not a hang. To buy the deepest tier short of
`max` back, set `effort: xhigh` in `agents/advisor.md`; it is valid on
Fable 5.1 and on the Opus and Sonnet fallbacks.

## Install

```
/plugin marketplace add z13z4ck/claude-plugins
/plugin install fable-advisor@z13z4ck-plugins
/fable-advisor:health        # run this FIRST — confirms Fable is reachable on your account
```

Hooks load at session start, so restart Claude Code after installing or
updating. Fable 5.1 needs Claude Code 2.1.255 or later, and the `fable`
alias resolves to it from 2.1.257 (`claude update`). On plans where Fable
bills to usage credits, accept the one-time consent by running `/model fable`
once before the first consultation — otherwise a dismissed consent prompt
hands the dispatch to your default model (see below). The hooks need
`python3` on `PATH`; without it every hook is a silent no-op and the plugin
falls back to description-driven consultation.

## Enforcement hooks

Claude Code decides on its own when to delegate to an agent by reading the
agent's `description`. That is real but not guaranteed, and the instruction
fades as context fills up. The hooks turn the policy into something the
harness applies:

| Hook | Event | What it does |
|---|---|---|
| Policy injection | `SessionStart` (startup, resume, clear, **compact**) | Puts the advisor policy — when to consult, how to dispatch, how to handle a degraded verdict — into context. Re-injected after every compaction, with a tally of consultations so far and files edited since the last one. |
| Prompt nudge | `UserPromptSubmit` | Recognises decision prompts ("should we", "which is better", "trade-offs"), planning prompts ("refactor", "migrate", "design"), stalled fixes ("still failing", "same error" — escalates on the second in a row) and review requests, and states that the policy applies to this turn. Also surfaces any unreviewed edits over the threshold. Silent on trivial prompts and slash commands. |
| Plan gate | `PreToolUse` on `ExitPlanMode` | **Denies** exiting plan mode until the advisor was dispatched during this planning episode (an `EnterPlanMode` call or a switch into plan mode starts one; a successful `ExitPlanMode` or a switch out of plan mode ends it — a denied attempt does not). Health checks don't count. Headless (`-p`) sessions have no `ExitPlanMode` tool, so this gate only ever fires interactively. After two denials it stops denying and only adds context, so a session where the Agent tool is unavailable cannot wedge; the normal plan-approval prompt still runs, so the user keeps their veto. |
| Edit watch | `PostToolUse` on `Edit`, `Write`, `MultiEdit`, `NotebookEdit`, `Bash` | Counts distinct files edited since the last consultation and nudges at every multiple of the threshold (4, 8, 12 …). Bash writes count too — heredocs, `>`/`>>` redirects, `tee`, `sed -i` — because sessions in bypass-permissions mode are steered to edit through Bash, which the Edit/Write tools never see. Temp and device paths, Claude's own plan files and memory notes are ignored. The same hook records advisor dispatches, so a consultation counts the moment it is made even before the transcript has caught up. |
| Stop audit | `Stop` | If the turn that is ending edited at least the threshold of distinct files and the advisor was not consulted during that turn, **holds the turn once** with an instruction to get a verification review of the change set. It is a hold, not a lock: after the model has acted on it (or explained why it could not), the next stop goes through. Honours `stop_hook_active`, never holds the same turn twice, and never fires inside a subagent. |

Ground truth is the session transcript on disk (the same JSONL
`/pause-resume:recover` reads), so a count cannot drift from what actually
happened. Because Claude Code flushes that file lazily — mid-turn it can lag
the tool calls by several entries — the `PostToolUse` hook also remembers
what it saw (files edited this turn, consultations dispatched) in a small
per-session state file, and every gate accepts either source. A consultation
is any `Agent` dispatch with `subagent_type: fable-advisor:advisor`,
whichever way it was triggered — autonomously, via `/fable-advisor:consult`,
or because a gate demanded it. Every hook fails open: an unexpected error
exits 0 with no output and a line in `events.log`.

### Configuration

Set these in the environment Claude Code runs in — the `env` block of
`settings.json` is the usual place.

| Variable | Default | Effect |
|---|---|---|
| `FABLE_ADVISOR_ENFORCE` | `full` | `nudge` keeps the context injection but never denies or holds; `off` silences every hook. |
| `FABLE_ADVISOR_FILE_THRESHOLD` | `4` | Distinct files that trigger the edit watch and the stop audit. The injected policy says "more than N−1 files" accordingly. |
| `FABLE_ADVISOR_PLAN_GATE` | `1` | `0` disables the `ExitPlanMode` gate. |
| `FABLE_ADVISOR_EDIT_WATCH` | `1` | `0` disables the edit-count nudge. |
| `FABLE_ADVISOR_STOP_AUDIT` | `1` | `0` disables the end-of-turn hold. |
| `FABLE_ADVISOR_PROMPT_NUDGE` | `1` | `0` disables per-prompt nudges. |
| `FABLE_ADVISOR_HOME` | `~/.claude/fable-advisor` | Where `events.log` and per-session state live. State files are reaped after 7 days. |

`~/.claude/fable-advisor/events.log` records every injection, nudge, denial,
release and hold with the session id, so you can see the hooks working;
`/fable-advisor:status` summarises the current session. The hooks have a
test suite: `bash plugins/fable-advisor/tests/run-tests.sh`.

### What this costs

Each consultation is one Fable dispatch at `high`, reading real files, so
expect minutes per consultation and one or two per substantive turn: a plan
review before edits, and a verification review at the end if the turn grew
past the threshold without one. Consulting early is cheaper than being held
later — a consultation anywhere in the same turn, plan review included,
satisfies the stop audit for that turn. If that cadence is too much for a
given project, `FABLE_ADVISOR_ENFORCE=nudge` keeps the reminders and drops
the gates.

## When your session already runs on Fable

The advisor is a second opinion, not necessarily a stronger one. If your main
session is on Opus or Sonnet, the advisor escalates to Fable. If your main
session is itself on Fable 5.1, the advisor is the same model — what you get
is a fresh-context, read-only, file-grounded review with none of the
session's accumulated assumptions, which Anthropic's Fable guidance rates
above self-critique. That is still worth it before large plans; just don't
expect a capability jump. And if your session runs at `xhigh`, note that the
default advisor is the same model at *lower* effort — a cheaper look, not a
deeper one. Set `effort: xhigh` in `agents/advisor.md` if you want parity.

## Fallback and substitution detection

If Fable is unavailable or refused, the commands retry once on `opus` (or
`sonnet`, if the model that failed was already `opus` via a `--model`
override) and label the verdict "ADVISOR RUNNING DEGRADED" — a degraded
verdict is never presented as Fable judgment. A dispatch that *succeeds* on
the wrong model is caught by the MODEL line the advisor prints at the top of
every verdict, and `/fable-advisor:health` treats "answered as another
model" as degraded, not as operational. The injected policy carries the same
rules, so autonomous consultations handle a degraded verdict the same way
the commands do.

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

## The four layers, in increasing reliability

1. **Agent description** — Claude Code's own delegation heuristic reads the
   trigger conditions in `agents/advisor.md` ("use PROACTIVELY", "MUST BE
   USED before …"). Autonomous, not guaranteed.
2. **Hooks** — the policy is in context every session and after every
   compaction, prompts that call for advice are flagged as they arrive, and
   the plan gate and stop audit refuse to let the two most consequential
   moments pass unadvised. Strongly steered, with hard stops.
3. **CLAUDE.md policy** — optional now, but still useful if you want the
   policy visible in the repo for people as well as for the model:

   ```markdown
   ## Advisor policy
   Before any architectural decision, any plan touching more than 3 files, or
   after two failed attempts at the same bug, consult the fable-advisor:advisor
   agent and present its verdict. If the built-in advisor tool is unavailable,
   use the fable-advisor:advisor agent — do not skip consultation because the
   built-in tool refused. Do not proceed on major decisions without either an
   advisor verdict or an explicit note that both advisor paths failed.
   ```

4. **Slash commands** — `/fable-advisor:consult` and
   `/fable-advisor:review-plan` when you want the consultation now,
   deterministically.

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

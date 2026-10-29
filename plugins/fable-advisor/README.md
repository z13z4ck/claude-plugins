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
set reviewed before finishing. Since 1.9.0 the first session on a device also
writes a short fallback policy block into your user-level CLAUDE.md, once
(see [layer 3](#the-four-layers-in-increasing-reliability)). Same advisor workflow as
[advisor-select](../advisor-select), but the advisor model is fixed to Fable
and the consultation is enforced rather than left to judgment.

## Components

| Component | Purpose |
|---|---|
| `agents/advisor.md` | Read-only advisor, `model: fable`, `effort: high` — enforcement makes consultation routine rather than rare, so the default buys a deep tier at a per-call cost you can afford one or two times a turn; `xhigh` is a one-line opt-up. Reads files itself instead of trusting summaries. Every verdict starts with a MODEL line so a silently substituted model can't pass as Fable. |
| `hooks/hooks.json` + `bin/` | Eight enforcement hooks (below). Transcript-driven and fail-open. Background workers of the types you list (default `feature-crew:feature-builder`) get their own policy, tally and end-of-run hold, and may not background a subagent; see [Subagents](#subagents). |
| `/fable-advisor:consult <question>` | Deterministic consultation. `--model <alias>` overrides the advisor model per call. |
| `/fable-advisor:review-plan` | Critique the session's current plan before execution. Takes the same `--model <alias>` override as consult. |
| `/fable-advisor:status` | How many consultations this session, which edits are still unreviewed, which hooks are active, and the last hook events. |
| `/fable-advisor:claude-md [install\|remove\|status]` | Show, (re)install or remove the advisor-policy block in your user-level CLAUDE.md. Never run by the model on its own. |
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
Python 3 on `PATH` (`python3`, or on Windows `python` / `py -3` — the Microsoft
Store `python3` stub is skipped); without it every hook is a silent no-op and
the plugin falls back to description-driven consultation.

## Enforcement hooks

Claude Code decides on its own when to delegate to an agent by reading the
agent's `description`. That is real but not guaranteed, and the instruction
fades as context fills up. The hooks turn the policy into something the
harness applies:

| Hook | Event | What it does |
|---|---|---|
| Policy injection | `SessionStart` (startup, resume, clear, **compact**) | Puts the advisor policy — when to consult, how to dispatch, how to handle a degraded verdict — into context. Re-injected after every compaction, with a tally of consultations so far and files edited since the last one. On `startup` only, also writes the [user CLAUDE.md block](#the-four-layers-in-increasing-reliability) once per device. |
| Prompt nudge | `UserPromptSubmit` | Recognises decision prompts ("should we", "which is better", "trade-offs"), planning prompts ("refactor", "migrate", "design"), stalled fixes ("still failing", "same error" — escalates on the second in a row) and review requests, and states that the policy applies to this turn. Also surfaces any unreviewed edits over the threshold. Silent on trivial prompts, slash commands, and harness messages such as a background agent's `<task-notification>` (which mentions "review" often enough to be mistaken for a request). Since 1.10.1 "end to end" no longer counts as planning, and "schema" and "extract" count only with change or refactor phrasing ("change the users schema", "extract the retry logic into its own module"), so "Verify X end to end" or "extract the zip" gets no nudge. |
| Plan gate | `PreToolUse` on `ExitPlanMode` | **Denies** exiting plan mode until the advisor was dispatched during this planning episode (an `EnterPlanMode` call or a switch into plan mode starts one; a successful `ExitPlanMode` or a switch out of plan mode ends it — a denied attempt does not). Health checks don't count. Headless (`-p`) sessions have no `ExitPlanMode` tool, so this gate only ever fires interactively. After two denials it stops denying and only adds context, so a session where the Agent tool is unavailable cannot wedge; the normal plan-approval prompt still runs, so the user keeps their veto. |
| Background gate | `PreToolUse` on `Agent`, `Task` | For enforced worker types only: **denies** an `Agent` (or `Task`) call with `run_in_background: true`, with a reason that says to re-send it in the foreground. A background subagent's completion notice is delivered to the top-level session, never to the worker that started it, so a worker that backgrounds its advisor and ends its turn waiting never wakes up (seen live: 68 minutes idle). Applies to every subagent type, not only the advisor. Background `Bash` and `Monitor` do wake the worker and are not touched; the main session and other subagents are never denied. A denied dispatch does not count as a consultation. It prevents a hang rather than a skipped consultation, so it stays on in `nudge` mode; only `off` disables it. |
| Edit watch | `PostToolUse` on `Edit`, `Write`, `MultiEdit`, `NotebookEdit`, `Bash` | Counts distinct files edited since the last consultation and nudges at every multiple of the threshold (4, 8, 12 …). Bash writes count too — heredocs, `>`/`>>` redirects, `tee`, `sed -i` — because sessions in bypass-permissions mode are steered to edit through Bash, which the Edit/Write tools never see. Temp and device paths, Claude's own plan files and memory notes are ignored. A `cd` is followed: relative writes after `cd /some/dir` are resolved against it (so a scratch dir under `/tmp` drops out), and relative writes after a `cd` it cannot resolve (`cd $DIR`, `cd -`) are skipped rather than guessed into the project; a `cd` inside `( … )` ends with the subshell. Relative Bash writes are resolved against the session's directory, so a file written by `Write` and later by `sed -i` counts once — and a project that itself lives under the temp dir is not enforced, through Bash or the Edit tools. The same hook records advisor dispatches, so a consultation counts the moment it is made even before the transcript has caught up. |
| Stop audit | `Stop` | If the turn that is ending edited at least the threshold of distinct files and the advisor was not consulted during that turn, **holds the turn once** with an instruction to get a verification review of the change set. It is a hold, not a lock: after the model has acted on it (or explained why it could not), the next stop goes through. Honours `stop_hook_active`, never holds the same turn twice, and never fires inside a subagent. |
| Worker policy | `SubagentStart` | For enforced worker types only: puts a worker version of the policy into the subagent before its first prompt — consult before design calls its brief doesn't settle and after two failed fixes, get a review of the committed diff before finishing a change of threshold+ files, and hand the advisor absolute paths, since it reads files only. Logs every subagent start with its raw `agent_type`. |
| Worker hold | `SubagentStop` | For enforced worker types only: if the worker edited at least the threshold of distinct files since **its own** last consultation (counted across resumes, not per prompt), **holds it once** and asks for a verification review before it reports. Skipped when the worker is stopping with `NEEDS-ANSWER` (the later `DONE` stop still catches it). Honours `stop_hook_active`. |

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
| `FABLE_ADVISOR_ENFORCE` | `full` | `nudge` keeps the context injection but never denies or holds, except the background gate, which prevents a stalled worker; `off` silences every hook. |
| `FABLE_ADVISOR_FILE_THRESHOLD` | `4` | Distinct files that trigger the edit watch and the stop audit. The injected policy says "more than N−1 files" accordingly. |
| `FABLE_ADVISOR_PLAN_GATE` | `1` | `0` disables the `ExitPlanMode` gate. |
| `FABLE_ADVISOR_EDIT_WATCH` | `1` | `0` disables the edit-count nudge. |
| `FABLE_ADVISOR_STOP_AUDIT` | `1` | `0` disables the end-of-turn hold. |
| `FABLE_ADVISOR_PROMPT_NUDGE` | `1` | `0` disables per-prompt nudges. |
| `FABLE_ADVISOR_SUBAGENTS` | `feature-crew:feature-builder` | Comma-separated subagent types enforced as workers (plugin-scoped name or bare frontmatter name). `none` turns worker enforcement off. |
| `FABLE_ADVISOR_SUBAGENT_STOP` | `1` | `0` disables the worker hold; the worker policy and nudges stay. |
| `FABLE_ADVISOR_CLAUDE_MD` | `1` | `0`/`off` stops the automatic advisor-policy block in your user-level CLAUDE.md. It does not remove a block already written — `/fable-advisor:claude-md remove` does. |
| `FABLE_ADVISOR_HOME` | `~/.claude/fable-advisor` | Where `events.log`, per-session state and the CLAUDE.md stamp (`claude-md.json`) live. State files are reaped after 7 days; the stamp is kept. |

`~/.claude/fable-advisor/events.log` records every injection, nudge, denial,
release and hold with the session id, so you can see the hooks working;
`/fable-advisor:status` summarises the current session. The hooks have a
test suite: `bash plugins/fable-advisor/tests/run-tests.sh`.

### Subagents

Claude Code reports a subagent's tool calls with the **parent's** session id
and transcript path, plus `agent_id` and `agent_type`; the subagent's own
transcript is `<parent>/subagents/agent-<id>.jsonl`. Before 1.8.0 the hooks
looked for `/subagents/` in the transcript path to stay out of subagents,
which current builds never send — so a subagent's edits were added to the
parent's tally and a subagent's advisor call counted as the parent's
consultation. Since 1.8.0 every subagent call is sorted into one of three
cases:

| Subagent | Treatment |
|---|---|
| An enforced worker type (`FABLE_ADVISOR_SUBAGENTS`) | Its own state file (`<session>--<agent_id>.json`) and its own transcript. Its edits, nudges, consultations and hold are its own and never count for the parent — a worker's review does not excuse the parent from its own, and a worker's edits never hold the parent. Since 1.10.0 it must dispatch the advisor and any other subagent in the foreground: the background gate denies `run_in_background: true`, and the worker policy says why. |
| The advisor itself | Silent. |
| Anything else (`general-purpose`, `Explore`, your own agents) | Counted for the parent, as before: it works in the parent's tree, so a turn that delegates six edits to a subagent is still held. |

Verified live on Claude Code 2.1.308 with a background `feature-builder`
that wrote four files and was told not to consult: `subagent-start
agent_type=feature-crew:feature-builder enforced=1`, an `edit-nudge` at four
files tagged with the worker's id, then `subagent-stop-hold` when it tried to
finish. The hold arrived in the worker's transcript as a `Stop hook
feedback` row, the worker wrote its diff, consulted the advisor, and
re-issued its DONE with `advisor: reviewed`; the parent got a single
completion notification and was never held for the worker's edits. One
thing the run surfaced: a worktree-isolated agent's git commands are refused
when they nest `$(git ...)`, so the worker policy and the hold give the diff
step as two plain `git -C <worktree>` commands with literal paths.

A later run (1.9.0) surfaced a stall: a worker dispatched the advisor with
`run_in_background: true` for a re-review and ended its turn "waiting on the
advisor". The advisor finished seven minutes later, but its completion notice
went to the top-level session, not to the worker, which sat idle for 68
minutes until the user stopped it. Since 1.10.0 the worker policy says to
dispatch in the foreground, and the background gate denies the call outright,
so the worker retries in the foreground and gets the result in its own turn.

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
3. **User CLAUDE.md block** — written for you. Plugins have no install
   hook, so the first session that starts on a device (`SessionStart` with
   source `startup`) appends a short block to your **user-level**
   `${CLAUDE_CONFIG_DIR:-~/.claude}/CLAUDE.md` — never a project's CLAUDE.md —
   between `<!-- fable-advisor:begin v1 -->` and `<!-- fable-advisor:end -->`.
   It is a fallback for sessions where the hooks did not run: it says to
   consult `fable-advisor:advisor` before design decisions and multi-file
   plans and after repeated failed fixes, and that an injected
   `[fable-advisor]` policy (the session policy, or a worker's) is
   authoritative whenever one is in context, so the two never conflict. It
   names no thresholds; the hooks own those. That first session's context
   says where the block went, and it takes effect from the next session
   (CLAUDE.md is read before hooks run).

   It is written once. A stamp in `FABLE_ADVISOR_HOME/claude-md.json` records
   the target path and block version, so if you delete the block it is
   **not** re-added. When a plugin update changes the block, an older
   version is replaced in place at the next startup. Nothing outside the
   markers is ever touched, a missing config dir is never created, and
   resume, clear and compact never write. `FABLE_ADVISOR_CLAUDE_MD=off` (or
   `FABLE_ADVISOR_ENFORCE=off`) stops the automatic write;
   `/fable-advisor:claude-md` shows the block's state, `install` writes or
   refreshes it even after you removed it, and `remove` deletes it (with the
   blank line it added; a file that had no final newline keeps the one added
   before the block) and keeps it from coming back. A stamp that cannot be
   read counts as "removed", never as "not written yet". A stray begin
   marker with no end marker anywhere in the file — say, in your own notes
   about this plugin — makes the file count as malformed: it is never
   rewritten, the automatic write stops, and `status` says so. There is no
   uninstall hook, so run `/fable-advisor:claude-md remove` before you
   uninstall the plugin; a leftover block is inert ("when the plugin is
   enabled") but stays in the file.

   On Windows the path is resolved like the rest of the plugin: a Git Bash
   `CLAUDE_CONFIG_DIR=/c/Users/you/.claude` is read as `C:/Users/you/.claude`,
   and the stamp compares paths case- and slash-insensitively. A CRLF file
   gets a CRLF block, a UTF-8 BOM is kept (and never added), and everything
   outside the markers stays byte for byte. A symlinked CLAUDE.md (dotfiles)
   keeps its link; the real file is updated. Writes are atomic; if the file
   is locked by an editor or antivirus, the hook retries briefly, then gives
   up without stamping, so the next startup tries again.

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

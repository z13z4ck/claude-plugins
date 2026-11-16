# feature-crew: orchestrator mode (core rules)

This session is the orchestrator. Background feature-crew workers build the
features and revisions the user asks for, so this conversation stays free.
Workers run on Sonnet or Opus, never on Fable: Fable is the advisor
(`fable-advisor:advisor`) only. This is the core; the full policy (path at
the end) holds the detailed procedures.

## Delegate, don't implement
- Building, changing, fixing or revising code that touches more than one file
  or takes more than a few minutes: dispatch a feature-crew worker. Handle
  questions, explanations, reviews and trivial one-line edits yourself.
- Workers never see this conversation. The brief is self-contained: goal,
  acceptance criteria, files/areas owned (including the relevant test files),
  files not to touch, branch `crew/<slug>`, base branch (always stated; the
  default branch unless chosen otherwise), every decision the user made, the
  verify command(s) (a quiet one for iterating and the full one, or "none
  exist"), and the tier line, e.g. "Tier: sonnet (rule 3)". Give each worker
  a short name.
- Run independent features in parallel; run workers that would touch the same
  files one after the other, or base the second on the first's branch.
- After dispatching, reply in one or two lines and end your turn. Never wait,
  sleep or poll: results arrive as notifications in later turns. Exception,
  for the 1-hour cache (a ping is ~1/40 of a miss): dispatching or resuming
  with no keep-alive pending, background Bash `sleep 2700`, description exactly
  `feature-crew keep-alive`. Its wake is not a worker event (no Read): reply
  in one line, re-arming only on `keep-alive: re-arm` with a worker still
  working (else mark the keep-alive item stopped, unless `duplicate chain`).

## Pick the worker tier

| Tier | Agent type | Agent `model` parameter |
|---|---|---|
| sonnet | `feature-crew:feature-builder-sonnet` (Sonnet, effort medium) | `sonnet` |
| opus | `feature-crew:feature-builder` (Opus, effort medium) | `opus` |
| deep | `feature-crew:feature-builder-deep` (Opus, effort xhigh) | `opus` |

First match decides:
1. The user named a model or tier: use it (nearest tier for others, and say
   so). Fable for a feature → deep tier, and tell the user Fable is the
   advisor only and the deep tier runs on Opus at effort xhigh.
2. Migration, schema or data model, concurrency, performance, security, or a
   cross-cutting refactor → deep.
3. Sonnet only if the brief names a verify command, names an existing pattern
   to copy, covers one area, and leaves no open decision.
4. Otherwise → opus.
Always pass the tier's alias as the Agent tool's `model` parameter too; never
pass `fable` or any other alias.

## Roster
One task-list item per worker: feature, name or ID, tier, branch, status
(running / waiting on you / under review / escalated / done / failed).
Update it on every event; re-read it after a compaction or resume.

## Worker events (one line each; details in the full policy)
- A `[feature-crew] worker <name> ...` model-check line with each report
  decides the model label: `as chosen` (name the model), `could not be
  confirmed` (say so), or `FELL BACK` (see rare events).
- **DONE** with every named full verify command run and passing: do the
  advisor check below, then report branch, changes, per-criterion results
  (as "reported") and open items in about five lines; mark it done.
- **NEEDS-ANSWER**: relay question and options verbatim, mark "waiting on
  you", and resume that same worker with SendMessage when the user answers.
- **No report** (no DONE/NEEDS-ANSWER block, no error, not stopped): resume it once with
  SendMessage asking for the block (not a ladder step); still none → failed DONE.
- **Failed or unverified DONE** (error, failed check, named full verify
  command not run): read the full policy's ladder first (a rare event below or a
  pre-existing failure replaces it);
  otherwise resume once, climb once to deep (never from deep), then ask.
- **Rare events** (read the full policy before acting on any): a rate-limit
  or overload error (one retry), a requested model unavailable or a `FELL
  BACK` line, no model-check line, a deep-tier worker failing again (the
  max-effort offer), a worker stopped by the user (save its patch at once).

## Review and merge
Never merge crew branches, push, or delete branches unless the user asks.

## With fable-advisor (when `fable-advisor:advisor` is available)
On DONE, count `git diff --name-only <base>...<branch> | wc -l` against the
original feature's base. Four or more files: accept only
`advisor: reviewed — ` with a Fable MODEL and a verdict (negatives listed as
fixed); otherwise run a fallback review yourself (verify log: the path in its DONE block). Under four files, also
review it if its `changed:` or `open:` names a migration, schema, new
dependency or public interface and its `advisor:` line says `not consulted`. A verdict asking for changes: offer the fix to the user,
never resume unasked. Never call a branch ready to merge while a review it
qualifies for is missing or against it.

## Full policy
Before the first dispatch or worker event after every session start,
compaction, resume or clear (an earlier Read does not survive a compaction),
and whenever handling a worker failure, an escalation, a model-check FELL
BACK line or a missing one, a stopped worker, a revision, a review or merge
request, or a fallback review, use the Read tool on the full policy at this
path (if the Read fails, tell the user):

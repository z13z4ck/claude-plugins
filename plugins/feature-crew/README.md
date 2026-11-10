# feature-crew — one session as an orchestrator for background feature work

You talk to one Claude Code session. Ask it for features or revisions; it
hands each one to a background `feature-builder` subagent working on its own
git branch in its own worktree, and your conversation stays free. The main
session keeps a roster, relays any worker's question to you, resumes that
worker with your answer, and tells you when each one is done.

No commands to learn. Install, enable in a project, and talk normally.

## Components

| Component | Purpose |
|---|---|
| `agents/feature-builder.md` | The worker. `background: true`, `isolation: worktree`, `model: fable`, `effort: high` (whatever the session uses). Branches as `crew/<slug>`, stays in its assigned files, plans a check per acceptance criterion before coding, consults `fable-advisor:advisor` itself when installed, runs its checks into a log outside the tree, commits, and ends with a fixed `DONE` or `NEEDS-ANSWER` block that carries `model:` and `advisor:` lines. |
| `agents/feature-builder-deep.md` | The escalation worker: the same prompt at `model: fable`, `effort: xhigh`. Never dispatched first; only when a `feature-builder`'s work still fails its checks after one resume (or it errored and can't be resumed) (see [Quality and escalation](#quality-and-escalation)). Plugin agent files cannot share text, so it is a copy: keep it identical to `feature-builder.md` apart from `name`, `description` and `effort` — `tests/run-tests.sh` fails if they drift. |
| `hooks/hooks.json` | One `SessionStart` hook, on every start source, that runs `bin/session-start.sh`. |
| `bin/session-start.sh` | Injects `policy/orchestrator.md` so the main session delegates instead of implementing, keeps a roster, and resumes workers with your answers. Adds a session note after `compact` (re-read the roster), and after `resume`, `fork` or `clear` (earlier workers are gone or out of reach; here are the `crew/*` branches that exist, with their worktrees). Outside a git work tree it prints a one-line "inactive" note instead, since workers need worktrees. Bash and git only, no jq or Python. |
| `policy/orchestrator.md` | The orchestrator rules. Edit this file to change how the main session behaves. |
| `tests/run-tests.sh` | `bash tests/run-tests.sh` — exercises the hook against throwaway repos and checks the plugin files agree. |

## Install

```
/plugin marketplace add z13z4ck/claude-plugins   # once
/plugin install feature-crew@z13z4ck-plugins
```

Restart Claude Code after installing: hooks load at session start.

Workers pin `model: fable`. On plans where Fable bills to usage credits,
run `/model fable` once and accept the consent before dispatching workers;
otherwise a worker may run on another model, and its DONE is flagged
WORKER RAN DEGRADED.

**Enable it per project, not globally.** The policy turns every session where
it is active into an orchestrator. Either install with project scope, or set
`FEATURE_CREW=off` in your user `settings.json` `env` block and
`FEATURE_CREW=on` in the projects where you want it.

## How it behaves

- **You:** "Build the credit balance API and the Livewire balance screen."
- **Main session:** dispatches two workers (`crew/credit-api`,
  `crew/credit-ui`), replies in two lines, ends its turn. You keep talking.
- **A worker hits a product decision:** it commits, ends with `NEEDS-ANSWER`;
  the main session shows you the question and options. You answer; the main
  session resumes the same worker with `SendMessage`.
- **A worker finishes:** you get branch, files changed, what it reports it
  ran, its advisor verdict, and open items.
- **With `fable-advisor` installed, workers consult it themselves:** before
  design decisions their brief doesn't settle, after two failed fixes, and
  for a verification review of their own diff when it touches 4+ files. They
  are the only ones who can — the advisor reads files by path, and the
  branch's files exist only in the worker's worktree. The main session checks
  each 4+-file DONE for a Fable verdict and runs the review itself, against
  the worker's worktree, if it is missing, degraded or unaddressed.
- **A worker's checks fail (or a named verify command wasn't run):** the main session resumes it
  once with the failure, then escalates to `feature-builder-deep`, then asks
  you (see below).
- **Revisions:** the main session resumes the original worker, or starts a new
  one from that feature's branch.
- **Merging:** never automatic. Ask the main session to review a branch; it
  won't call a branch ready while an advisor review it qualifies for is
  missing or negative.
- **Resuming the session later:** workers from the old conversation are gone.
  The session note lists the `crew/*` branches that exist, and the main
  session offers to continue unfinished ones from their branches.

## Quality and escalation

feature-crew 0.4 trades cost for output quality, following Anthropic's
model-selection guidance: workers run on Fable, and every claim of "done" is
tied to a check.

- **Workers on Fable at `high`.** `feature-builder` pins `model: fable`,
  `effort: high`, independent of the session's own model.
- **Run the orchestrator session on Fable at `high`, not `xhigh`.** Its
  leverage is the quality of its briefs and reviews, and it has to stay
  responsive while workers report in; `xhigh` makes every relay slower
  without making briefs better.
- **Verify-first briefs.** Each brief gives the worker ownership of the
  relevant test files and names the verify command(s) for the acceptance
  criteria, or says none exist. The worker plans a check per criterion
  before coding, runs the verify commands once as a baseline, writes check
  output with a header per run (baseline or post-change, command, commit)
  to `<gitdir>/crew-verify.log` (outside the tree), and hands that log to
  the advisor with its review diff. Its
  `verified:` line maps each criterion to evidence or to
  `not verified: <why>` — an honest answer when no meaningful check exists.
- **Degraded-model flag.** Each report carries a `model:` line naming the
  model the worker actually ran on. If a DONE names anything other than a
  Fable model (Fable unavailable on the account, consent dismissed, a
  fallback), the main session labels it **WORKER RAN DEGRADED** and tells
  you.
- **Escalation ladder.** When a verify command the brief named was not run
  or failed, or the worker errors: (1) the main session resumes that worker
  once with the failure evidence; (2) if it fails again, dispatches a fresh
  `feature-builder-deep` (`effort: xhigh`) from `crew/<slug>` on
  `crew/<slug>-deep` with the original brief plus what was tried; (3) if that
  fails too, it stops and asks you. Steps 1 and 2 happen without asking.
  Failures already present on the base branch that the brief didn't ask
  the worker to fix, or blocked by a missing tool, dependency or credential,
  are reported to you with the DONE instead of escalated. If the worker
  failed because Fable itself is unavailable (access, consent, billing,
  auth), or ran on another model, the main session asks you instead of
  escalating: the deep worker is pinned to Fable too and would hit the same
  wall. A rate-limit or overload error gets exactly one retry of the same
  worker and brief, then comes to you. A `-deep`
  branch is reviewed against the feature's original base, so the advisor
  sees the whole feature, not just the fix.
- **Token discipline (0.4.1).** In one measured 0.4.0 run the worker was
  about 60% of spend and the four advisor consultations inside it about
  36%, each re-reading the same files; the worker also pulled 800+ test
  results into its context. Since 0.4.1 a worker has a budget of two
  planned consultations: one on the design, only when the brief leaves a
  decision open, and one verification review of the final diff; mid-way
  only after two failed attempts at the same bug or an unexplained test
  failure. The review diff is written with `git diff -U25 <base>...HEAD` and
  the advisor starts from it, reads only the verify log's run headers and
  tail (or a grep of it for failures), and opens other files only where the
  diff lacks context. A re-review after a behaviour-changing fix, and a
  review after the worker is resumed following one, gets only the fix diff
  (`<reviewed-commit>..HEAD`); a worker that cannot name the reviewed commit
  sends the full diff instead. While iterating the worker runs only the
  affected tests with a failures-only reporter (each brief names that quiet
  command next to the full one where the project allows it); the full suite
  runs as the baseline and once more at the end. The worker reads only the
  tail of its verify log or a grep of it for failures. Pairs with fable-advisor
  1.10.3, which stops nudging workers mid-build and accepts a fix-diff
  review in its worker hold.

## Limits (from the Claude Code docs)

- Up to 20 subagents run at once per session by default
  (`CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS`).
- Background workers stop when the main session ends. Close it only after the
  roster is clear.
- Workers can't ask you questions directly (`AskUserQuestion` is removed from
  subagents); the `NEEDS-ANSWER` → `SendMessage` loop replaces it.
- Workers' permission prompts appear in the main session. Pre-allow your test
  and build commands in `permissions.allow` to keep them rare. Plugin agents
  ignore `permissionMode`, so this can't be set from the plugin.
- With `fable-advisor` 1.8.0 or later, workers are enforced by its hooks:
  each `feature-builder` gets the worker policy at start, a nudge at 4 files
  edited since its last consultation (none since fable-advisor 1.10.3, which
  keeps the count but no longer nudges workers), and one hold if it tries to
  finish 4+ unreviewed files. `feature-builder-deep` is enforced the same way from
  fable-advisor 1.10.2; on older versions add it to
  `FABLE_ADVISOR_SUBAGENTS`. Older fable-advisor versions don't enforce inside
  workers, so there the worker consults on instruction only. Either way the
  main session checks every 4+-file DONE for a verdict.
  Dispatching a brief does not need a consultation first unless the brief
  makes an architectural, data-model, interface or dependency decision you
  have not made.
- Workers dispatch the advisor, and any other subagent, in the foreground. A
  background subagent's completion notice goes to the main session, never to
  the worker that started it, so a worker that backgrounds its advisor and
  waits never wakes up. If such a notice does reach the main session, it
  forwards the result to the worker. From fable-advisor 1.10.0 its hooks deny
  a worker's background dispatch outright.
- A worker you stop cannot be resumed. The main session saves all of its
  uncommitted work, new and binary files included, as a patch and offers a
  new worker on `crew/<slug>-r<N>` that applies it.
- Workers reach the advisor as a nested subagent (worker = layer 1, advisor =
  layer 2). `CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH=1` turns that off; workers
  then report `advisor: not consulted` and the main session reviews instead.
- The main session checks the worker's review on every 4+-file DONE, but on
  smaller changes it only catches a skipped design consultation when the
  DONE names a migration, schema, new dependency or public interface.
- Revision branches (`crew/<slug>-r<N>`) are reviewed against the original
  feature's base before merge, so a chain of small revisions can't add up to
  an unreviewed large change.
- Workers are branched from the default branch, not the main session's HEAD,
  unless you set `worktree.baseRef` to `"head"` in settings. The policy has
  the main session state the base branch in every brief either way.
- Worktrees need git. Outside a git work tree the plugin stays inactive.
- Every worker draws on your plan's usage; N workers use it roughly N times as
  fast, and from 0.4.0 each one runs on Fable at `high` (an escalation at
  `xhigh`), which costs more per worker than the old inherit/medium default.
  To trade back, edit `model:` (and `effort:`) in `agents/feature-builder.md`
  and `model:` in `agents/feature-builder-deep.md` (the sync test allows only
  name, description and effort to differ) — and expect DONE reports to be
  flagged WORKER RAN DEGRADED off Fable.

## Housekeeping

Tested on Claude Code 2.1.310: a worker that made changes leaves its worktree
under `.claude/worktrees/agent-*` (checked out on its `crew/*` branch). Claude
Code also starts each worker on a `worktree-agent-*` branch; from 0.3.3 the
worker deletes that branch itself with `git branch -d` once it has switched
to `crew/*`, and says so under `open:` if git refuses. Workers from 0.3.2 and
earlier leave it behind.

- Add `.claude/worktrees/` to `.gitignore` so the main checkout stays clean.
- After merging or discarding a crew branch, remove its worktree and any
  leftover `worktree-agent-*` branch:

  ```bash
  git worktree list                       # find the agent-* path for the branch
  git worktree remove .claude/worktrees/agent-<id>
  git branch -d worktree-agent-<id>       # from the default branch, if it is still there
  ```

## Turn it off

`FEATURE_CREW=off` in the environment silences the policy hook; the
`feature-builder` agent stays available for explicit use.

## License

MIT © Aziz (z13z4ck)

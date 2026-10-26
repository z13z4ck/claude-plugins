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
| `agents/feature-builder.md` | The worker. `background: true`, `isolation: worktree`, `model: inherit`. Branches as `crew/<slug>`, stays in its assigned files, consults `fable-advisor:advisor` itself when installed, runs tests, commits, and ends with a fixed `DONE` or `NEEDS-ANSWER` block that carries an `advisor:` line. |
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
- **Revisions:** the main session resumes the original worker, or starts a new
  one from that feature's branch.
- **Merging:** never automatic. Ask the main session to review a branch; it
  won't call a branch ready while an advisor review it qualifies for is
  missing or negative.
- **Resuming the session later:** workers from the old conversation are gone.
  The session note lists the `crew/*` branches that exist, and the main
  session offers to continue unfinished ones from their branches.

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
  edited since its last consultation, and one hold if it tries to finish 4+
  unreviewed files. Older fable-advisor versions don't enforce inside
  workers, so there the worker consults on instruction only. Either way the
  main session checks every 4+-file DONE for a verdict.
  Dispatching a brief does not need a consultation first unless the brief
  makes an architectural, data-model, interface or dependency decision you
  have not made.
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
  fast.

## Housekeeping

Tested on Claude Code 2.1.310: a worker that made changes leaves its worktree
under `.claude/worktrees/agent-*` (checked out on its `crew/*` branch) plus an
unused `worktree-agent-*` branch Claude Code created for it.

- Add `.claude/worktrees/` to `.gitignore` so the main checkout stays clean.
- After merging or discarding a crew branch, remove its worktree and the
  leftover branch:

  ```bash
  git worktree list                       # find the agent-* path for the branch
  git worktree remove .claude/worktrees/agent-<id>
  git branch -D worktree-agent-<id>
  ```

## Turn it off

`FEATURE_CREW=off` in the environment silences the policy hook; the
`feature-builder` agent stays available for explicit use.

## License

MIT © Aziz (z13z4ck)

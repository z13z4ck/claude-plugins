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
| `agents/feature-builder.md` | The worker. `background: true`, `isolation: worktree`, `model: inherit`. Branches as `crew/<slug>`, stays in its assigned files, runs tests, commits, and ends with a fixed `DONE` or `NEEDS-ANSWER` block. |
| `hooks/hooks.json` | One `SessionStart` hook (startup, resume, clear, compact) that injects `policy/orchestrator.md` so the main session delegates instead of implementing, keeps a roster in the task list, and resumes workers with your answers. |
| `policy/orchestrator.md` | The orchestrator rules. Edit this file to change how the main session behaves. |

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
  ran, and open items.
- **Revisions:** the main session resumes the original worker, or starts a new
  one from that feature's branch.
- **Merging:** never automatic. Ask the main session to review a branch; with
  `fable-advisor` installed it sends branches with 4+ changed files to the
  advisor first.

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
- `fable-advisor`'s hooks deliberately stay silent inside subagents, so its
  enforcement does not apply to workers; the orchestrator policy compensates
  at review time.
- Workers are branched from the default branch, not the main session's HEAD.
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

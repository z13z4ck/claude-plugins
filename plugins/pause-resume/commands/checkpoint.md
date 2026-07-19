---
description: Write a resume brief for this session before disconnecting
argument-hint: "[note about what you are about to do]"
allowed-tools: Bash, Read, Write, Glob, Grep
---

Write a resume brief capturing where this session has got to, so the work can
be picked up later — by a future session, or by you after a reconnect.
User's note: $ARGUMENTS

The plugin can already rebuild a rough brief from the transcript automatically.
Yours should be better, because you know the *intent*: what the user is
actually trying to achieve, which decisions were already settled and should not
be relitigated, and what the next concrete step is. Aim for something a fresh
agent could act on without re-deriving your reasoning.

**1. Gather real state — do not write from memory alone.**

```bash
git status --short 2>/dev/null | head -40
git diff --stat 2>/dev/null | tail -20
git branch --show-current 2>/dev/null
```

**2. Write the brief** to the plugin's checkpoint directory:

```bash
CP_DIR="${CLAUDE_PAUSE_HOME:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/pause-resume}/checkpoints"
mkdir -p "$CP_DIR"
SLUG=$(pwd | sed 's/[^a-zA-Z0-9]/-/g')
echo "$CP_DIR/${SLUG}__${CLAUDE_CODE_SESSION_ID}.md"
```

Use the Write tool for the file itself. Cover, in prose and short lists:

- **Goal** — what the user is trying to achieve, in their terms, not a
  restatement of the last instruction.
- **Done** — what is finished and verified, distinguished from what is merely
  written. "Tests pass" and "code compiles" are different claims from "I wrote
  the function."
- **In flight** — the exact thing that was mid-way when work stopped, including
  any file left in a half-edited state. Be specific: this is the part that
  causes damage if it is guessed wrong.
- **Next** — the immediate next action, concretely enough to execute.
- **Decisions already made** — approaches chosen and, importantly, approaches
  already ruled out and why. This stops a resuming agent from re-proposing
  something the user already rejected.
- **Open questions** — anything you were going to ask the user.
- **Environment** — branch, uncommitted changes, running processes, anything
  started that must be cleaned up.

**3. Queue it for the next session** so it is offered automatically on restart:

```bash
PR_HOME="${CLAUDE_PAUSE_HOME:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/pause-resume}"
mkdir -p "$PR_HOME/pending"
printf '%s' "<the checkpoint path you wrote>" > "$PR_HOME/pending/$(pwd | sed 's/[^a-zA-Z0-9]/-/g')"
```

**4. Confirm** in two or three lines: where it was saved, and that the next
session in this directory will be offered it automatically. Mention
`agent-pause checkpoints` for listing saved briefs.

Be honest in the brief about uncertainty. A resume brief that overstates how
finished something is causes worse problems than one that admits a step was
never verified.

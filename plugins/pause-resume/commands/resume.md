---
description: Clear pause flags so held agents continue
argument-hint: "[session id] — omit to clear every pause flag"
allowed-tools: Bash(*/agent-pause:*), Bash(bash */agent-pause*)
---

Clear the pause state. Target: $ARGUMENTS (empty means all).

Note the limitation before you start: if *this* session were frozen, this
command could not be running — a frozen session is blocked inside a hook and
never gets to its queued input. So this command is for one of these cases:

- clearing a pause that was armed but has not fired yet
- clearing a stale flag left behind by a session that died
- continuing after the pause deadline expired and blocked a tool call
- releasing a *different* session from this one

Resolve the CLI, then run it — `${CLAUDE_PLUGIN_ROOT}` is not guaranteed to be
exported into the shell:

```bash
AP="$(command -v agent-pause 2>/dev/null)"
[ -z "$AP" ] && [ -x "${CLAUDE_PLUGIN_ROOT}/bin/agent-pause" ] && AP="${CLAUDE_PLUGIN_ROOT}/bin/agent-pause"
[ -z "$AP" ] && AP="$(find "$HOME/.claude/plugins" -name agent-pause -type f 2>/dev/null | head -1)"
"$AP" resume
```

Add `-s <session-id>` if they named one. If nothing resolves, point them at
`/pause-resume:install-cli` rather than guessing a path.

Then report what was cleared. If the output says nothing was paused, say so
plainly rather than implying something was fixed.

If a resume brief exists for this directory and the user seems to be picking up
interrupted work, offer to walk through it — but read the current state of any
files it mentions before acting on them. A brief describes what *was* true; the
working tree is what *is* true.

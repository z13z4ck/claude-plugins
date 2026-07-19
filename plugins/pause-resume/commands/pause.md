---
description: Freeze this session at its next tool call, optionally after a delay
argument-hint: "[in <duration>] [reason...] — e.g. 'in 10m boarding the train'"
allowed-tools: Bash(*/agent-pause:*), Bash(bash */agent-pause*)
---

The user wants to pause the agent. Their request: $ARGUMENTS

**Read this before acting — the timing matters.**

A pause set right now takes effect at your *very next tool call*, which means
you will freeze partway through this turn and the user will not see a
confirmation. That is almost never what they want when they type this command
interactively. So:

1. **Parse the request.** Look for a delay (`in 10m`, `in 30 minutes`, `after
   5m`) and a reason (everything else). Also look for `until online` /
   `when wifi is back`, which maps to `--until-online`.

2. **If they gave no delay, default to arming a short one** (`--in 2m`) rather
   than freezing instantly, unless they clearly said "now" / "immediately".
   Explain that you did so. An instant freeze from inside the session leaves
   them staring at a stalled terminal with no message.

3. **Resolve the CLI, then run it.** `${CLAUDE_PLUGIN_ROOT}` is not guaranteed
   to be exported into the shell, so fall back rather than assuming:

   ```bash
   AP="$(command -v agent-pause 2>/dev/null)"
   [ -z "$AP" ] && [ -x "${CLAUDE_PLUGIN_ROOT}/bin/agent-pause" ] && AP="${CLAUDE_PLUGIN_ROOT}/bin/agent-pause"
   [ -z "$AP" ] && AP="$(find "$HOME/.claude/plugins" -name agent-pause -type f 2>/dev/null | head -1)"
   "$AP" pause --in 2m -r "<reason>"
   ```

   If nothing resolves, tell them to run `/pause-resume:install-cli` and stop —
   do not improvise a path.

   Add `--until-online` for the connectivity case, `-m <dur>` if they set a
   ceiling, and `-s "${CLAUDE_CODE_SESSION_ID}"` if they want only this session
   frozen rather than every running agent.

4. **Tell them plainly how to get moving again**, because this part surprises
   people:

   > Once frozen, this session cannot process slash commands — the process is
   > blocked inside a hook, so anything you type here just queues. Resume from
   > **another terminal**:
   >
   > ```
   > agent-pause resume
   > ```
   >
   > (or `bash "${CLAUDE_PLUGIN_ROOT}/bin/agent-pause" resume` if you have not
   > run `/pause-resume:install-cli` yet)

5. If a long-running task is in flight, offer to write a checkpoint first with
   `/pause-resume:checkpoint`, so there is a readable brief if the session dies
   rather than merely pausing.

Keep the confirmation to a few lines. Do not restate the whole mechanism.

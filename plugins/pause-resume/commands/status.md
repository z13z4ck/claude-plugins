---
description: Show what is paused, frozen, and live right now
allowed-tools: Bash(*/agent-pause:*), Bash(bash */agent-pause*)
---

Report the current pause state.

```bash
AP="$(command -v agent-pause 2>/dev/null)"
[ -z "$AP" ] && [ -x "${CLAUDE_PLUGIN_ROOT}/bin/agent-pause" ] && AP="${CLAUDE_PLUGIN_ROOT}/bin/agent-pause"
[ -z "$AP" ] && AP="$(find "$HOME/.claude/plugins" -name agent-pause -type f 2>/dev/null | head -1)"
"$AP" status
```

Summarise the output in a couple of lines rather than pasting it wholesale.
The things worth calling out:

- whether anything is paused at all, and whether it is a global pause or one
  targeted at a single session
- any session frozen right now, which tool it is held at, and for how long
- how long until a pause hits its deadline, if one is close
- whether the network is currently reachable — relevant if a pause is in
  `until-online` mode, since that is what will thaw it

If a flag is set but no session is frozen, explain the difference plainly: the
flag is armed and waiting, and the next agent to reach a tool call will stop
there. That distinction confuses people who expect `status` to show an effect
immediately.

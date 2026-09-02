---
description: Show how often the advisor was consulted this session, which edits are still unreviewed, and which enforcement hooks are active
argument-hint: (no arguments)
allowed-tools: Bash(bash:*)
---

Report on advisor utilization for this session.

1. Run exactly this with the Bash tool and show its output to the user
   verbatim in a code block:

   ```
   bash "${CLAUDE_PLUGIN_ROOT}/bin/hook.sh" status
   ```

   If `${CLAUDE_PLUGIN_ROOT}` was not substituted, the plugin is installed
   under `~/.claude/plugins/cache/<marketplace>/fable-advisor/<version>/` —
   run `bin/hook.sh status` from the newest version directory there.
2. If the report says the session is over the file threshold with no
   consultation, offer to run `/fable-advisor:consult` on the pending change
   set now. Do not edit anything as part of this command.

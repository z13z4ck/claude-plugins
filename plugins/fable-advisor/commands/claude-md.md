---
description: Show, install or remove the advisor-policy block fable-advisor writes into your user-level CLAUDE.md
argument-hint: [install|remove|status]
disable-model-invocation: true
allowed-tools: Bash(bash:*)
---

Manage the fable-advisor block in the user-level CLAUDE.md
(`${CLAUDE_CONFIG_DIR:-~/.claude}/CLAUDE.md`). The action is `$ARGUMENTS`;
with no argument it is `status`.

1. Run exactly this with the Bash tool (use `status` in place of
   `$ARGUMENTS` if it is empty) and show its output to the user verbatim in a
   code block:

   ```
   bash "${CLAUDE_PLUGIN_ROOT}/bin/hook.sh" claude-md $ARGUMENTS
   ```

   If `${CLAUDE_PLUGIN_ROOT}` was not substituted, the plugin is installed
   under `~/.claude/plugins/cache/<marketplace>/fable-advisor/<version>/` —
   run `bin/hook.sh claude-md <action>` from the newest version directory
   there.
2. Do not edit CLAUDE.md yourself, and do nothing else as part of this
   command. `install` writes or refreshes the block (even after a `remove`),
   `remove` deletes it and keeps it from being re-added at startup, `status`
   changes nothing. A change takes effect from the next session.

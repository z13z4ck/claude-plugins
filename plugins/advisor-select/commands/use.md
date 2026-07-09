---
description: Select which model advises this session (opus, sonnet, haiku, or fable)
argument-hint: [opus|sonnet|haiku|fable] — no argument shows the current selection and asks
---

The user wants to set the advisor model for this session to: $ARGUMENTS

Do the following:

1. Read the current selection (empty output means no selection yet, so the
   default `opus` applies):

   ```bash
   cat "${TMPDIR:-/tmp}/claude-advisor-model-${CLAUDE_CODE_SESSION_ID}" 2>/dev/null
   ```

2. If no argument was given: report the current selection, then ask the user
   to pick one of `opus`, `sonnet`, `haiku`, `fable` (use the AskUserQuestion
   tool, with the current selection listed first). Briefly note the
   trade-off in each option's description: fable = strongest but may be
   gated on some accounts, opus = strong default, sonnet = fast and capable,
   haiku = cheapest.

3. Validate the choice. Only the four aliases `opus`, `sonnet`, `haiku`,
   `fable` are accepted — they are what the Agent tool's model parameter
   takes, and each alias tracks the newest model of its tier. If the user
   gave a full model ID (e.g. `claude-opus-4-8`), map it to its alias and
   tell them you did so. If it maps to nothing, list the valid options and
   stop — do not write anything.

4. Persist the selection for this session:

   ```bash
   printf '%s' "<alias>" > "${TMPDIR:-/tmp}/claude-advisor-model-${CLAUDE_CODE_SESSION_ID}"
   ```

   If `CLAUDE_CODE_SESSION_ID` is empty in this environment, skip the file
   write, keep the selection in conversation only, and warn the user that it
   may not survive context compaction.

5. Confirm in one or two lines: which model now advises this session, and
   that the main conversation model is unchanged. If the user selected
   `fable`, suggest running `/advisor-select:health` once to confirm it is
   actually reachable on this account.

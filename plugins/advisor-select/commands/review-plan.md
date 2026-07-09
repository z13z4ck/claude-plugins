---
description: Send the current plan to the session-selected advisor for critique before executing it
argument-hint: [optional extra context]
---

Before executing, get the current plan reviewed. Extra context from the user:
$ARGUMENTS

1. Resolve which model advises this session:

   ```bash
   cat "${TMPDIR:-/tmp}/claude-advisor-model-${CLAUDE_CODE_SESSION_ID}" 2>/dev/null
   ```

   If the file is missing or empty, use `opus`.

2. Assemble the most recent plan from this conversation: goals, ordered
   steps, files to be touched, and assumptions. If there is no explicit plan
   yet, tell the user that and stop — do not invent one just to have it
   reviewed.

3. Dispatch `advisor-select:advisor` with the plan, the file paths involved,
   and the instruction to critique it: wrong assumptions, missing steps,
   ordering risks, cheaper alternatives. Pass the resolved model explicitly
   as the model parameter.

4. FALLBACK: if the dispatch fails because the model is unavailable or
   refused, retry ONCE with `opus` — or `sonnet` if the resolved model
   already was `opus` — and label the result "ADVISOR RUNNING DEGRADED —
   <selected model> was unavailable." If both fail, report the exact errors
   and stop.

5. Check the advisor's MODEL line: if it reports anything other than the
   model you dispatched, prepend the same DEGRADED warning naming the model
   that actually answered. Present the advisor's verdict intact. Apply its
   changes to the plan only after the user agrees; where you think the
   advisor is wrong, say so explicitly rather than silently ignoring the
   finding.

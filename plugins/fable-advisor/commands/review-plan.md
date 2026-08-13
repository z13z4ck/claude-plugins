---
description: Send the current plan to the Fable advisor for critique before executing it
argument-hint: "[optional extra context] [--model <alias>]"
---

Before executing, get the current plan reviewed. Extra context from the user:
$ARGUMENTS

1. Assemble the most recent plan from this conversation: goals, ordered steps,
   files to be touched, and assumptions. If there is no explicit plan yet,
   tell the user that and stop — do not invent one just to have it reviewed.
2. Dispatch `fable-advisor:advisor` with the plan, the file paths involved,
   and the instruction to critique it: wrong assumptions, missing steps,
   ordering risks, cheaper alternatives. If the user passed `--model <value>`,
   pass that as the model parameter for this invocation; otherwise pass model
   `fable` explicitly.
3. FALLBACK: if the dispatch fails because the model is unavailable or
   refused, retry ONCE with a fallback: `opus` (the alias) — or `sonnet` if
   the model that just failed already was `opus` — and label the result
   "ADVISOR RUNNING DEGRADED — <requested model> was unavailable." If both
   fail, report the exact errors and stop.
4. Check the advisor's MODEL line: if it reports anything other than the
   model you dispatched, prepend the same DEGRADED warning
   naming the model that actually answered. Present the advisor's verdict
   intact. Apply its changes to the plan only after the user agrees; where
   you think the advisor is wrong, say so explicitly rather than silently
   ignoring the finding.

---
description: Verify the advisor is reachable and confirm which model actually answered
argument-hint: (no arguments)
disable-model-invocation: true
---

Health-check the advisor pipeline:

1. Dispatch the `fable-advisor:advisor` agent, passing model `fable`
   explicitly, with this exact task: "Health check. Do not read any files.
   Reply with one line: ADVISOR OK, then state which model you are and your
   knowledge cutoff."
2. Report to the user, verbatim: whether the dispatch succeeded, the agent's
   one-line reply, and any error message if it failed.
3. If the fable dispatch failed — or succeeded but the reply names a model
   other than Fable — repeat once with model `opus` (the alias) and report
   that result too, clearly labeled as the fallback path.
4. Conclude with one line, one of:
   - "Fable advisor operational" — the agent's reply names Fable
   - "Degraded: Fable refused or was substituted, fallback to Opus works
     (likely a model-access limit on this account/session)"
   - "Advisor pipeline broken: both dispatches failed."

   Compare the agent's self-reported model against `fable` to decide which
   case applies: a dispatch that succeeds but answers as another model is a
   silent substitution, not a healthy pipeline. Do not speculate beyond the
   observed errors.

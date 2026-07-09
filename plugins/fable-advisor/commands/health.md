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
3. If the fable dispatch failed, repeat once with model `opus` (the alias)
   and report that result too, clearly labeled as the fallback path.
4. Conclude with one line: either "Fable advisor operational", "Degraded:
   fallback to Opus works, Fable refused (likely a model-access limit on this
   account/session)", or "Advisor pipeline broken: both dispatches failed."
   Do not speculate beyond the observed errors.

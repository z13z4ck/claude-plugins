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
   - "Fable advisor operational (<Fable version the reply named>)" — the
     agent's reply names Fable. On Claude Code 2.1.257 or later the `fable`
     alias resolves to Fable 5.1; a reply naming Fable 5 means an older
     Claude Code or a gateway session where the alias still maps to Fable 5.
     Say which, but that is still operational, not degraded.
   - "Degraded: Fable refused or was substituted, fallback to Opus works"
     — only if the fallback reply actually names Opus. Append the likely
     cause when the error text or a transcript notice shows one: a
     model-access limit on this account/session, the organization lacking
     the 30-day data retention Fable requires, or the Fable usage-credits
     consent not yet accepted (fixed by running `/model fable` once and
     choosing to continue on Fable).
   - "Advisor pipeline broken: both dispatches failed, or neither reply
     names the model that was dispatched."

   Compare each reply's self-reported model against the model dispatched for
   that attempt: a dispatch that succeeds but answers as another model is a
   silent substitution, not a healthy pipeline — and that applies to the
   fallback dispatch too. Claude Code itself causes such substitutions: its
   safety-classifier fallback re-runs a refused Fable request on Opus, a
   configured `fallbackModel` chain lets a subagent continue on another
   model after an overload, and a dismissed usage-credits prompt continues
   the turn on the default model. `/tasks` shows the model and effort each
   subagent actually ran on; point the user there as a cross-check. Do not
   speculate beyond the observed errors and transcript notices.

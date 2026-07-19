---
description: Consult the Fable advisor on a decision, plan, or stalled problem (falls back to Opus if Fable is unavailable)
argument-hint: <question or decision> [--model <alias>]
---

The user wants a second opinion from the advisor agent on: $ARGUMENTS

Do the following:

1. Build a consultation brief for the `fable-advisor:advisor` agent containing:
   - The question or decision, verbatim
   - Relevant constraints the user has stated in this conversation
   - Exact file paths and symbol names involved (list them explicitly — the
     advisor will read the files itself, so paths matter more than summaries)
   - What has already been tried and how it failed, if this is a stalled
     problem
2. Dispatch the `fable-advisor:advisor` agent with that brief. If the user
   passed `--model <value>`, pass that as the model parameter for this
   invocation; otherwise pass model `fable` explicitly.
3. FALLBACK: if the dispatch fails because the model is unavailable, refused,
   or not permitted in this session, retry ONCE with a fallback: `opus` (the
   alias, so it tracks the newest Opus) — or `sonnet` if the model that just
   failed already was `opus`. Prepend to your report: "ADVISOR RUNNING
   DEGRADED — <requested model> was unavailable, this verdict is from
   <fallback model>." Never silently substitute the model, and never abandon
   the consultation because the first dispatch failed. If both dispatches
   fail, report both exact error messages to the user and ask how to proceed.
4. When the advisor reports back, check its MODEL line first: if it reports
   anything other than the model you dispatched, the model was silently
   substituted — prepend the same DEGRADED warning naming the model that
   actually answered. Then present its VERDICT and RISKS sections
   intact, state whether you agree, and if you disagree, say why in one or
   two sentences before asking the user which direction to take.
5. Do not begin implementing the advisor's recommendation until the user
   confirms.

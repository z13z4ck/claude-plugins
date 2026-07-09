---
description: Consult the session-selected advisor model on a decision, plan, or stalled problem
argument-hint: <question or decision> [--model <alias>]
---

The user wants a second opinion from the advisor agent on: $ARGUMENTS

Do the following:

1. Resolve which model advises this session:
   - If the user passed `--model <value>`, that wins for this invocation.
   - Otherwise read the session selection:

     ```bash
     cat "${TMPDIR:-/tmp}/claude-advisor-model-${CLAUDE_CODE_SESSION_ID}" 2>/dev/null
     ```

   - If the file is missing or empty, use `opus`.

2. Build a consultation brief for the `advisor-select:advisor` agent
   containing:
   - The question or decision, verbatim
   - Relevant constraints the user has stated in this conversation
   - Exact file paths and symbol names involved (list them explicitly — the
     advisor will read the files itself, so paths matter more than summaries)
   - What has already been tried and how it failed, if this is a stalled
     problem

3. Dispatch the `advisor-select:advisor` agent with that brief, passing the
   resolved model explicitly as the model parameter.

4. FALLBACK: if the dispatch fails because the model is unavailable,
   refused, or not permitted in this session, retry ONCE with a fallback:
   `opus` — or `sonnet` if the resolved model already was `opus`. Prepend to
   your report: "ADVISOR RUNNING DEGRADED — <selected model> was
   unavailable, this verdict is from <fallback model>." Never silently
   substitute the model, and never abandon the consultation because the
   first dispatch failed. If both dispatches fail, report both exact error
   messages to the user and ask how to proceed.

5. When the advisor reports back, check its MODEL line first: if it reports
   anything other than the model you dispatched, the model was silently
   substituted — prepend the same DEGRADED warning naming the model that
   actually answered. Then present its VERDICT and RISKS sections intact,
   state whether you agree, and if you disagree, say why in one or two
   sentences before asking the user which direction to take.

6. Do not begin implementing the advisor's recommendation until the user
   confirms.

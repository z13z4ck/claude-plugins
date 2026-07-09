---
description: Show the session's advisor selection and verify that model actually answers
argument-hint: (no arguments)
disable-model-invocation: true
---

Health-check the advisor pipeline:

1. Resolve the session selection:

   ```bash
   cat "${TMPDIR:-/tmp}/claude-advisor-model-${CLAUDE_CODE_SESSION_ID}" 2>/dev/null
   ```

   If the file is missing or empty, the effective selection is the default
   `opus`. Report the selection and whether it came from the session file or
   the default.

2. Dispatch the `advisor-select:advisor` agent, passing the resolved model
   explicitly, with this exact task: "Health check. Do not read any files.
   Reply with one line: ADVISOR OK, then state which model you are and your
   knowledge cutoff."

3. Report to the user, verbatim: whether the dispatch succeeded, the agent's
   one-line reply, and any error message if it failed.

4. If the dispatch failed, repeat once with the fallback (`opus`, or
   `sonnet` if the selection already was `opus`) and report that result too,
   clearly labeled as the fallback path.

5. Conclude with one line, one of:
   - "Advisor operational on <model>" — the selected model answered as
     itself
   - "Degraded: <selected model> refused or was substituted, fallback to
     <fallback model> works (likely a model-access limit on this
     account/session)"
   - "Advisor pipeline broken: both dispatches failed."

   Compare the agent's self-reported model against the selection to decide
   which case applies. Do not speculate beyond the observed errors.

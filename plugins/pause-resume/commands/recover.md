---
description: Rebuild a resume brief from a session that was cut off
argument-hint: "[session id or transcript path] — omit for the most recent in this directory"
allowed-tools: Bash, Read
---

A previous session died before it could save anything — dropped connection,
closed laptop, killed process. Reconstruct what it was doing. Target:
$ARGUMENTS

This works because Claude Code appends every turn to a transcript on disk as it
happens, so even a hard kill leaves the history intact. Nothing was lost; it
just was not summarised.

**1. Find the transcript.** If the user gave a session id, use it directly:

```bash
SLUG=$(pwd | sed 's/[^a-zA-Z0-9]/-/g')
ls -lt "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/$SLUG/"*.jsonl 2>/dev/null | head -10
```

The newest file that is *not* the current session (`${CLAUDE_CODE_SESSION_ID}`)
is usually the one they mean. If several are plausible, show the list with
timestamps and ask which — do not guess when the choice is ambiguous.

**2. Rebuild the brief:**

```bash
MK="${CLAUDE_PLUGIN_ROOT}/bin/make-checkpoint.py"
[ -f "$MK" ] || MK="$(find "$HOME/.claude/plugins" -name make-checkpoint.py -type f 2>/dev/null | head -1)"
python3 "$MK" --transcript "<path>" --note "Recovered after an interrupted session"
```

Add `--out <path>` to save it. Without `--transcript`, pass `--cwd "$(pwd)"` to
take the newest transcript for this directory automatically.

**3. Read it, then verify it against reality.** This is the part that matters.
The brief reports what the old session *believed*; the working tree is what is
actually true, and the two diverge exactly where the interruption happened —
a file may be half-written, an edit may have landed after the last recorded
turn, a command may have completed without its result being logged.

So check the files it lists and the git state before drawing conclusions:

```bash
git status --short | head -30
git diff --stat | tail -20
```

**4. Report to the user** in a short paragraph or two: what that session was
working on, how far it got, what looks incomplete in the working tree right
now, and what you would do next. Flag any mismatch between the brief and the
files explicitly — that gap is the most useful thing you can tell them.

Then stop and let them decide whether to continue. Do not resume the old work
on your own initiative; they may have moved on, or fixed it themselves.

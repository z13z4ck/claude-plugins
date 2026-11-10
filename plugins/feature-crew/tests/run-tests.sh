#!/usr/bin/env bash
# Self-contained tests for the feature-crew plugin.
#
# Runs the SessionStart hook against throwaway git repos with crafted hook
# input, and checks the plugin's files agree with each other. Needs only bash
# and git. Run: bash tests/run-tests.sh
set -u

PLUGIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$PLUGIN/bin/session-start.sh"
PASS=0
FAIL=0

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ok() {
  PASS=$((PASS + 1))
  printf '  \033[32mPASS\033[0m %s\n' "$1"
}
no() {
  FAIL=$((FAIL + 1))
  printf '  \033[31mFAIL\033[0m %s\n' "$1"
  [ $# -gt 1 ] && printf '       \033[90m%s\033[0m\n' "$2"
  return 0
}

# Run the hook. $1 = source ("" to omit), $2 = cwd. Extra env goes before the
# call: FEATURE_CREW=off run_hook ... Sets OUT and RC.
OUT=""
RC=0
run_hook() {
  local inp
  if [ -n "$1" ]; then
    inp="$(printf '{"session_id":"t","hook_event_name":"SessionStart","cwd":"%s","source":"%s"}' "$2" "$1")"
  else
    inp="$(printf '{"session_id":"t","hook_event_name":"SessionStart","cwd":"%s"}' "$2")"
  fi
  OUT="$(cd "$2" && printf '%s' "$inp" | CLAUDE_PLUGIN_ROOT="$PLUGIN" bash "$HOOK" 2>&1)"
  RC=$?
}

has() { case "$OUT" in *"$1"*) return 0 ;; esac; return 1; }

git_quiet() { git -c init.defaultBranch=main -c user.email=t@t -c user.name=t "$@" >/dev/null 2>&1; }

REPO="$TMP/repo"
mkdir -p "$REPO"
git_quiet -C "$REPO" init
git_quiet -C "$REPO" commit --allow-empty -m "init"
git_quiet -C "$REPO" branch crew/credit-api
git_quiet -C "$REPO" worktree add "$TMP/wt-ui" -b crew/credit-ui
git_quiet -C "$TMP/wt-ui" commit --allow-empty -m "Add balance screen"
git_quiet -C "$REPO" branch other/not-crew

PLAIN="$TMP/plain"
mkdir -p "$PLAIN"

echo "hook output"

run_hook startup "$REPO"
if [ "$RC" -eq 0 ] && has "# feature-crew: orchestrator mode" && ! has "Session note"; then
  ok "startup in a git repo prints the policy, no session note"
else
  no "startup in a git repo prints the policy, no session note" "rc=$RC"
fi

run_hook "" "$REPO"
if [ "$RC" -eq 0 ] && has "orchestrator mode" && ! has "Session note"; then
  ok "missing source is treated as startup"
else
  no "missing source is treated as startup" "rc=$RC"
fi

FEATURE_CREW=off run_hook startup "$REPO"
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
  ok "FEATURE_CREW=off prints nothing"
else
  no "FEATURE_CREW=off prints nothing" "rc=$RC out=${OUT:0:80}"
fi

run_hook startup "$PLAIN"
if [ "$RC" -eq 0 ] && has "Inactive here" && ! has "orchestrator mode"; then
  ok "outside a git repo: one-line inactive note, no policy"
else
  no "outside a git repo: one-line inactive note, no policy" "rc=$RC out=${OUT:0:80}"
fi

run_hook compact "$REPO"
if has "orchestrator mode" && has "context was just compacted" && has "still running" && ! has "Crew branches"; then
  ok "compact: policy + re-read roster, no branch list"
else
  no "compact: policy + re-read roster, no branch list"
fi

run_hook resume "$REPO"
if has "orchestrator mode" && has 'started from "resume"' && has "stopped when it ended" &&
  has "crew/credit-api" && has "crew/credit-ui" && ! has "other/not-crew"; then
  ok "resume: stale-roster warning and only crew/* branches listed"
else
  no "resume: stale-roster warning and only crew/* branches listed" "${OUT##*Session note}"
fi

if printf '%s\n' "$OUT" | grep -q "crew/credit-ui .*Add balance screen.*\[worktree: .*wt-ui\]"; then
  ok "resume: branch line carries subject and its worktree path"
else
  no "resume: branch line carries subject and its worktree path" "$(printf '%s\n' "$OUT" | grep credit-ui)"
fi

if printf '%s\n' "$OUT" | grep "crew/credit-api" | grep -qv "worktree:"; then
  ok "resume: branch with no worktree has no worktree tag"
else
  no "resume: branch with no worktree has no worktree tag"
fi

run_hook fork "$REPO"
if has 'started from "fork"' && has "stopped when it ended" && has "crew/credit-api"; then
  ok "fork is treated like resume"
else
  no "fork is treated like resume"
fi

run_hook clear "$REPO"
if has 'started from "clear"' && has "stopped when it ended" && has "crew/credit-ui"; then
  ok "clear is treated like resume (/clear ends the session)"
else
  no "clear is treated like resume (/clear ends the session)"
fi

# A tag with a crew branch's name must not break the branch name or the
# worktree join (refname:short would print heads/crew/credit-ui).
git_quiet -C "$REPO" tag crew/credit-ui
run_hook resume "$REPO"
if printf '%s\n' "$OUT" | grep -q "^- crew/credit-ui .*\[worktree: "; then
  ok "a same-named tag does not mangle the branch line"
else
  no "a same-named tag does not mangle the branch line" "$(printf '%s\n' "$OUT" | grep credit-ui)"
fi

MANY="$TMP/many"
mkdir -p "$MANY"
git_quiet -C "$MANY" init
git_quiet -C "$MANY" commit --allow-empty -m "init"
i=1
while [ "$i" -le 30 ]; do
  git_quiet -C "$MANY" branch "crew/f$i"
  i=$((i + 1))
done
run_hook resume "$MANY"
n="$(printf '%s\n' "$OUT" | grep -c '^- crew/')"
if [ "$n" -eq 25 ]; then ok "branch list is capped at 25"; else no "branch list is capped at 25" "got $n"; fi

EMPTY="$TMP/empty"
mkdir -p "$EMPTY"
git_quiet -C "$EMPTY" init
git_quiet -C "$EMPTY" commit --allow-empty -m "init"
run_hook resume "$EMPTY"
if has "No crew/* branches exist"; then
  ok "resume with no crew branches says so"
else
  no "resume with no crew branches says so"
fi

# cwd in the input wins over the process directory, and a bogus cwd falls
# back to the process directory instead of failing.
OUT="$(cd "$PLAIN" && printf '{"cwd":"%s","source":"startup"}' "$REPO" | CLAUDE_PLUGIN_ROOT="$PLUGIN" bash "$HOOK")"
if has "orchestrator mode"; then ok "cwd from hook input is used"; else no "cwd from hook input is used"; fi
OUT="$(cd "$REPO" && printf '{"cwd":"/no/such/dir","source":"startup"}' | CLAUDE_PLUGIN_ROOT="$PLUGIN" bash "$HOOK")"
if has "orchestrator mode"; then ok "missing cwd dir falls back to the process dir"; else no "missing cwd dir falls back to the process dir"; fi

# Windows paths arrive JSON-escaped (C:\\Users\\x); the hook must unescape
# them. A directory with a backslash in its name stands in for one on macOS
# and Linux; Git Bash cannot create one, so it is skipped there.
case "$(uname -s)" in
  MINGW* | MSYS*) echo "  SKIP backslash cwd is unescaped (Git Bash cannot make the dir)" ;;
  *)
    BS="$TMP/back\\slash"
    mkdir -p "$BS"
    git_quiet -C "$BS" init
    esc="$(printf '%s' "$BS" | sed 's/\\/\\\\/g')"
    OUT="$(cd "$PLAIN" && printf '{"source":"startup","cwd":"%s"}' "$esc" | CLAUDE_PLUGIN_ROOT="$PLUGIN" bash "$HOOK")"
    if has "orchestrator mode"; then ok "backslash cwd is unescaped"; else no "backslash cwd is unescaped" "${OUT:0:80}"; fi
    ;;
esac

# Only the first "cwd" counts, even if a later field also carries one.
OUT="$(cd "$PLAIN" && printf '{"cwd":"%s","tool_input":{"cwd":"%s"},"source":"startup"}' "$REPO" "$PLAIN" | CLAUDE_PLUGIN_ROOT="$PLUGIN" bash "$HOOK")"
if has "orchestrator mode"; then ok "first cwd in the input wins"; else no "first cwd in the input wins"; fi

OUT="$(cd "$REPO" && printf 'not json' | CLAUDE_PLUGIN_ROOT="$PLUGIN" bash "$HOOK")"
RC=$?
if [ "$RC" -eq 0 ] && has "orchestrator mode"; then ok "garbage stdin still yields the policy"; else no "garbage stdin still yields the policy"; fi

OUT="$(cd "$REPO" && printf '{"source":"startup"}' | CLAUDE_PLUGIN_ROOT="$TMP/nowhere" bash "$HOOK")"
RC=$?
if [ "$RC" -eq 0 ] && has "Policy file missing"; then ok "missing policy file is reported, exit 0"; else no "missing policy file is reported, exit 0"; fi

# has_phrase <file> <phrase>: fixed-string match after folding every run of
# whitespace (newlines included) to one space in both, so re-wrapping prose
# in a policy or agent file can never break a check.
has_phrase() {
  local text want
  text="$(tr '\r\n\t' '   ' <"$1" | tr -s ' ')"
  want="$(printf '%s' "$2" | tr '\r\n\t' '   ' | tr -s ' ')"
  case "$text" in *"$want"*) return 0 ;; *) return 1 ;; esac
}

echo "plugin files"

if grep -q 'bash \\"${CLAUDE_PLUGIN_ROOT}/bin/session-start.sh\\"' "$PLUGIN/hooks/hooks.json"; then
  ok "hooks.json runs bin/session-start.sh through bash"
else
  no "hooks.json runs bin/session-start.sh through bash"
fi

if ! grep -q '"hooks"' "$PLUGIN/.claude-plugin/plugin.json"; then
  ok "plugin.json has no hooks key (hooks/hooks.json is auto-loaded)"
else
  no "plugin.json has no hooks key (hooks/hooks.json is auto-loaded)"
fi

fm="$(sed -n '2,/^---$/p' "$PLUGIN/agents/feature-builder.md")"
case "$fm" in
  *"name: feature-builder"*"background: true"*"isolation: worktree"*) ok "worker frontmatter: name, background, worktree isolation" ;;
  *) no "worker frontmatter: name, background, worktree isolation" ;;
esac

# 0.4.0: quality over cost. Workers pin Fable; the first dispatch runs at
# high, the escalation worker at xhigh.
fm_line() { sed -n '2,/^---$/p' "$1" | grep -x "$2" >/dev/null; }
if fm_line "$PLUGIN/agents/feature-builder.md" "model: fable" && fm_line "$PLUGIN/agents/feature-builder.md" "effort: high"; then
  ok "feature-builder runs on model: fable at effort: high"
else
  no "feature-builder runs on model: fable at effort: high" "$(sed -n '2,/^---$/p' "$PLUGIN/agents/feature-builder.md" | grep -E '^(model|effort):')"
fi

D="$PLUGIN/agents/feature-builder-deep.md"
if [ -f "$D" ] && fm_line "$D" "name: feature-builder-deep" && fm_line "$D" "model: fable" &&
  fm_line "$D" "effort: xhigh" && fm_line "$D" "background: true" && fm_line "$D" "isolation: worktree"; then
  ok "feature-builder-deep: own name, model: fable, effort: xhigh, background, worktree"
else
  no "feature-builder-deep: own name, model: fable, effort: xhigh, background, worktree"
fi

if [ -f "$D" ] && sed -n '2,/^---$/p' "$D" | grep -qi "escalation"; then
  ok "feature-builder-deep's description marks it escalation-only"
else
  no "feature-builder-deep's description marks it escalation-only"
fi

# Plugin agent files cannot include shared text, so the deep worker is a copy.
# Strip the three lines allowed to differ (name, the folded description block,
# effort) and the rest must match byte for byte.
strip_fm_diffs() {
  awk '
    /^---$/ { fences++ }
    fences == 1 && /^description:/ { skip = 1; next }
    fences == 1 && skip && /^  / { next }
    { skip = 0 }
    fences == 1 && (/^name: / || /^effort: /) { next }
    { print }
  ' "$1"
}
if [ -f "$D" ] && [ "$(strip_fm_diffs "$PLUGIN/agents/feature-builder.md")" = "$(strip_fm_diffs "$D")" ]; then
  ok "feature-builder-deep matches feature-builder apart from name, description, effort"
else
  no "feature-builder-deep matches feature-builder apart from name, description, effort" \
    "$(diff <(strip_fm_diffs "$PLUGIN/agents/feature-builder.md") <(strip_fm_diffs "$D") 2>&1 | head -5)"
fi

if has_phrase "$PLUGIN/policy/orchestrator.md" "feature-crew:feature-builder" &&
  has_phrase "$PLUGIN/policy/orchestrator.md" "fable-advisor:advisor"; then
  ok "policy names the worker and the advisor by their qualified agent names"
else
  no "policy names the worker and the advisor by their qualified agent names"
fi

W="$PLUGIN/agents/feature-builder.md"
if has_phrase "$W" 'subagent_type: "fable-advisor:advisor"' && has_phrase "$W" "absolute-git-dir"; then
  ok "worker consults the advisor and writes its review diff outside the tree"
else
  no "worker consults the advisor and writes its review diff outside the tree"
fi

if [ "$(grep -c '^advisor: ' "$W")" -eq 2 ]; then
  ok "both final blocks (DONE, NEEDS-ANSWER) carry an advisor: line"
else
  no "both final blocks (DONE, NEEDS-ANSWER) carry an advisor: line" "found $(grep -c '^advisor: ' "$W")"
fi

if [ "$(grep -c '^model: <' "$W")" -eq 2 ]; then
  ok "both final blocks (DONE, NEEDS-ANSWER) carry a model: line"
else
  no "both final blocks (DONE, NEEDS-ANSWER) carry a model: line" "found $(grep -c '^model: <' "$W")"
fi

if has_phrase "$PLUGIN/policy/orchestrator.md" "WORKER RAN DEGRADED" && has_phrase "$PLUGIN/policy/orchestrator.md" "model:"; then
  ok "orchestrator flags a DONE whose model: is not Fable as WORKER RAN DEGRADED"
else
  no "orchestrator flags a DONE whose model: is not Fable as WORKER RAN DEGRADED"
fi

# A deep worker is pinned to Fable too: escalating a Fable-unavailable or
# degraded run would hit the same wall, so the orchestrator asks instead.
O="$PLUGIN/policy/orchestrator.md"
if has_phrase "$O" "Fable unavailable (check before step 1)" &&
  has_phrase "$O" "skip the whole ladder: no resume, no \`feature-builder-deep\`" &&
  has_phrase "$O" "would hit the same wall" &&
  has_phrase "$O" "billing or authentication error"; then
  ok "orchestrator asks instead of escalating when Fable is unavailable or the worker ran degraded"
else
  no "orchestrator asks instead of escalating when Fable is unavailable or the worker ran degraded"
fi

# Rate-limit/overload errors are transient: exactly one retry of the same
# worker and brief, never the ladder, then the user.
if has_phrase "$O" "Transient error (check before step 1)" &&
  has_phrase "$O" "rate-limit or overload error, retry exactly once per feature" &&
  has_phrase "$O" "same worker type with the same brief" &&
  has_phrase "$O" "unless the Transient-error or Fable-unavailable rule above applies" &&
  has_phrase "$O" "do not climb the ladder on transient errors" &&
  ! has_phrase "$O" "billing, rate-limit or overload error"; then
  ok "orchestrator retries a rate-limit/overload failure once, then asks; billing/auth go straight to the user"
else
  no "orchestrator retries a rate-limit/overload failure once, then asks; billing/auth go straight to the user"
fi

# has_phrase itself: a phrase split across a line break still matches.
printf 'alpha beta\ngamma   delta\n' >"$TMP/wrap.txt"
if has_phrase "$TMP/wrap.txt" "beta gamma delta" && ! has_phrase "$TMP/wrap.txt" "beta delta"; then
  ok "phrase checks fold line wraps and repeated spaces"
else
  no "phrase checks fold line wraps and repeated spaces"
fi

# Verify-first: a check per criterion planned before coding, evidence per
# criterion in DONE, output in a log outside the tree that the advisor reads.
if has_phrase "$W" "proves each acceptance criterion" && has_phrase "$W" "crew-verify.log" &&
  has_phrase "$W" "per acceptance criterion" && has_phrase "$W" "not verified: <why>"; then
  ok "worker plans checks per criterion, logs output outside the tree, maps criteria to evidence"
else
  no "worker plans checks per criterion, logs output outside the tree, maps criteria to evidence"
fi

r7="$(sed -n '/^7\. \*\*Review/,/^8\. /p' "$W")"
case "$r7" in
  *crew-review.diff*crew-verify.log*) ok "worker hands the advisor its verify log with the review diff" ;;
  *) no "worker hands the advisor its verify log with the review diff" ;;
esac

O="$PLUGIN/policy/orchestrator.md"
if has_phrase "$O" "names the verify command" && has_phrase "$O" "ownership of the test files"; then
  ok "orchestrator briefs grant test-file ownership and name verify commands"
else
  no "orchestrator briefs grant test-file ownership and name verify commands"
fi

if has_phrase "$O" "feature-crew:feature-builder-deep" && has_phrase "$O" "crew/<slug>-deep" &&
  has_phrase "$O" "Resume the same worker once" && has_phrase "$O" "ask the user how to proceed" &&
  has_phrase "$O" "baseline run"; then
  ok "orchestrator escalates: resume once, then feature-builder-deep on crew/<slug>-deep, then ask"
else
  no "orchestrator escalates: resume once, then feature-builder-deep on crew/<slug>-deep, then ask"
fi

steps="$(grep -o '^[0-9]\. \*\*' "$W" | cut -c1 | tr -d '\n')"
if [ "$steps" = 12345678 ]; then ok "worker steps are numbered 1-8 in order"; else no "worker steps are numbered 1-8 in order" "got $steps"; fi

# Claude Code's worktree guard refuses nested $(git ...) in an isolated
# worker (seen live), so the worker's instructions must not use it.
if ! grep -q '"\$(git ' "$W" && has_phrase "$W" 'git -C <worktree> rev-parse --absolute-git-dir'; then
  ok "worker's diff instructions use plain git -C commands, no nested \$(git ...)"
else
  no "worker's diff instructions use plain git -C commands, no nested \$(git ...)"
fi

# The review must come after the commit: <base>...HEAD only sees commits.
c="$(grep -n '^6\. \*\*Commit' "$W" | cut -d: -f1)"
r="$(grep -n '^7\. \*\*Review' "$W" | cut -d: -f1)"
if [ -n "$c" ] && [ -n "$r" ] && [ "$c" -lt "$r" ]; then
  ok "worker reviews after committing"
else
  no "worker reviews after committing" "commit=$c review=$r"
fi

if has_phrase "$PLUGIN/policy/orchestrator.md" "accept only \`advisor: reviewed" && has_phrase "$W" "advisor: <one of: reviewed"; then
  ok "orchestrator accepts only a 'reviewed' advisor line, which the worker can emit"
else
  no "orchestrator accepts only a 'reviewed' advisor line, which the worker can emit"
fi

if has_phrase "$PLUGIN/policy/orchestrator.md" "Fallback review" && has_phrase "$PLUGIN/policy/orchestrator.md" "worktree list --porcelain"; then
  ok "orchestrator falls back to its own review against the worker's worktree"
else
  no "orchestrator falls back to its own review against the worker's worktree"
fi

# A background subagent's completion notice goes to the top-level session,
# never to the worker that started it: a worker that backgrounds its advisor
# and ends its turn waiting stalls for good (seen live: 68 minutes).
if has_phrase "$W" "FOREGROUND" && has_phrase "$W" "run_in_background"; then
  ok "worker dispatches the advisor and other subagents in the foreground"
else
  no "worker dispatches the advisor and other subagents in the foreground"
fi

if has_phrase "$W" "ask it once more only if a fix changed"; then
  ok "worker re-asks the advisor only after a behaviour change"
else
  no "worker re-asks the advisor only after a behaviour change"
fi

# isolation: worktree starts each worker on a Claude Code-made
# worktree-agent-<id> branch, abandoned once it switches to crew/<slug> (seen
# live: one leftover per worker). The worker deletes it, safely only.
if has_phrase "$W" "worktree-agent-" && has_phrase "$W" "git branch -d"; then
  ok "worker deletes its worktree-agent-* starting branch with git branch -d"
else
  no "worker deletes its worktree-agent-* starting branch with git branch -d"
fi

if ! has_phrase "$W" "git branch -D"; then
  ok "worker never force-deletes a branch (no git branch -D)"
else
  no "worker never force-deletes a branch (no git branch -D)"
fi

# Resumed workers repeated open: items the orchestrator had already handled.
if has_phrase "$W" "re-check every item"; then
  ok "worker re-checks its open: items on a revision"
else
  no "worker re-checks its open: items on a revision"
fi

if has_phrase "$PLUGIN/policy/orchestrator.md" "Stopped by the user" &&
  has_phrase "$PLUGIN/policy/orchestrator.md" "arrives here instead of in its worker" &&
  has_phrase "$PLUGIN/policy/orchestrator.md" "diff --cached --binary"; then
  ok "orchestrator handles stopped workers and forwards misrouted subagent results"
else
  no "orchestrator handles stopped workers and forwards misrouted subagent results"
fi

# 0.4.1: token discipline. A two-consultation advisor budget, diff-first
# reviews with a fix-diff re-review, quiet checks, and a quiet verify command
# in each brief. No "smaller slices" rule (dropped by design).
if has_phrase "$W" "at most two planned consultations" && has_phrase "$W" "one on the design" &&
  has_phrase "$W" "one verification review of your final diff" &&
  has_phrase "$W" "Consult mid-way only after two failed attempts" &&
  ! has_phrase "$W" "two viable approaches"; then
  ok "worker states the two-consultation advisor budget, no two-approaches trigger"
else
  no "worker states the two-consultation advisor budget, no two-approaches trigger"
fi

if has_phrase "$W" "diff -U25 <base>...HEAD > <gitdir>/crew-review.diff" &&
  has_phrase "$W" "start from the diff and the log" &&
  has_phrase "$W" "diff <reviewed-commit>..HEAD > <gitdir>/crew-fix.diff"; then
  ok "worker sends a -U25 diff first and re-reviews only the fix diff"
else
  no "worker sends a -U25 diff first and re-reviews only the fix diff"
fi

r5="$(sed -n '/^5\. \*\*Verify/,/^6\. /p' "$W")"
if printf '%s\n' "$r5" >"$TMP/r5.txt" && has_phrase "$TMP/r5.txt" "only the tests affected by your change" &&
  has_phrase "$TMP/r5.txt" "failures-only reporter" && has_phrase "$TMP/r5.txt" "full suite once" &&
  has_phrase "$TMP/r5.txt" "tail -n 40 <gitdir>/crew-verify.log" &&
  [ "$(grep -c 'crew-verify.log' "$TMP/r5.txt")" -le 3 ]; then
  ok "worker keeps check output out of context (quiet checks, tail -n 40)"
else
  no "worker keeps check output out of context (quiet checks, tail -n 40)"
fi

if has_phrase "$O" "quiet one the worker runs while iterating" && has_phrase "$O" "failures-only"; then
  ok "orchestrator briefs name a quiet verify command next to the full one"
else
  no "orchestrator briefs name a quiet verify command next to the full one"
fi

if ! grep -rqi 'smaller slice' "$PLUGIN/agents" "$PLUGIN/policy"; then
  ok "no smaller-slices rule"
else
  no "no smaller-slices rule"
fi

if grep -rl $'\r' "$PLUGIN" >/dev/null 2>&1; then
  no "no CRLF line endings in the plugin" "$(grep -rl $'\r' "$PLUGIN")"
else
  ok "no CRLF line endings in the plugin"
fi

echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

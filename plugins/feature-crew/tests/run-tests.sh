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

if grep -q "feature-crew:feature-builder" "$PLUGIN/policy/orchestrator.md" &&
  grep -q "fable-advisor:advisor" "$PLUGIN/policy/orchestrator.md"; then
  ok "policy names the worker and the advisor by their qualified agent names"
else
  no "policy names the worker and the advisor by their qualified agent names"
fi

W="$PLUGIN/agents/feature-builder.md"
if grep -q 'subagent_type: "fable-advisor:advisor"' "$W" && grep -q "absolute-git-dir" "$W"; then
  ok "worker consults the advisor and writes its review diff outside the tree"
else
  no "worker consults the advisor and writes its review diff outside the tree"
fi

if [ "$(grep -c '^advisor: ' "$W")" -eq 2 ]; then
  ok "both final blocks (DONE, NEEDS-ANSWER) carry an advisor: line"
else
  no "both final blocks (DONE, NEEDS-ANSWER) carry an advisor: line" "found $(grep -c '^advisor: ' "$W")"
fi

steps="$(grep -o '^[0-9]\. \*\*' "$W" | cut -c1 | tr -d '\n')"
if [ "$steps" = 12345678 ]; then ok "worker steps are numbered 1-8 in order"; else no "worker steps are numbered 1-8 in order" "got $steps"; fi

# The review must come after the commit: <base>...HEAD only sees commits.
c="$(grep -n '^6\. \*\*Commit' "$W" | cut -d: -f1)"
r="$(grep -n '^7\. \*\*Review' "$W" | cut -d: -f1)"
if [ -n "$c" ] && [ -n "$r" ] && [ "$c" -lt "$r" ]; then
  ok "worker reviews after committing"
else
  no "worker reviews after committing" "commit=$c review=$r"
fi

if grep -q "accept only \`advisor: reviewed" "$PLUGIN/policy/orchestrator.md" && grep -q "advisor: <one of: reviewed" "$W"; then
  ok "orchestrator accepts only a 'reviewed' advisor line, which the worker can emit"
else
  no "orchestrator accepts only a 'reviewed' advisor line, which the worker can emit"
fi

if grep -q "Fallback review" "$PLUGIN/policy/orchestrator.md" && grep -q "worktree list --porcelain" "$PLUGIN/policy/orchestrator.md"; then
  ok "orchestrator falls back to its own review against the worker's worktree"
else
  no "orchestrator falls back to its own review against the worker's worktree"
fi

if grep -rl $'\r' "$PLUGIN" >/dev/null 2>&1; then
  no "no CRLF line endings in the plugin" "$(grep -rl $'\r' "$PLUGIN")"
else
  ok "no CRLF line endings in the plugin"
fi

echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

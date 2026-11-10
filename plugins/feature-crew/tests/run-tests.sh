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

if python3 - "$PLUGIN/hooks/hooks.json" <<'PY' 2>/dev/null
import json, sys
h = json.load(open(sys.argv[1]))["hooks"]
cmds = [x["command"] for e in h["UserPromptSubmit"] for x in e["hooks"]]
assert cmds == ['bash "${CLAUDE_PLUGIN_ROOT}/bin/model-check.sh"'], cmds
assert set(h) == {"SessionStart", "UserPromptSubmit"}, set(h)
PY
then
  ok "hooks.json registers the UserPromptSubmit model check through bash, no SubagentStop"
else
  no "hooks.json registers the UserPromptSubmit model check through bash, no SubagentStop"
fi

if grep -q '"version": "0.5.0"' "$PLUGIN/.claude-plugin/plugin.json" &&
  ! grep -qi 'on Fable' "$PLUGIN/.claude-plugin/plugin.json"; then
  ok "plugin.json is 0.5.0 and no longer says workers run on Fable"
else
  no "plugin.json is 0.5.0 and no longer says workers run on Fable"
fi

if grep -q 'for c in python3 python "py -3"' "$PLUGIN/bin/model-check.sh" &&
  grep -q 'FEATURE_CREW:-on' "$PLUGIN/bin/model-check.sh" && grep -q 'PYTHONUTF8=1' "$PLUGIN/bin/model-check.sh"; then
  ok "model-check.sh probes for a working interpreter on Windows and honours FEATURE_CREW=off"
else
  no "model-check.sh probes for a working interpreter on Windows and honours FEATURE_CREW=off"
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

# 0.5.0: three tiers, same prompt. feature-builder-sonnet (sonnet/medium),
# feature-builder (opus/medium), feature-builder-deep (fable/high).
fm_line() { sed -n '2,/^---$/p' "$1" | grep -x "$2" >/dev/null; }
S="$PLUGIN/agents/feature-builder-sonnet.md"
D="$PLUGIN/agents/feature-builder-deep.md"
tier_ok() {
  [ -f "$1" ] && fm_line "$1" "name: $2" && fm_line "$1" "model: $3" && fm_line "$1" "effort: $4" &&
    fm_line "$1" "background: true" && fm_line "$1" "isolation: worktree"
}
for spec in "feature-builder-sonnet sonnet medium" "feature-builder opus medium" "feature-builder-deep fable high"; do
  set -- $spec
  if tier_ok "$PLUGIN/agents/$1.md" "$1" "$2" "$3"; then
    ok "$1: own name, model: $2, effort: $3, background, worktree"
  else
    no "$1: own name, model: $2, effort: $3, background, worktree" \
      "$(sed -n '2,/^---$/p' "$PLUGIN/agents/$1.md" 2>&1 | grep -E '^(name|model|effort):')"
  fi
done

# The deep worker is both the fable-tier first dispatch and the climb target,
# no longer escalation-only.
dd="$(sed -n '2,/^---$/p' "$D" 2>/dev/null)"
case "$dd" in
  *"Escalation-only"* | *"Do NOT use it for"*) no "feature-builder-deep's description is no longer escalation-only" ;;
  *"Fable tier"*"fable trigger"*"climb"*) ok "feature-builder-deep's description: fable-tier first dispatch and the climb target" ;;
  *) no "feature-builder-deep's description: fable-tier first dispatch and the climb target" ;;
esac

sd="$(sed -n '2,/^---$/p' "$S" 2>/dev/null | tr '\n' ' ' | tr -s ' ')"
case "$sd" in
  *"Sonnet tier"*"verify command"*"pattern to copy"*"one area"*"no open decision"*) ok "feature-builder-sonnet's description states the sonnet routing conditions" ;;
  *) no "feature-builder-sonnet's description states the sonnet routing conditions" ;;
esac

# Plugin agent files cannot include shared text, so the tiers are copies.
# Strip the lines allowed to differ (name, the folded description block,
# model, effort) and the rest must match byte for byte.
strip_fm_diffs() {
  awk '
    /^---$/ { fences++ }
    fences == 1 && /^description:/ { skip = 1; next }
    fences == 1 && skip && /^  / { next }
    { skip = 0 }
    fences == 1 && (/^name: / || /^model: / || /^effort: /) { next }
    { print }
  ' "$1"
}
for t in "$S" "$D"; do
  if [ -f "$t" ] && [ "$(strip_fm_diffs "$PLUGIN/agents/feature-builder.md")" = "$(strip_fm_diffs "$t")" ]; then
    ok "$(basename "$t" .md) matches feature-builder apart from name, description, model, effort"
  else
    no "$(basename "$t" .md) matches feature-builder apart from name, description, model, effort" \
      "$(diff <(strip_fm_diffs "$PLUGIN/agents/feature-builder.md") <(strip_fm_diffs "$t") 2>&1 | head -5)"
  fi
done
if [ "$(ls "$PLUGIN/agents" | wc -l | tr -d ' ')" -eq 3 ]; then
  ok "exactly three worker agent files"
else
  no "exactly three worker agent files" "$(ls "$PLUGIN/agents")"
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

# 0.5.0: the label comes from the model-check hook line, not the worker's
# model: line, and a fallback reads WORKER FELL BACK TO <model>.
O="$PLUGIN/policy/orchestrator.md"
if has_phrase "$O" "WORKER FELL BACK TO <model>" && ! has_phrase "$O" "WORKER RAN DEGRADED" &&
  has_phrase "$O" "not the worker's \`model:\` line (informational only), decides the label" &&
  has_phrase "$O" "as chosen (<tier> tier)" && has_phrase "$O" "FELL BACK: requested <tier>, ran <model>" &&
  has_phrase "$O" "model could not be confirmed"; then
  ok "orchestrator labels from the model-check line: as chosen / WORKER FELL BACK TO / unconfirmed"
else
  no "orchestrator labels from the model-check line: as chosen / WORKER FELL BACK TO / unconfirmed"
fi

if has_phrase "$O" "If no \`[feature-crew]\` line arrives with the report, run the check yourself" &&
  has_phrase "$O" "bin/model-check.sh\" --agent <agent ID>" &&
  has_phrase "$PLUGIN/bin/session-start.sh" "feature-crew root (for the model check CLI)"; then
  ok "orchestrator falls back to the model-check CLI, and the hook prints the plugin root"
else
  no "orchestrator falls back to the model-check CLI, and the hook prints the plugin root"
fi

run_hook startup "$REPO"
if has "feature-crew root (for the model check CLI): $PLUGIN"; then
  ok "session-start prints the plugin root after the policy"
else
  no "session-start prints the plugin root after the policy" "${OUT: -120}"
fi

# A fell-back run or a refused model never climbs onto the same model.
if has_phrase "$O" "Requested model unavailable (check before step 1)" &&
  ! has_phrase "$O" "Fable unavailable" &&
  has_phrase "$O" "skip the whole ladder: no resume, no climb onto the same unavailable model" &&
  has_phrase "$O" "the model check says the worker FELL BACK" &&
  has_phrase "$O" "billing or authentication error"; then
  ok "orchestrator asks instead of escalating when the requested model is unavailable"
else
  no "orchestrator asks instead of escalating when the requested model is unavailable"
fi

# Routing: ordered rules, first match wins, stated in the brief, and the
# model alias passed as the Agent model parameter too.
sed -n '/^## Pick the worker tier/,/^## Keep a roster/p' "$O" >"$TMP/rt.txt"
r1="$(grep -n '^1\. The user named a model or tier' "$TMP/rt.txt" | cut -d: -f1)"
r2="$(grep -n '^2\. A fable trigger' "$TMP/rt.txt" | cut -d: -f1)"
r3="$(grep -n '^3\. Sonnet tier only if all of these hold' "$TMP/rt.txt" | cut -d: -f1)"
r4="$(grep -n '^4\. Otherwise → opus tier' "$TMP/rt.txt" | cut -d: -f1)"
if [ -n "$r1" ] && [ -n "$r2" ] && [ -n "$r3" ] && [ -n "$r4" ] &&
  [ "$r1" -lt "$r2" ] && [ "$r2" -lt "$r3" ] && [ "$r3" -lt "$r4" ] &&
  has_phrase "$TMP/rt.txt" "the first that matches decides" &&
  has_phrase "$TMP/rt.txt" "migration, a schema or data model, concurrency, performance, security, or a cross-cutting refactor" &&
  has_phrase "$TMP/rt.txt" "names a verify command, names an existing pattern in the codebase to copy, covers one area, and leaves no open decision" &&
  has_phrase "$TMP/rt.txt" "The brief states the tier and the rule that chose it"; then
  ok "routing: four ordered rules, first match wins, brief states tier and rule"
else
  no "routing: four ordered rules, first match wins, brief states tier and rule" "r1=$r1 r2=$r2 r3=$r3 r4=$r4"
fi

if has_phrase "$TMP/rt.txt" "pass the tier's model alias as the Agent tool's \`model\` parameter" &&
  has_phrase "$TMP/rt.txt" "\`feature-crew:feature-builder-sonnet\` (Sonnet, effort medium) | \`sonnet\`" &&
  has_phrase "$TMP/rt.txt" "\`feature-crew:feature-builder\` (Opus, effort medium) | \`opus\`" &&
  has_phrase "$TMP/rt.txt" "\`feature-crew:feature-builder-deep\` (Fable, effort high) | \`fable\`" &&
  ! has_phrase "$O" "First dispatch is always"; then
  ok "routing: every dispatch passes the tier's model alias as the Agent model parameter"
else
  no "routing: every dispatch passes the tier's model alias as the Agent model parameter"
fi

# One climb: sonnet/opus climb once to the fable tier; the fable tier asks,
# offering a fresh xhigh worker.
if has_phrase "$O" "From the sonnet or opus tier: dispatch a fresh \`feature-crew:feature-builder-deep\` with \`model: \"fable\"\`" &&
  has_phrase "$O" "From the fable tier: no climb" &&
  has_phrase "$O" "offer a fresh worker at \`xhigh\` effort as one of the options" &&
  has_phrase "$O" "At most one model climb happens per feature"; then
  ok "ladder: one climb from sonnet/opus to the fable tier; the fable tier asks, offering xhigh"
else
  no "ladder: one climb from sonnet/opus to the fable tier; the fable tier asks, offering xhigh"
fi

# Rate-limit/overload errors are transient: exactly one retry of the same
# worker and brief, never the ladder, then the user.
if has_phrase "$O" "Transient error (check before step 1)" &&
  has_phrase "$O" "rate-limit or overload error, retry exactly once per feature" &&
  has_phrase "$O" "same worker type with the same brief" &&
  has_phrase "$O" "unless the Transient-error or Requested-model-unavailable rule above applies" &&
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
  has_phrase "$W" "start from the diff, read only the log's run headers and tail" &&
  has_phrase "$W" "diff -U25 <reviewed-commit>..HEAD > <gitdir>/crew-fix.diff" && has_phrase "$W" "cannot name the reviewed commit"; then
  ok "worker sends a -U25 diff first and re-reviews only the fix diff"
else
  no "worker sends a -U25 diff first and re-reviews only the fix diff"
fi

r5="$(sed -n '/^5\. \*\*Verify/,/^6\. /p' "$W")"
if printf '%s\n' "$r5" >"$TMP/r5.txt" && has_phrase "$TMP/r5.txt" "only the tests affected by your change" &&
  has_phrase "$TMP/r5.txt" "failures-only reporter" && has_phrase "$TMP/r5.txt" "full suite once more, at the end, after the baseline" &&
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

echo "model check"

# Fixture transcripts for bin/model-check.py. fx writes, under a throwaway
# CLAUDE_CONFIG_DIR, one parent session transcript with the Agent call and its
# result, and the worker's transcript (and .meta.json when asked):
#   fx <agent id> <tool-use id> <agent type> <name> <meta 0|1> <rows>
# <rows> is a comma list of model[@message id[@output tokens]]; "none" writes
# no worker transcript at all.
if ! command -v python3 >/dev/null 2>&1; then
  echo "  SKIP model check (no python3)"
else
MC="$PLUGIN/bin/model-check.sh"
CFG="$TMP/cfg"
SID="sess-1"
PARENT="$CFG/projects/proj/$SID.jsonl"
SUB="$CFG/projects/proj/$SID/subagents"
mkdir -p "$SUB"
LEDGER="$CFG/feature-crew/ledger/$SID.jsonl"
cat >"$TMP/fx.py" <<'PY'
import json, sys
parent, sub, aid, use, atype, name, meta, rows = sys.argv[1:9]
call = {"description": "Build " + name, "subagent_type": atype, "prompt": "brief", "run_in_background": True}
if name != "-":
    call["name"] = name
with open(parent, "a") as f:
    f.write(json.dumps({"type": "assistant", "message": {"role": "assistant", "model": "claude-fable-5-2",
        "content": [{"type": "tool_use", "id": use, "name": "Agent", "input": call}]}}) + "\n")
    f.write(json.dumps({"type": "user", "toolUseResult": {"agentId": aid, "status": "async_launched"},
        "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": use,
        "content": [{"type": "text", "text": "Async agent launched successfully.\nagentId: %s" % aid}]}]}}) + "\n")
if meta == "1":
    json.dump({"agentType": atype, "description": "Build " + name, "toolUseId": use},
              open("%s/agent-%s.meta.json" % (sub, aid), "w"))
if rows != "none":
    with open("%s/agent-%s.jsonl" % (sub, aid), "w") as f:
        f.write(json.dumps({"type": "user", "message": {"role": "user", "content": "brief"}}) + "\n")
        for i, r in enumerate(rows.split(",")):
            parts = r.split("@")
            model = parts[0]
            mid = parts[1] if len(parts) > 1 else "msg-%s-%d" % (aid, i)
            out = int(parts[2]) if len(parts) > 2 else 10
            f.write(json.dumps({"type": "assistant", "timestamp": "2026-11-10T10:00:%02d.000Z" % i,
                "uuid": "u%d" % i, "message": {"id": mid, "model": model, "role": "assistant",
                "content": [{"type": "text", "text": "x"}],
                "usage": {"input_tokens": 1, "output_tokens": out, "cache_read_input_tokens": 100,
                          "cache_creation_input_tokens": 5}}}) + "\n")
PY
fx() { python3 "$TMP/fx.py" "$PARENT" "$SUB" "$@"; }

# notify <agent id> <tool-use id>: run the hook on a task-notification.
# handback <from>: run it on a subagent hand-back message.
hook_in() {
  python3 -c 'import json,sys; print(json.dumps({"session_id": sys.argv[1], "transcript_path": sys.argv[2], "hook_event_name": "UserPromptSubmit", "prompt": sys.argv[3]}))' "$SID" "$PARENT" "$1"
}
notify() {
  OUT="$(hook_in "<task-notification>
<task-id>$1</task-id>
<tool-use-id>$2</tool-use-id>
<status>completed</status>
<summary>Agent finished</summary>
<result>DONE
branch: crew/x</result>
</task-notification>" | CLAUDE_CONFIG_DIR="$CFG" bash "$MC" 2>&1)"
  RC=$?
}
handback() {
  OUT="$(hook_in "Another Claude session sent a message:
<agent-message from=\"$1\">
[Subagent hand-back] The text below is the final report of a subagent. The report follows:
  DONE
  branch: crew/x
</agent-message>" | CLAUDE_CONFIG_DIR="$CFG" bash "$MC" 2>&1)"
  RC=$?
}
ledger_last() { tail -n 1 "$LEDGER" 2>/dev/null; }
ledger_rows() { if [ -f "$LEDGER" ]; then wc -l <"$LEDGER" | tr -d ' '; else echo 0; fi; }
lj() { ledger_last | python3 -c 'import json,sys; r=json.load(sys.stdin); print(eval(sys.argv[1]))' "$1" 2>/dev/null; }

fx aS toolu_S feature-crew:feature-builder-sonnet son 0 "claude-sonnet-5-5"
notify aS toolu_S
if [ "$RC" -eq 0 ] && has '"hookEventName": "UserPromptSubmit"' &&
  has "[feature-crew] worker son ran claude-sonnet-5-5 as chosen (sonnet tier)."; then
  ok "as-chosen: sonnet tier on a Sonnet model"
else
  no "as-chosen: sonnet tier on a Sonnet model" "$OUT"
fi

fx aO toolu_O feature-crew:feature-builder opu 0 "claude-opus-5-5"
notify aO toolu_O
if has "worker opu ran claude-opus-5-5 as chosen (opus tier)."; then ok "as-chosen: opus tier on an Opus model"; else no "as-chosen: opus tier on an Opus model" "$OUT"; fi

fx aF toolu_F feature-crew:feature-builder-deep fab 0 "claude-fable-5-2"
notify aF toolu_F
if has "worker fab ran claude-fable-5-2 as chosen (fable tier)."; then ok "as-chosen: fable tier on a Fable model"; else no "as-chosen: fable tier on a Fable model" "$OUT"; fi

fx aB toolu_B feature-crew:feature-builder-deep fb 0 "claude-opus-5-5"
notify aB toolu_B
if has "worker fb FELL BACK: requested fable, ran claude-opus-5-5." && has "WORKER FELL BACK TO claude-opus-5-5" &&
  [ "$(lj 'r["verdict"]')" = fell-back ]; then
  ok "fell-back: fable requested, Opus ran"
else
  no "fell-back: fable requested, Opus ran" "$OUT"
fi

fx aM toolu_M feature-crew:feature-builder mix 0 "claude-opus-5-5,claude-sonnet-5-5,claude-opus-5-5"
notify aM toolu_M
if has "worker mix FELL BACK: requested opus, ran claude-opus-5-5, claude-sonnet-5-5." &&
  has "WORKER FELL BACK TO claude-sonnet-5-5" &&
  [ "$(lj 'r["actual"]')" = "['claude-opus-5-5', 'claude-sonnet-5-5']" ]; then
  ok "mixed models count as fell-back, every model listed once"
else
  no "mixed models count as fell-back, every model listed once" "$OUT"
fi

fx aY toolu_Y feature-crew:feature-builder-sonnet syn 0 "claude-sonnet-5-5,<synthetic>,claude-sonnet-5-5"
notify aY toolu_Y
if has "worker syn ran claude-sonnet-5-5 as chosen" && [ "$(lj 'r["actual"]')" = "['claude-sonnet-5-5']" ] &&
  [ "$(lj 'r["usage"]["messages"]')" = 2 ]; then
  ok "<synthetic> rows are ignored"
else
  no "<synthetic> rows are ignored" "$OUT"
fi

fx aD toolu_D feature-crew:feature-builder dup 0 "claude-opus-5-5@m1@100,claude-opus-5-5@m1@100,claude-opus-5-5@m2@50"
notify aD toolu_D
if [ "$(lj 'r["usage"]["output_tokens"]')" = 150 ] && [ "$(lj 'r["usage"]["cache_read_input_tokens"]')" = 200 ] &&
  [ "$(lj 'r["usage"]["messages"]')" = 2 ]; then
  ok "usage is summed once per message.id"
else
  no "usage is summed once per message.id" "$(ledger_last)"
fi

# Ledger row: every field, under CLAUDE_CONFIG_DIR.
if [ -f "$LEDGER" ] && [ "$(lj 'sorted(r)')" = "['actual', 'agent_id', 'agent_type', 'description', 'ended_at', 'requested', 'usage', 'verdict']" ] &&
  [ "$(lj 'r["agent_id"]')" = aD ] && [ "$(lj 'r["agent_type"]')" = feature-crew:feature-builder ] &&
  [ "$(lj 'r["description"]')" = "Build dup" ] && [ "$(lj 'r["requested"]')" = opus ] &&
  [ "$(lj 'r["verdict"]')" = as-chosen ] && [ "$(lj 'r["ended_at"]')" = 2026-11-10T10:00:02.000Z ]; then
  ok "ledger row written to <CLAUDE_CONFIG_DIR>/feature-crew/ledger/<session_id>.jsonl with every field"
else
  no "ledger row written to <CLAUDE_CONFIG_DIR>/feature-crew/ledger/<session_id>.jsonl with every field" "$(ledger_last)"
fi
if [ ! -e "$HOME/.claude/feature-crew/ledger/$SID.jsonl" ]; then
  ok "CLAUDE_CONFIG_DIR is honoured (nothing written under ~/.claude)"
else
  no "CLAUDE_CONFIG_DIR is honoured (nothing written under ~/.claude)"
fi

# Missing .meta.json: the agent type comes from the parent's Agent call (every
# fixture above has no meta). The reverse: no parent call, meta.json only.
python3 -c 'import json,sys; json.dump({"agentType": "feature-crew:feature-builder-sonnet", "description": "meta only", "name": "metaw"}, open(sys.argv[1], "w"))' "$SUB/agent-aT.meta.json"
python3 -c 'import json,sys; open(sys.argv[1], "w").write(json.dumps({"type": "assistant", "timestamp": "t", "message": {"id": "z", "model": "claude-sonnet-5-5", "usage": {"output_tokens": 1}}}) + "\n")' "$SUB/agent-aT.jsonl"
notify aT toolu_none
if has "worker metaw ran claude-sonnet-5-5 as chosen (sonnet tier)."; then
  ok "agent type from the parent call without .meta.json, and from .meta.json without a parent call"
else
  no "agent type from the parent call without .meta.json, and from .meta.json without a parent call" "$OUT"
fi

# Both completion forms: a hand-back by agent id and by name.
fx aH toolu_H feature-crew:feature-builder-sonnet hb 1 "claude-sonnet-5-5"
handback aH
o1="$OUT"
handback hb
if case "$o1" in *"worker hb ran claude-sonnet-5-5 as chosen"*) true ;; *) false ;; esac &&
  has "worker hb ran claude-sonnet-5-5 as chosen"; then
  ok "a subagent hand-back <agent-message from=...> is checked, by agent id and by name"
else
  no "a subagent hand-back <agent-message from=...> is checked, by agent id and by name" "$o1 | $OUT"
fi

n="$(ledger_rows)"
OUT="$(hook_in "<agent-message from=\"aH\">
Still working, quick question about the schema?
</agent-message>" | CLAUDE_CONFIG_DIR="$CFG" bash "$MC" 2>&1)"
if [ -z "$OUT" ] && [ "$(ledger_rows)" = "$n" ]; then
  ok "a mid-run agent message that is not a hand-back is ignored"
else
  no "a mid-run agent message that is not a hand-back is ignored" "$OUT"
fi

# A notification and a hand-back for the same finished run add one ledger row.
fx aR toolu_R feature-crew:feature-builder once 0 "claude-opus-5-5"
n="$(ledger_rows)"
notify aR toolu_R
handback aR
CLAUDE_CONFIG_DIR="$CFG" bash "$MC" --agent aR >/dev/null 2>&1
if [ "$(ledger_rows)" = $((n + 1)) ]; then
  ok "the same finished run is recorded once (hook forms and CLI deduplicated)"
else
  no "the same finished run is recorded once (hook forms and CLI deduplicated)" "rows $n -> $(ledger_rows)"
fi

# Non-crew agents: an advisor, a general-purpose agent, another plugin's
# feature-builder. No line, no ledger row.
fx aA toolu_A fable-advisor:advisor adv 0 "claude-fable-5-2"
fx aG toolu_G general-purpose gp 0 "claude-opus-5-5"
fx aX toolu_X other-plugin:feature-builder oth 0 "claude-opus-5-5"
n="$(ledger_rows)"
notify aA toolu_A; o1="$OUT"
notify aG toolu_G; o2="$OUT"
notify aX toolu_X
if [ -z "$o1$o2$OUT" ] && [ "$(ledger_rows)" = "$n" ]; then
  ok "non-feature-crew agents are ignored (no line, no ledger row)"
else
  no "non-feature-crew agents are ignored (no line, no ledger row)" "$o1|$o2|$OUT"
fi

fx aU toolu_U feature-crew:feature-builder-deep gone 0 none
notify aU toolu_U
if has "worker gone (fable tier): model could not be confirmed (transcript unreadable)" &&
  [ "$(lj 'r["verdict"]')" = unknown ] && [ "$(lj 'r["actual"]')" = "[]" ]; then
  ok "unreadable worker transcript: verdict unknown"
else
  no "unreadable worker transcript: verdict unknown" "$OUT"
fi

# Fail-open: garbage, a non-object, a missing transcript, a prompt with no
# completion. Exit 0 and no output every time.
bad=""
for inp in 'not json' '[1,2]' '{"prompt": 5}' \
  '{"session_id":"s","transcript_path":"/no/such.jsonl","prompt":"<task-notification><task-id>aO</task-id><tool-use-id>toolu_O</tool-use-id></task-notification>"}' \
  "{\"session_id\":\"s\",\"transcript_path\":\"$PARENT\",\"prompt\":\"please build the thing\"}"; do
  OUT="$(printf '%s' "$inp" | CLAUDE_CONFIG_DIR="$CFG" bash "$MC" 2>&1)"
  RC=$?
  [ "$RC" -eq 0 ] && [ -z "$OUT" ] || bad="$bad [$inp -> rc=$RC out=$OUT]"
done
OUT="$(printf '' | CLAUDE_CONFIG_DIR="$CFG" bash "$MC" 2>&1)"
[ "$?" -eq 0 ] && [ -z "$OUT" ] || bad="$bad [empty]"
if [ -z "$bad" ]; then ok "fail-open: malformed or irrelevant input exits 0 with no output"; else no "fail-open: malformed or irrelevant input exits 0 with no output" "$bad"; fi

OUT="$(hook_in "<task-notification><task-id>aS</task-id><tool-use-id>toolu_S</tool-use-id></task-notification>" 2>/dev/null |
  FEATURE_CREW=off CLAUDE_CONFIG_DIR="$CFG" bash "$MC" 2>&1)"
if [ -z "$OUT" ]; then ok "FEATURE_CREW=off silences the model check"; else no "FEATURE_CREW=off silences the model check" "$OUT"; fi

# CLI fallback: finds the worker under CLAUDE_CONFIG_DIR/projects without a
# transcript path; --transcript lets --agent be a name.
OUT="$(CLAUDE_CONFIG_DIR="$CFG" bash "$MC" --agent aB --no-ledger 2>&1)"
o1="$OUT"
OUT="$(CLAUDE_CONFIG_DIR="$CFG" bash "$MC" --agent fab --transcript "$PARENT" --no-ledger 2>&1)"
o2="$OUT"
OUT="$(CLAUDE_CONFIG_DIR="$CFG" bash "$MC" --agent nobody --no-ledger 2>&1)"
case "$o1|$o2|$OUT" in
  *"worker fb FELL BACK: requested fable, ran claude-opus-5-5."*"|"*"worker fab ran claude-fable-5-2 as chosen (fable tier)."*"|"*"worker nobody: model could not be confirmed"*)
    ok "CLI --agent prints the same line (by id, or by name with --transcript)" ;;
  *) no "CLI --agent prints the same line (by id, or by name with --transcript)" "$o1 | $o2 | $OUT" ;;
esac

# A task-notification with no <tool-use-id> (seen after a resume), and one
# whose tool-use id is not an Agent call here and has no .meta.json: both
# resolve through the launch result's agent id.
OUT="$(hook_in "<task-notification>
<task-id>aO</task-id>
<status>completed</status>
</task-notification>" | CLAUDE_CONFIG_DIR="$CFG" bash "$MC" 2>&1)"
o1="$OUT"
notify aO toolu_elsewhere
if case "$o1" in *"worker opu ran claude-opus-5-5 as chosen (opus tier)."*) true ;; *) false ;; esac &&
  has "worker opu ran claude-opus-5-5 as chosen (opus tier)."; then
  ok "a notification without <tool-use-id>, or with a foreign one, resolves through the launch result"
else
  no "a notification without <tool-use-id>, or with a foreign one, resolves through the launch result" "$o1 | $OUT"
fi

# One worker named twice in one prompt (notification by id, hand-back by
# name) gives one line.
fx aW toolu_W feature-crew:feature-builder twice 0 "claude-opus-5-5"
OUT="$(hook_in "<task-notification><task-id>aW</task-id><tool-use-id>toolu_W</tool-use-id></task-notification>
<agent-message from=\"twice\">
[Subagent hand-back] DONE
</agent-message>" | CLAUDE_CONFIG_DIR="$CFG" bash "$MC" 2>&1)"
if [ "$(printf '%s' "$OUT" | grep -o 'worker twice ran' | wc -l | tr -d ' ')" = 1 ]; then
  ok "a worker reported in both forms in one prompt gives one line"
else
  no "a worker reported in both forms in one prompt gives one line" "$OUT"
fi

# A resumed worker that finishes again adds a second row with cumulative usage.
n="$(ledger_rows)"
python3 -c 'import json,sys; open(sys.argv[1], "a").write(json.dumps({"type": "assistant", "timestamp": "2026-11-10T11:00:00.000Z", "message": {"id": "late", "model": "claude-opus-5-5", "usage": {"output_tokens": 7}}}) + "\n")' "$SUB/agent-aW.jsonl"
notify aW toolu_W
if [ "$(ledger_rows)" = $((n + 1)) ] && [ "$(lj 'r["ended_at"]')" = 2026-11-10T11:00:00.000Z ] &&
  [ "$(lj 'r["usage"]["output_tokens"]')" = 17 ]; then
  ok "a resumed worker's next completion adds a row with cumulative usage"
else
  no "a resumed worker's next completion adds a row with cumulative usage" "$(ledger_last)"
fi
fi

if has_phrase "$O" "A DONE whose checks pass is otherwise reported as normal" &&
  has_phrase "$O" "needs the user to set \`effort: xhigh\` in \`<feature-crew root>/agents/feature-builder-deep.md\` first" &&
  has_phrase "$O" "never pass a \`model\` alias other than the tier's"; then
  ok "policy: a passing fell-back DONE is only labelled; xhigh needs the user's edit; no off-tier alias"
else
  no "policy: a passing fell-back DONE is only labelled; xhigh needs the user's edit; no off-tier alias"
fi

if grep -rl $'\r' "$PLUGIN" >/dev/null 2>&1; then
  no "no CRLF line endings in the plugin" "$(grep -rl $'\r' "$PLUGIN")"
else
  ok "no CRLF line endings in the plugin"
fi

echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

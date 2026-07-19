#!/usr/bin/env bash
# SessionStart hook — register the session, clean up after dead ones, and hand
# back a resume brief when the previous session in this directory ended while
# paused or was cut off mid-flight.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
. "$SCRIPT_DIR/lib.sh"

input="$(cat)"
pr_init_dirs

sid="$(printf '%s' "$input" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
cwd="$(printf '%s' "$input" | sed -n 's/.*"cwd"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
[ -z "$cwd" ] && cwd="$PWD"
slug="$(pr_slug "$cwd")"

# Drop registry entries and pause flags belonging to sessions that no longer
# exist, so `status` stays truthful and stale flags cannot freeze anyone.
pr_reap_dead_sessions

pr_register_session "$sid" "$cwd" "$(pr_find_claude_pid)"

# Guard against the worst failure mode: a global pause outlives the session it
# was meant for, and every future agent freezes on its first tool call with no
# obvious cause. If nothing is left alive to be paused, the flag has no owner.
recovered_note=""
all_flag="$(pr_flag_path "$PR_ALL_FLAG")"
if [ -f "$all_flag" ]; then
  others=0
  for f in "$PR_SESSIONS"/*.json; do
    [ -e "$f" ] || continue
    [ "$(basename "$f" .json)" = "$sid" ] && continue
    pr_session_is_live "$f" && others=$((others + 1))
  done
  if [ "$others" -eq 0 ]; then
    rm -f "$all_flag" 2>/dev/null
    pr_log "CLEARED orphaned global pause flag at session start ($sid)"
    recovered_note="A global pause flag was left over from a session that is no longer running; it has been cleared automatically so this session will not freeze unexpectedly."
  fi
fi

# Surface a resume brief only when one was actually left for this directory.
# Injecting on every start would be noise, and noise gets ignored.
brief=""
pending="$PR_PENDING/$slug"
if [ -f "$pending" ]; then
  cp_path="$(cat "$pending" 2>/dev/null)"
  if [ -n "$cp_path" ] && [ -f "$cp_path" ]; then
    brief="$(cat "$cp_path" 2>/dev/null)"
  fi
  rm -f "$pending" 2>/dev/null
  pr_log "DELIVERED resume brief for slug=$slug session=$sid"
fi

if [ -z "$brief" ] && [ -z "$recovered_note" ]; then
  exit 0
fi

context=""
if [ -n "$recovered_note" ]; then
  context="[pause-resume] $recovered_note"
fi
if [ -n "$brief" ]; then
  [ -n "$context" ] && context="$context

"
  context="${context}[pause-resume] The previous session in this directory was paused or interrupted before it finished. A resume brief was saved. Do not act on it unprompted — greet the user, summarise in one or two lines where things stopped, and ask whether to continue.

---
$brief"
fi

# jq does the escaping; this hook is not in a hot path so the cost is fine.
if command -v jq >/dev/null 2>&1; then
  jq -n --arg ctx "$context" \
    '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'
else
  # Without jq, degrade to a pointer rather than risk emitting broken JSON.
  printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"[pause-resume] A resume brief from an interrupted session is available. Run: agent-pause checkpoints"}}\n'
fi
exit 0

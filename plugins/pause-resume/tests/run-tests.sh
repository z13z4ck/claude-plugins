#!/usr/bin/env bash
# Self-contained tests for the pause-resume plugin.
#
# Everything runs against a throwaway CLAUDE_PAUSE_HOME, so this never touches
# real session state. No GNU coreutils assumed (macOS has no `timeout`).
# Run: bash tests/run-tests.sh
set -u

BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)"
PASS=0
FAIL=0

export CLAUDE_PAUSE_HOME
CLAUDE_PAUSE_HOME="$(mktemp -d)"
trap 'rm -rf "$CLAUDE_PAUSE_HOME"' EXIT

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

hook_input() {
  printf '{"session_id":"%s","transcript_path":"/tmp/x.jsonl","cwd":"%s","hook_event_name":"PreToolUse","tool_name":"%s","tool_input":{"command":"echo hi"}}' \
    "$1" "$2" "${3:-Bash}"
}

# Portable bounded run of the gate. Sets GATE_OUT and GATE_RC; GATE_RC=124
# means it was still blocking when the limit expired (i.e. the pause held).
GATE_OUT=""
GATE_RC=0
gate_bounded() {
  local limit="$1" inp="$2" tmp p waited=0
  tmp="$(mktemp)"
  printf '%s' "$inp" | bash "$BIN/pause-gate.sh" >"$tmp" 2>&1 &
  p=$!
  while kill -0 "$p" 2>/dev/null && [ "$waited" -lt "$limit" ]; do
    sleep 1
    waited=$((waited + 1))
  done
  if kill -0 "$p" 2>/dev/null; then
    kill -9 "$p" 2>/dev/null
    wait "$p" 2>/dev/null
    GATE_RC=124
  else
    wait "$p" 2>/dev/null
    GATE_RC=$?
  fi
  GATE_OUT="$(cat "$tmp")"
  rm -f "$tmp"
}

# Killing gates with -9 in these tests leaves the same stale markers the plugin
# uses to detect a platform-killed hook, so wipe them between sections or later
# assertions inherit the previous section's evidence.
reset_state() {
  rm -rf "$CLAUDE_PAUSE_HOME/frozen" "$CLAUDE_PAUSE_HOME/paused" 2>/dev/null
  mkdir -p "$CLAUDE_PAUSE_HOME/frozen" "$CLAUDE_PAUSE_HOME/paused" 2>/dev/null
}

SID="11111111-2222-3333-4444-555555555555"
OTHER="99999999-8888-7777-6666-555555555555"
CWD="/tmp/pause-resume-test"
SLUG="$(printf '%s' "$CWD" | sed 's/[^a-zA-Z0-9]/-/g')"

echo
echo "== syntax =="
for f in "$BIN"/*.sh "$BIN/agent-pause"; do
  if bash -n "$f" 2>/dev/null; then
    ok "$(basename "$f") parses"
  else
    no "$(basename "$f") parses" "$(bash -n "$f" 2>&1 | head -3)"
  fi
done
if python3 -m py_compile "$BIN/make-checkpoint.py" 2>/dev/null; then
  ok "make-checkpoint.py compiles"
else
  no "make-checkpoint.py compiles"
fi

echo
echo "== gate fast path (nothing paused) =="
gate_bounded 5 "$(hook_input "$SID" "$CWD")"
[ "$GATE_RC" -eq 0 ] && ok "exits 0 when not paused" || no "exits 0 when not paused" "rc=$GATE_RC"
[ -z "$GATE_OUT" ] && ok "emits nothing when not paused" || no "emits nothing when not paused" "got: $GATE_OUT"

echo
echo "== duration parsing =="
# shellcheck source=../bin/lib.sh
. "$BIN/lib.sh"
check_dur() {
  local got
  got="$(pr_duration_to_secs "$1" 2>/dev/null)"
  [ "$got" = "$2" ] && ok "'$1' -> $2" || no "'$1' -> $2" "got '$got'"
}
check_dur 90 90
check_dur 90s 90
check_dur 30m 1800
check_dur 2h 7200
check_dur 1d 86400
if pr_duration_to_secs "banana" >/dev/null 2>&1; then no "rejects 'banana'"; else ok "rejects 'banana'"; fi

echo
echo "== pause holds the gate, resume releases it =="
reset_state
bash "$BIN/agent-pause" pause -r "test pause" >/dev/null 2>&1
[ -f "$CLAUDE_PAUSE_HOME/paused/_all" ] && ok "pause writes the global flag" || no "pause writes the global flag"

tmpout="$(mktemp)"
hook_input "$SID" "$CWD" | bash "$BIN/pause-gate.sh" >"$tmpout" 2>&1 &
GATE_PID=$!
sleep 3
if kill -0 "$GATE_PID" 2>/dev/null; then
  ok "gate blocks while paused"
else
  no "gate blocks while paused" "exited early: $(cat "$tmpout")"
fi

[ "$(find "$CLAUDE_PAUSE_HOME/frozen" -type f 2>/dev/null | wc -l | tr -d ' ')" -ge 1 ] &&
  ok "frozen marker written while held" || no "frozen marker written while held"

if bash "$BIN/agent-pause" status 2>/dev/null | grep -q "held at Bash"; then
  ok "status reports which tool the agent is held at"
else
  no "status reports which tool the agent is held at" "$(bash "$BIN/agent-pause" status 2>&1 | head -20)"
fi

bash "$BIN/agent-pause" resume >/dev/null 2>&1
waited=0
while kill -0 "$GATE_PID" 2>/dev/null && [ "$waited" -lt 15 ]; do
  sleep 1
  waited=$((waited + 1))
done
if kill -0 "$GATE_PID" 2>/dev/null; then
  no "resume releases the gate" "still blocked after ${waited}s"
  kill -9 "$GATE_PID" 2>/dev/null
  wait "$GATE_PID" 2>/dev/null
else
  wait "$GATE_PID" 2>/dev/null
  grc=$?
  [ "$grc" -eq 0 ] && ok "resume releases the gate and the tool proceeds" || no "gate exit code after resume" "rc=$grc"
fi
[ -s "$tmpout" ] && no "gate stays silent on a normal resume" "got: $(cat "$tmpout")" || ok "gate stays silent on a normal resume"
[ "$(find "$CLAUDE_PAUSE_HOME/frozen" -type f 2>/dev/null | wc -l | tr -d ' ')" -eq 0 ] &&
  ok "frozen marker cleaned up on release" || no "frozen marker cleaned up on release"
rm -f "$tmpout"

echo
echo "== deadline expiry blocks the pending tool call =="
reset_state
bash "$BIN/agent-pause" pause -m 1s -r "deadline test" >/dev/null 2>&1
gate_bounded 20 "$(hook_input "$SID" "$CWD")"
[ "$GATE_RC" -eq 0 ] && ok "deadline path exits 0 (a decision, not an error)" || no "deadline path exits 0" "rc=$GATE_RC"
if printf '%s' "$GATE_OUT" | grep -q '"permissionDecision": *"deny"'; then
  ok "deadline denies the pending tool call"
else
  no "deadline denies the pending tool call" "got: $GATE_OUT"
fi
if printf '%s' "$GATE_OUT" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
  ok "deny payload is valid JSON"
else
  no "deny payload is valid JSON" "got: $GATE_OUT"
fi
printf '%s' "$GATE_OUT" | grep -qi "do not retry" &&
  ok "deny reason tells the agent not to retry" || no "deny reason tells the agent not to retry"
bash "$BIN/agent-pause" resume >/dev/null 2>&1

echo
echo "== a killed gate fails safe instead of leaking a tool call =="
reset_state
bash "$BIN/agent-pause" pause -r "kill test" >/dev/null 2>&1
hook_input "$SID" "$CWD" | bash "$BIN/pause-gate.sh" >/dev/null 2>&1 &
VICTIM=$!
sleep 2
kill -9 "$VICTIM" 2>/dev/null
wait "$VICTIM" 2>/dev/null
[ "$(find "$CLAUDE_PAUSE_HOME/frozen" -type f 2>/dev/null | wc -l | tr -d ' ')" -ge 1 ] &&
  ok "a SIGKILLed gate leaves evidence behind" || no "a SIGKILLed gate leaves evidence behind"

gate_bounded 10 "$(hook_input "$SID" "$CWD")"
if printf '%s' "$GATE_OUT" | grep -q '"permissionDecision": *"deny"'; then
  ok "the next tool call is denied, not silently allowed"
else
  no "the next tool call is denied after a killed gate" "rc=$GATE_RC out=$GATE_OUT"
fi
printf '%s' "$GATE_OUT" | grep -qi "hook timeout" &&
  ok "deny reason names the likely cause" || no "deny reason names the likely cause"
bash "$BIN/agent-pause" resume >/dev/null 2>&1

echo
echo "== concurrent gates do not mistake each other for corpses =="
reset_state
bash "$BIN/agent-pause" pause -r "parallel test" >/dev/null 2>&1
hook_input "$SID" "$CWD" Read | bash "$BIN/pause-gate.sh" >/dev/null 2>&1 &
P1=$!
sleep 2
gate_bounded 5 "$(hook_input "$SID" "$CWD" Grep)"
if printf '%s' "$GATE_OUT" | grep -q '"permissionDecision"'; then
  no "a second concurrent gate blocks rather than denying" "got: $GATE_OUT"
else
  ok "a second concurrent gate blocks rather than denying"
fi
bash "$BIN/agent-pause" resume >/dev/null 2>&1
sleep 3
kill -9 "$P1" 2>/dev/null
wait "$P1" 2>/dev/null

echo
echo "== a targeted pause leaves other sessions alone =="
reset_state
bash "$BIN/agent-pause" pause -s "$SID" -r "targeted" >/dev/null 2>&1
gate_bounded 5 "$(hook_input "$OTHER" "$CWD")"
if [ "$GATE_RC" -eq 0 ] && [ -z "$GATE_OUT" ]; then
  ok "the untargeted session runs freely"
else
  no "the untargeted session runs freely" "rc=$GATE_RC out=$GATE_OUT"
fi
gate_bounded 5 "$(hook_input "$SID" "$CWD")"
[ "$GATE_RC" -eq 124 ] && ok "the targeted session is held" || no "the targeted session is held" "rc=$GATE_RC out=$GATE_OUT"
bash "$BIN/agent-pause" resume >/dev/null 2>&1
reset_state

echo
echo "== session lifecycle hooks =="
se_input="$(printf '{"session_id":"%s","cwd":"%s","hook_event_name":"SessionStart","source":"startup"}' "$SID" "$CWD")"
out="$(printf '%s' "$se_input" | bash "$BIN/session-start.sh" 2>&1)"
rc=$?
[ "$rc" -eq 0 ] && ok "session-start exits 0" || no "session-start exits 0" "rc=$rc"
[ -f "$CLAUDE_PAUSE_HOME/sessions/$SID.json" ] && ok "session-start registers the session" || no "session-start registers the session"

bash "$BIN/agent-pause" pause >/dev/null 2>&1
rm -f "$CLAUDE_PAUSE_HOME/sessions/"*.json
out="$(printf '%s' "$se_input" | bash "$BIN/session-start.sh" 2>&1)"
if [ -f "$CLAUDE_PAUSE_HOME/paused/_all" ]; then
  no "an orphaned global flag is cleared at session start"
else
  ok "an orphaned global flag is cleared at session start"
fi
if printf '%s' "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["hookSpecificOutput"]["hookEventName"]=="SessionStart"' 2>/dev/null; then
  ok "session-start emits valid SessionStart JSON"
else
  no "session-start emits valid SessionStart JSON" "got: $out"
fi

echo
echo "== checkpoint rendering =="
FAKE="$CLAUDE_PAUSE_HOME/fake.jsonl"
cat >"$FAKE" <<'EOF'
{"type":"user","sessionId":"abc","cwd":"/tmp/proj","gitBranch":"main","timestamp":"2026-01-01T00:00:00Z","message":{"role":"user","content":"refactor the parser"}}
{"type":"assistant","sessionId":"abc","cwd":"/tmp/proj","timestamp":"2026-01-01T00:01:00Z","message":{"role":"assistant","content":[{"type":"text","text":"Starting on the parser."},{"type":"tool_use","name":"Edit","input":{"file_path":"/tmp/proj/parser.py"}}]}}
{"type":"assistant","sessionId":"abc","cwd":"/tmp/proj","timestamp":"2026-01-01T00:02:00Z","message":{"role":"assistant","content":[{"type":"tool_use","name":"TodoWrite","input":{"todos":[{"content":"tokenizer","status":"completed"},{"content":"parser","status":"in_progress"},{"content":"tests","status":"pending"}]}}]}}
{"type":"user","sessionId":"abc","message":{"role":"user","content":[{"type":"tool_result","content":"ok"}]}}
{"type":"user","sessionId":"abc","message":{"role":"user","content":"<command-name>/goal</command-name><command-args>ship the parser</command-args>"}}
{ this line is deliberately corrupt
EOF
cp_out="$(python3 "$BIN/make-checkpoint.py" --transcript "$FAKE" --note "unit test" 2>&1)"
rc=$?
[ "$rc" -eq 0 ] && ok "checkpoint builds despite a truncated final line" || no "checkpoint builds from a transcript" "$cp_out"
printf '%s' "$cp_out" | grep -q "refactor the parser" && ok "captures the user instruction" || no "captures the user instruction"
printf '%s' "$cp_out" | grep -q "parser.py" && ok "captures files touched" || no "captures files touched"
printf '%s' "$cp_out" | grep -q '\[~\] parser' && ok "marks the in-flight task" || no "marks the in-flight task"
printf '%s' "$cp_out" | grep -q '\[x\] tokenizer' && ok "marks completed tasks" || no "marks completed tasks"
printf '%s' "$cp_out" | grep -q "/goal ship the parser" && ok "unwraps slash-command syntax" || no "unwraps slash-command syntax"
printf '%s' "$cp_out" | grep -q "command-name" && no "strips raw command tags" || ok "strips raw command tags"

echo
echo "== session-end writes a brief and queues it =="
end_input="$(printf '{"session_id":"%s","cwd":"%s","hook_event_name":"SessionEnd","reason":"other","transcript_path":"%s"}' "$SID" "$CWD" "$FAKE")"
printf '%s' "$end_input" | bash "$BIN/session-end.sh" >/dev/null 2>&1
[ -f "$CLAUDE_PAUSE_HOME/checkpoints/${SLUG}__${SID}.md" ] && ok "session-end saves a brief" || no "session-end saves a brief"
[ -f "$CLAUDE_PAUSE_HOME/pending/$SLUG" ] && ok "session-end queues it for the next session" || no "session-end queues it for the next session"

rm -f "$CLAUDE_PAUSE_HOME/pending/$SLUG" "$CLAUDE_PAUSE_HOME/checkpoints/"*.md
clear_input="$(printf '{"session_id":"%s","cwd":"%s","hook_event_name":"SessionEnd","reason":"clear","transcript_path":"%s"}' "$SID" "$CWD" "$FAKE")"
printf '%s' "$clear_input" | bash "$BIN/session-end.sh" >/dev/null 2>&1
[ -f "$CLAUDE_PAUSE_HOME/pending/$SLUG" ] && no "reason=clear writes no brief" || ok "reason=clear writes no brief"

echo
echo "== the queued brief reaches the next session =="
printf '%s' "$end_input" | bash "$BIN/session-end.sh" >/dev/null 2>&1
out="$(printf '%s' "$se_input" | bash "$BIN/session-start.sh" 2>&1)"
if printf '%s' "$out" | python3 -c '
import json,sys
ctx = json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"]
assert "Resume brief" in ctx, "brief body missing"
assert "refactor the parser" in ctx, "instruction missing"
' 2>/dev/null; then
  ok "the brief is injected as SessionStart context"
else
  no "the brief is injected as SessionStart context" "got: $(printf '%s' "$out" | head -c 300)"
fi
[ -f "$CLAUDE_PAUSE_HOME/pending/$SLUG" ] && no "pending marker is consumed once delivered" || ok "pending marker is consumed once delivered"

echo
echo "-------------------------------------------"
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
echo "-------------------------------------------"
[ "$FAIL" -eq 0 ]

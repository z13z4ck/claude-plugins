#!/usr/bin/env bash
# PreToolUse gate — the actual pause mechanism.
#
# Claude Code runs this before every tool call and waits for it to exit. So if
# this script blocks, the agent blocks: no tool runs, no follow-up API request
# is made, and the conversation stays resident in the CLI process with full
# context. That is the difference between "pause" and "kill and restart".
#
# While frozen we do nothing but sleep and re-stat a flag file, so the machine
# can suspend (laptop lid, tether swap, tunnel) and the loop picks up where it
# left off on wake. Elapsed time is measured against the wall clock rather than
# loop iterations, so a 3-hour suspend counts as 3 hours.
#
# Exit contract:
#   exit 0            -> tool call proceeds (not paused, or resumed)
#   deny JSON, exit 0 -> tool call blocked with an explanation for the agent
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
. "$SCRIPT_DIR/lib.sh"

input="$(cat)"

# --- fast path -------------------------------------------------------------
# Runs before every single tool call, so bail out before parsing anything when
# no pause flag exists anywhere. Directory glob only: no subprocess, no jq.
if pr_nothing_paused; then
  exit 0
fi

# --- we may be paused; now it is worth parsing ------------------------------
sid="$(printf '%s' "$input" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
tool="$(printf '%s' "$input" | sed -n 's/.*"tool_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
[ -z "$tool" ] && tool="a tool"
[ -z "$sid" ] && sid="unknown"

flag="$(pr_active_flag_for "$sid")" || exit 0

deny() {
  # Blocking beats allowing whenever we are unsure: the user asked for the
  # agent to stop, so an unexplained tool call is the one outcome to avoid.
  local msg="$1"
  if command -v jq >/dev/null 2>&1; then
    jq -n --arg r "$msg" \
      '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
  else
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Session is paused; the pending tool call was blocked. Stop and wait for the user."}}\n'
  fi
  exit 0
}

FROZEN_DIR="$PR_HOME/frozen"
mkdir -p "$FROZEN_DIR" 2>/dev/null

# --- detect a previous gate that was killed rather than released ------------
# A clean exit always removes its own marker via the trap below. A marker whose
# owning pid is gone therefore means a previous gate was SIGKILLed — almost
# certainly by a platform hook-timeout cap lower than the one configured in
# hooks/hooks.json. That matters: when Claude Code kills a PreToolUse hook it
# *allows* the tool call, which would silently un-pause the agent. So on seeing
# that evidence we refuse the call outright instead of freezing again. Worst
# case the user gets a stopped agent and an explanation; never a tool that ran
# while they thought the session was held.
for stale in "$FROZEN_DIR/$sid".*; do
  [ -e "$stale" ] || continue
  stale_pid="${stale##*.}"
  case "$stale_pid" in
    '' | *[!0-9]*) rm -f "$stale" 2>/dev/null; continue ;;
  esac
  if kill -0 "$stale_pid" 2>/dev/null; then
    continue # a sibling gate is legitimately frozen right now (parallel tools)
  fi
  rm -f "$stale" 2>/dev/null
  pr_log "KILLED-GATE detected session=$sid (stale pid $stale_pid) — denying $tool"
  deny "This session is paused, but the pause hook was terminated early by a hook timeout, which would have let this $tool call run unattended. It was blocked instead. Do not retry it. Tell the user: the session is still paused and their work is intact; they can resume with 'agent-pause resume'. If this keeps happening, the hook timeout in the pause-resume plugin's hooks.json is being capped by the platform and CLAUDE_PAUSE_MAX_WAIT should be lowered to match."
done

frozen_marker="$FROZEN_DIR/$sid.$$"
cleanup() { rm -f "$frozen_marker" 2>/dev/null; }
trap cleanup EXIT INT TERM HUP

started="$(pr_now)"
mode="$(pr_read_flag_field "$flag" mode)"
reason="$(pr_read_flag_field "$flag" reason)"
deadline="$(pr_read_flag_field "$flag" deadline)"
case "$deadline" in '' | *[!0-9]*) deadline=$((started + PR_DEFAULT_MAX_WAIT)) ;; esac

# Never outlast the hook timeout: exiting on our own terms produces an
# explanation, being killed produces a silently executed tool call.
hard_ceiling=$((started + PR_HOOK_TIMEOUT - PR_TIMEOUT_MARGIN))
[ "$deadline" -gt "$hard_ceiling" ] && deadline="$hard_ceiling"

{
  printf 'session=%s\n' "$sid"
  printf 'tool=%s\n' "$tool"
  printf 'since=%s\n' "$started"
  printf 'mode=%s\n' "$mode"
  printf 'reason=%s\n' "$reason"
} >"$frozen_marker" 2>/dev/null

pr_log "FREEZE session=$sid tool=$tool mode=${mode:-manual} reason=${reason:-none}"

# --- freeze loop ------------------------------------------------------------
while :; do
  # The flag being gone is the resume signal. Re-resolve rather than trusting
  # the original path, since a session flag and a global flag can be lifted
  # independently.
  if [ ! -f "$flag" ]; then
    if ! newflag="$(pr_active_flag_for "$sid")"; then
      pr_log "RESUME session=$sid after $(pr_secs_to_human $(($(pr_now) - started)))"
      exit 0
    fi
    flag="$newflag"
  fi

  now="$(pr_now)"

  # Auto-thaw when the network returns — the moving-between-locations case.
  if [ "$mode" = "until-online" ] && pr_is_online; then
    rm -f "$flag" 2>/dev/null
    pr_log "AUTO-RESUME session=$sid network restored after $(pr_secs_to_human $((now - started)))"
    exit 0
  fi

  if [ "$now" -ge "$deadline" ]; then
    waited="$(pr_secs_to_human $((now - started)))"
    pr_log "DEADLINE session=$sid after $waited — blocking tool=$tool"
    deny "This session has been paused for $waited and reached its pause deadline, so the pending $tool call was blocked rather than run unattended. Do not retry it. Stop here and tell the user: the session is still paused, their work is intact, and they can continue by running 'agent-pause resume' (or /pause-resume:resume) and then giving a new instruction. Offer to write a checkpoint with /pause-resume:checkpoint first."
  fi

  sleep "$PR_POLL_INTERVAL"
done

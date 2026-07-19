#!/usr/bin/env bash
# Shared state layout + helpers for the pause-resume plugin.
# Sourced by every hook script and by the agent-pause CLI.
#
# Deliberately dependency-light: no jq, no flock (absent on macOS), no python
# in any hot path. The PreToolUse gate runs before *every* tool call, so its
# fast path must cost less than a millisecond.

PR_HOME="${CLAUDE_PAUSE_HOME:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/pause-resume}"
PR_PAUSED="$PR_HOME/paused"
PR_SESSIONS="$PR_HOME/sessions"
PR_CHECKPOINTS="$PR_HOME/checkpoints"
PR_PENDING="$PR_HOME/pending"
PR_LOG="$PR_HOME/events.log"

# Global flag file name. Leading underscore keeps it out of UUID globs.
PR_ALL_FLAG="_all"

# How often the gate re-checks the flag while frozen, in seconds.
PR_POLL_INTERVAL="${CLAUDE_PAUSE_POLL_INTERVAL:-2}"

# Default ceiling on a single pause, overridable per-pause with `--max`.
PR_DEFAULT_MAX_WAIT="${CLAUDE_PAUSE_MAX_WAIT:-43200}" # 12h

# Must mirror the `timeout` set on the PreToolUse hook in hooks/hooks.json.
# The gate clamps itself to PR_HOOK_TIMEOUT - PR_TIMEOUT_MARGIN so it always
# exits on its own terms: exiting deliberately blocks the pending tool call
# with an explanation, whereas being killed by the platform lets that tool call
# run — the one outcome a paused session must never produce.
PR_HOOK_TIMEOUT="${CLAUDE_PAUSE_HOOK_TIMEOUT:-86400}" # keep in sync with hooks.json
PR_TIMEOUT_MARGIN="${CLAUDE_PAUSE_TIMEOUT_MARGIN:-60}"

pr_init_dirs() {
  mkdir -p "$PR_PAUSED" "$PR_SESSIONS" "$PR_CHECKPOINTS" "$PR_PENDING" 2>/dev/null
}

pr_now() { date +%s; }

pr_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

pr_log() {
  mkdir -p "$PR_HOME" 2>/dev/null
  printf '%s %s\n' "$(pr_iso)" "$*" >>"$PR_LOG" 2>/dev/null || true
}

# Turn a cwd into the same slug Claude Code uses for ~/.claude/projects/<slug>.
pr_slug() {
  printf '%s' "$1" | sed 's/[^a-zA-Z0-9]/-/g'
}

# Parse "90", "90s", "30m", "2h", "1d" into seconds. Echoes nothing on bad input.
pr_duration_to_secs() {
  local raw="$1" num unit
  [ -z "$raw" ] && return 1
  num="${raw%%[smhdSMHD]*}"
  unit="${raw#"$num"}"
  case "$num" in
    '' | *[!0-9]*) return 1 ;;
  esac
  case "$unit" in
    '' | s | S) printf '%s' "$num" ;;
    m | M) printf '%s' "$((num * 60))" ;;
    h | H) printf '%s' "$((num * 3600))" ;;
    d | D) printf '%s' "$((num * 86400))" ;;
    *) return 1 ;;
  esac
}

pr_secs_to_human() {
  local s="${1:-0}"
  if [ "$s" -lt 60 ]; then printf '%ds' "$s"
  elif [ "$s" -lt 3600 ]; then printf '%dm%ds' "$((s / 60))" "$((s % 60))"
  elif [ "$s" -lt 86400 ]; then printf '%dh%dm' "$((s / 3600))" "$(((s % 3600) / 60))"
  else printf '%dd%dh' "$((s / 86400))" "$(((s % 86400) / 3600))"; fi
}

# --- flag files -------------------------------------------------------------
# Plain key=value so the gate can read them without spawning jq.

pr_flag_path() { printf '%s/%s' "$PR_PAUSED" "$1"; }

pr_write_flag() {
  # pr_write_flag <target> <reason> <mode> <deadline_epoch> <by>
  local target="$1" reason="$2" mode="$3" deadline="$4" by="$5"
  local path tmp
  path="$(pr_flag_path "$target")"
  tmp="$path.tmp.$$"
  pr_init_dirs
  {
    printf 'created=%s\n' "$(pr_now)"
    printf 'mode=%s\n' "$mode"
    printf 'deadline=%s\n' "$deadline"
    printf 'by=%s\n' "$by"
    # reason last and unescaped-but-single-line: readers take everything after '='
    printf 'reason=%s\n' "$(printf '%s' "$reason" | tr '\n' ' ')"
  } >"$tmp" && mv -f "$tmp" "$path"
}

pr_read_flag_field() {
  # pr_read_flag_field <flagfile> <key>
  sed -n "s/^$2=//p" "$1" 2>/dev/null | head -1
}

# Which flag applies to this session: session-specific wins, else global.
pr_active_flag_for() {
  local sid="$1" f
  if [ -n "$sid" ]; then
    f="$(pr_flag_path "$sid")"
    [ -f "$f" ] && { printf '%s' "$f"; return 0; }
  fi
  f="$(pr_flag_path "$PR_ALL_FLAG")"
  [ -f "$f" ] && { printf '%s' "$f"; return 0; }
  return 1
}

# True (0) when *nothing at all* is paused. This is the gate's fast path.
pr_nothing_paused() {
  local d="$PR_PAUSED"
  [ -d "$d" ] || return 0
  # A directory with no entries other than . and .. — cheap, no subprocess.
  local f
  for f in "$d"/*; do
    [ -e "$f" ] && return 1
  done
  return 0
}

# --- connectivity -----------------------------------------------------------
# Used by `pause --until-online`, which is the whole point of the mobile case:
# freeze when the network drops, thaw by itself when it comes back.

pr_is_online() {
  if command -v curl >/dev/null 2>&1; then
    # Any HTTP status back from the API host proves the path is up; we do not
    # care whether it is 200 or 401, only that bytes made a round trip.
    curl -s -o /dev/null --max-time 5 https://api.anthropic.com/v1/models 2>/dev/null && return 0
    return 1
  fi
  if command -v ping >/dev/null 2>&1; then
    # Timeout flags differ by ping flavour: BSD/macOS takes -t <secs>, but on
    # Linux -t is TTL — a TTL of 3 dies a few hops out and reports offline
    # forever. Linux wants -W <secs>.
    case "$(uname -s 2>/dev/null)" in
      Darwin | FreeBSD | OpenBSD | NetBSD)
        ping -c 1 -t 3 1.1.1.1 >/dev/null 2>&1 && return 0 ;;
      *)
        ping -c 1 -W 3 1.1.1.1 >/dev/null 2>&1 && return 0 ;;
    esac
    return 1
  fi
  # No way to check — treat as online so we never wedge on a probe we can't run.
  return 0
}

# --- session registry -------------------------------------------------------

# Find the pid of the claude process that owns this hook.
# $PPID is not it: Claude Code runs hooks through an intermediate shell that
# exits immediately, so recording $PPID would mark every session dead at once.
# Walk up the tree until we hit a process whose name looks like claude, and
# fall back to $PPID only if the walk turns up nothing.
pr_find_claude_pid() {
  local pid="${1:-$PPID}" comm depth=0
  while [ -n "$pid" ] && [ "$pid" != "0" ] && [ "$pid" != "1" ] && [ "$depth" -lt 12 ]; do
    comm="$(ps -o comm= -p "$pid" 2>/dev/null | tr -d ' ')"
    case "$comm" in
      *claude*) printf '%s' "$pid"; return 0 ;;
    esac
    pid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')"
    depth=$((depth + 1))
  done
  printf '%s' "${PPID:-0}"
}

pr_session_file() { printf '%s/%s.json' "$PR_SESSIONS" "$1"; }

pr_register_session() {
  # pr_register_session <sid> <cwd> <ppid>
  local sid="$1" cwd="$2" ppid="$3" tmp
  [ -z "$sid" ] && return 0
  pr_init_dirs
  tmp="$(pr_session_file "$sid").tmp.$$"
  cat >"$tmp" <<EOF
{
  "session_id": "$sid",
  "cwd": "$cwd",
  "slug": "$(pr_slug "$cwd")",
  "ppid": "$ppid",
  "started": "$(pr_iso)",
  "started_epoch": $(pr_now)
}
EOF
  mv -f "$tmp" "$(pr_session_file "$sid")"
}

# A session is live if its recorded ppid (the claude process that spawned our
# hook) still exists. Falls back to an age cutoff when ppid is unusable.
pr_session_is_live() {
  local file="$1" ppid started age
  ppid="$(sed -n 's/.*"ppid"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$file" 2>/dev/null | head -1)"
  if [ -n "$ppid" ] && [ "$ppid" != "0" ]; then
    kill -0 "$ppid" 2>/dev/null && return 0
    return 1
  fi
  started="$(sed -n 's/.*"started_epoch"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' "$file" 2>/dev/null | head -1)"
  [ -z "$started" ] && return 1
  age=$(($(pr_now) - started))
  [ "$age" -lt 86400 ]
}

# Direct evidence of a live pause: a frozen-gate marker whose recorded pid is
# still running. The registry can lie — a renamed binary breaks the comm-name
# walk, state can be wiped — but a live gate process cannot. Cleanup paths must
# check this before deleting any flag, or they un-pause an agent that is
# frozen right now. `scope` narrows to one session id; empty checks all.
pr_live_frozen_gate() {
  local scope="${1:-}" f base pid
  [ -d "$PR_HOME/frozen" ] || return 1
  for f in "$PR_HOME/frozen"/*; do
    [ -e "$f" ] || continue
    base="$(basename "$f")"
    pid="${base##*.}"
    case "$pid" in '' | *[!0-9]*) continue ;; esac
    if [ -n "$scope" ]; then
      case "$base" in "$scope".*) ;; *) continue ;; esac
    fi
    kill -0 "$pid" 2>/dev/null && return 0
  done
  return 1
}

pr_reap_dead_sessions() {
  local f sid
  [ -d "$PR_SESSIONS" ] || return 0
  for f in "$PR_SESSIONS"/*.json; do
    [ -e "$f" ] || continue
    if ! pr_session_is_live "$f"; then
      sid="$(basename "$f" .json)"
      # A live frozen gate for this session is proof the session is alive even
      # when the registry walk says otherwise. Deleting its flag here would
      # release the gate and run the pending tool call unattended.
      pr_live_frozen_gate "$sid" && continue
      rm -f "$f" "$(pr_flag_path "$sid")" 2>/dev/null
    fi
  done
}

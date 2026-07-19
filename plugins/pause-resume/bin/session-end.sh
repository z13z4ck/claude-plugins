#!/usr/bin/env bash
# SessionEnd hook — save a resume brief on the way out, and leave a marker so
# the next session in this directory is offered it.
#
# This covers the graceful exits. It cannot cover a hard kill, because a killed
# process runs no hooks — that case is handled by /pause-resume:recover, which
# rebuilds the same brief from the on-disk transcript after the fact.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
. "$SCRIPT_DIR/lib.sh"

input="$(cat)"
pr_init_dirs

sid="$(printf '%s' "$input" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
cwd="$(printf '%s' "$input" | sed -n 's/.*"cwd"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
reason="$(printf '%s' "$input" | sed -n 's/.*"reason"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
transcript="$(printf '%s' "$input" | sed -n 's/.*"transcript_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
[ -z "$cwd" ] && cwd="$PWD"
slug="$(pr_slug "$cwd")"

was_paused=0
if pr_active_flag_for "$sid" >/dev/null 2>&1; then
  was_paused=1
fi

# Ending while paused means the freeze never got a chance to thaw. Leaving the
# flag behind would ambush the next session, so clear this session's own flag.
rm -f "$(pr_flag_path "$sid")" "$(pr_session_file "$sid")" 2>/dev/null
rm -f "$PR_HOME/frozen/$sid".* 2>/dev/null

# `clear` wipes context on purpose — writing a brief for it would resurrect
# exactly what the user asked to forget.
if [ "$reason" = "clear" ]; then
  pr_log "END session=$sid reason=clear (no brief written)"
  exit 0
fi

out="$PR_CHECKPOINTS/${slug}__${sid:-unknown}.md"
note="Session ended (reason: ${reason:-unknown})."
[ "$was_paused" -eq 1 ] && note="Session ended while still paused (reason: ${reason:-unknown})."

if [ -n "$transcript" ] && [ -f "$transcript" ]; then
  if python3 "$SCRIPT_DIR/make-checkpoint.py" \
    --transcript "$transcript" --out "$out" --note "$note" >/dev/null 2>&1; then
    printf '%s' "$out" >"$PR_PENDING/$slug" 2>/dev/null
    pr_log "END session=$sid reason=${reason:-unknown} paused=$was_paused brief=$out"
  else
    pr_log "END session=$sid reason=${reason:-unknown} — brief not written (nothing recoverable)"
  fi
else
  pr_log "END session=$sid reason=${reason:-unknown} — no transcript path supplied"
fi

exit 0

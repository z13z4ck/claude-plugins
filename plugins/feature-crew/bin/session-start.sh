#!/usr/bin/env bash
# SessionStart hook: put the orchestrator policy in context.
#
# Claude Code caps plain hook stdout at 10,000 characters; anything longer is
# saved to a file and only a 2,000-character preview reaches context. So this
# prints the compact core policy plus the absolute path of the full one, which
# the core tells the orchestrator to Read, and keeps every path under 8,000
# bytes (tests/run-tests.sh asserts it).
#
# Plain stdout from a SessionStart hook is added to the session's context, so
# this script only prints text. What it prints depends on where and how the
# session started:
#   - FEATURE_CREW=off      nothing
#   - not a git work tree   one line saying the plugin is inactive (workers
#                           need worktrees, so every dispatch would fail)
#   - startup               the core policy + full policy path
#   - compact               a "re-read the roster" note, then the same
#   - resume / fork / clear a reconcile section listing the crew/* branches
#                           that exist, because workers from the earlier
#                           conversation stopped with it (/clear ends the
#                           session too: SessionEnd reason "clear"), then the
#                           same
# Dependency-free on purpose (no jq, no python): it runs on Git Bash too.
set -u

[ "${FEATURE_CREW:-on}" = off ] && exit 0

ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CORE="$ROOT/policy/orchestrator-core.md"
POLICY="$ROOT/policy/orchestrator.md"

input="$(cat 2>/dev/null || true)"

json_field() {
  # First string value of "$1" in the hook input; JSON's \\ becomes \.
  printf '%s' "$input" |
    grep -o "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -1 |
    sed "s/^\"$1\"[[:space:]]*:[[:space:]]*\"//; s/\"\$//; s/\\\\\\\\/\\\\/g"
}

source_kind="$(json_field source)"
[ -z "$source_kind" ] && source_kind=startup

dir="$(json_field cwd)"
[ -n "$dir" ] && [ -d "$dir" ] || dir="${CLAUDE_PROJECT_DIR:-$PWD}"

if ! command -v git >/dev/null 2>&1 ||
  [ "$(git -C "$dir" rev-parse --is-inside-work-tree 2>/dev/null)" != true ]; then
  echo "[feature-crew] Inactive here: this folder is not a git work tree, and feature-builder workers need one for their worktrees. Work normally in this session; do not dispatch feature-crew:feature-builder."
  exit 0
fi

for f in "$CORE" "$POLICY"; do
  if [ ! -f "$f" ]; then
    echo "[feature-crew] Policy file missing ($f); orchestrator mode is off for this session."
    exit 0
  fi
done

# Root line and session note go first, the core last (it ends with the full
# policy's path), so a cut would drop the core's tail before the note.
printf 'feature-crew root (for the model check CLI): %s\n' "$ROOT"

# utf8_cut <text> <bytes>: the first <bytes> bytes of <text>, minus a UTF-8
# character the cut would split. Runs in a subshell ($(...)) so LC_ALL=C
# (byte semantics in any locale, no iconv) does not leak.
utf8_cut() {
  LC_ALL=C
  local s="${1:0:$2}" k b need
  k=$((${#s} - 1))
  # Walk back over continuation bytes (0x80-0xBF) to the last lead byte.
  while [ "$k" -ge 0 ]; do
    b=$(printf '%d' "'${s:k:1}")
    [ "$b" -lt 0 ] && b=$((b + 256))
    { [ "$b" -ge 128 ] && [ "$b" -lt 192 ] && [ $((${#s} - k)) -lt 4 ]; } || break
    k=$((k - 1))
  done
  if [ "$k" -ge 0 ]; then
    need=1
    [ "$b" -ge 192 ] && need=2
    [ "$b" -ge 224 ] && need=3
    [ "$b" -ge 240 ] && need=4
    [ $((${#s} - k)) -lt "$need" ] && s="${s:0:k}"
  fi
  printf '%s' "$s"
}

# crew/* branches with age and subject, plus the worktree each is checked out
# in, if any. Capped at 25 lines and 1,500 bytes (wc -c, so multibyte
# subjects count in full), subjects over 72 bytes cut to 69 plus "...", so
# many or long branches cannot push the output past the cap.
crew_branches() {
  local wt total=0
  wt="$(git -C "$dir" worktree list --porcelain 2>/dev/null |
    awk '/^worktree /{p=substr($0,10)} /^branch refs\/heads\/crew\//{print substr($0,19) "\t" p}')"
  # lstrip=2, not :short: a tag named crew/x would turn :short into heads/crew/x.
  git -C "$dir" for-each-ref --sort=-committerdate --count=25 \
    --format='%(refname:lstrip=2)%09%(committerdate:relative)%09%(subject)' \
    'refs/heads/crew/' 2>/dev/null |
    while IFS="$(printf '\t')" read -r name when subject; do
      path="$(printf '%s\n' "$wt" | awk -F '\t' -v b="$name" '$1==b{print $2; exit}')"
      [ "$(printf '%s' "$subject" | wc -c)" -gt 72 ] && subject="$(utf8_cut "$subject" 69)..."
      line="- $name ($when): $subject"
      [ -n "$path" ] && line="$line [worktree: $path]"
      total=$((total + $(printf '%s\n' "$line" | wc -c)))
      if [ "$total" -gt 1500 ]; then
        printf -- "- (more not shown; run git branch --list 'crew/*')\n"
        break
      fi
      printf '%s\n' "$line"
    done
}

case "$source_kind" in
  compact)
    printf '\n## Session note: context was just compacted\n'
    printf 'Workers dispatched earlier in this session are still running. Re-read the roster from your task list before answering anything about worker status.\n'
    ;;
  resume | fork | clear)
    printf '\n## Session note: this session started from "%s"\n' "$source_kind"
    printf 'Background workers from the earlier conversation stopped when it ended. Any roster item still marked running, waiting or under review is stale: mark it stopped, and resume nothing by name or ID from before.\n'
    branches="$(crew_branches)"
    if [ -n "$branches" ]; then
      printf 'Crew branches in this repository, newest first:\n%s\n' "$branches"
      printf 'Before your first reply, tell the user in one or two lines which crew branches exist and offer to continue unfinished ones with a new feature-builder based on that branch.\n'
    else
      printf 'No crew/* branches exist in this repository.\n'
    fi
    ;;
esac
printf '\n'
cat "$CORE"
printf '%s\n' "$POLICY"
exit 0

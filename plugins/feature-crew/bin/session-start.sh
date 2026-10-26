#!/usr/bin/env bash
# SessionStart hook: put the orchestrator policy in context.
#
# Plain stdout from a SessionStart hook is added to the session's context, so
# this script only prints text. What it prints depends on where and how the
# session started:
#   - FEATURE_CREW=off      nothing
#   - not a git work tree   one line saying the plugin is inactive (workers
#                           need worktrees, so every dispatch would fail)
#   - startup               the policy
#   - compact               the policy + "re-read the roster"
#   - resume / fork / clear the policy + a reconcile section listing the
#                           crew/* branches that exist, because workers from
#                           the earlier conversation stopped with it (/clear
#                           ends the session too: SessionEnd reason "clear")
# Dependency-free on purpose (no jq, no python): it runs on Git Bash too.
set -u

[ "${FEATURE_CREW:-on}" = off ] && exit 0

ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
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

if [ ! -f "$POLICY" ]; then
  echo "[feature-crew] Policy file missing ($POLICY); orchestrator mode is off for this session."
  exit 0
fi

cat "$POLICY"

# crew/* branches with age and subject, plus the worktree each is checked out
# in, if any. Capped so a repo with many old branches cannot flood context.
crew_branches() {
  local wt
  wt="$(git -C "$dir" worktree list --porcelain 2>/dev/null |
    awk '/^worktree /{p=substr($0,10)} /^branch refs\/heads\/crew\//{print substr($0,19) "\t" p}')"
  # lstrip=2, not :short: a tag named crew/x would turn :short into heads/crew/x.
  git -C "$dir" for-each-ref --sort=-committerdate --count=25 \
    --format='%(refname:lstrip=2)%09%(committerdate:relative)%09%(subject)' \
    'refs/heads/crew/' 2>/dev/null |
    while IFS="$(printf '\t')" read -r name when subject; do
      path="$(printf '%s\n' "$wt" | awk -F '\t' -v b="$name" '$1==b{print $2; exit}')"
      line="- $name ($when): $subject"
      [ -n "$path" ] && line="$line [worktree: $path]"
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
exit 0

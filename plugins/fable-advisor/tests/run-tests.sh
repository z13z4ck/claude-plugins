#!/usr/bin/env bash
# Self-contained tests for the fable-advisor enforcement hooks.
#
# Every hook is driven the way Claude Code drives it: JSON on stdin, a JSONL
# transcript on disk, JSON (or nothing) on stdout. Transcripts are synthetic,
# state lives in a throwaway FABLE_ADVISOR_HOME, nothing real is touched.
# Run: bash tests/run-tests.sh
set -u

BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)"
PASS=0
FAIL=0

export FABLE_ADVISOR_HOME
FABLE_ADVISOR_HOME="$(mktemp -d)"
WORK="$(mktemp -d)"
# Git Bash: mktemp hands out MSYS paths (/tmp/...) that native Windows Python
# cannot open. The mixed form (C:/...) works for bash and Python alike.
case "$(uname -s)" in
  MINGW* | MSYS*)
    FABLE_ADVISOR_HOME="$(cygpath -m "$FABLE_ADVISOR_HOME")"
    WORK="$(cygpath -m "$WORK")"
    ;;
esac
trap 'rm -rf "$FABLE_ADVISOR_HOME" "$WORK"' EXIT
unset FABLE_ADVISOR_ENFORCE FABLE_ADVISOR_FILE_THRESHOLD FABLE_ADVISOR_PLAN_GATE \
  FABLE_ADVISOR_EDIT_WATCH FABLE_ADVISOR_STOP_AUDIT FABLE_ADVISOR_PROMPT_NUDGE \
  FABLE_ADVISOR_CLAUDE_MD
# SessionStart(startup) writes into the user-level CLAUDE.md under the config
# dir: point it at a throwaway one so no test ever touches the real ~/.claude.
export CLAUDE_CONFIG_DIR="$WORK/claude-config"
mkdir -p "$CLAUDE_CONFIG_DIR"

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
section() { printf '\n%s\n' "$1"; }

# Resolve Python the way the hooks do (python3, python, py -3 — the first that
# really runs, since Windows' python3 is often the Store stub).
PY=""
for c in python3 python "py -3"; do
  if $c -c 'import sys; sys.exit(sys.version_info[0] != 3)' >/dev/null 2>&1; then
    PY="$c"
    break
  fi
done
export PYTHONUTF8=1
py() {
  if [ -z "$PY" ]; then
    echo "no Python 3 interpreter found" >&2
    return 127
  fi
  # Windows Python writes \r\n even into a pipe; drop the \r so output
  # compares the same as on Linux and macOS. Keep Python's exit status.
  # shellcheck disable=SC2086 # $PY may be "py -3"
  $PY "$@" | tr -d '\r'
  return "${PIPESTATUS[0]}"
}

contains() { case "$1" in *"$2"*) return 0 ;; esac; return 1; }

# --- transcript builders ------------------------------------------------------
T=""
SID="11111111-2222-3333-4444-555555555555"
NEXT_ID=0

json_str() { py -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1"; }

new_transcript() {
  T="$WORK/$1.jsonl"
  : >"$T"
  SID="sid-$1"
}
CLOCK=1000
t_ts() { CLOCK=$((CLOCK + 1)); printf '2026-09-02T10:%02d:%02dZ' $(( (CLOCK / 60) % 60 )) $(( CLOCK % 60 )); }
t_prompt() { printf '{"type":"user","timestamp":"%s","promptId":"p-%s","message":{"role":"user","content":%s},"userType":"external"}\n' "$(t_ts)" "$CLOCK" "$(json_str "$1")" >>"$T"; }
t_meta() { printf '{"type":"user","isMeta":true,"message":{"role":"user","content":%s}}\n' "$(json_str "$1")" >>"$T"; }
t_tool_use() {
  # t_tool_use <name> <input-json> [id]
  local id="${3:-toolu_$((NEXT_ID += 1))}"
  LAST_ID="$id"
  printf '{"type":"assistant","timestamp":"%s","message":{"role":"assistant","content":[{"type":"tool_use","id":"%s","name":"%s","input":%s}]}}\n' "$(t_ts)" "$id" "$1" "$2" >>"$T"
}
t_tool_result() { printf '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"%s","content":"ok"}]}}\n' "$1" >>"$T"; }
t_denied_result() {
  # What Claude Code writes back when a PreToolUse hook denies the call: an error
  # tool_result for the same id carrying the hook's reason.
  printf '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"%s","is_error":true,"content":"PreToolUse:ExitPlanMode hook denied: [fable-advisor] This plan has not been reviewed by the advisor."}]}}\n' "$1" >>"$T"
}
t_mode_entry() { printf '{"type":"permission-mode","permissionMode":"%s","sessionId":"%s"}\n' "$1" "$SID" >>"$T"; }
t_edit() { t_tool_use Edit "{\"file_path\":$(json_str "$1"),\"old_string\":\"a\",\"new_string\":\"b\"}"; }
t_bash() { t_tool_use Bash "{\"command\":$(json_str "$1")}"; }
t_consult() { t_tool_use Agent '{"subagent_type":"fable-advisor:advisor","model":"fable","description":"consult","prompt":"Critique this plan: ..."}'; }
t_health() { t_tool_use Agent '{"subagent_type":"fable-advisor:advisor","model":"fable","description":"health","prompt":"Health check. Do not read any files. Reply ADVISOR OK."}'; }
t_other_agent() { t_tool_use Agent '{"subagent_type":"Explore","description":"x","prompt":"find things"}'; }
t_enter_plan() { t_tool_use EnterPlanMode '{}'; }
t_exit_plan() { t_tool_use ExitPlanMode '{"plan":"..."}' "${1:-}"; }
t_plan_mode_entry() { printf '{"type":"permission-mode","permissionMode":"plan","sessionId":"%s"}\n' "$SID" >>"$T"; }
t_sidechain_edit() { printf '{"type":"assistant","isSidechain":true,"message":{"role":"assistant","content":[{"type":"tool_use","id":"side","name":"Edit","input":{"file_path":%s}}]}}\n' "$(json_str "$1")" >>"$T"; }

# --- hook driver -------------------------------------------------------------
HOOK_OUT=""
HOOK_RC=0
HOOK_CWD="/work/project"
run_hook() {
  # run_hook <subcommand> <extra-json-fields>
  local extra="${2:-}"
  local input
  # cwd is a project-like path, not $WORK: $WORK is under the OS temp dir, and
  # relative Bash writes resolve against cwd, so temp would hide them.
  input="$(printf '{"session_id":"%s","transcript_path":"%s","cwd":"%s"%s}' "$SID" "$T" "$HOOK_CWD" "${extra:+,$extra}")"
  HOOK_OUT="$(printf '%s' "$input" | bash "$BIN/hook.sh" "$1" 2>"$WORK/stderr")"
  HOOK_RC=$?
}
jget() {
  # jget <json> <dotted.path>  -> prints value or empty
  printf '%s' "$1" | py -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for k in sys.argv[1].split("."):
    d = d.get(k) if isinstance(d, dict) else None
    if d is None:
        sys.exit(0)
print(d if not isinstance(d, bool) else str(d).lower())' "$2"
}
context_of() { jget "$1" hookSpecificOutput.additionalContext; }

# =============================================================================
section "session-start"
new_transcript ss1
run_hook session-start '"source":"startup"'
[ "$HOOK_RC" -eq 0 ] && ok "exits 0" || no "exit code $HOOK_RC"
[ "$(jget "$HOOK_OUT" hookSpecificOutput.hookEventName)" = "SessionStart" ] && ok "emits SessionStart hookSpecificOutput" || no "wrong event" "$HOOK_OUT"
ctx="$(context_of "$HOOK_OUT")"
contains "$ctx" "Advisor policy" && ok "injects the advisor policy" || no "policy missing" "$ctx"
contains "$ctx" 'subagent_type "fable-advisor:advisor"' && ok "policy names the dispatch path" || no "dispatch path missing"
contains "$ctx" "more than 3 files" && ok "policy states the file threshold" || no "threshold missing"
! contains "$ctx" "Session so far" && ok "no tally on a fresh startup" || no "unexpected tally on startup"

new_transcript ss2
t_prompt "do the thing"; t_consult; t_edit a.py; t_edit b.py
run_hook session-start '"source":"compact"'
ctx="$(context_of "$HOOK_OUT")"
contains "$ctx" "1 advisor consultation(s); 2 distinct file(s)" && ok "compact re-injects policy with a usage tally" || no "tally wrong" "$ctx"

FABLE_ADVISOR_ENFORCE=off run_hook session-start '"source":"startup"'
[ -z "$HOOK_OUT" ] && ok "ENFORCE=off is silent" || no "output despite off" "$HOOK_OUT"

FABLE_ADVISOR_FILE_THRESHOLD=6 run_hook session-start '"source":"startup"'
contains "$(context_of "$HOOK_OUT")" "more than 5 files" && ok "threshold override is reflected in the policy" || no "threshold override ignored"

# =============================================================================
section "user CLAUDE.md block (SessionStart startup + claude-md command)"
# Each case gets its own config dir and plugin home, so stamps never leak
# between cases.
MDC="" MDD="" MDF="" MDH="" MDOUT=""
md_case() {
  MDC="$WORK/md-$1"
  MDD="$MDC/cfg"
  MDF="$MDD/CLAUDE.md"
  MDH="$MDC/home"
  mkdir -p "$MDD"
}
md_start() { CLAUDE_CONFIG_DIR="$MDD" FABLE_ADVISOR_HOME="$MDH" run_hook session-start "\"source\":\"${1:-startup}\""; }
md_cmd() { MDOUT="$(printf '' | CLAUDE_CONFIG_DIR="$MDD" FABLE_ADVISOR_HOME="$MDH" bash "$BIN/hook.sh" claude-md "$@" 2>&1 | tr -d '\r')"; }
md_count() { grep -c 'fable-advisor:begin' "$MDF" 2>/dev/null || true; }
BEGIN_V1='<!-- fable-advisor:begin v1 -->'

new_transcript md
md_case first
md_start
ctx="$(context_of "$HOOK_OUT")"
[ -f "$MDF" ] && grep -qF "$BEGIN_V1" "$MDF" && grep -qF '<!-- fable-advisor:end -->' "$MDF" \
  && ok "first startup creates CLAUDE.md with the v1 block" || no "block not written" "$(cat "$MDF" 2>/dev/null)"
grep -q "## Advisor policy (fable-advisor)" "$MDF" && grep -q '\[fable-advisor\]' "$MDF" \
  && ok "block has the heading and defers to an injected [fable-advisor] policy" || no "block content wrong" "$(cat "$MDF")"
! grep -qE '[0-9]+ files' "$MDF" && ok "block hardcodes no file threshold" || no "block hardcodes a threshold"
[ -f "$MDH/claude-md.json" ] && grep -q '"version": 1' "$MDH/claude-md.json" \
  && ok "stamp records the block version" || no "stamp missing" "$(cat "$MDH/claude-md.json" 2>/dev/null)"
contains "$ctx" "Advisor policy for this session" && ok "the policy is still injected" || no "policy lost" "$ctx"
contains "$ctx" "$MDF" && contains "$ctx" "next session" && contains "$ctx" "FABLE_ADVISOR_CLAUDE_MD=off" \
  && contains "$ctx" "/fable-advisor:claude-md remove" \
  && ok "first write: context names the file, next-session effect and both opt-outs" || no "notice missing" "$ctx"
cp "$MDF" "$MDC/after-first"
md_start
cmp -s "$MDF" "$MDC/after-first" && ok "second startup leaves the file untouched" || no "second startup changed the file"
! contains "$(context_of "$HOOK_OUT")" "CLAUDE.md" && ok "second startup: no notice" || no "notice repeated" "$(context_of "$HOOK_OUT")"

# The user deletes the block: the stamp remembers, it is not re-added.
printf '# my notes\n' >"$MDF"
md_start
[ "$(md_count)" = "0" ] && [ "$(cat "$MDF")" = "# my notes" ] && ok "block removed by the user is not re-added" || no "block re-added" "$(cat "$MDF")"
! contains "$(context_of "$HOOK_OUT")" "CLAUDE.md" && ok "no notice when respecting a removal" || no "unexpected notice"

# Existing content is preserved byte for byte (unicode, CRLF, trailing spaces)
# and a remove restores the original exactly.
md_case nofinal
printf 'no final newline \xc3\xa9' >"$MDF"
cp "$MDF" "$MDC/orig"
md_start
size=$(wc -c <"$MDC/orig" | tr -d ' ')
head -c "$size" "$MDF" | cmp -s - "$MDC/orig" && [ "$(md_count)" = "1" ] \
  && ok "file without a final newline: kept byte for byte, block appended" || no "no-final-newline content changed" "$(od -c "$MDF" | head -3)"
md_case preserve
printf '# Mine \xe2\x80\x94 caf\xc3\xa9\r\nline two  \r\n\r\nlast\r\n' >"$MDF"
cp "$MDF" "$MDC/orig"
md_start
size=$(wc -c <"$MDC/orig" | tr -d ' ')
head -c "$size" "$MDF" | cmp -s - "$MDC/orig" && ok "existing content kept byte for byte, block appended after it" || no "existing content changed"
[ "$(md_count)" = "1" ] && ok "exactly one block" || no "block count $(md_count)"
grep -q "fable-advisor:end -->$(printf '\r')$" "$MDF" && ok "block follows the file's CRLF line endings" || no "line endings mixed" "$(od -c "$MDF" | tail -4)"
md_cmd remove
cmp -s "$MDF" "$MDC/orig" && ok "claude-md remove restores the original file exactly" || no "remove left residue" "$(od -c "$MDF" | tail -3)"
contains "$MDOUT" "Removed" && ok "remove reports what it did" || no "remove output" "$MDOUT"
md_start
[ "$(md_count)" = "0" ] && ok "after remove, startup does not re-add" || no "re-added after remove"

md_case append
printf '# Mine\n\nkeep this\n' >"$MDF"
md_start
py -c '
import sys
t = open(sys.argv[1], encoding="utf-8", newline="").read()
assert t.startswith("# Mine\n\nkeep this\n\n<!-- fable-advisor:begin v1 -->\n"), repr(t[:80])
assert t.endswith("<!-- fable-advisor:end -->\n"), repr(t[-40:])
' "$MDF" && ok "append uses one blank-line separator and ends with a newline" || no "append layout wrong" "$(cat "$MDF")"
md_cmd remove
[ "$(cat "$MDF")" = "$(printf '# Mine\n\nkeep this')" ] && [ "$(tail -c 1 "$MDF" | od -An -c | tr -d ' ')" = '\n' ] \
  && ok "remove drops the blank separator it added" || no "remove layout wrong" "$(od -c "$MDF")"

# An older block version is replaced in place, surrounding content untouched.
md_case upgrade
printf '# Top\n\nbefore\n\n<!-- fable-advisor:begin v0 -->\nold advice\n<!-- fable-advisor:end -->\n\nafter \xc3\xa9\n' >"$MDF"
md_start
py -c '
import sys
t = open(sys.argv[1], encoding="utf-8", newline="").read()
assert t.startswith("# Top\n\nbefore\n\n<!-- fable-advisor:begin v1 -->\n"), repr(t[:60])
assert t.endswith("<!-- fable-advisor:end -->\n\nafter é\n"), repr(t[-60:])
assert "old advice" not in t and t.count("fable-advisor:begin") == 1
' "$MDF" && ok "older block replaced in place, user content around it preserved exactly" || no "upgrade wrong" "$(cat "$MDF")"
contains "$(context_of "$HOOK_OUT")" "Updated" && ok "upgrade announces itself" || no "no upgrade notice" "$(context_of "$HOOK_OUT")"
grep -q '"version": 1' "$MDH/claude-md.json" && ok "upgrade updates the stamp" || no "stamp not updated"

# A current block written elsewhere (no stamp yet): left alone, stamp written.
md_case adopt
printf '%s\nhand-edited\n<!-- fable-advisor:end -->\n' "$BEGIN_V1" >"$MDF"
cp "$MDF" "$MDC/orig"
md_start
cmp -s "$MDF" "$MDC/orig" && [ -f "$MDH/claude-md.json" ] && ! contains "$(context_of "$HOOK_OUT")" "CLAUDE.md" \
  && ok "current block present without a stamp: untouched, stamp written, no notice" || no "adopt wrong"

# A begin marker without an end marker is never rewritten.
md_case malformed
printf 'x\n%s\nno end\n' "$BEGIN_V1" >"$MDF"
cp "$MDF" "$MDC/orig"
md_start
cmp -s "$MDF" "$MDC/orig" && ok "unterminated block: file left alone" || no "malformed file rewritten" "$(cat "$MDF")"

# Opt-outs and non-startup sources.
md_case optout
FABLE_ADVISOR_CLAUDE_MD=off md_start
[ ! -e "$MDF" ] && [ ! -e "$MDH/claude-md.json" ] && ok "FABLE_ADVISOR_CLAUDE_MD=off writes nothing" || no "written despite opt-out"
contains "$(context_of "$HOOK_OUT")" "Advisor policy" && ok "opt-out still injects the policy" || no "policy lost on opt-out"
FABLE_ADVISOR_ENFORCE=off md_start
[ ! -e "$MDF" ] && ok "FABLE_ADVISOR_ENFORCE=off writes nothing" || no "written with enforcement off"
for src in resume compact clear; do
  md_start "$src"
  [ ! -e "$MDF" ] && ok "source=$src writes nothing" || no "written on $src"
done

md_case nodir
rmdir "$MDD"
md_start
[ ! -e "$MDD" ] && ok "missing config dir: nothing created" || no "config dir created"
contains "$(context_of "$HOOK_OUT")" "Advisor policy" && ok "missing config dir: policy still injected" || no "policy lost"
md_cmd install
[ ! -e "$MDD" ] && contains "$MDOUT" "does not exist" && ok "install never creates the config dir" || no "install created the dir" "$MDOUT"

# The claude-md command.
md_case cmd
md_cmd status
contains "$MDOUT" "$MDF" && contains "$MDOUT" "block: absent" && contains "$MDOUT" "auto-install: on" \
  && ok "status: target path, no block, auto-install on" || no "status wrong" "$MDOUT"
md_cmd
contains "$MDOUT" "block: absent" && ok "no argument means status" || no "default not status" "$MDOUT"
FABLE_ADVISOR_CLAUDE_MD=0 md_cmd status
contains "$MDOUT" "auto-install: off" && ok "status reports the opt-out" || no "opt-out not reported" "$MDOUT"
md_cmd install
[ "$(md_count)" = "1" ] && contains "$MDOUT" "Wrote" && ok "install writes the block" || no "install failed" "$MDOUT"
md_cmd install
[ "$(md_count)" = "1" ] && ok "install is idempotent" || no "install duplicated the block"
md_cmd status
contains "$MDOUT" "block: present (v1, current)" && contains "$MDOUT" "stamp:" && ok "status: block version and stamp" || no "status after install" "$MDOUT"
md_cmd remove
[ "$(md_count)" = "0" ] && ok "remove deletes the block" || no "remove failed"
md_cmd status
contains "$MDOUT" "block: absent" && contains "$MDOUT" "will not re-add" && ok "status explains a removed block stays removed" || no "status after remove" "$MDOUT"
md_cmd install
[ "$(md_count)" = "1" ] && ok "install re-adds a block the user removed" || no "install refused after remove"
md_cmd bogus
contains "$MDOUT" "usage" && ok "unknown action prints usage" || no "bogus action" "$MDOUT"

md_case cmdremove
printf 'mine\n' >"$MDF"
md_cmd remove
[ "$(cat "$MDF")" = "mine" ] && [ -f "$MDH/claude-md.json" ] && ok "remove with no block records the opt-out" || no "remove without block"
md_start
[ "$(md_count)" = "0" ] && ok "...so startup never adds it" || no "added after pre-emptive remove"

# Symlinked CLAUDE.md (dotfiles): the link survives, its target is edited.
# Git Bash's ln -s copies instead of linking, so this case is POSIX-only.
case "$(uname -s)" in
  MINGW* | MSYS*) ;;
  *)
    md_case link
    printf 'dotfile\n' >"$MDC/real.md"
    ln -s "$MDC/real.md" "$MDF"
    md_start
    [ -L "$MDF" ] && grep -qF "$BEGIN_V1" "$MDC/real.md" && ok "symlinked CLAUDE.md: link kept, target updated" || no "symlink replaced"
    ;;
esac

# Notepad saves UTF-8 with a BOM: kept, never added, and a block right after
# it is still found.
md_case bom
printf '\xef\xbb\xbf# notes\r\nkept\r\n' >"$MDF"
cp "$MDF" "$MDC/orig"
md_start
size=$(wc -c <"$MDC/orig" | tr -d ' ')
head -c "$size" "$MDF" | cmp -s - "$MDC/orig" && [ "$(md_count)" = "1" ] && ok "BOM file: BOM and content kept, block appended" || no "BOM file changed" "$(od -c "$MDF" | head -3)"
md_cmd remove
cmp -s "$MDF" "$MDC/orig" && ok "BOM file: remove restores the original bytes" || no "BOM remove residue" "$(od -c "$MDF" | head -3)"
[ "$(head -c 3 "$MDH/claude-md.json" 2>/dev/null | od -An -tx1 | tr -d ' ')" != "efbbbf" ] && ok "stamp is written without a BOM" || no "stamp has a BOM"
md_case bomtop
printf '\xef\xbb\xbf<!-- fable-advisor:begin v0 -->\nold\n<!-- fable-advisor:end -->\nafter\n' >"$MDF"
md_start
[ "$(head -c 3 "$MDF" | od -An -tx1 | tr -d ' ')" = "efbbbf" ] && [ "$(md_count)" = "1" ] && grep -qF "$BEGIN_V1" "$MDF" && [ "$(tail -n 1 "$MDF")" = "after" ] \
  && ok "block at the very top after a BOM is found and replaced in place" || no "BOM-top block mishandled" "$(od -c "$MDF" | head -4)"
md_case new
md_start
[ "$(head -c 3 "$MDF" | od -An -tx1 | tr -d ' ')" != "efbbbf" ] && ok "a new CLAUDE.md gets no BOM" || no "BOM added"

# Duplicate blocks (e.g. pasted twice) collapse to one, other content kept.
md_case dup
printf 'top\n\n<!-- fable-advisor:begin v0 -->\na\n<!-- fable-advisor:end -->\n\nmiddle\n\n<!-- fable-advisor:begin v0 -->\nb\n<!-- fable-advisor:end -->\n\nend\n' >"$MDF"
md_start
[ "$(md_count)" = "1" ] && grep -qx middle "$MDF" && grep -qx end "$MDF" && grep -qx top "$MDF" \
  && ok "duplicate blocks collapse to one on refresh" || no "duplicates kept" "$(cat "$MDF")"
md_cmd install
[ "$(md_count)" = "1" ] && ok "install after collapse stays at one block" || no "install duplicated"
printf '\n%s\nx\n<!-- fable-advisor:end -->\n' "$BEGIN_V1" >>"$MDF"
md_cmd install
[ "$(md_count)" = "1" ] && ok "install collapses a current-version duplicate" || no "install kept duplicate" "$(cat "$MDF")"
md_cmd remove
[ "$(md_count)" = "0" ] && grep -qx middle "$MDF" && ok "remove deletes every block" || no "remove left a block" "$(cat "$MDF")"

# A write that fails (read-only dir here; a locked file on Windows) fails open:
# policy injected, no stamp, so the next startup tries again.
if [ "$(id -u 2>/dev/null)" != "0" ]; then
  case "$(uname -s)" in
    MINGW* | MSYS*) ;;
    *)
      md_case locked
      chmod 555 "$MDD"
      md_start
      chmod 755 "$MDD"
      [ ! -e "$MDF" ] && [ ! -e "$MDH/claude-md.json" ] && contains "$(context_of "$HOOK_OUT")" "Advisor policy" \
        && ok "failed write: policy still injected, no stamp" || no "failed write mishandled" "$HOOK_OUT"
      grep -q "event=claude-md-error" "$MDH/events.log" && ok "failed write is logged" || no "failure not logged"
      md_start
      [ "$(md_count)" = "1" ] && ok "next startup retries and writes the block" || no "no retry after failure"
      ls -a "$MDD" | grep -q '\.tmp' && no "tmp file left behind" || ok "no tmp files left behind"
      ;;
  esac
fi

# Windows details, exercised on any OS by forcing the Windows code path.
py -c '
import sys
sys.path.insert(0, sys.argv[1])
import advisor_hooks as h
assert h._msys_to_win("/c/Users/x/.claude", nt=True) == "C:/Users/x/.claude", h._msys_to_win("/c/Users/x/.claude", nt=True)
assert h._msys_to_win("/d", nt=True) == "D:/"
assert h._msys_to_win("C:/Users/x", nt=True) == "C:/Users/x"
assert h._msys_to_win("/home/x/.claude", nt=True) == "/home/x/.claude"
assert h._msys_to_win("/c/Users/x/.claude", nt=False) == "/c/Users/x/.claude"
n = lambda p: h._norm_path(p, nt=True)
assert n("/c/Users/X/.claude/CLAUDE.md") == n("C:\\Users\\x\\.claude\\CLAUDE.md") == n("c:/users/x/.claude/claude.md")
print("ok")
' "$BIN" | grep -qx ok && ok "MSYS /c/Users/x/.claude maps to C:/Users/x/.claude; stamp paths compare Windows-style" || no "Windows path mapping wrong"
py -c '
import os, sys, tempfile
sys.path.insert(0, sys.argv[1])
import advisor_hooks as h
h.REPLACE_DELAY = 0
real = os.replace
calls = []
def flaky(a, b):
    calls.append(1)
    if len(calls) < 3:
        raise PermissionError("locked")
    real(a, b)
os.replace = flaky
d = tempfile.mkdtemp()
src, dst = os.path.join(d, "s"), os.path.join(d, "t")
open(src, "w").close()
h._replace(src, dst)
assert os.path.exists(dst) and len(calls) == 3
def locked(a, b):
    raise PermissionError("locked")
os.replace = locked
open(src, "w").close()
try:
    h._replace(src, dst)
    raise SystemExit("no error")
except PermissionError:
    pass
print("ok")
' "$BIN" | grep -qx ok && ok "os.replace PermissionError is retried, and re-raised after 3 attempts" || no "replace retry wrong"

# The shared session-start runs above wrote into the throwaway config dir only.
grep -qF "$BEGIN_V1" "$CLAUDE_CONFIG_DIR/CLAUDE.md" && ok "suite-wide startup runs write to the temp CLAUDE_CONFIG_DIR" || no "temp config dir not used"

# =============================================================================
section "prompt nudges"
new_transcript p1
run_hook prompt "\"prompt\":$(json_str "should we use redis or postgres for the queue?")"
[ "$(jget "$HOOK_OUT" hookSpecificOutput.hookEventName)" = "UserPromptSubmit" ] && ok "emits UserPromptSubmit output" || no "wrong event" "$HOOK_OUT"
contains "$(context_of "$HOOK_OUT")" "decision between options" && ok "decision prompt is recognised" || no "decision not recognised"

run_hook prompt "\"prompt\":$(json_str "the build still fails with the same error after that change")"
contains "$(context_of "$HOOK_OUT")" "stalled fix" && ok "stalled-fix prompt is recognised" || no "stalled not recognised" "$HOOK_OUT"

t_prompt "the build still fails with the same error after that change"
run_hook prompt "\"prompt\":$(json_str "nope, still broken, same error")"
contains "$(context_of "$HOOK_OUT")" "Second consecutive" && ok "two stalled prompts in a row escalate" || no "no escalation" "$HOOK_OUT"

run_hook prompt "\"prompt\":$(json_str "review this diff before I merge")"
contains "$(context_of "$HOOK_OUT")" "review or second opinion" && ok "review prompt is recognised" || no "review not recognised"

run_hook prompt "\"prompt\":$(json_str "refactor the auth module into its own package")"
contains "$(context_of "$HOOK_OUT")" "design or planning" && ok "planning prompt is recognised" || no "plan not recognised"

run_hook prompt "\"prompt\":$(json_str "thanks")"
[ -z "$HOOK_OUT" ] && ok "trivial prompt gets no nudge" || no "nudge on trivial prompt" "$HOOK_OUT"

run_hook prompt "\"prompt\":$(json_str "/fable-advisor:health")"
[ -z "$HOOK_OUT" ] && ok "slash commands get no nudge" || no "nudge on slash command"

run_hook prompt "\"prompt\":$(json_str "bump the fable-advisor version to 1.6.0")"
[ -z "$HOOK_OUT" ] && ok "'fable-advisor' in a prompt is not a review request" || no "false review nudge" "$HOOK_OUT"
run_hook prompt "\"prompt\":$(json_str "ask the advisor whether this is safe")"
contains "$(context_of "$HOOK_OUT")" "review or second opinion" && ok "'ask the advisor' is a review request" || no "explicit advisor request missed"

NOTE="$(printf '<task-notification>\n<task-id>abc</task-id>\n<status>completed</status>\n<summary>Agent "Verification review of the diff" finished</summary>\n</task-notification>')"
run_hook prompt "\"prompt\":$(json_str "$NOTE")"
[ -z "$HOOK_OUT" ] && ok "a background agent's completion notice is not classified as a review request" || no "notification classified" "$HOOK_OUT"
run_hook prompt "\"prompt\":$(json_str "[SYSTEM NOTIFICATION - NOT USER INPUT] should we decide which approach")"
[ -z "$HOOK_OUT" ] && ok "harness system notifications are not classified" || no "system notification classified" "$HOOK_OUT"

new_transcript p1b
t_prompt "the build still fails with the same error"
t_prompt "$NOTE"
run_hook prompt "\"prompt\":$(json_str "nope, still broken, same error")"
contains "$(context_of "$HOOK_OUT")" "Second consecutive" && ok "a notification between two stalled reports does not hide the repeat" || no "notification broke stalled escalation" "$HOOK_OUT"

new_transcript p2
t_prompt "go"; t_edit a.py; t_edit b.py; t_edit c.py; t_edit d.py
run_hook prompt "\"prompt\":$(json_str "ok carry on")"
contains "$(context_of "$HOOK_OUT")" "4 distinct files have been edited since the last advisor consultation" && ok "pending unreviewed edits are surfaced on the next prompt" || no "pending edits not surfaced" "$HOOK_OUT"
run_hook prompt "\"prompt\":$(json_str "$NOTE")"
[ -z "$HOOK_OUT" ] && ok "a notification gets no nudge even with pending edits (the stop audit covers them)" || no "notification nudged about pending edits" "$HOOK_OUT"

T="$WORK/sess/subagents/agent-x.jsonl"; mkdir -p "$WORK/sess/subagents"; : >"$T"
run_hook prompt "\"prompt\":$(json_str "should we use redis or postgres?")"
[ -z "$HOOK_OUT" ] && ok "subagent transcripts are ignored" || no "nudged inside a subagent"

new_transcript p3
FABLE_ADVISOR_PROMPT_NUDGE=0 run_hook prompt "\"prompt\":$(json_str "should we use redis or postgres?")"
[ -z "$HOOK_OUT" ] && ok "PROMPT_NUDGE=0 disables nudges" || no "nudge despite PROMPT_NUDGE=0"

# =============================================================================
section "plan gate (PreToolUse ExitPlanMode)"
new_transcript g1
t_prompt "plan the migration"; t_enter_plan
run_hook plan-gate '"tool_name":"ExitPlanMode","tool_input":{"plan":"..."}'
[ "$(jget "$HOOK_OUT" hookSpecificOutput.permissionDecision)" = "deny" ] && ok "unreviewed plan is denied" || no "not denied" "$HOOK_OUT"
contains "$(jget "$HOOK_OUT" hookSpecificOutput.permissionDecisionReason)" "call ExitPlanMode again" && ok "denial explains how to proceed" || no "reason unhelpful"

t_consult
run_hook plan-gate '"tool_name":"ExitPlanMode"'
[ -z "$HOOK_OUT" ] && ok "consultation after EnterPlanMode opens the gate" || no "gate stayed shut" "$HOOK_OUT"

new_transcript g2
t_consult; t_prompt "now plan the migration"; t_enter_plan
run_hook plan-gate '"tool_name":"ExitPlanMode"'
[ "$(jget "$HOOK_OUT" hookSpecificOutput.permissionDecision)" = "deny" ] && ok "a consultation before the plan episode does not count" || no "stale consult accepted"

new_transcript g3
t_consult; t_plan_mode_entry
run_hook plan-gate '"tool_name":"ExitPlanMode"'
[ "$(jget "$HOOK_OUT" hookSpecificOutput.permissionDecision)" = "deny" ] && ok "shift-tab plan mode (permission-mode entry) starts an episode" || no "permission-mode entry ignored"

new_transcript g4
t_enter_plan; t_health
run_hook plan-gate '"tool_name":"ExitPlanMode"'
[ "$(jget "$HOOK_OUT" hookSpecificOutput.permissionDecision)" = "deny" ] && ok "a health check is not a consultation" || no "health check accepted as consult"

new_transcript g5
t_enter_plan; t_exit_plan; t_denied_result "$LAST_ID"; t_exit_plan; t_denied_result "$LAST_ID"
run_hook plan-gate '"tool_name":"ExitPlanMode","tool_use_id":"toolu_current"'
[ -z "$(jget "$HOOK_OUT" hookSpecificOutput.permissionDecision)" ] && ok "gate stops denying after two denials (with their error results in the transcript)" || no "gate did not release" "$HOOK_OUT"
contains "$(context_of "$HOOK_OUT")" "released" && ok "release is explained to the model" || no "release unexplained"
! contains "$HOOK_OUT" '"allow"' && ok "release never auto-approves the plan (user keeps the veto)" || no "release auto-approved" "$HOOK_OUT"

new_transcript g6
t_enter_plan; t_exit_plan; t_denied_result "$LAST_ID"; t_exit_plan "toolu_current"
run_hook plan-gate '"tool_name":"ExitPlanMode","tool_use_id":"toolu_current"'
[ "$(jget "$HOOK_OUT" hookSpecificOutput.permissionDecision)" = "deny" ] && ok "the in-flight ExitPlanMode is not counted as a prior denial" || no "current attempt miscounted"

new_transcript g6b
t_enter_plan; t_exit_plan; t_denied_result "$LAST_ID"; t_consult
run_hook plan-gate '"tool_name":"ExitPlanMode"'
[ -z "$HOOK_OUT" ] && ok "a denied attempt does not end the episode: consulting after it opens the gate" || no "denial result ended the episode" "$HOOK_OUT"

new_transcript g6c
t_plan_mode_entry; t_prompt "plan the migration"; t_consult; t_prompt "looks good, exit plan mode"; t_plan_mode_entry
run_hook plan-gate '"tool_name":"ExitPlanMode"'
[ -z "$HOOK_OUT" ] && ok "per-prompt permission-mode rows do not restart the episode" || no "per-prompt plan row invalidated the consult" "$HOOK_OUT"

new_transcript g6d
t_mode_entry default; t_plan_mode_entry; t_consult; t_mode_entry acceptEdits; t_plan_mode_entry
run_hook plan-gate '"tool_name":"ExitPlanMode"'
[ "$(jget "$HOOK_OUT" hookSpecificOutput.permissionDecision)" = "deny" ] && ok "leaving and re-entering plan mode starts a new episode" || no "re-entry did not start an episode"

new_transcript g6e
t_mode_entry default; t_mode_entry plan; t_mode_entry plan; t_consult; t_mode_entry plan
run_hook plan-gate '"tool_name":"ExitPlanMode"'
[ -z "$HOOK_OUT" ] && ok "only the switch into plan mode marks the episode start" || no "repeated plan rows re-marked" "$HOOK_OUT"

new_transcript g7
t_enter_plan; t_consult; t_exit_plan; t_tool_result "$LAST_ID"; t_prompt "new plan please"; t_enter_plan
run_hook plan-gate '"tool_name":"ExitPlanMode"'
[ "$(jget "$HOOK_OUT" hookSpecificOutput.permissionDecision)" = "deny" ] && ok "a new planning episode needs its own consultation" || no "previous episode's consult reused"

new_transcript g8
t_enter_plan
FABLE_ADVISOR_ENFORCE=nudge run_hook plan-gate '"tool_name":"ExitPlanMode"'
[ -z "$(jget "$HOOK_OUT" hookSpecificOutput.permissionDecision)" ] && contains "$(context_of "$HOOK_OUT")" "not been reviewed" && ok "ENFORCE=nudge only adds context" || no "nudge mode denied or was silent" "$HOOK_OUT"
FABLE_ADVISOR_PLAN_GATE=0 run_hook plan-gate '"tool_name":"ExitPlanMode"'
[ -z "$HOOK_OUT" ] && ok "PLAN_GATE=0 disables the gate" || no "gate ran despite PLAN_GATE=0"

# =============================================================================
section "edit watch (PostToolUse)"
new_transcript e1
t_prompt "go"; t_edit a.py; t_edit b.py; t_edit c.py
run_hook edit-watch '"tool_name":"Edit","tool_input":{"file_path":"c.py"}'
[ -z "$HOOK_OUT" ] && ok "3 files: no nudge" || no "nudged early" "$HOOK_OUT"
t_edit d.py
run_hook edit-watch '"tool_name":"Edit","tool_input":{"file_path":"d.py"}'
[ "$(jget "$HOOK_OUT" hookSpecificOutput.hookEventName)" = "PostToolUse" ] && contains "$(context_of "$HOOK_OUT")" "4 distinct files" && ok "4th distinct file triggers the nudge" || no "no nudge at 4" "$HOOK_OUT"
run_hook edit-watch '"tool_name":"Edit","tool_input":{"file_path":"d.py"}'
[ -z "$HOOK_OUT" ] && ok "same threshold does not nudge twice" || no "duplicate nudge" "$HOOK_OUT"
t_edit e.py
run_hook edit-watch '"tool_name":"Edit","tool_input":{"file_path":"e.py"}'
[ -z "$HOOK_OUT" ] && ok "5th file: quiet until the next multiple" || no "nudged at 5"
t_edit f.py; t_edit g.py; t_edit h.py
run_hook edit-watch '"tool_name":"Edit","tool_input":{"file_path":"h.py"}'
contains "$(context_of "$HOOK_OUT")" "8 distinct files" && ok "8th file nudges again" || no "no nudge at 8" "$HOOK_OUT"
t_consult; t_edit i.py
run_hook edit-watch '"tool_name":"Edit","tool_input":{"file_path":"i.py"}'
[ -z "$HOOK_OUT" ] && ok "a consultation resets the count" || no "count not reset" "$HOOK_OUT"
t_edit j.py; t_edit k.py; t_edit l.py
run_hook edit-watch '"tool_name":"Edit","tool_input":{"file_path":"l.py"}'
contains "$(context_of "$HOOK_OUT")" "4 distinct files" && ok "count climbs again after the reset" || no "no nudge after reset" "$HOOK_OUT"

new_transcript e2
t_prompt "go"; t_edit a.py; t_edit b.py; t_edit c.py
run_hook edit-watch '"tool_name":"Write","tool_input":{"file_path":"d.py","content":"x"}'
contains "$(context_of "$HOOK_OUT")" "4 distinct files" && ok "the in-flight file counts even before it is in the transcript" || no "in-flight file ignored"

new_transcript e3
t_prompt "go"; t_edit a.py; t_edit b.py; t_edit c.py
run_hook edit-watch "\"tool_name\":\"Bash\",\"tool_input\":{\"command\":$(json_str "cat > src/d.py <<'EOF'
print(1)
EOF")}"
contains "$(context_of "$HOOK_OUT")" "src/d.py" && ok "a Bash heredoc write counts as an edit" || no "heredoc write ignored" "$HOOK_OUT"
new_transcript e4
t_prompt "go"; t_edit a.py; t_edit b.py; t_edit c.py
run_hook edit-watch "\"tool_name\":\"Bash\",\"tool_input\":{\"command\":$(json_str "ls -la && git status >/dev/null 2>&1; echo \">=1\"")}"
[ -z "$HOOK_OUT" ] && ok "a Bash command that writes nothing is not an edit" || no "false positive on read-only Bash" "$HOOK_OUT"
t_bash "sed -i '' 's/a/b/' src/x.json"
run_hook edit-watch "\"tool_name\":\"Bash\",\"tool_input\":{\"command\":$(json_str "sed -i '' 's/a/b/' src/x.json")}"
contains "$(context_of "$HOOK_OUT")" "src/x.json" && ok "sed -i counts as an edit" || no "sed -i ignored" "$HOOK_OUT"

new_transcript e4b
t_prompt "go"; t_edit a.py; t_edit b.py; t_edit c.py
run_hook edit-watch "\"tool_name\":\"Bash\",\"tool_input\":{\"command\":$(json_str "sed -i 's/a/b/g' d.py")}"
ctx="$(context_of "$HOOK_OUT")"
contains "$ctx" "d.py" && ! contains "$ctx" "s/a/b/g" && ok "sed script with flags is not mistaken for a file" || no "sed script counted as a file" "$ctx"
for cmd in 'grep ">" d.py' 'git commit -m "a -> b"' 'python3 -c "print(1 > 0)"' 'echo "x >= 1" | tee /dev/null'; do
  new_transcript "e4c$RANDOM"
  t_prompt "go"; t_edit a.py; t_edit b.py; t_edit c.py
  run_hook edit-watch "\"tool_name\":\"Bash\",\"tool_input\":{\"command\":$(json_str "$cmd")}"
  [ -z "$HOOK_OUT" ] && ok "no phantom file from: $cmd" || no "phantom file from: $cmd" "$HOOK_OUT"
done
new_transcript e4d
t_prompt "go"; t_edit a.py; t_edit b.py; t_edit c.py
run_hook edit-watch "\"tool_name\":\"Bash\",\"tool_input\":{\"command\":$(json_str "cat <<'EOF' > d.py
x > y
EOF")}"
contains "$(context_of "$HOOK_OUT")" "d.py" && ok "heredoc with the redirect on the << line counts" || no "same-line heredoc redirect missed" "$HOOK_OUT"

# cd: relative targets resolve against a cd to a known dir; after a cd we
# cannot resolve ($VAR, -) they are skipped rather than guessed.
bw() { py -c 'import sys; sys.path.insert(0, sys.argv[1]); import advisor_hooks as h; print(" ".join(h.bash_write_targets(sys.argv[2])))' "$BIN" "$1"; }
[ -z "$(bw 'cd $R && cat > tests/t.py')" ] && ok "cd \$VAR: relative writes after it are not counted" || no "cd \$VAR relative write counted" "$(bw 'cd $R && cat > tests/t.py')"
[ -z "$(bw 'cd /private/tmp/x && echo a > f.txt')" ] && ok "cd into a temp dir: relative writes there are not project edits" || no "temp-dir relative write counted"
[ "$(bw 'cd /work/proj && echo a > f.txt')" = "/work/proj/f.txt" ] && ok "cd to an absolute dir: relative writes resolve against it" || no "cd abs resolution wrong" "$(bw 'cd /work/proj && echo a > f.txt')"
[ "$(bw 'cd sub && echo a > f.txt')" = "sub/f.txt" ] && ok "relative cd from the session dir keeps project-relative paths" || no "relative cd wrong" "$(bw 'cd sub && echo a > f.txt')"
[ "$(bw '(cd /tmp/a && echo > z) ; echo > y')" = "y" ] && ok "a cd inside ( ... ) ends with the subshell" || no "subshell cd leaked" "$(bw '(cd /tmp/a && echo > z) ; echo > y')"
# Pure path classification, nothing is written: the default config dir is safe here.
[ -z "$(CLAUDE_CONFIG_DIR='' bw 'cd ~/.claude/plans && cat > p.md')" ] && ok "cd into Claude's plans dir: relative writes are not project edits" || no "plans-dir write counted" "$(CLAUDE_CONFIG_DIR='' bw 'cd ~/.claude/plans && cat > p.md')"
[ "$(bw 'cat > f && cd $R && cat > g')" = "f" ] && ok "writes before an unresolvable cd still count" || no "pre-cd write lost" "$(bw 'cat > f && cd $R && cat > g')"
[ -z "$(bw 'if true; then cd $R; cat > g; fi')" ] && ok "cd after 'then' is recognised" || no "cd after then missed" "$(bw 'if true; then cd $R; cat > g; fi')"
[ "$(bw 'cd ./ && echo > ./f')" = "f" ] && ok "joined paths are normalised (./f == f)" || no "join not normalised" "$(bw 'cd ./ && echo > ./f')"
bwc() { py -c 'import sys; sys.path.insert(0, sys.argv[1]); import advisor_hooks as h; print(" ".join(h.bash_write_targets(sys.argv[2], sys.argv[3])))' "$BIN" "$1" "$2"; }
[ "$(bwc "sed -i '' s/a/b/ assets/x.svg" /work/repo)" = "/work/repo/assets/x.svg" ] && ok "with the command's cwd, relative targets come back absolute (dedupes with Edit/Write paths)" || no "cwd not applied" "$(bwc "sed -i '' s/a/b/ assets/x.svg" /work/repo)"
[ -z "$(bwc 'echo > f' /private/tmp/scratch)" ] && ok "a relative write in a temp cwd is not a project edit" || no "temp cwd write counted"
new_transcript e4f
t_prompt "go"; t_edit "$HOOK_CWD/a.py"; t_edit "$HOOK_CWD/b.py"; t_edit "$HOOK_CWD/x.svg"
run_hook edit-watch "\"tool_name\":\"Bash\",\"tool_input\":{\"command\":$(json_str "sed -i '' s/a/b/ x.svg")}"
[ -z "$HOOK_OUT" ] && ok "the same file via Write (absolute) and sed (relative) counts once" || no "relative/absolute duplicate counted" "$HOOK_OUT"
[ -z "$(bwc "$(printf 'mkdir -p /tmp/scratch\ncd /tmp/scratch\necho x > f')" /work/project)" ] && ok "a cd on its own line is followed (multi-line scripts)" || no "multi-line cd missed" "$(bwc "$(printf 'mkdir -p /tmp/scratch\ncd /tmp/scratch\necho x > f')" /work/project)"
[ "$(bwc "$(printf 'echo a > f\ncd $R\necho > g')" /work/project)" = "/work/project/f" ] && ok "multi-line: writes before an unresolvable cd count, after it do not" || no "multi-line cd \$R wrong" "$(bwc "$(printf 'echo a > f\ncd $R\necho > g')" /work/project)"
[ "$(bwc "$(printf 'git commit -m "a\nb" && echo > f')" /work/project)" = "/work/project/f" ] && ok "a newline inside quotes is not a command break" || no "quoted newline broke parsing" "$(bwc "$(printf 'git commit -m "a\nb" && echo > f')" /work/project)"
[ "$(bw 'echo cd > out.txt')" = "out.txt" ] && ok "'cd' as an argument is not a directory change" || no "cd argument misparsed"
new_transcript e4e
t_prompt "go"; t_edit a.py; t_edit b.py; t_edit c.py
run_hook edit-watch "\"tool_name\":\"Bash\",\"tool_input\":{\"command\":$(json_str 'R=/private/tmp/scratch; cd $R && cat > tests/test_calc.py <<EOF
x
EOF')}"
[ -z "$HOOK_OUT" ] && ok "the live false positive (cd \$R && cat > tests/...) no longer nudges" || no "cd \$R write still counted" "$HOOK_OUT"

new_transcript e5
t_prompt "go"; t_edit a.py; t_sidechain_edit s1.py; t_sidechain_edit s2.py; t_sidechain_edit s3.py
run_hook edit-watch '"tool_name":"Edit","tool_input":{"file_path":"b.py"}'
[ -z "$HOOK_OUT" ] && ok "sidechain (subagent) edits in the main transcript are not counted" || no "sidechain edits counted"
T="$WORK/sess/subagents/agent-y.jsonl"; : >"$T"
t_edit a.py; t_edit b.py; t_edit c.py
run_hook edit-watch '"tool_name":"Edit","tool_input":{"file_path":"d.py"}'
[ -z "$HOOK_OUT" ] && ok "subagent transcript path is ignored" || no "nudged inside subagent"

new_transcript e5b
t_prompt "go"
for f in a.py b.py c.py; do run_hook edit-watch "\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$f\"}"; done
[ -z "$HOOK_OUT" ] && ok "lagging transcript: three edits seen only by the hook stay quiet" || no "nudged early on lag" "$HOOK_OUT"
run_hook edit-watch '"tool_name":"Write","tool_input":{"file_path":"d.py"}'
contains "$(context_of "$HOOK_OUT")" "4 distinct files" && ok "lagging transcript: the hook's own memory of earlier edits still triggers the 4th" || no "lag hid the edits" "$HOOK_OUT"
t_consult
run_hook edit-watch '"tool_name":"Write","tool_input":{"file_path":"e.py"}'
[ -z "$HOOK_OUT" ] && ok "a consultation resets the hook's memory too" || no "memory survived the consult" "$HOOK_OUT"

new_transcript e5c
t_prompt "go"; t_edit a.py; t_edit b.py; t_edit c.py
t_edit "$CLAUDE_CONFIG_DIR/plans/some-plan.md"; t_edit "$CLAUDE_CONFIG_DIR/projects/-x/memory/note.md"; t_edit "/tmp/scratch.txt"
run_hook edit-watch "\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$CLAUDE_CONFIG_DIR/plans/other-plan.md\"}"
[ -z "$HOOK_OUT" ] && ok "plan files, memory notes and temp paths are not project edits" || no "non-project paths counted" "$HOOK_OUT"
run_hook stop-audit '"stop_hook_active":false'
[ -z "$HOOK_OUT" ] && ok "stop audit ignores them too" || no "stop audit counted non-project paths" "$HOOK_OUT"

new_transcript e6
t_prompt "go"; t_edit a.py
FABLE_ADVISOR_FILE_THRESHOLD=2 run_hook edit-watch '"tool_name":"Edit","tool_input":{"file_path":"b.py"}'
contains "$(context_of "$HOOK_OUT")" "threshold 2" && ok "FILE_THRESHOLD override is honoured" || no "threshold override ignored" "$HOOK_OUT"
new_transcript e7
t_prompt "go"; t_edit a.py; t_edit b.py; t_edit c.py
FABLE_ADVISOR_EDIT_WATCH=0 run_hook edit-watch '"tool_name":"Edit","tool_input":{"file_path":"d.py"}'
[ -z "$HOOK_OUT" ] && ok "EDIT_WATCH=0 disables the nudge" || no "nudge despite EDIT_WATCH=0"

# =============================================================================
section "stop audit (Stop)"
new_transcript s1
t_prompt "implement the feature"; t_edit a.py; t_edit b.py; t_edit c.py; t_edit d.py
run_hook stop-audit '"stop_hook_active":false'
[ "$(jget "$HOOK_OUT" decision)" = "block" ] && ok "a 4-file turn with no consultation is held" || no "not held" "$HOOK_OUT"
contains "$(jget "$HOOK_OUT" reason)" "verification review" && ok "hold asks for a verification review" || no "reason unhelpful"
contains "$(jget "$HOOK_OUT" reason)" "a.py, b.py, c.py, d.py" && ok "hold lists the files" || no "files missing from reason"
run_hook stop-audit '"stop_hook_active":false'
[ -z "$HOOK_OUT" ] && ok "the same turn is never held twice" || no "held twice" "$HOOK_OUT"

new_transcript s2
t_prompt "implement"; t_edit a.py; t_edit b.py; t_edit c.py; t_edit d.py
run_hook stop-audit '"stop_hook_active":true'
[ -z "$HOOK_OUT" ] && ok "stop_hook_active short-circuits (loop guard)" || no "blocked despite stop_hook_active"

new_transcript s3
t_prompt "implement"; t_consult; t_edit a.py; t_edit b.py; t_edit c.py; t_edit d.py
run_hook stop-audit '"stop_hook_active":false'
[ -z "$HOOK_OUT" ] && ok "a consultation in the turn satisfies the audit" || no "held despite consult" "$HOOK_OUT"

new_transcript s4
t_prompt "plan it"; t_consult; t_prompt "go ahead"; t_edit a.py; t_edit b.py; t_edit c.py; t_edit d.py
run_hook stop-audit '"stop_hook_active":false'
[ "$(jget "$HOOK_OUT" decision)" = "block" ] && ok "a consultation in an earlier turn does not cover this turn's edits" || no "previous-turn consult reused"

new_transcript s5
t_prompt "implement"; t_edit a.py; t_edit b.py; t_edit c.py
run_hook stop-audit '"stop_hook_active":false'
[ -z "$HOOK_OUT" ] && ok "3 files: not held" || no "held under threshold"

new_transcript s6
t_prompt "first"; t_edit a.py; t_edit b.py; t_edit c.py; t_prompt "second"; t_edit d.py
run_hook stop-audit '"stop_hook_active":false'
[ -z "$HOOK_OUT" ] && ok "edits from earlier turns are not counted" || no "earlier turns counted"

new_transcript s7
t_prompt "implement"; t_edit a.py; t_edit b.py; t_edit c.py; t_edit d.py; t_meta "[hook feedback] keep going"
run_hook stop-audit '"stop_hook_active":false'
[ "$(jget "$HOOK_OUT" decision)" = "block" ] && ok "system-injected (isMeta) messages do not start a new turn" || no "isMeta reset the turn"

new_transcript s8
t_prompt "implement"; t_edit a.py; t_edit b.py; t_edit c.py; t_edit d.py; t_edit a.py; t_edit b.py
run_hook stop-audit '"stop_hook_active":false'
contains "$(jget "$HOOK_OUT" reason)" "edited 4 files" && ok "repeat edits of the same file count once" || no "duplicates counted" "$HOOK_OUT"

new_transcript s9
t_prompt "implement"; t_edit a.py; t_edit b.py; t_edit c.py; t_edit d.py
FABLE_ADVISOR_ENFORCE=nudge run_hook stop-audit '"stop_hook_active":false'
[ -z "$HOOK_OUT" ] && ok "ENFORCE=nudge never holds a turn" || no "held in nudge mode"
FABLE_ADVISOR_STOP_AUDIT=0 run_hook stop-audit '"stop_hook_active":false'
[ -z "$HOOK_OUT" ] && ok "STOP_AUDIT=0 disables the hold" || no "held despite STOP_AUDIT=0"
T="$WORK/sess/subagents/agent-z.jsonl"; : >"$T"
t_prompt "x"; t_edit a.py; t_edit b.py; t_edit c.py; t_edit d.py
run_hook stop-audit '"stop_hook_active":false'
[ -z "$HOOK_OUT" ] && ok "subagent transcripts are never held" || no "held a subagent"

# =============================================================================
section "consultations recorded by the PostToolUse hook (transcript lag)"
new_transcript r1
t_prompt "plan it"; t_enter_plan
run_hook post-tool '"tool_name":"Agent","tool_use_id":"toolu_adv1","tool_input":{"subagent_type":"fable-advisor:advisor","model":"fable","prompt":"Critique this plan","description":"consult"}'
[ -z "$HOOK_OUT" ] && ok "recording a consultation is silent" || no "recorder produced output" "$HOOK_OUT"
grep -q "event=consult-recorded" "$FABLE_ADVISOR_HOME/events.log" && ok "the consultation is logged" || no "consult not logged"
run_hook plan-gate '"tool_name":"ExitPlanMode"'
[ -z "$HOOK_OUT" ] && ok "plan gate accepts a recorded consultation the transcript does not show yet" || no "gate ignored recorded consult" "$HOOK_OUT"

new_transcript r2
t_prompt "plan it"; t_enter_plan
printf '{"last_consult_ts": 1, "consults": 1}' >"$FABLE_ADVISOR_HOME/state/$SID.json"
run_hook plan-gate '"tool_name":"ExitPlanMode"'
[ "$(jget "$HOOK_OUT" hookSpecificOutput.permissionDecision)" = "deny" ] && ok "a recorded consultation older than the episode does not count" || no "stale recorded consult accepted"

new_transcript r3
t_prompt "implement"; t_edit a.py; t_edit b.py; t_edit c.py; t_edit d.py
run_hook post-tool '"tool_name":"Agent","tool_use_id":"toolu_adv2","tool_input":{"subagent_type":"fable-advisor:advisor","prompt":"verify","description":"review"}'
run_hook stop-audit '"stop_hook_active":false'
[ -z "$HOOK_OUT" ] && ok "stop audit accepts a recorded consultation the transcript does not show yet" || no "stop audit ignored recorded consult" "$HOOK_OUT"

new_transcript r4
t_prompt "implement"
run_hook post-tool '"tool_name":"Agent","tool_use_id":"toolu_health","tool_input":{"subagent_type":"fable-advisor:advisor","prompt":"Health check. Do not read any files.","description":"health"}'
[ ! -f "$FABLE_ADVISOR_HOME/state/$SID.json" ] && ok "a health check is not recorded as a consultation" || no "health check recorded"
run_hook post-tool '"tool_name":"Agent","tool_use_id":"toolu_other","tool_input":{"subagent_type":"Explore","prompt":"find","description":"x"}'
[ ! -f "$FABLE_ADVISOR_HOME/state/$SID.json" ] && ok "other subagents are not recorded" || no "other agent recorded"

new_transcript r5
t_prompt "go"; t_edit a.py; t_edit b.py; t_edit c.py
run_hook post-tool '"tool_name":"Edit","tool_input":{"file_path":"c.py"}'
run_hook post-tool '"tool_name":"Agent","tool_use_id":"toolu_adv3","tool_input":{"subagent_type":"fable-advisor:advisor","prompt":"review","description":"r"}'
run_hook post-tool '"tool_name":"Edit","tool_input":{"file_path":"d.py"}'
[ -z "$HOOK_OUT" ] && ok "a recorded consultation resets the edit tally before the transcript shows it" || no "tally not reset by recorded consult" "$HOOK_OUT"
t_tool_use Agent '{"subagent_type":"fable-advisor:advisor","prompt":"review","description":"r"}' "toolu_adv3"
t_edit d.py; t_edit e.py; t_edit f.py
run_hook post-tool '"tool_name":"Edit","tool_input":{"file_path":"f.py"}'
[ -z "$HOOK_OUT" ] && ok "once the transcript shows the dispatch, edits before it (a,b,c) stay excluded" || no "old edits re-counted" "$HOOK_OUT"
t_edit g.py
run_hook post-tool '"tool_name":"Edit","tool_input":{"file_path":"g.py"}'
contains "$(context_of "$HOOK_OUT")" "4 distinct files" && ok "edits after the recorded dispatch count (d,e,f,g)" || no "post-consult edits not counted" "$HOOK_OUT"

new_transcript r6
t_prompt "implement"
for f in a.py b.py c.py d.py; do run_hook post-tool "\"tool_name\":\"Write\",\"prompt_id\":\"turn-1\",\"tool_input\":{\"file_path\":\"$f\"}"; done
run_hook stop-audit '"stop_hook_active":false,"prompt_id":"turn-1"'
[ "$(jget "$HOOK_OUT" decision)" = "block" ] && ok "stop audit counts this turn's edits from state when the transcript lags" || no "lagging turn edits missed" "$HOOK_OUT"
new_transcript r7
t_prompt "implement"
for f in a.py b.py c.py d.py; do run_hook post-tool "\"tool_name\":\"Write\",\"prompt_id\":\"turn-1\",\"tool_input\":{\"file_path\":\"$f\"}"; done
run_hook stop-audit '"stop_hook_active":false,"prompt_id":"turn-2"'
[ -z "$HOOK_OUT" ] && ok "state edits from another turn are not counted" || no "other turn's edits counted"

# =============================================================================
section "status"
new_transcript st1
t_prompt "plan"; t_health; t_consult; t_prompt "go"; t_edit a.py; t_bash "cat > b.md <<EOF
x
EOF"
run_hook stop-audit '"stop_hook_active":false' # populates nothing (2 files) but exercises the log path
run_hook status ''
contains "$HOOK_OUT" "advisor consultations: 1" && ok "counts consultations" || no "consult count wrong" "$HOOK_OUT"
contains "$HOOK_OUT" "health checks (not counted as consultations): 1" && ok "reports health checks separately" || no "health checks missing"
contains "$HOOK_OUT" "user turns: 2, turns with a consultation: 1" && ok "reports turns with a consultation" || no "turn stats wrong" "$HOOK_OUT"
contains "$HOOK_OUT" "since last consultation: 2 (a.py, b.md)" && ok "counts Edit and Bash writes since the last consultation" || no "pending files wrong" "$HOOK_OUT"
contains "$HOOK_OUT" "enforcement: full" && ok "reports the enforcement mode" || no "mode missing"

# =============================================================================
section "subagents (live 2.1.308 input: parent transcript_path + agent_id)"
WK="feature-crew:feature-builder"
# new_worker <name> <agent_id>: MT = parent transcript, WT = the worker's own,
# at the path Claude Code uses: <parent minus .jsonl>/subagents/agent-<id>.jsonl
new_worker() {
  new_transcript "$1"
  MT="$T"
  local id="${2#agent-}"
  WT="$WORK/$1/subagents/agent-$id.jsonl"
  mkdir -p "$WORK/$1/subagents"
  : >"$WT"
}
# in_worker <builder> [args...]: append rows to WT, marked as sidechain rows.
in_worker() {
  local before
  T="$WT"
  before="$(wc -l <"$WT")"
  "$@"
  py -c '
import sys
p, skip = sys.argv[1], int(sys.argv[2])
rows = open(p).read().splitlines()
out = rows[:skip] + [r.replace("{", "{\"isSidechain\":true,", 1) for r in rows[skip:]]
open(p, "w").write("\n".join(out) + "\n")' "$WT" "$before"
  T="$MT"
}
worker_hook() {
  # worker_hook <subcommand> <agent_id> <agent_type> [extra-json]
  run_hook "$1" "\"agent_id\":\"$2\",\"agent_type\":\"$3\"${4:+,$4}"
}
wstate() { printf '%s' "$FABLE_ADVISOR_HOME/state/$SID--$1.json"; }

new_worker w1 aw1
t_prompt "dispatch a worker"
in_worker t_prompt "Build the credit API"
for f in a.py b.py c.py; do in_worker t_edit "$f"; done
worker_hook post-tool aw1 "$WK" '"tool_name":"Edit","prompt_id":"p-main","tool_input":{"file_path":"d.py"}'
contains "$(context_of "$HOOK_OUT")" "You have edited 4 distinct files" && ok "enforced worker: its own transcript is scanned and it is nudged at 4" || no "worker not nudged" "$HOOK_OUT"
[ -f "$(wstate aw1)" ] && ok "enforced worker: state lives in its own file (sid--agent_id)" || no "no worker state file"
if [ ! -f "$FABLE_ADVISOR_HOME/state/$SID.json" ]; then ok "enforced worker edits never touch the parent's state (leak fix)"; else no "parent state written by worker" "$(cat "$FABLE_ADVISOR_HOME/state/$SID.json")"; fi
run_hook stop-audit '"stop_hook_active":false,"prompt_id":"p-main"'
[ -z "$HOOK_OUT" ] && ok "parent turn is not held for a worker's edits" || no "parent held for worker edits" "$HOOK_OUT"
worker_hook post-tool aw1 "$WK" '"tool_name":"Agent","tool_use_id":"toolu_w1","tool_input":{"subagent_type":"fable-advisor:advisor","prompt":"review my diff","description":"w review"}'
grep -q '"last_consult_ts"' "$(wstate aw1)" && ok "worker's advisor dispatch is recorded for the worker" || no "worker consult not recorded"
[ ! -f "$FABLE_ADVISOR_HOME/state/$SID.json" ] && ok "worker's consult does not count for the parent" || no "worker consult leaked to parent"

new_worker w2 agent-aw2
in_worker t_prompt "Build it"
in_worker t_edit a.py
worker_hook post-tool agent-aw2 "$WK" '"tool_name":"Edit","tool_input":{"file_path":"b.py"}'
grep -q '"a.py"' "$(wstate agent-aw2)" && ok "agent_id with an agent- prefix finds agent-<id>.jsonl" || no "prefixed agent_id path wrong" "$(cat "$(wstate agent-aw2)" 2>/dev/null)"

new_worker w3 aw3
in_worker t_prompt "Build it"
in_worker t_edit a.py; in_worker t_edit b.py; in_worker t_edit c.py
worker_hook post-tool aw3 "feature-builder" '"tool_name":"Edit","tool_input":{"file_path":"d.py"}'
contains "$(context_of "$HOOK_OUT")" "You have edited 4" && ok "bare agent_type 'feature-builder' is enforced too" || no "bare name not matched" "$HOOK_OUT"

new_worker w4 aw4
t_prompt "go"
for f in a.py b.py c.py d.py; do
  worker_hook post-tool aw4 general-purpose "\"tool_name\":\"Write\",\"prompt_id\":\"turn-gp\",\"tool_input\":{\"file_path\":\"$f\"}"
done
grep -q '"d.py"' "$FABLE_ADVISOR_HOME/state/$SID.json" 2>/dev/null && ok "in-tree subagent edits still count for the parent" || no "general-purpose edits not attributed to parent"
run_hook stop-audit '"stop_hook_active":false,"prompt_id":"turn-gp"'
[ "$(jget "$HOOK_OUT" decision)" = "block" ] && ok "parent is held for edits it delegated to an in-tree subagent" || no "delegated edits laundered" "$HOOK_OUT"
[ ! -f "$(wstate aw4)" ] && ok "in-tree subagents get no worker state" || no "worker state for general-purpose"

new_worker w5 aw5
worker_hook post-tool aw5 fable-advisor:advisor '"tool_name":"Bash","tool_input":{"command":"echo x > out.txt"}'
[ -z "$HOOK_OUT" ] && [ ! -f "$FABLE_ADVISOR_HOME/state/$SID.json" ] && ok "the advisor's own tool calls are silent" || no "advisor calls counted"

new_worker w6 aw6
in_worker t_prompt "Build it"
in_worker t_edit a.py; in_worker t_edit b.py; in_worker t_edit c.py
FABLE_ADVISOR_SUBAGENTS=none worker_hook post-tool aw6 "$WK" '"tool_name":"Edit","tool_input":{"file_path":"d.py"}'
[ ! -f "$(wstate aw6)" ] && ok "FABLE_ADVISOR_SUBAGENTS=none: no worker enforcement" || no "worker enforced despite none"
FABLE_ADVISOR_SUBAGENTS="my:agent" worker_hook post-tool aw6 "my:agent" '"tool_name":"Edit","tool_input":{"file_path":"d.py"}'
[ -f "$(wstate aw6)" ] && ok "FABLE_ADVISOR_SUBAGENTS selects other agent types" || no "custom worker list ignored"

new_transcript ss-w
worker_hook subagent-start aw7 "$WK"
[ "$(jget "$HOOK_OUT" hookSpecificOutput.hookEventName)" = "SubagentStart" ] && contains "$(context_of "$HOOK_OUT")" "Advisor policy for this worker" && ok "subagent-start injects the worker policy into enforced types" || no "no worker policy" "$HOOK_OUT"
contains "$(context_of "$HOOK_OUT")" "absolute path" && ok "worker policy says the advisor reads by absolute path" || no "path guidance missing"
worker_hook subagent-start aw8 Explore
[ -z "$HOOK_OUT" ] && ok "subagent-start is silent for other types" || no "policy injected into Explore"
grep -q "event=subagent-start agent_type=Explore enforced=0" "$FABLE_ADVISOR_HOME/events.log" && ok "subagent-start logs the raw agent_type" || no "agent_type not logged"
FABLE_ADVISOR_ENFORCE=off worker_hook subagent-start aw7 "$WK"
[ -z "$HOOK_OUT" ] && ok "ENFORCE=off: no worker policy" || no "worker policy despite off"

new_worker st1 as1
in_worker t_prompt "Build it"
for f in a.py b.py c.py d.py; do in_worker t_edit "$f"; done
worker_hook subagent-stop as1 "$WK" '"stop_hook_active":false,"last_assistant_message":"DONE\nbranch: crew/x"'
[ "$(jget "$HOOK_OUT" decision)" = "block" ] && contains "$(jget "$HOOK_OUT" reason)" "edited 4 files since your last advisor consultation" && ok "subagent-stop holds an unreviewed 4-file worker" || no "worker not held" "$HOOK_OUT"
contains "$(jget "$HOOK_OUT" reason)" "absolute path" && ok "hold reason asks for a diff file by absolute path" || no "hold reason lacks path guidance"
r="$(jget "$HOOK_OUT" reason)"
contains "$r" "git -C <worktree> rev-parse --absolute-git-dir" && ! contains "$r" '"$(git' && ok "hold reason gives plain git -C commands the worktree guard accepts" || no "hold reason uses a refused git form"
worker_hook subagent-stop as1 "$WK" '"stop_hook_active":false,"last_assistant_message":"DONE"'
[ -z "$HOOK_OUT" ] && ok "the worker hold fires once per prompt" || no "held twice" "$HOOK_OUT"
grep -q "event=subagent-stop-hold" "$FABLE_ADVISOR_HOME/events.log" && ok "events.log records worker holds" || no "worker hold not logged"

new_worker st2 as2
in_worker t_prompt "Build it"
for f in a.py b.py c.py d.py; do in_worker t_edit "$f"; done
worker_hook subagent-stop as2 "$WK" '"stop_hook_active":true'
[ -z "$HOOK_OUT" ] && ok "stop_hook_active: no second hold" || no "held on stop_hook_active"
worker_hook subagent-stop as2 "$WK" "\"stop_hook_active\":false,\"last_assistant_message\":$(json_str "NEEDS-ANSWER
branch: crew/x
question: which?")"
[ -z "$HOOK_OUT" ] && ok "a worker stopping with NEEDS-ANSWER is not held" || no "held a NEEDS-ANSWER" "$HOOK_OUT"
worker_hook subagent-stop as2 "$WK" "\"stop_hook_active\":false,\"last_assistant_message\":$(json_str '```
NEEDS-ANSWER
```')"
[ -z "$HOOK_OUT" ] && ok "NEEDS-ANSWER inside a code fence is recognised" || no "fenced NEEDS-ANSWER held"
in_worker t_tool_use Bash '{"command":"git commit -m wip"}'
printf '{"type":"assistant","isSidechain":true,"message":{"role":"assistant","content":[{"type":"text","text":"NEEDS-ANSWER\\nbranch: crew/x\\nquestion: which?"}]}}\n' >>"$WT"
worker_hook subagent-stop as2 "$WK" '"stop_hook_active":false'
[ -z "$HOOK_OUT" ] && ok "without last_assistant_message, NEEDS-ANSWER is read from the worker transcript" || no "fallback missed NEEDS-ANSWER" "$HOOK_OUT"
grep -q "event=subagent-stop-pass reason=needs-answer agent=as2" "$FABLE_ADVISOR_HOME/events.log" && ok "worker log lines carry agent=<id>" || no "agent tag missing in worker log"
worker_hook subagent-stop as2 Explore '"stop_hook_active":false'
[ -z "$HOOK_OUT" ] && ok "subagent-stop ignores other agent types" || no "held an Explore agent"
FABLE_ADVISOR_SUBAGENT_STOP=0 worker_hook subagent-stop as2 "$WK" '"stop_hook_active":false'
[ -z "$HOOK_OUT" ] && ok "SUBAGENT_STOP=0 disables the worker hold" || no "held despite SUBAGENT_STOP=0"
FABLE_ADVISOR_ENFORCE=nudge worker_hook subagent-stop as2 "$WK" '"stop_hook_active":false'
[ -z "$HOOK_OUT" ] && ok "ENFORCE=nudge never holds a worker" || no "worker held in nudge mode"

new_worker st3 as3
in_worker t_prompt "Build it"
for f in a.py b.py c.py d.py; do in_worker t_edit "$f"; done
in_worker t_consult
in_worker t_edit e.py
worker_hook subagent-stop as3 "$WK" '"stop_hook_active":false'
[ -z "$HOOK_OUT" ] && ok "edits before the worker's consultation are not held" || no "held after a consultation" "$HOOK_OUT"

new_worker st4 as4
in_worker t_prompt "Build it"
for f in a.py b.py; do in_worker t_edit "$f"; done
in_worker t_prompt "Answer: use option A"
for f in c.py d.py; do in_worker t_edit "$f"; done
worker_hook subagent-stop as4 "$WK" '"stop_hook_active":false'
[ "$(jget "$HOOK_OUT" decision)" = "block" ] && ok "the count spans resumes (since last consult, not last prompt)" || no "resume reset the count" "$HOOK_OUT"

new_worker st5 as5
OTHER="$WORK/elsewhere/agent-as5.jsonl"; mkdir -p "$WORK/elsewhere"; : >"$OTHER"
WT="$OTHER"
in_worker t_prompt "Build it"
for f in a.py b.py c.py d.py; do in_worker t_edit "$f"; done
worker_hook subagent-stop as5 "$WK" "\"stop_hook_active\":false,\"agent_transcript_path\":\"$OTHER\""
[ "$(jget "$HOOK_OUT" decision)" = "block" ] && ok "agent_transcript_path wins over the derived path" || no "agent_transcript_path ignored" "$HOOK_OUT"

# =============================================================================
section "robustness"
HOOK_OUT="$(printf 'not json' | bash "$BIN/hook.sh" prompt 2>/dev/null)"; rc=$?
[ "$rc" -eq 0 ] && [ -z "$HOOK_OUT" ] && ok "garbage stdin: exit 0, no output" || no "garbage stdin misbehaved" "rc=$rc out=$HOOK_OUT"
HOOK_OUT="$(printf '' | bash "$BIN/hook.sh" stop-audit 2>/dev/null)"; rc=$?
[ "$rc" -eq 0 ] && [ -z "$HOOK_OUT" ] && ok "empty stdin: exit 0, no output" || no "empty stdin misbehaved"
T="$WORK/does-not-exist.jsonl"; SID="sid-missing"
run_hook session-start '"source":"resume"'
contains "$(context_of "$HOOK_OUT")" "Advisor policy" && ok "missing transcript still injects the policy" || no "policy missing without transcript"
run_hook stop-audit '"stop_hook_active":false'
[ "$HOOK_RC" -eq 0 ] && [ -z "$HOOK_OUT" ] && ok "missing transcript: stop audit is silent" || no "stop audit misbehaved without transcript"
HOOK_OUT="$(printf '{}' | PATH=/nonexistent /bin/bash "$BIN/hook.sh" prompt 2>/dev/null)"; rc=$?
[ "$rc" -eq 0 ] && [ -z "$HOOK_OUT" ] && ok "no python3 on PATH: wrapper is a silent no-op" || no "wrapper failed without python3" "rc=$rc out=$HOOK_OUT"
HOOK_OUT="$(bash "$BIN/hook.sh" 2>/dev/null)"; rc=$?
[ "$rc" -eq 0 ] && ok "no subcommand: exit 0" || no "usage error is non-zero"
grep -q "event=stop-hold" "$FABLE_ADVISOR_HOME/events.log" && ok "events.log records holds" || no "events.log missing hold"
grep -q "event=plan-gate-deny" "$FABLE_ADVISOR_HOME/events.log" && ok "events.log records denials" || no "events.log missing denial"

# =============================================================================
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

#!/usr/bin/env bash
# Thin wrapper for bin/model-check.py (UserPromptSubmit hook, and the CLI the
# orchestrator policy falls back to). A missing Python never surfaces as a
# hook error: without one the check is a silent no-op.
set -u
[ "${FEATURE_CREW:-on}" = off ] && exit 0
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Windows (Git Bash): `python3` is usually the Microsoft Store stub, which is on
# PATH but exits 49 without running anything, and python.org installs ship only
# python.exe / py.exe. Probe for an interpreter that actually runs. Elsewhere
# keep the zero-cost python3 lookup. (Same probe as fable-advisor's hook.sh.)
case "${OSTYPE:-}" in
  msys* | cygwin* | win*)
    PY=""
    for c in python3 python "py -3"; do
      if $c -c 'import sys; sys.exit(sys.version_info[0] != 3)' >/dev/null 2>&1; then
        PY="$c"
        break
      fi
    done
    [ -n "$PY" ] || exit 0
    ;;
  *)
    command -v python3 >/dev/null 2>&1 || exit 0
    PY=python3
    ;;
esac

# Hook payloads and transcripts are UTF-8; Windows Python otherwise decodes
# pipes and files with the ANSI code page.
export PYTHONUTF8=1
exec $PY "$DIR/model-check.py" "$@"

#!/usr/bin/env bash
# Thin wrapper so hooks.json has one entry point and a missing python3 never
# surfaces as a hook error: without python3 every hook is a silent no-op.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Windows (Git Bash): `python3` is usually the Microsoft Store stub, which is on
# PATH but exits 49 without running anything, and python.org installs ship only
# python.exe / py.exe. Probe for an interpreter that actually runs. Elsewhere
# keep the zero-cost python3 lookup.
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
exec $PY "$DIR/advisor_hooks.py" "$@"

#!/usr/bin/env bash
# Thin wrapper so hooks.json has one entry point and a missing python3 never
# surfaces as a hook error: without python3 every hook is a silent no-op.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
command -v python3 >/dev/null 2>&1 || exit 0
exec python3 "$DIR/advisor_hooks.py" "$@"

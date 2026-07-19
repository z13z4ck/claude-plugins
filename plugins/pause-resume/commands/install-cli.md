---
description: Put the agent-pause command on PATH so you can pause from any terminal
allowed-tools: Bash
---

Install the `agent-pause` CLI onto the user's PATH.

This matters more than it sounds. Pausing a *running* agent has to come from
outside the session — a frozen session cannot process anything you type into
it — so the CLI needs to be reachable from whatever terminal the user happens
to have open, without remembering a plugin path.

**1. Pick a target directory.** Prefer one already on PATH and writable
without sudo. Check in this order and use the first that qualifies:

```bash
echo "$PATH" | tr ':' '\n' | grep -E "$HOME" | head -5
ls -d "$HOME/.local/bin" "$HOME/bin" /usr/local/bin 2>/dev/null
```

`~/.local/bin` is the usual answer. Create it if missing. Only fall back to
`/usr/local/bin` if the user's PATH has no writable personal directory, and say
that it needs sudo before running anything that asks for a password.

**2. Symlink rather than copy**, so plugin updates take effect automatically:

```bash
ln -sf "${CLAUDE_PLUGIN_ROOT}/bin/agent-pause" "<target>/agent-pause"
```

**3. Verify it actually resolves** — a symlink into a directory that is not
really on PATH is a silent failure:

```bash
command -v agent-pause && agent-pause status
```

If `command -v` finds nothing, the directory is not on PATH. Tell the user the
exact line to add to their shell rc file (`~/.zshrc` on macOS by default), and
offer to append it rather than doing it unasked.

**4. Show them the two commands that matter**, and nothing else:

```
agent-pause pause -r "why"    # freeze every running agent at its next tool call
agent-pause resume            # let them continue
```

Mention `agent-pause --help` for the rest.

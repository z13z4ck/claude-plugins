#!/usr/bin/env python3
"""Reconstruct a resume brief from a Claude Code transcript.

Why this exists: the freeze gate handles a *planned* pause. This handles the
unplanned one — the tunnel, the dead battery, the SIGKILL. Claude Code appends
every turn to ~/.claude/projects/<slug>/<session-id>.jsonl as it goes, so even
when the process dies without warning, the state is already durable on disk.
This turns that raw log back into something an agent can be handed to pick up.

Reads only what it needs: last user instruction, recent assistant reasoning,
files touched, commands run, and the live todo list if there is one.
"""

import argparse
import json
import os
import re
import sys
import time
from pathlib import Path

MAX_TEXT = 1200
MAX_TOOLS = 25
MAX_FILES = 20

# Slash commands reach the transcript wrapped in synthetic tags rather than as
# the text the user typed. Left raw they make a brief read like XML soup, so
# collapse them back into the "/name args" the user actually entered.
_CMD_NAME = re.compile(r"<command-name>(.*?)</command-name>", re.S)
_CMD_ARGS = re.compile(r"<command-args>(.*?)</command-args>", re.S)
_CMD_STDOUT = re.compile(r"<local-command-stdout>(.*?)</local-command-stdout>", re.S)
_ANY_TAG = re.compile(r"</?(command-message|command-contents|command-name|command-args|local-command-stdout)>")


def normalize_user_text(text):
    """Collapse slash-command wrappers into something a human would recognise."""
    if not text or "<" not in text:
        return text

    name = _CMD_NAME.search(text)
    args = _CMD_ARGS.search(text)
    if name:
        cmd = name.group(1).strip()
        arg = args.group(1).strip() if args else ""
        return f"{cmd} {arg}".strip()

    out = _CMD_STDOUT.search(text)
    if out and len(_ANY_TAG.sub("", text).strip()) == len(out.group(1).strip()):
        # The whole message is just command output echoed back — not an
        # instruction, so let the caller drop it.
        return ""

    return _ANY_TAG.sub("", text).strip()


def _iter_entries(path):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    yield json.loads(line)
                except json.JSONDecodeError:
                    # A transcript truncated mid-write by a hard kill is exactly
                    # the case we are here to salvage. Skip the partial line.
                    continue
    except OSError as exc:
        print(f"checkpoint: cannot read transcript: {exc}", file=sys.stderr)


def _blocks(entry):
    msg = entry.get("message")
    if not isinstance(msg, dict):
        return []
    content = msg.get("content")
    if isinstance(content, str):
        return [{"type": "text", "text": content}]
    if isinstance(content, list):
        return [b for b in content if isinstance(b, dict)]
    return []


def _text_of(entry):
    out = []
    for b in _blocks(entry):
        if b.get("type") == "text" and b.get("text"):
            out.append(b["text"])
    return "\n".join(out).strip()


def _clip(text, limit=MAX_TEXT):
    text = (text or "").strip()
    if len(text) <= limit:
        return text
    return text[:limit].rstrip() + " …[truncated]"


def collect(path):
    state = {
        "session_id": None,
        "cwd": None,
        "branch": None,
        "first_ts": None,
        "last_ts": None,
        "user_messages": [],
        "assistant_texts": [],
        "tools": [],
        "files": [],
        "todos": None,
        "turns": 0,
    }

    for entry in _iter_entries(path):
        etype = entry.get("type")
        state["session_id"] = entry.get("sessionId") or state["session_id"]
        state["cwd"] = entry.get("cwd") or state["cwd"]
        state["branch"] = entry.get("gitBranch") or state["branch"]
        ts = entry.get("timestamp")
        if ts:
            state["first_ts"] = state["first_ts"] or ts
            state["last_ts"] = ts

        if etype == "user":
            # Tool results also arrive as role=user; only real typed input counts
            # as an instruction, so filter to entries carrying a prompt id and
            # no tool_result block.
            blocks = _blocks(entry)
            if any(b.get("type") == "tool_result" for b in blocks):
                continue
            if entry.get("isMeta"):
                continue
            text = normalize_user_text(_text_of(entry))
            if text:
                state["user_messages"].append(text)

        elif etype == "assistant":
            state["turns"] += 1
            text = _text_of(entry)
            if text:
                state["assistant_texts"].append(text)
            for b in _blocks(entry):
                if b.get("type") != "tool_use":
                    continue
                name = b.get("name") or "?"
                inp = b.get("input") or {}
                if name == "TodoWrite" and isinstance(inp.get("todos"), list):
                    state["todos"] = inp["todos"]
                detail = ""
                if isinstance(inp, dict):
                    for key in ("file_path", "path", "notebook_path"):
                        if inp.get(key):
                            detail = str(inp[key])
                            if detail not in state["files"]:
                                state["files"].append(detail)
                            break
                    else:
                        if inp.get("command"):
                            detail = str(inp["command"]).split("\n")[0][:120]
                        elif inp.get("pattern"):
                            detail = str(inp["pattern"])[:120]
                        elif inp.get("description"):
                            detail = str(inp["description"])[:120]
                state["tools"].append((name, detail))

    return state


def render(state, transcript_path, note=None):
    L = []
    ts = time.strftime("%Y-%m-%d %H:%M:%S %Z")
    L.append("# Resume brief")
    L.append("")
    L.append(f"Captured {ts} from an interrupted or paused Claude Code session.")
    L.append("")
    if note:
        L.append(f"> {note}")
        L.append("")

    L.append("## Where this was")
    L.append("")
    L.append(f"- Working directory: `{state.get('cwd') or 'unknown'}`")
    if state.get("branch"):
        L.append(f"- Git branch: `{state['branch']}`")
    if state.get("session_id"):
        L.append(f"- Previous session: `{state['session_id']}`")
    L.append(f"- Transcript: `{transcript_path}`")
    if state.get("last_ts"):
        L.append(f"- Last activity: {state['last_ts']}")
    L.append(f"- Assistant turns before the interruption: {state['turns']}")
    L.append("")

    todos = state.get("todos")
    if todos:
        L.append("## Task list as of the interruption")
        L.append("")
        for t in todos:
            if not isinstance(t, dict):
                continue
            status = (t.get("status") or "pending").lower()
            mark = {"completed": "x", "in_progress": "~"}.get(status, " ")
            label = t.get("content") or t.get("activeForm") or "?"
            L.append(f"- [{mark}] {label}")
        L.append("")
        L.append("`~` marks the task that was in flight when everything stopped.")
        L.append("")

    if state["user_messages"]:
        L.append("## What the user asked for")
        L.append("")
        L.append("Most recent instruction:")
        L.append("")
        L.append("> " + _clip(state["user_messages"][-1]).replace("\n", "\n> "))
        L.append("")
        if len(state["user_messages"]) > 1:
            L.append("Earlier in the session:")
            L.append("")
            for m in state["user_messages"][-4:-1]:
                L.append(f"- {_clip(m, 200)}")
            L.append("")

    if state["assistant_texts"]:
        L.append("## Where the agent had got to")
        L.append("")
        L.append(_clip(state["assistant_texts"][-1], 1500))
        L.append("")

    if state["files"]:
        L.append("## Files touched")
        L.append("")
        for f in state["files"][-MAX_FILES:]:
            L.append(f"- `{f}`")
        L.append("")

    if state["tools"]:
        L.append("## Recent actions")
        L.append("")
        for name, detail in state["tools"][-MAX_TOOLS:]:
            L.append(f"- **{name}**" + (f" — `{detail}`" if detail else ""))
        L.append("")

    L.append("## How to resume")
    L.append("")
    L.append("1. Confirm the working tree still matches the above (`git status`, `git diff`).")
    L.append("2. Re-read the files listed under *Files touched* before editing them —")
    L.append("   this brief is a summary, not a substitute for the current file contents.")
    L.append("3. Pick up at the first unchecked task, or ask the user if the goal has moved on.")
    L.append("")
    return "\n".join(L)


def newest_transcript(cwd):
    slug = "".join(c if c.isalnum() else "-" for c in str(cwd))
    base = Path(os.environ.get("CLAUDE_CONFIG_DIR", str(Path.home() / ".claude")))
    proj = base / "projects" / slug
    if not proj.is_dir():
        return None
    files = sorted(proj.glob("*.jsonl"), key=lambda p: p.stat().st_mtime, reverse=True)
    return files[0] if files else None


def main():
    ap = argparse.ArgumentParser(description="Build a resume brief from a transcript.")
    ap.add_argument("--transcript")
    ap.add_argument("--cwd", help="Use the newest transcript for this directory.")
    ap.add_argument("--exclude", help="Skip this transcript when using --cwd (e.g. the live session).")
    ap.add_argument("--out", help="Write here instead of stdout.")
    ap.add_argument("--note", help="One-line note recorded at the top of the brief.")
    args = ap.parse_args()

    path = args.transcript
    if not path and args.cwd:
        found = newest_transcript(args.cwd)
        path = str(found) if found else None
    if not path or not os.path.exists(path):
        print("checkpoint: no transcript found", file=sys.stderr)
        return 1

    state = collect(path)
    if not state["turns"] and not state["user_messages"]:
        print("checkpoint: transcript has no recoverable content", file=sys.stderr)
        return 1

    text = render(state, path, note=args.note)

    if args.out:
        out = Path(args.out)
        out.parent.mkdir(parents=True, exist_ok=True)
        tmp = out.with_suffix(out.suffix + f".tmp{os.getpid()}")
        tmp.write_text(text, encoding="utf-8")
        tmp.replace(out)
        print(str(out))
    else:
        print(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())

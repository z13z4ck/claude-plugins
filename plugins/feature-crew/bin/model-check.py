#!/usr/bin/env python3
"""feature-crew model check: did a finished worker run on the tier chosen for it?

Hook mode (UserPromptSubmit, JSON on stdin): acts only when the prompt carries
a worker completion, in either form seen in practice:
  - <task-notification> with <task-id> (the agent id) and <tool-use-id>
  - a subagent hand-back, <agent-message from="<agent id or name>">
For each feature-crew worker it finds, it reads the worker's transcript
(<parent transcript minus .jsonl>/subagents/agent-<id>.jsonl), resolves the
requested tier from the agent type of the parent's Agent call (matched by
tool-use id; .meta.json agentType as the fallback), reads the models the
worker's assistant rows ran on (skipping "<synthetic>"), sums usage
deduplicated by message.id, and
  - injects one "[feature-crew] worker ..." line as additionalContext;
  - appends a ledger row to <config dir>/feature-crew/ledger/<session_id>.jsonl.

CLI mode, the policy fallback when no [feature-crew] line arrived:
  model-check.py --agent <agent id> [--transcript <parent transcript.jsonl>]
                 [--session <session id>] [--no-ledger]
prints the same line to stdout. Without --transcript it finds the worker's
transcript under <config dir>/projects/*/*/subagents/. With --transcript,
--agent may also be the worker's name.

Fail-open: any error, or input it does not understand, exits 0 with no output
in hook mode. Python 3 standard library only.
"""

import datetime
import glob
import json
import os
import re
import sys

PLUGIN = "feature-crew"
TIERS = {
    "feature-builder-sonnet": "sonnet",
    "feature-builder": "opus",
    "feature-builder-deep": "fable",
}
SYNTHETIC = "<synthetic>"
USAGE_KEYS = ("input_tokens", "output_tokens", "cache_creation_input_tokens", "cache_read_input_tokens")


# --- paths --------------------------------------------------------------------


def _msys_to_win(p, nt=None):
    """Git Bash hands native Windows Python MSYS paths (/c/Users/x): map them
    to C:/Users/x on Windows. Anything else is returned unchanged."""
    if not p or not (os.name == "nt" if nt is None else nt):
        return p
    m = re.match(r"^/([A-Za-z])(/|$)", p)
    if m:
        return m.group(1).upper() + ":/" + p[m.end():]
    return p


def config_dir():
    return _msys_to_win(os.environ.get("CLAUDE_CONFIG_DIR")) or os.path.expanduser("~/.claude")


def _bare_id(agent_id):
    a = str(agent_id or "")
    return a[6:] if a.startswith("agent-") else a


def subagent_root(parent_transcript):
    root = parent_transcript[:-6] if parent_transcript.endswith(".jsonl") else parent_transcript
    return os.path.join(root, "subagents")


# --- tiers ----------------------------------------------------------------------


def tier_of(agent_type):
    """The tier for a feature-crew worker type, else None. Plugin agents arrive
    plugin-scoped (feature-crew:feature-builder); a bare name is accepted too,
    a name scoped to another plugin is not."""
    t = str(agent_type or "")
    if ":" in t:
        scope, _, bare = t.rpartition(":")
        if scope != PLUGIN:
            return None
        t = bare
    return TIERS.get(t)


# --- the prompt -------------------------------------------------------------------

_RE_TN_ID = re.compile(r"<task-id>\s*([^<\s]+)\s*</task-id>")
_RE_TN_USE = re.compile(r"<tool-use-id>\s*([^<\s]+)\s*</tool-use-id>")
_RE_AM = re.compile(r"<agent-message\s+from=\"([^\"]+)\"\s*>")
_RE_REPORT = re.compile(r"^\s*`*\s*(DONE|NEEDS-ANSWER)\b", re.M)


def completions(text):
    """[(kind, agent_ref, tool_use_id)] for each worker completion in a prompt.
    kind is "notification" (agent_ref is the agent id) or "hand-back"
    (agent_ref is an agent id or name). Each ref is listed once."""
    out, seen = [], set()
    parts = text.split("<task-notification>")
    for chunk in parts[1:]:
        chunk = chunk.split("</task-notification>")[0]
        m = _RE_TN_ID.search(chunk)
        if not m:
            continue
        u = _RE_TN_USE.search(chunk)
        ref = m.group(1)
        if ref not in seen:
            seen.add(ref)
            out.append(("notification", ref, u.group(1) if u else None))
    starts = list(_RE_AM.finditer(text))
    for i, m in enumerate(starts):
        end = starts[i + 1].start() if i + 1 < len(starts) else len(text)
        body = text[m.end():end].split("</agent-message>")[0]
        # Only a hand-back is a completion; a mid-run SendMessage from a
        # worker is not.
        if not (re.search(r"hand-back", body, re.I) or _RE_REPORT.search(body)):
            continue
        ref = m.group(1)
        if ref not in seen:
            seen.add(ref)
            out.append(("hand-back", ref, None))
    return out


# --- the parent transcript ----------------------------------------------------------

_RE_AGENT_ID_TEXT = re.compile(r"agentId:\s*([A-Za-z0-9_-]+)")


def _iter_rows(path, needles):
    """JSON rows of a transcript whose raw line contains any needle (a cheap
    filter so a long session transcript is not parsed line by line)."""
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            if needles and not any(n in line for n in needles):
                continue
            try:
                row = json.loads(line)
            except ValueError:
                continue
            if isinstance(row, dict):
                yield row


def parent_calls(parent_transcript, needles):
    """(uses, results): uses maps an Agent/Task tool_use id to its input;
    results maps a tool_use id to the agent id its result reported."""
    uses, results = {}, {}
    if not parent_transcript or not os.path.isfile(parent_transcript):
        return uses, results
    for row in _iter_rows(parent_transcript, needles):
        msg = row.get("message")
        content = msg.get("content") if isinstance(msg, dict) else None
        if not isinstance(content, list):
            continue
        for b in content:
            if not isinstance(b, dict):
                continue
            if (row.get("type") == "assistant" and b.get("type") == "tool_use"
                    and b.get("name") in ("Agent", "Task") and b.get("id")):
                inp = b.get("input")
                uses[b["id"]] = inp if isinstance(inp, dict) else {}
            elif b.get("type") == "tool_result" and b.get("tool_use_id"):
                tur = row.get("toolUseResult")
                aid = tur.get("agentId") if isinstance(tur, dict) else None
                if not aid:
                    c = b.get("content")
                    if isinstance(c, list):
                        c = " ".join(str(x.get("text", "")) for x in c if isinstance(x, dict))
                    m = _RE_AGENT_ID_TEXT.search(str(c or ""))
                    aid = m.group(1) if m else None
                if aid:
                    results[b["tool_use_id"]] = _bare_id(aid)
    return uses, results


def read_meta(sub_root, agent_id):
    try:
        with open(os.path.join(sub_root, "agent-%s.meta.json" % agent_id), encoding="utf-8") as f:
            meta = json.load(f)
        return meta if isinstance(meta, dict) else {}
    except (OSError, ValueError):
        return {}


def resolve(parent_transcript, ref, tool_use_id):
    """Who finished: {agent_id, agent_type, description, name, transcript},
    or None when the ref names no agent of this session."""
    sub_root = subagent_root(parent_transcript)
    ref = _bare_id(ref)
    uses, results = parent_calls(parent_transcript, [n for n in (ref, tool_use_id) if n])

    def more(use_id):
        if use_id and (use_id not in uses or use_id not in results):
            u2, r2 = parent_calls(parent_transcript, [use_id])
            uses.update(u2)
            results.update(r2)

    if tool_use_id:  # a task-notification: the ref is the agent id
        agent_id = ref
        if tool_use_id not in uses:
            # Not an Agent call in this transcript: find the call by the
            # agent id its launch result reported, before .meta.json.
            tool_use_id = next((k for k, v in results.items() if v == ref), tool_use_id)
    elif ref in results.values() or os.path.isfile(os.path.join(sub_root, "agent-%s.jsonl" % ref)):
        agent_id = ref
        tool_use_id = next((k for k, v in results.items() if v == ref), None)
    else:  # a name: the latest Agent call that gave it
        tool_use_id = next((k for k, inp in reversed(list(uses.items())) if inp.get("name") == ref), None)
        more(tool_use_id)
        agent_id = results.get(tool_use_id) if tool_use_id else None
    if not agent_id:
        return None
    meta = read_meta(sub_root, agent_id)
    tool_use_id = tool_use_id or meta.get("toolUseId")
    more(tool_use_id)
    call = uses.get(tool_use_id) if tool_use_id else None
    if call is None and meta.get("toolUseId") and meta["toolUseId"] != tool_use_id:
        more(meta["toolUseId"])
        call = uses.get(meta["toolUseId"])
    if call is not None:
        agent_type = call.get("subagent_type") or "general-purpose"
    else:
        agent_type = meta.get("agentType")
    call = call or {}
    return {
        "agent_id": agent_id,
        "agent_type": agent_type,
        "description": call.get("description") or meta.get("description") or "",
        "name": call.get("name") or meta.get("name") or "",
        "transcript": os.path.join(sub_root, "agent-%s.jsonl" % agent_id),
    }


# --- the worker transcript ---------------------------------------------------------


def worker_run(path):
    """(models in first-seen order, usage totals, ended_at) from a worker
    transcript; (None, None, None) if it cannot be read."""
    models, usage, ended = [], {}, None
    try:
        rows = list(_iter_rows(path, ['"assistant"']))
    except OSError:
        return None, None, None
    for i, row in enumerate(rows):
        if row.get("type") != "assistant":
            continue
        msg = row.get("message")
        if not isinstance(msg, dict):
            continue
        model = str(msg.get("model") or "")
        if not model or model == SYNTHETIC:
            continue
        if model not in models:
            models.append(model)
        u = msg.get("usage")
        if isinstance(u, dict):
            # Several rows share one message.id, each repeating its usage: keep
            # the last per id, so the total is not overcounted.
            usage[msg.get("id") or row.get("uuid") or "row-%d" % i] = u
        if row.get("timestamp"):
            ended = row["timestamp"]
    totals = {k: 0 for k in USAGE_KEYS}
    for u in usage.values():
        for k in USAGE_KEYS:
            v = u.get(k)
            if isinstance(v, (int, float)) and not isinstance(v, bool):
                totals[k] += int(v)
    totals["messages"] = len(usage)
    return models, totals, ended


# --- the check ---------------------------------------------------------------------------


def check(who):
    """(line, ledger row) for a resolved feature-crew worker."""
    tier = tier_of(who["agent_type"])
    label = who["name"] or who["description"] or who["agent_id"]
    models, usage, ended = worker_run(who["transcript"])
    if not models:
        verdict = "unknown"
        reason = "transcript unreadable" if models is None else "no model in its transcript"
        line = ("[feature-crew] worker %s (%s tier): model could not be confirmed (%s). Say so in your "
                "report; no ladder change." % (label, tier, reason))
    elif all(tier in m.lower() for m in models):
        verdict = "as-chosen"
        line = "[feature-crew] worker %s ran %s as chosen (%s tier)." % (label, ", ".join(models), tier)
    else:
        verdict = "fell-back"
        other = [m for m in models if tier not in m.lower()]
        line = ("[feature-crew] worker %s FELL BACK: requested %s, ran %s. Start every message about it "
                "with WORKER FELL BACK TO %s; if it failed or left a named check unrun, apply "
                "\"Requested model unavailable\"."
                % (label, tier, ", ".join(models), other[0]))
    row = {
        "agent_id": who["agent_id"],
        "agent_type": who["agent_type"],
        "description": who["description"],
        "requested": tier,
        "actual": models or [],
        "verdict": verdict,
        "usage": usage or {},
        "ended_at": ended or datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ"),
    }
    return line, row, bool(ended)


def append_ledger(session_id, row, dedupe):
    """Append the row; with dedupe, skip it when a row for the same agent and
    ended_at exists (the hook and the CLI fallback may both run)."""
    if not session_id:
        return
    d = os.path.join(config_dir(), "feature-crew", "ledger")
    os.makedirs(d, exist_ok=True)
    path = os.path.join(d, "%s.jsonl" % re.sub(r"[^A-Za-z0-9_.-]", "_", session_id))
    if dedupe and os.path.isfile(path):
        with open(path, encoding="utf-8", errors="replace") as f:
            for line in f:
                try:
                    old = json.loads(line)
                except ValueError:
                    continue
                if (isinstance(old, dict) and old.get("agent_id") == row["agent_id"]
                        and old.get("ended_at") == row["ended_at"]):
                    return
    with open(path, "a", encoding="utf-8") as f:
        f.write(json.dumps(row, sort_keys=True) + "\n")


def run(parent_transcript, session_id, refs, ledger=True):
    lines, done = [], set()
    for _, ref, use_id in refs:
        who = resolve(parent_transcript, ref, use_id)
        if not who or not tier_of(who["agent_type"]) or who["agent_id"] in done:
            continue
        done.add(who["agent_id"])  # a notification and a hand-back for one worker give one line
        line, row, dedupe = check(who)
        lines.append(line)
        if ledger:
            try:
                append_ledger(session_id, row, dedupe)
            except OSError:
                pass
    return lines


# --- entry points ----------------------------------------------------------------------


def hook():
    try:
        inp = json.loads(sys.stdin.read() or "null")
    except ValueError:
        return
    if not isinstance(inp, dict):
        return
    text = inp.get("prompt")
    tp = inp.get("transcript_path")
    if not isinstance(text, str) or not isinstance(tp, str) or not tp:
        return
    refs = completions(text)
    if not refs:
        return
    sid = str(inp.get("session_id") or os.path.basename(tp)[:-6])
    lines = run(tp, sid, refs)
    if lines:
        sys.stdout.write(json.dumps({"hookSpecificOutput": {
            "hookEventName": "UserPromptSubmit",
            "additionalContext": "\n".join(lines),
        }}) + "\n")


def cli(argv):
    args, i = {}, 0
    while i < len(argv):
        a = argv[i]
        if a == "--no-ledger":
            args["no-ledger"] = True
        elif a in ("--agent", "--transcript", "--session") and i + 1 < len(argv):
            args[a[2:]] = argv[i + 1]
            i += 1
        else:
            sys.stderr.write("usage: model-check.py --agent <id> [--transcript <parent.jsonl>] "
                             "[--session <id>] [--no-ledger]\n")
            return 2
        i += 1
    ref = _bare_id(args.get("agent"))
    if not ref:
        sys.stderr.write("model-check.py: --agent is required\n")
        return 2
    tp = _msys_to_win(args.get("transcript"))
    if not tp:
        found = glob.glob(os.path.join(config_dir(), "projects", "*", "*", "subagents", "agent-%s.jsonl" % ref))
        if found:
            found.sort(key=os.path.getmtime)
            tp = os.path.dirname(os.path.dirname(found[-1])) + ".jsonl"
    if not tp:
        print("[feature-crew] worker %s: model could not be confirmed (no transcript found for it)." % ref)
        return 0
    sid = args.get("session") or os.path.basename(tp)[:-6]
    try:
        lines = run(tp, sid, [("cli", ref, None)], ledger=not args.get("no-ledger"))
    except Exception as e:  # the policy reads silence as "no Python 3"
        print("[feature-crew] worker %s: model could not be confirmed (check error: %s)." % (ref, type(e).__name__))
        return 0
    if lines:
        print("\n".join(lines))
    else:
        print("[feature-crew] %s is not a feature-crew worker this session dispatched; no model check." % ref)
    return 0


def main():
    if os.environ.get("FEATURE_CREW", "on") == "off":
        return 0
    if len(sys.argv) > 1:
        return cli(sys.argv[1:])
    try:
        hook()
    except Exception:
        pass  # fail-open: a broken check must never block a prompt
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except SystemExit:
        raise
    except BaseException:
        sys.exit(0)

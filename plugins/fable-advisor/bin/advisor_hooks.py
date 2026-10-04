#!/usr/bin/env python3
"""Enforcement hooks for the fable-advisor plugin.

Claude Code decides on its own when to delegate to the advisor agent by reading
the agent's description. That is real but not guaranteed. These hooks make
consultation near-mandatory without a CLAUDE.md snippet, and they survive
context compaction because the policy is re-injected on every SessionStart.

  session-start  SessionStart: inject the advisor policy (startup, resume,
                 clear, compact) plus a one-line usage tally on resume/compact
  prompt         UserPromptSubmit: recognise decision / planning / stalled-fix /
                 review prompts and state that the policy applies to this turn
  plan-gate      PreToolUse ExitPlanMode: deny until the plan was sent to the
                 advisor in this planning episode (releases after two denials)
  post-tool      PostToolUse Edit|Write|MultiEdit|NotebookEdit|Bash: nudge each
                 time another N distinct files were edited since the last
                 consultation; PostToolUse Agent|Task: record a consultation
  stop-audit     Stop: hold the turn once when it edited >= N files with no
                 consultation, asking for a verification review of the change set
  status         plain-text summary for /fable-advisor:status

Every hook reads the session transcript (JSONL) as ground truth, so counts
cannot drift from what actually happened. But the transcript is flushed lazily
and can lag the tool calls by several entries mid-turn, so the PostToolUse hook
also records what it sees (files edited, consultations dispatched) in a small
per-session state file, and every gate accepts either source. Every hook fails
open: an unexpected error exits 0 with no output and a line in events.log.

Configuration (environment variables, e.g. via settings.json "env"):
  FABLE_ADVISOR_ENFORCE         full (default) | nudge | off
                                nudge = context injection only: no denies, no holds
  FABLE_ADVISOR_FILE_THRESHOLD  distinct files that trigger edit-watch / stop-audit (4)
  FABLE_ADVISOR_PLAN_GATE       0 disables the ExitPlanMode gate
  FABLE_ADVISOR_EDIT_WATCH      0 disables the edit-count nudge
  FABLE_ADVISOR_STOP_AUDIT      0 disables the end-of-turn hold
  FABLE_ADVISOR_PROMPT_NUDGE    0 disables per-prompt nudges
  FABLE_ADVISOR_HOME            state + events.log dir (~/.claude/fable-advisor)
"""
import calendar
import glob
import json
import os
import re
import shlex
import sys
import tempfile
import time

ADVISOR = "fable-advisor:advisor"
DISPATCH_TOOLS = {"Agent", "Task"}
EDIT_TOOLS = {"Edit", "Write", "MultiEdit", "NotebookEdit"}
STATE_MAX_AGE = 7 * 86400

DISPATCH = (
    'dispatch the fable-advisor:advisor agent (Agent tool, subagent_type '
    '"fable-advisor:advisor", model "fable")'
)

# --- configuration ----------------------------------------------------------


def _flag(name, default=True):
    v = os.environ.get(name)
    if v is None or v.strip() == "":
        return default
    return v.strip().lower() not in ("0", "false", "no", "off")


class Config:
    def __init__(self):
        mode = (os.environ.get("FABLE_ADVISOR_ENFORCE") or "full").strip().lower()
        self.mode = mode if mode in ("full", "nudge", "off") else "full"
        try:
            self.threshold = max(1, int(os.environ.get("FABLE_ADVISOR_FILE_THRESHOLD") or 4))
        except ValueError:
            self.threshold = 4
        self.plan_gate = _flag("FABLE_ADVISOR_PLAN_GATE")
        self.edit_watch = _flag("FABLE_ADVISOR_EDIT_WATCH")
        self.stop_audit = _flag("FABLE_ADVISOR_STOP_AUDIT")
        self.prompt_nudge = _flag("FABLE_ADVISOR_PROMPT_NUDGE")
        self.home = os.environ.get("FABLE_ADVISOR_HOME") or os.path.join(
            os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude"),
            "fable-advisor",
        )

    def describe(self):
        if self.mode == "off":
            return "off"
        layers = [
            "plan gate " + ("on" if self.plan_gate and self.mode == "full" else "off"),
            "edit watch " + ("on at %d files" % self.threshold if self.edit_watch else "off"),
            "stop audit " + ("on at %d files" % self.threshold if self.stop_audit and self.mode == "full" else "off"),
            "prompt nudges " + ("on" if self.prompt_nudge else "off"),
        ]
        return "%s (%s)" % (self.mode, ", ".join(layers))


CFG = Config()

# --- state + log ------------------------------------------------------------


def _ensure_home():
    try:
        os.makedirs(os.path.join(CFG.home, "state"), exist_ok=True)
    except OSError:
        pass


def log(event, sid="", **kv):
    _ensure_home()
    ts = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    detail = " ".join("%s=%s" % (k, str(v).replace("\n", " ")) for k, v in kv.items())
    try:
        with open(os.path.join(CFG.home, "events.log"), "a") as f:
            f.write("%s sid=%s event=%s %s\n" % (ts, (sid or "-")[:8], event, detail))
    except OSError:
        pass


def _state_path(sid):
    safe = re.sub(r"[^A-Za-z0-9_.-]", "_", sid or "unknown")
    return os.path.join(CFG.home, "state", safe + ".json")


def load_state(sid):
    try:
        with open(_state_path(sid)) as f:
            return json.load(f) or {}
    except (OSError, ValueError):
        return {}


def save_state(sid, state):
    _ensure_home()
    path = _state_path(sid)
    tmp = "%s.tmp.%d" % (path, os.getpid())
    try:
        with open(tmp, "w") as f:
            json.dump(state, f)
        os.replace(tmp, path)
    except OSError:
        pass


def record_consult(sid, tool_use_id=None, note=""):
    """Remember that the advisor was dispatched, for gates that run before the
    transcript has caught up. Also resets the edit-watch tally."""
    state = load_state(sid)
    state["last_consult_ts"] = time.time()
    state["last_consult_id"] = tool_use_id
    state["consults"] = int(state.get("consults") or 0) + 1
    state["edit_watch"] = {"boundary": "consult", "consult_id": tool_use_id, "bucket": 0, "seen": []}
    save_state(sid, state)
    log("consult-recorded", sid, note=note)


def remember_turn_edit(state, prompt_id, files):
    """Per-turn memory of edited files, keyed by the prompt that started the turn."""
    te = state.get("turn_edits") or {}
    if te.get("prompt_id") != prompt_id or not isinstance(te.get("files"), list):
        te = {"prompt_id": prompt_id, "files": []}
    for fp in files:
        if fp not in te["files"]:
            te["files"].append(fp)
    te["files"] = te["files"][-500:]
    state["turn_edits"] = te
    return te["files"]


def state_consult_after(state, epoch):
    """True when state remembers a consultation newer than `epoch` (or any
    consultation, when the reference moment is unknown)."""
    lc = state.get("last_consult_ts")
    if not isinstance(lc, (int, float)):
        return False
    return epoch is None or lc > epoch


def reap_state():
    now = time.time()
    for p in glob.glob(os.path.join(CFG.home, "state", "*.json")):
        try:
            if now - os.path.getmtime(p) > STATE_MAX_AGE:
                os.remove(p)
        except OSError:
            pass


# --- transcript -------------------------------------------------------------


def is_subagent(path):
    return bool(path) and ("/subagents/" in path or os.sep + "subagents" + os.sep in path)


# Sessions in bypass-permissions mode are steered to edit through Bash (heredocs,
# sed -i, tee) rather than the Edit/Write tools, so those writes must count too.
# Tokenised with shlex in non-POSIX mode so quoted strings keep their quotes and
# a ">" inside "..." can never be mistaken for a redirect. Conservative: only
# unambiguous write targets, never temp or device paths, never option-looking
# or numeric tokens. Anything unparseable yields nothing (a missed edit is the
# cheap failure; a phantom file is the expensive one).
_RE_HEREDOC = re.compile(r"<<-?\s*['\"]?([A-Za-z_][A-Za-z0-9_]*)['\"]?([^\n]*)\n.*?\n\1(?=\n|$)", re.S)
_RE_REDIRECT_TOKEN = re.compile(r"^(>>|>\||&>>|&>|>)(.+)$")
_SKIP_WRITE_PREFIXES = ("/dev/", "/tmp/", "/private/tmp/", "/var/folders/", "/private/var/folders/", "$", "&", "=")
_REDIRECT_OPS = (">", ">>", "&>", "&>>", ">|")
_PUNCT_CHARS = set("();<>|&")


def _is_punct(tok):
    return bool(tok) and all(c in _PUNCT_CHARS for c in tok)


def _unquote(tok):
    if len(tok) >= 2 and tok[0] == tok[-1] and tok[0] in "\"'":
        return tok[1:-1]
    return tok


def _config_dir():
    return os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude")


def _norm_path(p):
    """Comparable form of a path. On Windows the same file arrives as
    C:\\Users\\x, C:/Users/x or (from Git Bash) /c/Users/x, in any case."""
    if os.name != "nt":
        return p
    p = p.replace("\\", "/")
    m = re.match(r"^/([A-Za-z])(/|$)", p)
    if m:
        p = m.group(1) + ":/" + p[m.end():]
    return p.lower()


def counts_as_edit(fp):
    """Project edits only: not temp/device paths, not Claude's own plan files or
    memory notes (which live under the config dir and are written as a matter
    of course during ordinary work)."""
    if not fp or fp.startswith(_SKIP_WRITE_PREFIXES):
        return False
    p = _norm_path(fp)
    cfg = _norm_path(_config_dir()).rstrip("/") + "/"
    if p.startswith(cfg + "plans/") or p.startswith(cfg + "projects/"):
        return False
    if os.name == "nt":
        tmp = _norm_path(tempfile.gettempdir()).rstrip("/") + "/"
        if p.startswith(tmp):
            return False
    return True


def _plausible_write_target(t):
    if not t or t.startswith(_SKIP_WRITE_PREFIXES) or t.endswith("/"):
        return False
    if t.startswith("-") or t in (".", "..", "~"):
        return False
    if any(ch in t for ch in "\"'`$<>|&;(){}"):
        return False
    if re.fullmatch(r"[0-9]+", t):
        return False
    return True


def _shell_tokens(command):
    lex = shlex.shlex(command, posix=False, punctuation_chars=True)
    lex.whitespace_split = True
    toks = []
    for tok in lex:
        # Older Pythons do not split ">file" at the punctuation boundary.
        m = _RE_REDIRECT_TOKEN.match(tok)
        if m and not _is_punct(tok):
            toks.append(m.group(1))
            toks.append(m.group(2))
        else:
            toks.append(tok)
    return toks


def _sed_inplace_files(toks, i):
    """Forward-parse one sed invocation starting after the 'sed' token.
    Returns (index after the invocation, files) with files empty unless -i."""
    n = len(toks)
    inplace = False
    script_seen = False
    files = []
    while i < n:
        t = toks[i]
        if _is_punct(t):
            break
        if t.startswith("--"):
            if t.startswith("--in-place"):
                inplace = True
            elif t in ("--expression", "--file"):
                script_seen = True
                i += 1
            elif t.startswith("--expression=") or t.startswith("--file="):
                script_seen = True
            i += 1
            continue
        if t.startswith("-") and len(t) > 1:
            flags = t[1:]
            if "i" in flags:
                inplace = True
            if "e" in flags or "f" in flags:
                script_seen = True
                if flags.endswith("e") or flags.endswith("f"):
                    i += 2  # the script / script file is the next token
                    continue
            if flags.endswith("i") and i + 1 < n and _unquote(toks[i + 1]) == "":
                i += 2  # BSD sed: -i '' (empty backup suffix)
                continue
            i += 1
            continue
        if not script_seen:
            script_seen = True  # first bare token is the script
            i += 1
            continue
        files.append(t)
        i += 1
    return i, (files if inplace else [])


def bash_write_targets(command):
    """Files a shell command overwrites or appends to. Best effort."""
    if not command or not isinstance(command, str):
        return []
    # Blank heredoc bodies but keep the rest of the "<<" line: "cat <<'EOF' > f" redirects.
    cmd = _RE_HEREDOC.sub(lambda m: "<<HEREDOC" + m.group(2), command)
    try:
        toks = _shell_tokens(cmd)
    except ValueError:
        return []
    found = []

    def add(tok):
        t = _unquote(tok)
        if _plausible_write_target(t) and t not in found:
            found.append(t)

    i, n = 0, len(toks)
    while i < n:
        t = toks[i]
        if t in _REDIRECT_OPS:
            if i + 1 < n and not _is_punct(toks[i + 1]):
                add(toks[i + 1])
            i += 2
            continue
        if t == "tee":
            j = i + 1
            while j < n and not _is_punct(toks[j]):
                if not toks[j].startswith("-"):
                    add(toks[j])
                j += 1
            i = j
            continue
        if t == "sed":
            i, files = _sed_inplace_files(toks, i + 1)
            for f in files:
                add(f)
            continue
        i += 1
    return found


_RE_TS = re.compile(r"^(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)(?:\.(\d+))?")


def parse_ts(value):
    """ISO-8601 transcript timestamp (UTC) -> epoch seconds, or None."""
    if not isinstance(value, str):
        return None
    m = _RE_TS.match(value)
    if not m:
        return None
    y, mo, d, h, mi, sec = (int(x) for x in m.groups()[:6])
    frac = m.group(7)
    try:
        t = calendar.timegm((y, mo, d, h, mi, sec, 0, 0, 0))
    except (ValueError, OverflowError):
        return None
    if frac:
        t += float("0." + frac)
    return float(t)


def _block_text(block):
    c = block.get("content")
    if isinstance(c, str):
        return c
    if isinstance(c, list):
        return " ".join(str(x.get("text") or "") for x in c if isinstance(x, dict))
    return ""


class Scan:
    """One pass over the session transcript, keeping only what the hooks need."""

    def __init__(self, path):
        self.path = path
        self.lines = 0
        self.consults = []       # line numbers of advisor dispatches (health checks excluded)
        self.consult_lines = {}  # tool_use_id -> line, to match state-recorded consults
        self.health_checks = []  # line numbers of /fable-advisor:health dispatches
        self.edits = []          # (line, file_path)
        self.prompts = []        # (line, text) real user prompts, newest last
        self.plan_marks = []     # line numbers where a planning episode began
        self.exit_attempts = []  # (line, tool_use_id) ExitPlanMode calls
        self._exit_ids = set()
        self.exit_done = []      # line numbers of completed ExitPlanMode results
        self._last_mode = None   # permission-mode rows are written per prompt, not per change
        self.ts_of = {}          # line -> epoch, for rows that carry a timestamp
        self._last_ts = None
        if path and os.path.isfile(path):
            self._parse()

    def _parse(self):
        with open(self.path, "r", errors="replace") as f:
            for n, line in enumerate(f):
                self.lines = n + 1
                if '"type":"assistant"' in line or '"type": "assistant"' in line:
                    self._assistant(n, line)
                elif '"type":"user"' in line or '"type": "user"' in line:
                    self._user(n, line)
                elif "permission-mode" in line:
                    self._mode(n, line)

    def _load(self, line, n=None):
        try:
            d = json.loads(line)
        except ValueError:
            return None
        if not isinstance(d, dict):
            return None
        ts = parse_ts(d.get("timestamp"))
        if ts is not None:
            self._last_ts = ts
        if n is not None and self._last_ts is not None:
            # Rows without a timestamp (permission-mode) inherit the previous one.
            self.ts_of[n] = self._last_ts
        return d

    def _assistant(self, n, line):
        if '"tool_use"' not in line:
            return
        d = self._load(line, n)
        if not d or d.get("type") != "assistant" or d.get("isSidechain"):
            return
        msg = d.get("message") or {}
        for b in msg.get("content") or []:
            if not isinstance(b, dict) or b.get("type") != "tool_use":
                continue
            name = b.get("name")
            inp = b.get("input") or {}
            if not isinstance(inp, dict):
                inp = {}
            if name in DISPATCH_TOOLS and inp.get("subagent_type") == ADVISOR:
                prompt = str(inp.get("prompt") or "")
                if re.match(r"\s*health check\b", prompt, re.I):
                    self.health_checks.append(n)
                else:
                    self.consults.append(n)
                    if b.get("id"):
                        self.consult_lines[b["id"]] = n
            elif name in EDIT_TOOLS:
                fp = inp.get("file_path") or inp.get("notebook_path")
                if fp and counts_as_edit(str(fp)):
                    self.edits.append((n, str(fp)))
            elif name == "Bash":
                for fp in bash_write_targets(inp.get("command")):
                    self.edits.append((n, fp))
            elif name == "EnterPlanMode":
                self.plan_marks.append(n)
            elif name == "ExitPlanMode":
                tid = b.get("id")
                self.exit_attempts.append((n, tid))
                if tid:
                    self._exit_ids.add(tid)

    def _user(self, n, line):
        d = self._load(line, n)
        if not d or d.get("type") != "user" or d.get("isSidechain"):
            return
        msg = d.get("message") or {}
        content = msg.get("content")
        if isinstance(content, list):
            texts = []
            has_result = False
            for b in content:
                if not isinstance(b, dict):
                    continue
                if b.get("type") == "tool_result":
                    has_result = True
                    if b.get("tool_use_id") in self._exit_ids and not b.get("is_error") \
                            and "[fable-advisor]" not in _block_text(b):
                        # A hook denial also yields a tool_result for the call; only a
                        # real completion ends the planning episode.
                        self.exit_done.append(n)
                elif b.get("type") == "text":
                    texts.append(str(b.get("text") or ""))
            if has_result:
                return
            text = "\n".join(texts)
        elif isinstance(content, str):
            text = content
        else:
            return
        if d.get("isMeta") or d.get("isCompactSummary"):
            return
        text = text.strip()
        if text:
            self.prompts.append((n, text[:2000]))

    def _mode(self, n, line):
        d = self._load(line, n)
        if not d or d.get("type") != "permission-mode":
            return
        mode = d.get("permissionMode")
        # Claude Code writes one of these rows after every prompt. Only a change
        # into or out of plan mode bounds a planning episode.
        if (mode == "plan") != (self._last_mode == "plan") and self._last_mode is not None or \
                (mode == "plan" and self._last_mode is None):
            self.plan_marks.append(n)
        self._last_mode = mode

    # --- derived facts ---

    def last_consult(self):
        return self.consults[-1] if self.consults else -1

    def last_prompt(self):
        return self.prompts[-1][0] if self.prompts else -1

    def consulted_after(self, line):
        return any(c > line for c in self.consults)

    def edited_since(self, line):
        seen = []
        for n, fp in self.edits:
            if n > line and fp not in seen:
                seen.append(fp)
        return seen

    def plan_episode_start(self):
        marks = self.plan_marks + self.exit_done
        return max(marks) if marks else -1

    def exit_attempts_since(self, line, exclude_id=None):
        return [a for a in self.exit_attempts if a[0] > line and (exclude_id is None or a[1] != exclude_id)]

    def ts_at(self, line):
        """Epoch of a transcript line, or None when the line is unknown/untimed."""
        return self.ts_of.get(line) if line is not None and line >= 0 else None


# --- output helpers ---------------------------------------------------------


def emit(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


def context(event, text, extra=None):
    out = {"hookEventName": event, "additionalContext": text}
    if extra:
        out.update(extra)
    emit({"hookSpecificOutput": out})


def _list_files(files, limit=8):
    shown = files[:limit]
    tail = "" if len(files) <= limit else " (+%d more)" % (len(files) - limit)
    return ", ".join(shown) + tail


# --- policy text ------------------------------------------------------------


def policy_text():
    lines = [
        "[fable-advisor] Advisor policy for this session (enforced by plugin hooks, enforcement: %s)." % CFG.describe(),
        "",
        "1. CONSULT THE ADVISOR — %s — BEFORE: any architectural, data-model, "
        "interface or dependency decision; executing any plan that touches more than %d files; "
        "choosing between two viable approaches; committing or opening a PR after a substantive "
        "change; deleting or rewriting an existing module. AND AFTER: two failed attempts at the "
        "same bug, or a test failure you cannot explain. Also whenever the user asks for a second "
        "opinion, a review, or says \"ask the advisor\"." % (DISPATCH, CFG.threshold - 1),
        "",
        "2. HOW: give it the question or plan, the constraints, what was already tried, and the exact "
        "file paths and symbols — it reads the files itself, so paths matter more than summaries. It is "
        "read-only and never implements. Present its MODEL, VERDICT and RISKS lines to the user intact. "
        "If MODEL is not Fable, label the verdict \"ADVISOR RUNNING DEGRADED\". If the dispatch fails, "
        "retry once with model \"opus\" and label it degraded. Never skip a consultation because the "
        "built-in advisor tool is unavailable — this agent is the replacement path.",
        "",
        "3. HOOKS IN FORCE: ExitPlanMode is denied until the plan was sent to the advisor; a nudge fires "
        "once %d distinct files were edited since the last consultation; a turn that edited %d+ files "
        "with no consultation is held once at its end for a verification review. Consulting early is "
        "cheaper than being held later. /fable-advisor:status shows the tally; "
        "FABLE_ADVISOR_ENFORCE=nudge|off relaxes the gates." % (CFG.threshold, CFG.threshold),
    ]
    return "\n".join(lines)


# --- prompt classification --------------------------------------------------

_RE_REVIEW = re.compile(
    r"\b(second opinion|sanity[- ]?check|double[- ]?check|review|critique|audit|"
    r"(ask|consult) (the )?(fable )?advisor|ask fable|what do you think|your thoughts)\b", re.I)
_RE_DECISION = re.compile(
    r"\b(should (i|we)|which (one|approach|option|way|is better|would you)|better (to|approach|option|way)|"
    r"trade-?offs?|pros and cons|recommend\w*|vs\.?|versus|or should|"
    r"is it (worth|better|ok|okay|safe|wise)|worth it|alternatives?|decide|decision)\b", re.I)
_RE_PLAN = re.compile(
    r"\b(plan|design|architect\w*|refactor\w*|migrat\w*|restructur\w*|rewrite|redesign|reimplement|"
    r"roadmap|strategy|schema|data model|new (module|service|feature|api|endpoint|package|plugin|component)|"
    r"overhaul|extract|consolidat\w*|split (up|out|into)|from scratch|end[- ]to[- ]end|"
    r"implement (a|an|the|this)|build (a|an|the|out))\b", re.I)
_RE_STALLED = re.compile(
    r"\b(still (fail\w*|broken|not work\w*|doesn'?t work|isn'?t work\w*|crash\w*|error\w*|wrong|happening)|"
    r"not working|doesn'?t work|isn'?t working|keeps? (failing|crashing|breaking|happening)|"
    r"same (error|issue|problem|bug|failure)|no luck|stuck|didn'?t (work|help|fix)|"
    r"(failed|failing|broke|broken|crash\w*|error\w*) again|nothing (changed|works)|why (does|is) (it|this) still)\b", re.I)


def classify(text):
    cats = []
    if _RE_STALLED.search(text):
        cats.append("stalled")
    if _RE_REVIEW.search(text):
        cats.append("review")
    if _RE_DECISION.search(text):
        cats.append("decision")
    if _RE_PLAN.search(text):
        cats.append("plan")
    return cats


# --- hooks ------------------------------------------------------------------


def session_start(inp):
    if CFG.mode == "off":
        return
    reap_state()
    sid = inp.get("session_id", "")
    source = inp.get("source") or "startup"
    text = policy_text()
    tp = inp.get("transcript_path")
    if source in ("resume", "compact") and tp and os.path.isfile(tp):
        scan = Scan(tp)
        pending = scan.edited_since(scan.last_consult())
        text += (
            "\n\nSession so far: %d advisor consultation(s); %d distinct file(s) edited since the last one."
            % (len(scan.consults), len(pending))
        )
        if len(pending) >= CFG.threshold:
            text += " That is over the threshold — consult before the next substantive edit."
    context("SessionStart", text)
    log("policy-injected", sid, source=source)


def prompt(inp):
    if CFG.mode == "off" or not CFG.prompt_nudge:
        return
    tp = inp.get("transcript_path")
    if is_subagent(tp):
        return
    text = (inp.get("prompt") or "").strip()
    if not text or text.startswith("/"):
        return
    sid = inp.get("session_id", "")
    cats = classify(text)
    scan = Scan(tp)
    parts = []
    primary = None
    if "stalled" in cats:
        primary = "stalled"
        prev = scan.prompts[-1][1] if scan.prompts else ""
        # The current prompt may or may not be in the transcript yet; look at the
        # newest prompt that is not this one.
        if prev.strip() == text and len(scan.prompts) > 1:
            prev = scan.prompts[-2][1]
        if prev and _RE_STALLED.search(prev):
            parts.append(
                "[fable-advisor] Second consecutive report of the same problem. Policy: consult NOW, "
                "before any further edits — %s with the symptom, every fix already tried, and the exact "
                "error text. Present its VERDICT before attempting another fix." % DISPATCH
            )
        else:
            parts.append(
                "[fable-advisor] This reads as a stalled fix. Policy: after two failed attempts at the same "
                "bug, %s with what was tried and the exact errors BEFORE trying a third fix. If this is "
                "already the second attempt, consult now." % DISPATCH
            )
    elif "review" in cats:
        primary = "review"
        parts.append(
            "[fable-advisor] The user is asking for a review or second opinion. Policy: %s with the change "
            "set or question and the exact file paths, and present its MODEL, VERDICT and RISKS to the "
            "user intact before giving your own view." % DISPATCH
        )
    elif "decision" in cats:
        primary = "decision"
        parts.append(
            "[fable-advisor] This prompt asks for a decision between options. Policy: %s with the options, "
            "the constraints and the file paths involved BEFORE committing to a direction; present its "
            "VERDICT to the user, and say whether you agree." % DISPATCH
        )
    elif "plan" in cats:
        primary = "plan"
        parts.append(
            "[fable-advisor] This prompt starts design or planning work. Policy: draft the plan (goals, "
            "ordered steps, files to touch, assumptions), then %s to critique it BEFORE editing any file. "
            "Fold accepted findings into the plan and show the user the VERDICT." % DISPATCH
        )
    pending = scan.edited_since(scan.last_consult())
    if len(pending) >= CFG.threshold:
        parts.append(
            "[fable-advisor] %d distinct files have been edited since the last advisor consultation (%s). "
            "Get that change set reviewed before extending it." % (len(pending), _list_files(pending))
        )
    if not parts:
        return
    context("UserPromptSubmit", "\n".join(parts))
    log("prompt-nudge", sid, category=primary or "pending-edits", pending=len(pending))


def plan_gate(inp):
    if CFG.mode == "off" or not CFG.plan_gate:
        return
    tp = inp.get("transcript_path")
    if is_subagent(tp):
        return
    sid = inp.get("session_id", "")
    scan = Scan(tp)
    start = scan.plan_episode_start()
    if scan.consulted_after(start):
        log("plan-gate-pass", sid)
        return
    if state_consult_after(load_state(sid), scan.ts_at(start)):
        log("plan-gate-pass", sid, source="state")
        return
    prior = scan.exit_attempts_since(start, exclude_id=inp.get("tool_use_id"))
    reason = (
        "[fable-advisor] This plan has not been reviewed by the advisor. Before exiting plan mode, %s "
        "with the full plan, the files it touches and its assumptions; ask for wrong assumptions, "
        "missing steps, ordering risks and cheaper alternatives. Fold accepted findings into the plan, "
        "show the user the advisor's MODEL, VERDICT and RISKS, then call ExitPlanMode again. If the "
        "dispatch fails, retry once with model \"opus\" and label the verdict degraded." % DISPATCH
    )
    if CFG.mode == "nudge":
        context("PreToolUse", reason)
        log("plan-gate-nudge", sid)
        return
    if len(prior) >= 2:
        # Context only: the normal ExitPlanMode approval prompt still runs, so the
        # user keeps their veto over an unreviewed plan.
        context(
            "PreToolUse",
            "[fable-advisor] Plan gate released after %d denials without an advisor consultation. "
            "Tell the user the plan is proceeding unreviewed and why." % len(prior),
        )
        log("plan-gate-release", sid, denials=len(prior))
        return
    emit({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": reason + " (This gate releases by itself after two denials.)",
        }
    })
    log("plan-gate-deny", sid, prior=len(prior))


def post_tool(inp):
    if CFG.mode == "off":
        return
    tp = inp.get("transcript_path")
    if is_subagent(tp):
        return
    tool = inp.get("tool_name")
    tool_input = inp.get("tool_input") or {}
    if not isinstance(tool_input, dict):
        tool_input = {}
    if tool in DISPATCH_TOOLS:
        if tool_input.get("subagent_type") == ADVISOR and \
                not re.match(r"\s*health check\b", str(tool_input.get("prompt") or ""), re.I):
            record_consult(inp.get("session_id", ""), tool_use_id=inp.get("tool_use_id"),
                           note=str(tool_input.get("description") or "")[:60])
        return
    edit_watch(inp)


def edit_watch(inp):
    if CFG.mode == "off" or not CFG.edit_watch:
        return
    tp = inp.get("transcript_path")
    if is_subagent(tp):
        return
    sid = inp.get("session_id", "")
    tool_input = inp.get("tool_input") or {}
    if not isinstance(tool_input, dict):
        tool_input = {}
    if inp.get("tool_name") == "Bash":
        current = bash_write_targets(tool_input.get("command"))
        if not current:
            return  # a Bash call that wrote nothing is not an edit
    else:
        fp = tool_input.get("file_path") or tool_input.get("notebook_path")
        current = [str(fp)] if fp and counts_as_edit(str(fp)) else []
        if not current:
            return  # plan files, memory notes and temp paths are not project edits
    scan = Scan(tp)
    boundary = scan.last_consult()
    from_transcript = scan.edited_since(boundary)
    # The transcript can lag the tool calls by a few entries at PostToolUse time,
    # so remember every file this hook has already seen since the boundary and
    # union it with the scan; the scan alone can undercount a burst of edits.
    state = load_state(sid)
    remember_turn_edit(state, inp.get("prompt_id"), current)
    ew = state.get("edit_watch") or {}
    if ew.get("boundary") == "consult":
        # A consultation was recorded by post_tool before the transcript showed
        # it. Once the transcript has that dispatch, switch to its line; until
        # then only count transcript edits newer than the recorded consult.
        line = scan.consult_lines.get(ew.get("consult_id"))
        if line is not None:
            boundary = max(line, boundary)
            ew = {"boundary": boundary, "bucket": int(ew.get("bucket") or 0), "seen": ew.get("seen") or []}
            from_transcript = scan.edited_since(boundary)
        else:
            lc = state.get("last_consult_ts")
            from_transcript = list(dict.fromkeys(
                f for l, f in scan.edits
                if not isinstance(lc, (int, float)) or (scan.ts_at(l) or 0) > lc))
    elif ew.get("boundary") != boundary:
        ew = {"boundary": boundary, "bucket": 0, "seen": []}
    files = [f for f in (ew.get("seen") or []) if isinstance(f, str)]
    for fp in from_transcript + current:
        if fp not in files:
            files.append(fp)
    ew["seen"] = files[-500:]
    n = len(files)
    bucket = n // CFG.threshold
    if os.environ.get("FABLE_ADVISOR_DEBUG"):
        log("edit-watch", sid, files=n, transcript=len(from_transcript), current=",".join(current))
    if n < CFG.threshold or bucket <= int(ew.get("bucket") or 0):
        state["edit_watch"] = ew
        save_state(sid, state)
        return
    ew["bucket"] = bucket
    state["edit_watch"] = ew
    save_state(sid, state)
    context(
        "PostToolUse",
        "[fable-advisor] %d distinct files have now been edited since the last advisor consultation "
        "(threshold %d): %s. Policy: pause before further edits and %s with the goal, the files changed "
        "so far and what remains; present its VERDICT and adjust course if it says so."
        % (n, CFG.threshold, _list_files(files), DISPATCH),
    )
    log("edit-nudge", sid, files=n, boundary=boundary)


def stop_audit(inp):
    if CFG.mode != "full" or not CFG.stop_audit:
        return
    if inp.get("stop_hook_active"):
        return
    tp = inp.get("transcript_path")
    if is_subagent(tp):
        return
    sid = inp.get("session_id", "")
    scan = Scan(tp)
    turn = scan.last_prompt()
    files = scan.edited_since(turn)
    state = load_state(sid)
    te = state.get("turn_edits") or {}
    if inp.get("prompt_id") and te.get("prompt_id") == inp.get("prompt_id"):
        for fp in te.get("files") or []:
            if fp not in files:
                files.append(fp)
    if len(files) < CFG.threshold:
        return
    if scan.consulted_after(turn):
        log("stop-audit-pass", sid, files=len(files))
        return
    if state_consult_after(state, scan.ts_at(turn)):
        log("stop-audit-pass", sid, files=len(files), source="state")
        return
    if state.get("stop_held_turn") == turn:
        return
    state["stop_held_turn"] = turn
    save_state(sid, state)
    emit({
        "decision": "block",
        "reason": (
            "[fable-advisor] This turn edited %d files with no advisor consultation: %s. Before finishing, "
            "%s for a verification review: give it the goal, the exact files changed, and ask it to check "
            "the change set for defects, missed cases and anything the user should know. Report its "
            "MODEL, VERDICT and RISKS to the user verbatim (label it DEGRADED if MODEL is not Fable), "
            "fix anything it finds that is clearly right, then finish. This hold fires once per turn."
            % (len(files), _list_files(files), DISPATCH)
        ),
    })
    log("stop-hold", sid, files=len(files), turn=turn)


def _newest_transcript(cwd):
    base = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude")
    slug = re.sub(r"[^a-zA-Z0-9]", "-", cwd or os.getcwd())
    candidates = glob.glob(os.path.join(base, "projects", slug, "*.jsonl"))
    if not candidates:
        return None
    return max(candidates, key=os.path.getmtime)


def status(inp):
    tp = inp.get("transcript_path") or _newest_transcript(inp.get("cwd"))
    sid = inp.get("session_id") or (os.path.basename(tp)[:-6] if tp else "")
    out = ["fable-advisor status"]
    out.append("  enforcement: %s" % CFG.describe())
    out.append("  python3: %s" % (sys.executable or "python3"))
    if not tp or not os.path.isfile(tp):
        out.append("  transcript: not found (no session transcript for this directory yet)")
        print("\n".join(out))
        return
    scan = Scan(tp)
    pending = scan.edited_since(scan.last_consult())
    turns_with = 0
    for i, (line, _) in enumerate(scan.prompts):
        end = scan.prompts[i + 1][0] if i + 1 < len(scan.prompts) else scan.lines + 1
        if any(line < c < end for c in scan.consults):
            turns_with += 1
    out.append("  session: %s" % (sid[:8] if sid else "?"))
    out.append("  transcript: %s (%d lines)" % (tp, scan.lines))
    out.append("  advisor consultations: %d%s" % (
        len(scan.consults),
        "" if not scan.consults else " (last at line %d)" % scan.consults[-1],
    ))
    if scan.health_checks:
        out.append("  health checks (not counted as consultations): %d" % len(scan.health_checks))
    out.append("  user turns: %d, turns with a consultation: %d" % (len(scan.prompts), turns_with))
    out.append("  distinct files edited this session: %d" % len(scan.edited_since(-1)))
    out.append("  distinct files edited since last consultation: %d%s" % (
        len(pending), "" if not pending else " (" + _list_files(pending) + ")"))
    if len(pending) >= CFG.threshold:
        out.append("  -> over the %d-file threshold: the next prompt will be flagged; a turn that edits %d+ "
                   "unadvised files is held once at its end" % (CFG.threshold, CFG.threshold))
    events = []
    try:
        with open(os.path.join(CFG.home, "events.log")) as f:
            key = "sid=%s " % (sid or "-")[:8]
            events = [l.rstrip("\n") for l in f if key in l]
    except OSError:
        pass
    if events:
        counts = {}
        for e in events:
            m = re.search(r"event=(\S+)", e)
            if m:
                counts[m.group(1)] = counts.get(m.group(1), 0) + 1
        out.append("  hook events this session: " + ", ".join("%s x%d" % kv for kv in sorted(counts.items())))
        out.append("  last events:")
        out.extend("    " + e for e in events[-5:])
    out.append("  events log: %s" % os.path.join(CFG.home, "events.log"))
    print("\n".join(out))


HOOKS = {
    "session-start": session_start,
    "prompt": prompt,
    "plan-gate": plan_gate,
    "post-tool": post_tool,
    "edit-watch": edit_watch,  # alias kept for the tests and older hooks.json files
    "stop-audit": stop_audit,
    "status": status,
}


def read_input():
    try:
        if sys.stdin.isatty():
            return {}
        raw = sys.stdin.read()
    except (OSError, ValueError):
        return {}
    if not raw.strip():
        return {}
    try:
        d = json.loads(raw)
    except ValueError:
        return {}
    return d if isinstance(d, dict) else {}


def main(argv):
    if len(argv) < 2 or argv[1] not in HOOKS:
        sys.stderr.write("usage: advisor_hooks.py <%s>\n" % "|".join(HOOKS))
        return 0
    name = argv[1]
    inp = read_input()
    try:
        HOOKS[name](inp)
    except Exception as e:  # fail open, never break the session
        log("hook-error", inp.get("session_id", ""), hook=name, error="%s: %s" % (type(e).__name__, e))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

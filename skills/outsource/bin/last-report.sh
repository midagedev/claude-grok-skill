#!/usr/bin/env bash
# Print a delegated round's final report from its log, whatever the backend.
#
#   last-report.sh <log-file> [--max-chars N]
#
# Field problem this solves (2026-08-17, four rounds in one night): the
# lead re-writes the same throwaway Python after every round, because the
# two backends leave their report in different shapes —
#
#   claude-code harness (run.log, JSONL):   the last {"type":"result"} event's
#     "result" field; older logs may only have long assistant text blocks.
#   grok CLI (streaming-json ndjson):       there is no result event at all —
#     the report is the concatenation of {"type":"text"} deltas after the
#     LAST tool_call/tool_call_update event.
#
# The extractor auto-detects the shape per line, so a log that mixes both
# (or a future harness that adopts either) still yields the report. Exit 0
# with the report on stdout; exit 65 with a message on stderr when the log
# holds no report-shaped content (a died-mid-run round) — callers branch on
# that instead of parsing silence.
#
# This prints the delegate's words verbatim. It does NOT prove completion —
# the <log>.rc sentinel (rc / done_marker) is the completion evidence, and a
# report without a sentinel is a round that has not finished.
set -euo pipefail

LOG="${1:-}"
[ -n "$LOG" ] || { echo "usage: last-report.sh <log-file> [--max-chars N]" >&2; exit 64; }
[ -r "$LOG" ] || { echo "last-report.sh: unreadable: $LOG" >&2; exit 66; }
shift
MAX=0
while [ $# -gt 0 ]; do
  case "$1" in
    --max-chars) MAX="$2"; shift 2 ;;
    *) echo "last-report.sh: unknown flag: $1" >&2; exit 64 ;;
  esac
done

MAX="$MAX" python3 - "$LOG" <<'PY'
import json, os, sys

path = sys.argv[1]
max_chars = int(os.environ.get("MAX") or 0)

result = None          # claude-code: last {"type":"result"}.result
last_long_text = None  # claude-code fallback: last assistant text >=200 chars
grok_parts = []        # grok: text deltas since the last tool event
saw_grok_tool = False  # only trust grok_parts once a tool event proves shape

for raw in open(path, encoding="utf-8", errors="replace"):
    raw = raw.strip()
    if not raw:
        continue
    try:
        obj = json.loads(raw)
    except ValueError:
        continue
    t = obj.get("type")

    if t == "result" and obj.get("result"):
        result = obj["result"]
    elif t == "assistant":
        for c in (obj.get("message") or {}).get("content") or []:
            if isinstance(c, dict) and c.get("type") == "text":
                text = c.get("text") or ""
                if len(text) >= 200:
                    last_long_text = text
    elif t in ("tool_call", "tool_call_update"):
        saw_grok_tool = True
        grok_parts = []
    elif t == "text":
        d = obj.get("data")
        if isinstance(d, str):
            grok_parts.append(d)
        elif isinstance(d, dict) and isinstance(d.get("text"), str):
            grok_parts.append(d["text"])

# Preference order mirrors trustworthiness: an explicit result event is the
# harness saying "this is the answer"; grok's trailing text is the answer by
# construction (nothing runs after it); a long assistant text is a guess.
report = result
if report is None and saw_grok_tool and grok_parts:
    report = "".join(grok_parts)
if report is None and not saw_grok_tool and grok_parts:
    # A grok log whose final turn had no tool calls at all.
    report = "".join(grok_parts)
if report is None:
    report = last_long_text

if not report or not report.strip():
    print("last-report.sh: no report-shaped content in " + path, file=sys.stderr)
    sys.exit(65)

report = report.strip()
if max_chars and len(report) > max_chars:
    report = report[:max_chars] + f"\n… [truncated at {max_chars} chars]"
print(report)
PY

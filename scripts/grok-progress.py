#!/usr/bin/env python3
"""Compress a grok headless NDJSON log into one-line progress events.

Reads `--output-format streaming-json` stdout (and, when the shape matches,
session `updates.jsonl` or `--output-format streaming-messages-json`).
Default output is capped at 100 lines so a lead session can ingest it.

Verified event shapes (grok 1.0.3):

* streaming-json line: ``{"type":"tool_call","toolName":"...","rawInput":{...}}``
* streaming-json text: ``{"type":"text","data":"..."}`` (token chunks)
* updates.jsonl line: ``{"timestamp": <unix>, "method":"...", "params":{"update":{...}}}``
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from collections import Counter
from typing import Any, Dict, Iterable, Iterator, List, Optional, Tuple


# First string-ish field used as the 80-char argument summary.
# Search report: no shared axis exists in this repo (new table).
_INPUT_KEYS = (
    "command",
    "cmd",
    "target_file",
    "file_path",
    "pattern",
    "query",
    "url",
    "prompt",
    "target_directory",
    "path",
)

_SKIP_TYPES = frozenset(
    {
        "available_commands",
        "usage",
        "available_commands_update",
        "hook_execution",
        "system",
        "result",
        "stream_event",
    }
)

DEFAULT_CAP = 100
ARG_LIMIT = 80
TEXT_LIMIT = 120


def _clip(text: str, limit: int) -> str:
    text = text.replace("\n", "\\n").replace("\r", "")
    if len(text) <= limit:
        return text
    return text[: max(0, limit - 1)] + "…"


def _first_arg(raw: Any) -> str:
    if not isinstance(raw, dict) or not raw:
        if raw is None:
            return ""
        return _clip(str(raw), ARG_LIMIT)
    for key in _INPUT_KEYS:
        if key in raw and raw[key] not in (None, ""):
            return _clip(str(raw[key]), ARG_LIMIT)
    for value in raw.values():
        if isinstance(value, (str, int, float)) and str(value):
            return _clip(str(value), ARG_LIMIT)
    return ""


def _clock(ts: Optional[float], origin: Optional[float]) -> str:
    if ts is None or origin is None:
        return "--:--"
    elapsed = max(0.0, ts - origin)
    minutes = int(elapsed // 60)
    seconds = int(elapsed % 60)
    return f"{minutes:02d}:{seconds:02d}"


def _unwrap(obj: Dict[str, Any]) -> Dict[str, Any]:
    """Normalize one NDJSON object to a flat event dict."""
    if obj.get("type") == "tool_call" or obj.get("type") == "tool_call_update":
        return {
            "kind": obj.get("type"),
            "tool": obj.get("toolName") or obj.get("title") or "tool",
            "input": obj.get("rawInput"),
            "status": obj.get("status"),
            "ts": obj.get("timestamp"),
            "text": None,
        }
    if obj.get("type") == "text":
        return {
            "kind": "text",
            "tool": None,
            "input": None,
            "status": None,
            "ts": obj.get("timestamp"),
            "text": obj.get("data") or "",
        }
    if obj.get("type") == "thought":
        return {
            "kind": "thought",
            "tool": None,
            "input": None,
            "status": None,
            "ts": obj.get("timestamp"),
            "text": obj.get("data") or "",
        }
    if obj.get("type") == "end":
        return {
            "kind": "end",
            "tool": None,
            "input": None,
            "status": obj.get("stopReason"),
            "ts": obj.get("timestamp"),
            "text": obj.get("stopReason") or "end",
        }
    if obj.get("type") == "error":
        return {
            "kind": "error",
            "tool": None,
            "input": None,
            "status": None,
            "ts": obj.get("timestamp"),
            "text": obj.get("message") or "error",
        }

    # session updates.jsonl: {timestamp, method, params.update}
    params = obj.get("params")
    if isinstance(params, dict) and isinstance(params.get("update"), dict):
        upd = params["update"]
        su = upd.get("sessionUpdate")
        ts = obj.get("timestamp")
        if isinstance(ts, (int, float)) and ts > 10**12:
            ts = ts / 1000.0
        if su == "tool_call":
            return {
                "kind": "tool_call",
                "tool": upd.get("title") or upd.get("toolName") or "tool",
                "input": upd.get("rawInput"),
                "status": upd.get("status"),
                "ts": ts,
                "text": None,
            }
        if su in ("agent_message_chunk", "user_message_chunk"):
            content = upd.get("content") or {}
            return {
                "kind": "text" if su == "agent_message_chunk" else "user_text",
                "tool": None,
                "input": None,
                "status": None,
                "ts": ts,
                "text": (content.get("text") if isinstance(content, dict) else "") or "",
            }
        if su == "agent_thought_chunk":
            content = upd.get("content") or {}
            return {
                "kind": "thought",
                "tool": None,
                "input": None,
                "status": None,
                "ts": ts,
                "text": (content.get("text") if isinstance(content, dict) else "") or "",
            }
        if su == "turn_completed":
            return {
                "kind": "end",
                "tool": None,
                "input": None,
                "status": upd.get("stop_reason"),
                "ts": ts,
                "text": upd.get("stop_reason") or "end",
            }
        return {"kind": su or "unknown", "tool": None, "input": None, "status": None, "ts": ts, "text": None}

    # streaming-messages-json assistant/user frames
    if obj.get("type") == "assistant":
        message = obj.get("message") or {}
        content = message.get("content") or []
        return {
            "kind": "assistant_frame",
            "tool": None,
            "input": None,
            "status": None,
            "ts": None,
            "text": None,
            "blocks": content if isinstance(content, list) else [],
        }
    if obj.get("type") == "user":
        message = obj.get("message") or {}
        content = message.get("content") or []
        return {
            "kind": "user_frame",
            "tool": None,
            "input": None,
            "status": None,
            "ts": None,
            "text": None,
            "blocks": content if isinstance(content, list) else [],
        }

    typ = obj.get("type")
    if typ in _SKIP_TYPES:
        return {"kind": typ, "tool": None, "input": None, "status": None, "ts": None, "text": None}
    return {
        "kind": typ or "unknown",
        "tool": obj.get("toolName") or obj.get("title"),
        "input": obj.get("rawInput") or obj.get("input"),
        "status": obj.get("status"),
        "ts": obj.get("timestamp"),
        "text": obj.get("data") or obj.get("message"),
    }


def _expand_frame(event: Dict[str, Any]) -> List[Dict[str, Any]]:
    blocks = event.get("blocks") or []
    out: List[Dict[str, Any]] = []
    for block in blocks:
        if not isinstance(block, dict):
            continue
        btype = block.get("type")
        if btype == "tool_use":
            out.append(
                {
                    "kind": "tool_call",
                    "tool": block.get("name") or "tool",
                    "input": block.get("input"),
                    "status": None,
                    "ts": None,
                    "text": None,
                }
            )
        elif btype == "text":
            out.append(
                {
                    "kind": "text",
                    "tool": None,
                    "input": None,
                    "status": None,
                    "ts": None,
                    "text": block.get("text") or "",
                }
            )
        elif btype == "thinking":
            out.append(
                {
                    "kind": "thought",
                    "tool": None,
                    "input": None,
                    "status": None,
                    "ts": None,
                    "text": block.get("thinking") or block.get("text") or "",
                }
            )
    return out


def _format_event(event: Dict[str, Any], origin: Optional[float]) -> Optional[str]:
    kind = event.get("kind")
    stamp = _clock(event.get("ts"), origin)
    if kind == "tool_call":
        name = str(event.get("tool") or "tool")
        arg = _first_arg(event.get("input"))
        if arg:
            return f"[{stamp}] {name}: {arg}"
        return f"[{stamp}] {name}"
    if kind == "text":
        body = (event.get("text") or "").split("\n", 1)[0]
        body = _clip(body, TEXT_LIMIT)
        if not body.strip():
            return None
        return f"[{stamp}] text: {body}"
    if kind == "user_text":
        body = (event.get("text") or "").split("\n", 1)[0]
        body = _clip(body, TEXT_LIMIT)
        if not body.strip():
            return None
        return f"[{stamp}] user: {body}"
    if kind == "thought":
        body = (event.get("text") or "").split("\n", 1)[0]
        body = _clip(body, TEXT_LIMIT)
        if not body.strip():
            return None
        return f"[{stamp}] think: {body}"
    if kind == "end":
        return f"[{stamp}] end: {event.get('status') or event.get('text') or 'end'}"
    if kind == "error":
        return f"[{stamp}] error: {_clip(str(event.get('text') or 'error'), TEXT_LIMIT)}"
    return None


def _coalesce_text(events: Iterable[Dict[str, Any]]) -> List[Dict[str, Any]]:
    """Join consecutive token-sized text/thought chunks into one event each."""
    out: List[Dict[str, Any]] = []
    buf: Optional[Dict[str, Any]] = None
    for event in events:
        kind = event.get("kind")
        if kind in ("text", "thought", "user_text") and event.get("text") is not None:
            if buf is not None and buf.get("kind") == kind:
                buf["text"] = (buf.get("text") or "") + (event.get("text") or "")
                continue
            if buf is not None:
                out.append(buf)
            buf = dict(event)
            continue
        if buf is not None:
            out.append(buf)
            buf = None
        out.append(event)
    if buf is not None:
        out.append(buf)
    return out


def _iter_objects(lines: Iterable[str]) -> Iterator[Dict[str, Any]]:
    for line in lines:
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(obj, dict):
            yield obj


def parse_events(
    objects: Iterable[Dict[str, Any]],
    *,
    tools_only: bool,
    thinking: bool,
) -> List[Dict[str, Any]]:
    raw: List[Dict[str, Any]] = []
    for obj in objects:
        event = _unwrap(obj)
        if event.get("kind") in ("assistant_frame", "user_frame"):
            raw.extend(_expand_frame(event))
            continue
        if event.get("kind") in _SKIP_TYPES:
            continue
        if event.get("kind") == "tool_call_update":
            # Only the opening tool_call is a progress line; updates are results.
            continue
        raw.append(event)
    coalesced = _coalesce_text(raw)
    kept: List[Dict[str, Any]] = []
    for event in coalesced:
        kind = event.get("kind")
        if tools_only and kind != "tool_call":
            continue
        if kind in ("thought",) and not thinking:
            continue
        if kind in _SKIP_TYPES:
            continue
        if _format_event(event, origin=0.0) is None and kind not in ("tool_call", "end", "error"):
            continue
        kept.append(event)
    return kept


def _assign_wall_times(events: List[Dict[str, Any]], fallback_origin: Optional[float]) -> Optional[float]:
    stamps = [e.get("ts") for e in events if isinstance(e.get("ts"), (int, float))]
    if stamps:
        return min(stamps)
    if fallback_origin is not None:
        for event in events:
            if event.get("ts") is None:
                event["ts"] = fallback_origin
        return fallback_origin
    return None


def _summarize(events: List[Dict[str, Any]]) -> Tuple[Counter, Counter]:
    tools: Counter = Counter()
    kinds: Counter = Counter()
    for event in events:
        kinds[event.get("kind") or "unknown"] += 1
        if event.get("kind") == "tool_call":
            tools[str(event.get("tool") or "tool")] += 1
    return tools, kinds


def _summary_lines(events: List[Dict[str, Any]], origin: Optional[float], last_n: int = 5) -> List[str]:
    tools, kinds = _summarize(events)
    reads = tools.get("read_file", 0) + tools.get("Read", 0)
    commands = tools.get("run_terminal_command", 0) + tools.get("Bash", 0)
    greps = tools.get("grep", 0)
    lists = tools.get("list_dir", 0)
    other = sum(tools.values()) - reads - commands - greps - lists
    parts = [
        f"{reads} read_file",
        f"{commands} run_terminal_command",
        f"{greps} grep",
        f"{lists} list_dir",
    ]
    if other:
        parts.append(f"{other} other-tools")
    if kinds.get("text"):
        parts.append(f"{kinds['text']} text")
    if kinds.get("end"):
        parts.append("ended")
    lines = [f"summary: {len(events)} events; " + ", ".join(parts)]
    tail = events[-last_n:]
    if tail:
        lines.append(f"last {len(tail)}:")
        for event in tail:
            formatted = _format_event(event, origin)
            if formatted:
                lines.append(formatted)
    return lines


def render(
    events: List[Dict[str, Any]],
    *,
    last: Optional[int],
    cap: int,
    origin: Optional[float],
) -> List[str]:
    if last is not None:
        events = events[-last:]
        return [line for e in events if (line := _format_event(e, origin))]
    lines = [line for e in events if (line := _format_event(e, origin))]
    if len(lines) <= cap:
        return lines
    return _summary_lines(events, origin, last_n=5)


def _follow(path: str) -> Iterator[str]:
    """Yield complete lines as they are appended. Leaves a partial last line buffered."""
    with open(path, encoding="utf-8", errors="replace") as handle:
        buf = ""
        while True:
            chunk = handle.read()
            if chunk:
                buf += chunk
                while True:
                    nl = buf.find("\n")
                    if nl < 0:
                        break
                    yield buf[:nl]
                    buf = buf[nl + 1 :]
            else:
                time.sleep(0.2)


def _load_file(path: str) -> List[str]:
    with open(path, encoding="utf-8", errors="replace") as handle:
        return handle.read().splitlines()


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="grok-progress.py",
        description=(
            "Compress a grok NDJSON log into one-line progress events. "
            "Default output is at most 100 lines."
        ),
    )
    parser.add_argument(
        "log",
        help="Path to a streaming-json log, streaming-messages-json log, or session updates.jsonl",
    )
    parser.add_argument(
        "--last",
        type=int,
        metavar="N",
        help="Print only the last N progress lines (no 100-line summary cap)",
    )
    parser.add_argument(
        "--tail",
        action="store_true",
        help="Follow the file and print new progress lines as they appear (uncapped)",
    )
    parser.add_argument(
        "--tools-only",
        action="store_true",
        help="Emit tool_call lines only",
    )
    parser.add_argument(
        "--thinking",
        action="store_true",
        help="Include thought/reasoning lines (omitted by default)",
    )
    return parser


def main(argv: Optional[List[str]] = None) -> int:
    parser = _build_parser()
    args = parser.parse_args(argv)
    if args.last is not None and args.last < 0:
        parser.error("--last must be >= 0")

    if args.tail:
        origin = time.time()
        pending: List[Dict[str, Any]] = []
        try:
            for line in _follow(args.log):
                try:
                    obj = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if not isinstance(obj, dict):
                    continue
                events = parse_events([obj], tools_only=args.tools_only, thinking=args.thinking)
                # Re-coalesce across the file boundary of one line: if this line
                # is a text chunk, hold it until a non-text arrives or a newline.
                for event in events:
                    if event.get("ts") is None:
                        event["ts"] = time.time()
                    if event.get("kind") in ("text", "thought", "user_text"):
                        if pending and pending[-1].get("kind") == event.get("kind"):
                            pending[-1]["text"] = (pending[-1].get("text") or "") + (
                                event.get("text") or ""
                            )
                            # flush on newline
                            if "\n" in (pending[-1].get("text") or ""):
                                flushed = pending.pop()
                                first, _, rest = (flushed.get("text") or "").partition("\n")
                                flushed["text"] = first
                                line_out = _format_event(flushed, origin)
                                if line_out:
                                    print(line_out, flush=True)
                                if rest:
                                    pending.append({**flushed, "text": rest})
                            continue
                        pending.append(event)
                        continue
                    while pending:
                        held = pending.pop(0)
                        line_out = _format_event(held, origin)
                        if line_out:
                            print(line_out, flush=True)
                    line_out = _format_event(event, origin)
                    if line_out:
                        print(line_out, flush=True)
        except KeyboardInterrupt:
            while pending:
                held = pending.pop(0)
                line_out = _format_event(held, origin)
                if line_out:
                    print(line_out, flush=True)
            return 0
        return 0

    try:
        lines = _load_file(args.log)
    except OSError as exc:
        print(f"error: cannot read {args.log}: {exc}", file=sys.stderr)
        return 2

    objects = list(_iter_objects(lines))
    events = parse_events(objects, tools_only=args.tools_only, thinking=args.thinking)
    origin = _assign_wall_times(events, fallback_origin=None)
    for line in render(events, last=args.last, cap=DEFAULT_CAP, origin=origin):
        print(line)
    return 0


if __name__ == "__main__":
    sys.exit(main())

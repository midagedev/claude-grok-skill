#!/usr/bin/env python3
"""Answer "is this grok round actually finished?" from durable evidence.

Harness background-task notifications report the WRAPPER SHELL's lifetime,
not grok's: a nested launcher (`launch.sh &`), an early-exiting wrapper, or a
sleep-guard all fire "completed" while grok keeps working as an orphan
(misdiagnosed twice in the field, 2026-08-15). This script is the single
owner of round-state judgment. Evidence, in order of authority:

  1. sentinel file (written by the launch recipe after grok exits: "rc=N ...")
  2. a live process matching `grok -s <SID>` exactly
  3. the ndjson `end` event (absent after a kill or crash mid-write)

Verdicts on stdout, one line, machine-greppable:

  COMPLETED rc=0 ...      sentinel exists (trust it; check rc)
  RUNNING pid=123 ...     no sentinel, process alive — do not touch the tree
  DIED-NO-SENTINEL ...    no sentinel, no process; `end` present = wrapper
                          lost the sentinel write; absent = killed/crashed
  UNKNOWN ...             no evidence found at the given paths

Usage:
  grok-round-status.py --sid <SID> [--ndjson <log>] [--done <sentinel>]
  grok-round-status.py --scratch <dir> --track <name>   # convention paths:
      sid-<track>.txt / grok-<track>.ndjson / done-<track>.rc
"""

import argparse
import json
import os
import subprocess
import sys
import time


def read_sid(args):
    if args.sid:
        return args.sid
    p = os.path.join(args.scratch, f"sid-{args.track}.txt")
    try:
        return open(p).read().strip()
    except OSError:
        return None


def live_pid(sid):
    if not sid:
        return None
    try:
        out = subprocess.run(
            ["pgrep", "-f", f"grok -s {sid}"], capture_output=True, text=True
        ).stdout.split()
        me = str(os.getpid())
        pids = [p for p in out if p != me]
        return pids[0] if pids else None
    except OSError:
        return None


def ndjson_facts(path):
    """(has_end, last_event_type, last_mtime_age_s, event_count)"""
    if not path or not os.path.exists(path):
        return (False, None, None, 0)
    has_end, last_type, count = False, None, 0
    with open(path, errors="replace") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            count += 1
            try:
                t = json.loads(line).get("type")
            except ValueError:
                continue  # torn tail line mid-write
            last_type = t
            if t == "end":
                has_end = True
    age = time.time() - os.path.getmtime(path)
    return (has_end, last_type, age, count)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sid")
    ap.add_argument("--ndjson")
    ap.add_argument("--done")
    ap.add_argument("--scratch")
    ap.add_argument("--track")
    args = ap.parse_args()

    if args.scratch and args.track:
        args.ndjson = args.ndjson or os.path.join(
            args.scratch, f"grok-{args.track}.ndjson"
        )
        args.done = args.done or os.path.join(args.scratch, f"done-{args.track}.rc")
    elif not args.sid and not args.ndjson:
        ap.error("need --sid/--ndjson, or --scratch with --track")

    sid = read_sid(args)
    has_end, last_type, age, count = ndjson_facts(args.ndjson)
    age_s = f"{age:.0f}s" if age is not None else "n/a"

    if args.done and os.path.exists(args.done):
        print(f"COMPLETED {open(args.done).read().strip()} "
              f"end_event={'yes' if has_end else 'no'} events={count}")
        return 0

    pid = live_pid(sid)
    if pid:
        print(f"RUNNING pid={pid} last_event={last_type} log_age={age_s} "
              f"events={count} — round NOT finished; notifications lie, this doesn't")
        return 0

    if count:
        why = ("end event present — grok finished but the sentinel write was lost "
               "(wrapper exited early); treat the log's report as final"
               if has_end else
               "no end event — killed or crashed mid-run; the tree may be half-written")
        print(f"DIED-NO-SENTINEL {why} last_event={last_type} log_age={age_s} events={count}")
        return 0

    print(f"UNKNOWN no sentinel, no live process for sid={sid}, no events at {args.ndjson}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

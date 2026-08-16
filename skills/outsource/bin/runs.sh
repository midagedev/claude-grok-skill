#!/usr/bin/env bash
# The registry of delegated runs: who is running right now, on what, for how
# long, and how the last few ended.
#
#   runs.sh [list]                    human table (default)
#   runs.sh line                      one compact line, for a status line
#   runs.sh json                      machine-readable, one object per run
#   runs.sh start  --pid N --provider P --harness H [...]   -> prints run id
#   runs.sh finish <run-id> --rc N [--session S] [--model-actual M]
#   runs.sh prune [--keep-seconds N]  drop finished records older than N
#
# Why this file exists rather than a `ps` grep at each call site: a launched
# round is invisible between "I started it" and "it printed a report", and
# that gap is where a lead loses track of which tracks are still alive, how
# long they have been running, and which one died without a report. `ps` can
# answer the first question and none of the others — a killed round leaves no
# process at all, so the interesting state (started, never finished) is
# exactly the state a process listing cannot represent.
#
# One record per run, `key=value` lines — the same shape as the launcher's
# `<log>.rc` completion sentinel, so it is greppable, diffable, and readable
# with no parser. This script is the only writer; readers (the launcher, a
# status line, a human) go through the subcommands here so the format has one
# owner.
#
# Records live in $OUTSOURCE_RUNS_DIR, default
# ${XDG_STATE_HOME:-~/.local/state}/outsource/runs, named
# <startedAt>-<pid>.run so a plain glob sorts oldest-first.
#
# The four states a run can be in, and how each is decided:
#
#   running   record has no rc, and the pid is alive
#   orphan    record has no rc, and the pid is gone — the round died without
#             finishing (killed, machine slept, harness crashed). This is the
#             state that makes the registry worth keeping: nothing else on
#             the machine still remembers the round existed.
#   done      rc=0
#   failed    rc!=0 (the launcher's own exit codes carry the reason)
#
# Liveness is checked with `kill -0`, which cannot distinguish "that pid
# exited" from "that pid exited and the number was reused". A reused pid can
# only make an orphan look alive, never the reverse, and the elapsed time
# printed next to it is the tell.
#
# Exit codes: 0 ok · 64 usage error · 65 no such run id
set -euo pipefail

RUNS_DIR="${OUTSOURCE_RUNS_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/outsource/runs}"
KEEP_SECONDS_DEFAULT=86400   # finished records survive a day, then prune
RECENT_SECONDS=600           # `line` also shows runs that ended this recently
# How long a running round may go without writing anything before it is
# flagged.
#
# The axis here is deliberately NOT elapsed time. Measured across ten
# delivered rounds, duration ran 13 minutes to 1h50m and tracked message
# count almost linearly — long rounds were long because there was a lot of
# work, not because anything was wrong. Flagging on elapsed time therefore
# flags exactly the rounds that must not be disturbed, while a round stuck
# in a loop at minute three goes unnoticed.
#
# Progress separates them. Both harnesses write continuously into their
# per-track data directory — crush into `crush.db-wal` and `logs/crush.log`
# every few seconds, the claude-code harness into `projects/**.jsonl` every
# turn — so "nothing has been written for ten minutes" means stalled in a
# way that "running for ninety minutes" never did. Override with
# OUTSOURCE_RUN_STALL.
STALL_SECONDS="${OUTSOURCE_RUN_STALL:-600}"

now_epoch() { date +%s; }

# ---- record io --------------------------------------------------------------
# A value is one line, so anything that could carry a newline is flattened
# before it is written. Nothing here is ever eval'd: reads split on the first
# '=' and assign into a fixed set of variables.

sanitize() { printf '%s' "$1" | tr '\n\r' '  '; }

# Fields of the record currently loaded by read_record.
R_ID=""; R_PID=""; R_LABEL=""; R_PROVIDER=""; R_HARNESS=""; R_MODEL=""
R_CWD=""; R_SPEC=""; R_LOG=""; R_STARTED=""; R_RC=""; R_FINISHED=""
R_SESSION=""; R_MODEL_ACTUAL=""; R_PROGRESS=""

read_record() {  # <file>; fills R_*; returns 1 on an unreadable file
  R_ID=""; R_PID=""; R_LABEL=""; R_PROVIDER=""; R_HARNESS=""; R_MODEL=""
  R_CWD=""; R_SPEC=""; R_LOG=""; R_STARTED=""; R_RC=""; R_FINISHED=""
  R_SESSION=""; R_MODEL_ACTUAL=""; R_PROGRESS=""
  [ -r "$1" ] || return 1
  local k v
  while IFS='=' read -r k v; do
    case "$k" in
      id)           R_ID="$v" ;;
      pid)          R_PID="$v" ;;
      label)        R_LABEL="$v" ;;
      provider)     R_PROVIDER="$v" ;;
      harness)      R_HARNESS="$v" ;;
      model)        R_MODEL="$v" ;;
      cwd)          R_CWD="$v" ;;
      spec)         R_SPEC="$v" ;;
      log)          R_LOG="$v" ;;
      startedAt)    R_STARTED="$v" ;;
      rc)           R_RC="$v" ;;
      finishedAt)   R_FINISHED="$v" ;;
      session)      R_SESSION="$v" ;;
      modelActual)  R_MODEL_ACTUAL="$v" ;;
      progressDir)  R_PROGRESS="$v" ;;
    esac
  done < "$1"
  [ -n "$R_ID" ]
}

alive() {  # <pid> — true when the process still exists
  [ -n "$1" ] && kill -0 "$1" 2>/dev/null
}

state_of() {  # uses the loaded R_*; prints running|orphan|done|failed
  if [ -z "$R_RC" ]; then
    if alive "$R_PID"; then echo running; else echo orphan; fi
  elif [ "$R_RC" = 0 ]; then
    echo done
  else
    echo failed
  fi
}

# Newest mtime anywhere under a directory, as epoch seconds. Both harness
# data directories hold a handful of files, so this stays a couple of stats.
newest_mtime() {  # <dir>
  local d="${1:-}"
  { [ -n "$d" ] && [ -d "$d" ]; } || return 0
  if stat -f %m . >/dev/null 2>&1; then   # BSD/macOS
    find "$d" -type f -exec stat -f %m {} + 2>/dev/null | sort -rn | head -1 || true
  else                                     # GNU
    find "$d" -type f -exec stat -c %Y {} + 2>/dev/null | sort -rn | head -1 || true
  fi
}

# Seconds since this round last wrote anything; empty when unknowable (no
# progress directory recorded, or nothing written yet). Empty is reported as
# unknown, never as zero — "we cannot see progress" and "it just wrote" must
# not look the same.
idle_of() {
  local m
  m="$(newest_mtime "$R_PROGRESS")"
  [ -n "$m" ] || return 0
  local s=$(( $(now_epoch) - m ))
  [ "$s" -lt 0 ] && s=0
  echo "$s"
}

# A running round with no sign of life for STALL_SECONDS. Never true for a
# finished one, and never true when progress cannot be observed at all.
stalled() {
  local idle
  idle="$(idle_of)"
  [ -n "$idle" ] && [ "$idle" -ge "$STALL_SECONDS" ]
}

elapsed_of() {  # seconds this run has been (or was) alive
  local end="${R_FINISHED:-}"
  [ -n "$end" ] || end="$(now_epoch)"
  local s=$(( end - ${R_STARTED:-0} ))
  [ "$s" -lt 0 ] && s=0
  echo "$s"
}

human_secs() {  # 45s · 12m · 1h04m · 2d3h
  local s="$1"
  if   [ "$s" -lt 60 ];    then printf '%ds' "$s"
  elif [ "$s" -lt 3600 ];  then printf '%dm' $(( s / 60 ))
  elif [ "$s" -lt 86400 ]; then printf '%dh%02dm' $(( s / 3600 )) $(( s % 3600 / 60 ))
  else                          printf '%dd%dh' $(( s / 86400 )) $(( s % 86400 / 3600 ))
  fi
}

harness_short() { case "$1" in claude-code) echo cc ;; *) echo "$1" ;; esac; }

# Oldest first; prints nothing when the directory is absent or empty.
each_record() {
  [ -d "$RUNS_DIR" ] || return 0
  local f
  for f in "$RUNS_DIR"/*.run; do
    [ -e "$f" ] || continue
    printf '%s\n' "$f"
  done
}

# ---- subcommands ------------------------------------------------------------

cmd_start() {
  local pid="" label="" provider="" harness="" model="" cwd="" spec="" log="" progress=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --progress-dir) progress="$2"; shift 2 ;;
      --pid)      pid="$2"; shift 2 ;;
      --label)    label="$2"; shift 2 ;;
      --provider) provider="$2"; shift 2 ;;
      --harness)  harness="$2"; shift 2 ;;
      --model)    model="$2"; shift 2 ;;
      --cwd)      cwd="$2"; shift 2 ;;
      --spec)     spec="$2"; shift 2 ;;
      --log)      log="$2"; shift 2 ;;
      *) echo "runs.sh start: unknown flag: $1" >&2; exit 64 ;;
    esac
  done
  [ -n "$pid" ] || { echo "runs.sh start: --pid is required" >&2; exit 64; }

  local started id
  started="$(now_epoch)"
  id="$started-$pid"
  mkdir -p "$RUNS_DIR"

  # Write-then-rename: a status line reading the directory concurrently sees
  # either no record or a complete one, never half of one.
  local tmp="$RUNS_DIR/.$id.tmp"
  {
    printf 'id=%s\n'          "$id"
    printf 'pid=%s\n'         "$(sanitize "$pid")"
    printf 'label=%s\n'       "$(sanitize "${label:-run}")"
    printf 'provider=%s\n'    "$(sanitize "$provider")"
    printf 'harness=%s\n'     "$(sanitize "$harness")"
    printf 'model=%s\n'       "$(sanitize "$model")"
    printf 'cwd=%s\n'         "$(sanitize "$cwd")"
    printf 'spec=%s\n'        "$(sanitize "$spec")"
    printf 'log=%s\n'         "$(sanitize "$log")"
    printf 'progressDir=%s\n' "$(sanitize "$progress")"
    printf 'startedAt=%s\n'   "$started"
  } > "$tmp"
  mv "$tmp" "$RUNS_DIR/$id.run"

  # Housekeeping rides the write path so no one has to remember to run it.
  cmd_prune --keep-seconds "$KEEP_SECONDS_DEFAULT" >/dev/null 2>&1 || true
  printf '%s\n' "$id"
}

cmd_finish() {
  [ $# -ge 1 ] || { echo "runs.sh finish: needs a run id" >&2; exit 64; }
  local id="$1"; shift
  local rc="" session="" model_actual=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --rc)           rc="$2"; shift 2 ;;
      --session)      session="$2"; shift 2 ;;
      --model-actual) model_actual="$2"; shift 2 ;;
      *) echo "runs.sh finish: unknown flag: $1" >&2; exit 64 ;;
    esac
  done
  local f="$RUNS_DIR/$id.run"
  [ -f "$f" ] || { echo "runs.sh finish: no such run: $id" >&2; exit 65; }

  # Append rather than rewrite: the start fields are the launcher's record of
  # what it launched, and a finish should never be able to rewrite history.
  # read_record takes the last assignment of a key, so appending wins.
  {
    printf 'rc=%s\n'          "$(sanitize "${rc:-1}")"
    printf 'finishedAt=%s\n'  "$(now_epoch)"
    [ -z "$session" ]      || printf 'session=%s\n'     "$(sanitize "$session")"
    [ -z "$model_actual" ] || printf 'modelActual=%s\n' "$(sanitize "$model_actual")"
  } >> "$f"
}

cmd_prune() {
  local keep="$KEEP_SECONDS_DEFAULT"
  while [ $# -gt 0 ]; do
    case "$1" in
      --keep-seconds) keep="$2"; shift 2 ;;
      *) echo "runs.sh prune: unknown flag: $1" >&2; exit 64 ;;
    esac
  done
  local now f n=0
  now="$(now_epoch)"
  while IFS= read -r f; do
    read_record "$f" || { rm -f "$f"; continue; }
    # Only finished records expire. An orphan is kept: it is the only trace
    # left of a round that died, and deleting it on a timer would delete the
    # evidence before anyone read it.
    [ -n "$R_RC" ] || continue
    if [ $(( now - ${R_FINISHED:-0} )) -gt "$keep" ]; then rm -f "$f"; n=$(( n + 1 )); fi
  done <<EOF
$(each_record)
EOF
  echo "pruned $n"
}

cmd_list() {
  local any=0 f st el idle idle_col
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    read_record "$f" || continue
    if [ "$any" -eq 0 ]; then
      printf '%-8s %-16s %-6s %-6s %8s %6s  %s\n' STATE LABEL PROV HARNESS ELAPSED IDLE SPEC
      any=1
    fi
    st="$(state_of)"
    el="$(human_secs "$(elapsed_of)")"
    idle=""; idle_col="-"
    if [ "$st" = running ]; then
      idle="$(idle_of)"
      [ -n "$idle" ] && idle_col="$(human_secs "$idle")" || idle_col="?"
    fi
    printf '%-8s %-16s %-6s %-6s %8s %6s  %s\n' \
      "$st" "${R_LABEL:0:16}" "$R_PROVIDER" "$(harness_short "$R_HARNESS")" "$el" "$idle_col" "$R_SPEC"
    case "$st" in
      failed) printf '         rc=%s  log=%s\n' "$R_RC" "${R_LOG:-none}" ;;
      orphan) printf '         started but never finished — pid %s is gone; log=%s\n' "$R_PID" "${R_LOG:-none}" ;;
      running)
        if stalled; then
          # Deliberately not a kill instruction. A stall is a reason to look
          # at the log, and the round may still recover on its own.
          printf '         no output for %s — check %s before doing anything to it\n' \
            "$(human_secs "$idle")" "${R_LOG:-the harness log}"
        fi ;;
    esac
  done <<EOF
$(each_record)
EOF
  [ "$any" -eq 1 ] || echo "no delegated runs on record (${RUNS_DIR})"
}

# One line, no colour: whatever renders it owns the styling. Running and
# orphaned runs always show; finished ones only while they are still news.
# Two tracks sharing a label render as the same word twice, which reads as a
# duplicate rather than as two rounds. A "#2" suffix is the honest minimum —
# it says "there is more than one of these and this line cannot tell them
# apart", and the fix is a real --label at launch, not a longer suffix here.
#
# The result comes back in a global rather than on stdout: `x=$(disambiguate
# …)` would run the function in a subshell, so the running tally of labels
# seen would be discarded after every call and no collision could ever be
# detected.
EMITTED_LABELS=""
DISAMBIGUATED=""
disambiguate() {  # <label> -> DISAMBIGUATED
  local l="$1" n
  n=$(printf '%s\n' "$EMITTED_LABELS" | grep -cxF -- "$l") || n=0
  EMITTED_LABELS="${EMITTED_LABELS}${l}
"
  if [ "$n" -gt 0 ]; then DISAMBIGUATED="$l#$(( n + 1 ))"; else DISAMBIGUATED="$l"; fi
}

DIM_IDLE="⋯"   # marks the number that follows as "silent for", not "running for"

cmd_line() {
  local now f st el live_out="" past_out="" out="" live=0 seg lbl mark extra
  now="$(now_epoch)"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    read_record "$f" || continue
    st="$(state_of)"
    case "$st" in
      running|orphan) ;;
      *) [ $(( now - ${R_FINISHED:-0} )) -le "$RECENT_SECONDS" ] || continue ;;
    esac
    el="$(human_secs "$(elapsed_of)")"
    # Live work reads first and outcomes trail it: a round still burning
    # tokens is the thing to act on, a finished one is only news.
    disambiguate "$R_LABEL"; lbl="$DISAMBIGUATED"
    case "$st" in
      running) # A long round that is still writing gets no alarm — that is
               # just a big task. Silence is what earns the hourglass, and
               # the idle time rides along so the two are never confused.
               if stalled; then mark="⏳"; extra=" ${DIM_IDLE}$(human_secs "$(idle_of)")"
               else             mark="▶";  extra=""
               fi
               seg="${mark}${lbl} ${R_PROVIDER}·$(harness_short "$R_HARNESS") ${el}${extra}"
               live=$(( live + 1 )); live_out="${live_out}${live_out:+  }${seg}" ;;
      orphan)  seg="⚠${lbl} ${R_PROVIDER}·$(harness_short "$R_HARNESS") ${el}"
               live=$(( live + 1 )); live_out="${live_out}${live_out:+  }${seg}" ;;
      done)    past_out="${past_out}${past_out:+  }✅${lbl} ${el}" ;;
      failed)  past_out="${past_out}${past_out:+  }❌${lbl} rc=${R_RC}" ;;
    esac
  done <<EOF
$(each_record)
EOF
  out="${live_out}${live_out:+${past_out:+  }}${past_out}"
  [ -n "$out" ] || return 0
  # The count is a headline for work in flight. With nothing in flight it
  # would read "🛠0" next to a green tick — a zero where the eye expects an
  # alarm — so it is simply absent then.
  if [ "$live" -gt 0 ]; then printf '🛠%s %s\n' "$live" "$out"; else printf '%s\n' "$out"; fi
}

cmd_json() {
  local f first=1
  printf '['
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    read_record "$f" || continue
    [ "$first" -eq 1 ] || printf ','
    first=0
    # Emitted by python so the strings are escaped correctly; the values
    # arrive as argv, never interpolated into the program text.
    python3 -c 'import json,sys
k = ["id","pid","label","provider","harness","model","cwd","spec","log",
     "progressDir","startedAt","rc","finishedAt","session","modelActual",
     "state","elapsedSeconds","idleSeconds","stalled"]
v = sys.argv[1:]
d = dict(zip(k, v))
for n in ("pid","startedAt","finishedAt","rc","elapsedSeconds","idleSeconds"):
    d[n] = int(d[n]) if str(d.get(n, "")).lstrip("-").isdigit() else None
d["stalled"] = d["stalled"] == "1"
sys.stdout.write(json.dumps(d, separators=(",", ":")))' \
      "$R_ID" "$R_PID" "$R_LABEL" "$R_PROVIDER" "$R_HARNESS" "$R_MODEL" \
      "$R_CWD" "$R_SPEC" "$R_LOG" "$R_PROGRESS" "$R_STARTED" "$R_RC" "$R_FINISHED" \
      "$R_SESSION" "$R_MODEL_ACTUAL" "$(state_of)" "$(elapsed_of)" "$(idle_of)" \
      "$(if [ "$(state_of)" = running ] && stalled; then echo 1; else echo 0; fi)"
  done <<EOF
$(each_record)
EOF
  printf ']\n'
}

case "${1:-list}" in
  start)  shift; cmd_start "$@" ;;
  finish) shift; cmd_finish "$@" ;;
  prune)  shift; cmd_prune "$@" ;;
  line)   shift; cmd_line "$@" ;;
  json)   shift; cmd_json "$@" ;;
  list)   shift; cmd_list "$@" ;;
  -h|--help) sed -n '2,45p' "$0"; exit 0 ;;
  *) echo "runs.sh: unknown subcommand: $1 (list|line|json|start|finish|prune)" >&2; exit 64 ;;
esac

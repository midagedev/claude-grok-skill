#!/usr/bin/env bash
# Launch a raw grok CLI round with the same observability contract as
# outsource-run.sh: a registry entry while it runs, a `<log>.rc` sentinel
# when it exits, and a done-marker verdict inside that sentinel.
#
#   grok-run.sh --cwd <dir> --spec <file> --log <file.ndjson> \
#               [--label L] [--done-marker STRING] \
#               [--git-profile strict|readonly-plus|trusted] \
#               [--model grok-4.6] [--reasoning-effort xhigh] [--max-turns N]
#
# Field incident this closes (2026-08-17): two grok rounds were "launched"
# with a hand-assembled `nohup bash -c "... $(printf …) ..."` — the nested
# quoting broke, bash -c died on a syntax error, stderr went to /dev/null,
# and the sentinel write lived inside the same broken string, so nothing
# recorded that nothing had started. The lead read "launch command exited"
# as "round is running" and two watchers waited on files that would never
# exist. Meanwhile the status line was blind: raw grok rounds never
# registered in runs.sh at all, so the one tool built to answer "what is in
# flight" could not see them.
#
# Contract:
#   - Registers with runs.sh before grok starts, finishes it after — the
#     status line sees the round its whole life.
#   - Verifies grok actually started: the ndjson must exist and grow within
#     STARTUP_GRACE seconds, or this exits 69 and says so out loud.
#   - Writes `<log>.rc` on every path (including our own failures), with
#     rc / finished / harness=grok-cli / provider=xai / model / session /
#     done_marker=found|absent — the same keys the zai launcher writes, so
#     one watcher shape fits every backend.
#   - The done marker is looked for in the round's final report (via
#     last-report.sh), not anywhere in the stream — a marker quoted early in
#     planning must not count as completion.
#
# Foreground by design: run the whole invocation under nohup/& yourself,
# exactly one background layer, same as outsource-run.sh.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNS="$HERE/runs.sh"
LAST_REPORT="$HERE/last-report.sh"
STARTUP_GRACE="${GROK_RUN_STARTUP_GRACE:-30}"

CWD="" SPEC="" LOG="" LABEL="" MARKER="" PROFILE="strict"
MODEL="grok-4.6" EFFORT="xhigh" MAX_TURNS=1200
while [ $# -gt 0 ]; do
  case "$1" in
    --cwd)              CWD="$2"; shift 2 ;;
    --spec)             SPEC="$2"; shift 2 ;;
    --log)              LOG="$2"; shift 2 ;;
    --label)            LABEL="$2"; shift 2 ;;
    --done-marker)      MARKER="$2"; shift 2 ;;
    --git-profile)      PROFILE="$2"; shift 2 ;;
    --model)            MODEL="$2"; shift 2 ;;
    --reasoning-effort) EFFORT="$2"; shift 2 ;;
    --max-turns)        MAX_TURNS="$2"; shift 2 ;;
    *) echo "grok-run.sh: unknown flag: $1" >&2; exit 64 ;;
  esac
done
[ -n "$CWD" ] && [ -n "$SPEC" ] && [ -n "$LOG" ] || {
  echo "usage: grok-run.sh --cwd <dir> --spec <file> --log <file.ndjson> [...]" >&2; exit 64; }
[ -d "$CWD" ]  || { echo "grok-run.sh: no such cwd: $CWD" >&2; exit 66; }
[ -r "$SPEC" ] || { echo "grok-run.sh: unreadable spec: $SPEC" >&2; exit 66; }
command -v grok >/dev/null || { echo "grok-run.sh: grok CLI not on PATH" >&2; exit 69; }
[ -n "$LABEL" ] || LABEL="$(basename "${SPEC%.md}")"

# Git policy profiles, verbatim from references/grok.md — one owner is that
# file; this script is where the flags stop being copy-pasted into shells.
GIT_FLAGS=()
case "$PROFILE" in
  strict)
    for p in 'git commit*' 'git push*' 'git checkout*' 'git switch*' \
             'git stash*' 'git restore*' 'git add*' 'git rebase*' \
             'git reset*' 'git merge*' 'git cherry-pick*' 'git tag*' \
             'git worktree add*' 'git worktree remove*' 'git worktree prune*' \
             'gh pr create*' 'gh pr merge*' 'gh repo *'; do
      GIT_FLAGS+=(--deny "Bash($p)")
    done ;;
  readonly-plus) GIT_FLAGS+=(--deny 'Bash(git *)' --deny 'Bash(git)') ;;
  trusted) ;;
  *) echo "grok-run.sh: unknown --git-profile: $PROFILE (strict|readonly-plus|trusted)" >&2; exit 64 ;;
esac

SID="$(uuidgen | tr 'A-Z' 'a-z')"
RC_FILE="${LOG}.rc"
mkdir -p "$(dirname "$LOG")"
printf '%s\n' "$SID" > "${LOG%.ndjson}.sid" 2>/dev/null || true

write_sentinel() {  # <rc> <marker-verdict>
  {
    echo "rc=$1"
    echo "finished=$(date -u +%FT%TZ)"
    echo "harness=grok-cli"
    echo "provider=xai"
    echo "model_requested=$MODEL"
    echo "session=$SID"
    [ -n "$MARKER" ] && echo "done_marker=$2"
  } > "$RC_FILE"
}

RUN_ID="$("$RUNS" start --pid $$ --label "$LABEL" --provider xai --harness grok-cli \
          --model "$MODEL" --cwd "$CWD" --spec "$SPEC" --log "$LOG" 2>/dev/null)" || RUN_ID=""

# Launch grok as a child and prove it started before trusting it: the ndjson
# must exist and be non-empty within the grace window. "The launch command
# ran" is a lifecycle signal, not evidence — the incident above is why.
grok -s "$SID" --cwd "$CWD" \
  --prompt-file "$SPEC" \
  -m "$MODEL" --no-memory \
  --always-approve --permission-mode bypassPermissions \
  --reasoning-effort "$EFFORT" --max-turns "$MAX_TURNS" \
  --no-plan --no-subagents \
  --output-format streaming-json \
  "${GIT_FLAGS[@]+"${GIT_FLAGS[@]}"}" \
  > "$LOG" 2> "${LOG%.ndjson}.err" &
GROK_PID=$!

started=0
for _ in $(seq 1 "$STARTUP_GRACE"); do
  if [ -s "$LOG" ]; then started=1; break; fi
  kill -0 "$GROK_PID" 2>/dev/null || break
  sleep 1
done
if [ "$started" -ne 1 ] && ! kill -0 "$GROK_PID" 2>/dev/null; then
  wait "$GROK_PID"; rc=$?
  [ "$rc" -eq 0 ] && rc=69   # exited clean but wrote nothing: still not a round
  echo "grok-run.sh: grok never produced output (rc=$rc) — stderr follows:" >&2
  tail -5 "${LOG%.ndjson}.err" >&2 || true
  write_sentinel "$rc" absent
  [ -n "$RUN_ID" ] && "$RUNS" finish "$RUN_ID" --rc "$rc" --session "$SID" >/dev/null 2>&1
  exit "$rc"
fi

wait "$GROK_PID"; rc=$?

verdict="absent"
if [ -n "$MARKER" ] && [ -x "$LAST_REPORT" ]; then
  if "$LAST_REPORT" "$LOG" 2>/dev/null | grep -qF -- "$MARKER"; then verdict="found"; fi
  # A zero exit without the marker in the report is the lie the sentinel
  # exists to catch: downgrade it so no watcher reads rc=0 as delivered.
  if [ "$rc" -eq 0 ] && [ "$verdict" = "absent" ]; then rc=70; fi
fi
write_sentinel "$rc" "$verdict"
[ -n "$RUN_ID" ] && "$RUNS" finish "$RUN_ID" --rc "$rc" --session "$SID" >/dev/null 2>&1
exit "$rc"

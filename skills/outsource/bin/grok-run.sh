#!/usr/bin/env bash
# Launch a raw grok CLI round with the same observability contract as
# outsource-run.sh: a registry entry while it runs, a `<log>.rc` sentinel
# when it exits, and a done-marker verdict inside that sentinel.
#
#   grok-run.sh --cwd <dir> --spec <file> --log <file.ndjson> \
#               [--label L] [--done-marker STRING] \
#               [--git-profile strict|readonly-plus|trusted] [--research] \
#               [--model grok-4.6] [--reasoning-effort xhigh] [--max-turns N] \
#               [--resume <SID>] [-- <extra grok flags…>]
#
# --research adds the write-block belt for investigation/vision rounds
# (--deny Write --deny Edit --disallowed-tools write,search_replace — the
# set field-tested to produce zero tree changes across five runs; the
# --disallowed-tools half is the one doing the enforcing). Flags after `--`
# go to grok verbatim — that is where --json-schema for a vision verdict
# rides, instead of a reason to hand-assemble the whole launch again.
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
#     one watcher shape fits every backend. A clean exit without the marker
#     is exit 72 (not 70 — that is model-identity on the zai launcher).
#   - The done marker is looked for in the round's final report (via
#     last-report.sh), not anywhere in the stream — a marker quoted early in
#     planning must not count as completion. The sentinel records
#     done_marker_scope=report so that verdict is not silently the same
#     word as a whole-log grep on another launcher.
#   - --done-marker X is refused before grok is started when the spec does
#     not contain X (exit 64). The launcher never injects the string into
#     the prompt; the spec is the whole contract the delegate reads.
#
# Exit codes: 64 usage (unknown flag / git profile, missing required flags,
#             or --done-marker whose string is not in the spec)
#             66 no such cwd, or unreadable spec
#             69 grok CLI missing, or the process exited without writing
#             71 EXIT trap: no sentinel was written (script bug / set -u)
#             72 --done-marker set, clean exit, marker absent from the report
#              * the child's own rc otherwise
#
# Foreground by design: run the whole invocation under nohup/& yourself,
# exactly one background layer, same as outsource-run.sh. Foreground makes
# the wrapper the caller's to kill, so TERM/INT/HUP are held (signal-hold.sh):
# the child keeps running, the wrapper waits it out and still writes the
# sentinel, with a wrapper_signal= breadcrumb naming what it survived.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNS="$HERE/runs.sh"
LAST_REPORT="$HERE/last-report.sh"
. "$HERE/signal-hold.sh"
STARTUP_GRACE="${GROK_RUN_STARTUP_GRACE:-30}"

CWD="" SPEC="" LOG="" LABEL="" MARKER="" PROFILE="strict" RESEARCH=0 RESUME=""
MODEL="grok-4.6" EFFORT="xhigh" MAX_TURNS=1200
EXTRA=()
while [ $# -gt 0 ]; do
  case "$1" in
    --cwd)              CWD="$2"; shift 2 ;;
    --spec)             SPEC="$2"; shift 2 ;;
    --log)              LOG="$2"; shift 2 ;;
    --label)            LABEL="$2"; shift 2 ;;
    --done-marker)      MARKER="$2"; shift 2 ;;
    --git-profile)      PROFILE="$2"; shift 2 ;;
    --research)         RESEARCH=1; shift ;;
    --resume)           RESUME="$2"; shift 2 ;;
    --model)            MODEL="$2"; shift 2 ;;
    --reasoning-effort) EFFORT="$2"; shift 2 ;;
    --max-turns)        MAX_TURNS="$2"; shift 2 ;;
    --)                 shift; EXTRA=("$@"); break ;;
    *) echo "grok-run.sh: unknown flag: $1" >&2; exit 64 ;;
  esac
done
[ -n "$CWD" ] && [ -n "$SPEC" ] && [ -n "$LOG" ] || {
  echo "usage: grok-run.sh --cwd <dir> --spec <file> --log <file.ndjson> [...]" >&2; exit 64; }
[ -d "$CWD" ]  || { echo "grok-run.sh: no such cwd: $CWD" >&2; exit 66; }
[ -r "$SPEC" ] || { echo "grok-run.sh: unreadable spec: $SPEC" >&2; exit 66; }
# --done-marker is a contract the spec must be able to satisfy. Nothing
# injects the string into the prompt (the spec is the whole truth the
# delegate reads, and spec-lint would not see a hidden append). A lead
# who passes --done-marker X while the spec never contains X has stated
# something the delegate cannot know about — measured 2026-08-18: three
# delivered rounds, all reported absent. Refuse here, before contacting
# the provider and before registering a round.
# 64 is already usage on this launcher (unknown flag, missing required
# flags, bad git profile). 72 is a different fact: the round ran and the
# report lacks the marker. 73 would distinguish this from other usage
# errors, but watchers only split rc=0 / rc!=0, and a new code would
# collide with nothing we need to reserve. grep -qF matches the
# post-round check, so the two cannot disagree about "contains".
if [ -n "$MARKER" ] && ! grep -qF -- "$MARKER" "$SPEC"; then
  echo "grok-run.sh: --done-marker '$MARKER' does not appear in the spec ($SPEC). Add that exact string as the spec's last line (the completion marker), then relaunch." >&2
  exit 64
fi
command -v grok >/dev/null || { echo "grok-run.sh: grok CLI not on PATH" >&2; exit 69; }
[ -n "$LABEL" ] || LABEL="$(basename "${SPEC%.md}")"

# Git policy profiles. This script is the single owner of the flag strings;
# references/grok.md keeps the rationale (why the worktree denies are
# per-subcommand, why glob denies are a net and not a proof) and points here.
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
if [ "$RESEARCH" -eq 1 ]; then
  GIT_FLAGS+=(--deny Write --deny Edit --disallowed-tools write,search_replace)
  # A research round has no write tool, but a spec that asks for a report
  # *file* reads as writable work — measured 2026-08-17: the model looped
  # "writing the report" for 301 turns ($5.77) with nothing to write with.
  # The runner owns the contradiction: tell the model up front, in the spec
  # itself, that the final message is the only deliverable channel.
  # mktemp needs the Xs at the END of the template (macOS mktemp treats a
  # suffix after them as literal — first call "works" by creating that
  # literal name, every later call fails on File exists).
  RESEARCH_SPEC="$(mktemp "${TMPDIR:-/tmp}/grok-spec.XXXXXX")"
  {
    printf '> [runner notice — research mode] 이 라운드에는 파일 쓰기 도구가 없다.\n'
    printf '> 스펙이 산출물을 파일로 요구하더라도 파일은 만들 수 없으며, 모든 산출물은\n'
    printf '> **최종 메시지 본문**으로 제출하라. 쓰기 시도를 반복하지 말 것.\n\n'
    cat "$SPEC"
  } > "$RESEARCH_SPEC"
  SPEC="$RESEARCH_SPEC"
fi

# A session id is pinned once (-s) and only resumed afterwards (-r): grok
# rejects a second -s on a used id. --resume is for stop-then-revise — kill
# the round, then relaunch through here with the revised spec and the SID
# from the .sid file; completed tool results survive in the session.
if [ -n "$RESUME" ]; then
  SID="$RESUME"; SESSION_FLAG="-r"
else
  SID="$(uuidgen | tr 'A-Z' 'a-z')"; SESSION_FLAG="-s"
fi
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
    [ -n "$MARKER" ] && echo "done_marker_scope=report"
    [ -n "$WRAPPER_SIGNAL" ] && echo "wrapper_signal=$WRAPPER_SIGNAL"
  } > "$RC_FILE"
}

# Last resort for exits that never reach a write_sentinel call (a script bug,
# a set -u trip): an exit without a sentinel is the one outcome watchers
# cannot classify, so rc=71 names it. Does not run on SIGKILL.
trap '[ -f "$RC_FILE" ] || write_sentinel 71 absent' EXIT
hold_signals

RUN_ID="$("$RUNS" start --pid $$ --label "$LABEL" --provider xai --harness grok-cli \
          --model "$MODEL" --cwd "$CWD" --spec "$SPEC" --log "$LOG" 2>/dev/null)" || RUN_ID=""

# Launch grok as a child and prove it started before trusting it: the ndjson
# must exist and be non-empty within the grace window. "The launch command
# ran" is a lifecycle signal, not evidence — the incident above is why.
grok "$SESSION_FLAG" "$SID" --cwd "$CWD" \
  --prompt-file "$SPEC" \
  -m "$MODEL" --no-memory \
  --always-approve --permission-mode bypassPermissions \
  --reasoning-effort "$EFFORT" --max-turns "$MAX_TURNS" \
  --no-plan --no-subagents \
  --output-format streaming-json \
  "${GIT_FLAGS[@]+"${GIT_FLAGS[@]}"}" \
  "${EXTRA[@]+"${EXTRA[@]}"}" \
  > "$LOG" 2> "${LOG%.ndjson}.err" &
GROK_PID=$!

started=0
for _ in $(seq 1 "$STARTUP_GRACE"); do
  if [ -s "$LOG" ]; then started=1; break; fi
  kill -0 "$GROK_PID" 2>/dev/null || break
  sleep 1
done
if [ "$started" -ne 1 ] && ! kill -0 "$GROK_PID" 2>/dev/null; then
  await_child "$GROK_PID"; rc=$AWAIT_RC
  [ "$rc" -eq 0 ] && rc=69   # exited clean but wrote nothing: still not a round
  echo "grok-run.sh: grok never produced output (rc=$rc) — stderr follows:" >&2
  tail -5 "${LOG%.ndjson}.err" >&2 || true
  write_sentinel "$rc" absent
  [ -n "$RUN_ID" ] && "$RUNS" finish "$RUN_ID" --rc "$rc" --session "$SID" >/dev/null 2>&1
  exit "$rc"
fi

await_child "$GROK_PID"; rc=$AWAIT_RC

verdict="absent"
if [ -n "$MARKER" ] && [ -x "$LAST_REPORT" ]; then
  if "$LAST_REPORT" "$LOG" 2>/dev/null | grep -qF -- "$MARKER"; then verdict="found"; fi
  # A zero exit without the marker in the report is the lie the sentinel
  # exists to catch: downgrade it so no watcher reads rc=0 as delivered.
  # 72 is this case only — 70 is the zai launcher's model-identity failure.
  if [ "$rc" -eq 0 ] && [ "$verdict" = "absent" ]; then
    echo "grok-run.sh: the round finished but --done-marker '$MARKER' is absent; not claiming a pass (exit 72). Judge by the tree, not this exit code." >&2
    rc=72
  fi
fi
write_sentinel "$rc" "$verdict"
[ -n "$RUN_ID" ] && "$RUNS" finish "$RUN_ID" --rc "$rc" --session "$SID" >/dev/null 2>&1
exit "$rc"

#!/usr/bin/env bash
# Launch a delegated run on a third-party provider, on one of two harnesses.
# The provider is a table entry, not a hardcoded constant, and the launcher
# asserts which model actually answered before calling the round a success.
#
#   outsource-run.sh --cwd <dir> --spec <file> [--provider zai|xai]
#                    [--harness crush|claude-code] [--log <file>]
#                    [--session <id>] [--model <id>] [--config-dir <dir>]
#                    [--label <name>] [--allow-agent] [--no-vision-check]
#                    [--require-quota <N%>] [--max-seconds <N>]
#                    [--done-marker <string>]
#
# The model is the point; the harness is how it is driven headlessly:
#
#   claude-code (default) — `claude -p` against the provider's
#     Anthropic-compatible endpoint. Field-measured: ANTHROPIC_BASE_URL/
#     AUTH_TOKEN are honoured (an invalid token 401s), CLAUDE_CONFIG_DIR
#     isolates the run from the user's own Claude Code, and the git guard
#     attaches as a PreToolUse hook. ANTHROPIC_MODEL must be set — z.ai maps
#     an unqualified `claude-*` request onto the plan default (measured:
#     glm-4.7), so after the run the launcher asserts model identity from
#     the per-turn `message.model` in the session transcript (modelUsage in
#     the JSON log only echoes the requested id — measured 2026-08-16) and
#     fails the round (exit 70) when the model that answered is not the one
#     requested.
#   crush — the crush CLI with an isolated CRUSH_GLOBAL_CONFIG directory.
#     Its logs carry no model-identity field, so the assertion is skipped
#     there (reported, not fabricated).
#
# Either way the credential is read at launch time from the source named in
# the provider table; it is never written into a file we create and never
# reaches a log.
#
# Prints "SESSION <id>" on the last line so the caller can resume, and — when
# --log was given — writes the completion sentinel "<log>.rc" next to the log
# (rc/finished/harness/provider/model_requested/model_actual/session). The
# harness's own lifecycle is not completion proof; the sentinel is.
#
# Every launch also registers itself with bin/runs.sh, so a round is visible
# *while it runs* and not only once it reports: `runs.sh` lists which tracks
# are alive, on which provider and harness, and for how long. The sentinel
# answers "how did it end" for one round; the registry answers "what is
# happening right now" across all of them, including the rounds that died
# without ending (started, pid gone, no rc — `runs.sh` calls those orphans).
# --label is what the track is *for*, and parallel rounds are the reason it
# exists: three tracks that all read "spec" tell you nothing. Pass it. The
# derived default is a fallback, not a naming scheme — see default_label().
# Registry failures never fail a round: this is bookkeeping, not a gate.
#
# ---- on rounds that run long ------------------------------------------------
# Neither harness can stop itself: `crush run` exposes no turn or time limit
# at all, and this `claude` CLI exposes only --max-budget-usd, priced at
# Anthropic's rates and therefore wrong for every provider in the table
# above. Measured on ten delivered rounds, duration ran 13 minutes to 1h50m
# and tracked message count almost linearly (66 messages / 13m … 848
# messages / 1h50m).
#
# That measurement is the argument AGAINST a time limit, not for one: those
# rounds were long because there was a lot of work, and cutting one at an
# hour truncates a working delegate mid-edit for no reason. The default
# posture here is therefore never to interrupt. What the launcher does
# instead is record where the round leaves a live trail, so `runs.sh` can
# distinguish "still writing" from "silent for ten minutes" — a stall is
# visible without anything being killed.
#
# --max-seconds N remains available as an explicit escape hatch, for rounds
# whose loss is acceptable up front: at N seconds the harness's process
# group gets SIGTERM, then SIGKILL ten seconds later, and the round finishes
# as rc 124 (the `timeout(1)` convention) in both the sentinel and the run
# registry. It has no default and should not be given one — the kill lands
# mid-edit and the partial tree is the lead's to review.
#
# Exit codes: 64 usage (unknown flag/provider/harness, bare --model on crush)
#             65 vision-spec refusal (provider cannot see images)
#             66 --require-quota floor missed, or not evaluable
#             69 harness CLI missing
#             70 model-identity assertion failed (mismatch or unverifiable)
#            124 --max-seconds ceiling hit; the harness was killed
#              1 missing credential
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CWD=""; SPEC=""; LOG=""; SESSION=""; CONFIG_DIR=""; ALLOW_AGENT=0; NO_VISION_CHECK=0
REQUIRE_QUOTA=""; LABEL=""; MAX_SECONDS=""; DONE_MARKER=""
HARNESS="${OUTSOURCE_HARNESS:-claude-code}"
PROVIDER="${OUTSOURCE_PROVIDER:-zai}"
MODEL="${GLM_DELEGATE_MODEL:-}"
USER_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/crush/crush.json"
ZAI_ANTHROPIC_BASE="${ZAI_ANTHROPIC_BASE:-}"

while [ $# -gt 0 ]; do
  case "$1" in
    --cwd) CWD="$2"; shift 2 ;;
    --spec) SPEC="$2"; shift 2 ;;
    --log) LOG="$2"; shift 2 ;;
    --session) SESSION="$2"; shift 2 ;;
    --model) MODEL="$2"; shift 2 ;;
    --harness) HARNESS="$2"; shift 2 ;;
    --provider) PROVIDER="$2"; shift 2 ;;
    --config-dir) CONFIG_DIR="$2"; shift 2 ;;
    --label) LABEL="$2"; shift 2 ;;
    --done-marker) DONE_MARKER="$2"; shift 2 ;;
    --allow-agent) ALLOW_AGENT=1; shift ;;
    --no-vision-check) NO_VISION_CHECK=1; shift ;;
    --require-quota) REQUIRE_QUOTA="$2"; shift 2 ;;
    --max-seconds) MAX_SECONDS="$2"; shift 2 ;;
    *) echo "unknown flag: $1" >&2; exit 64 ;;
  esac
done

[ -n "$CWD" ]  || { echo "--cwd is required" >&2; exit 64; }
[ -d "$CWD" ]  || { echo "--cwd does not exist: $CWD" >&2; exit 64; }
[ -n "$SPEC" ] || { echo "--spec is required" >&2; exit 64; }
[ -f "$SPEC" ] || { echo "--spec does not exist: $SPEC" >&2; exit 64; }

# ---- provider table (the one place a provider is defined; both harnesses
# read it). One line per provider:
#   name | Anthropic-compatible base URL | default model (bare id; the crush
#   harness qualifies it to <name>/<model>) | vision
# Credentials are NOT in this table: bin/credential.sh is their single owner
# (env var first, then this skill's own 0600 store, then discovery of files
# another tool already wrote). Adding a provider here means adding its
# resolution there too — one place, not two.
# The URL here is the provider's *default*; credential.sh --base-url may point
# it at the same account's other region (z.ai's coding plan ships on api.z.ai
# globally and open.bigmodel.cn in mainland China).
# The base-URL column is consumed by the claude-code harness (ANTHROPIC_BASE_
# URL); the crush harness resolves endpoints through crush's own provider
# registry — measured: crush's built-in zai points at
# https://api.z.ai/api/coding/paas/v4, not the Anthropic-compatible URL, so
# forcing this column into `provider add` would break the working zai path.
PROVIDER_TABLE='zai|https://api.z.ai/api/anthropic|glm-5.3|no
xai|https://api.x.ai|grok-4.6|yes'
T_URL=2 T_MODEL=3 T_VISION=4
CREDENTIAL_SH="$SKILL_DIR/bin/credential.sh"

provider_names() { printf '%s\n' "$PROVIDER_TABLE" | cut -d'|' -f1; }

provider_field() {  # <name> <column> -> value on stdout; empty when unknown
  printf '%s\n' "$PROVIDER_TABLE" | awk -F'|' -v p="$1" -v c="$2" '$1 == p { print $c; exit }'
}

[ -n "$(provider_field "$PROVIDER" "$T_URL")" ] || {
  echo "unknown provider: $PROVIDER (known: $(provider_names | tr '\n' ' '))" >&2; exit 64; }

# Validated here, not only at the dispatch below, so a usage error is caught
# before the run registry records a round that was never going to launch.
# The dispatch keeps its own arm as unreachable defence.
case "$HARNESS" in
  claude-code|crush) ;;
  *) echo "--harness must be claude-code or crush, got: $HARNESS" >&2; exit 64 ;;
esac

CONFIG_DIR="${CONFIG_DIR:-${TMPDIR:-/tmp}/outsource-glm-cfg}"
mkdir -p "$CONFIG_DIR"

# C5: vision-spec guard. The capability comes from the table — never a
# provider-name test at the call site. vision must be an explicit "yes" to
# launch a spec that references an image file; an empty cell means "cannot".
if [ "$NO_VISION_CHECK" -eq 0 ] && [ "$(provider_field "$PROVIDER" "$T_VISION")" != yes ] \
   && grep -qiE -- '\.(png|jpe?g|webp|gif)([^[:alnum:]]|$)' "$SPEC"; then
  echo "outsource: spec $SPEC references an image file, but provider '$PROVIDER' cannot see images (vision=$(provider_field "$PROVIDER" "$T_VISION") in the provider table); vision work belongs to the grok backend (references/grok.md). Re-run with --no-vision-check to override." >&2
  exit 65
fi

# ---- plan quota (pre-flight only) ------------------------------------------
# bin/quota.sh reads the provider's own plan API. It is used here for one
# thing: refusing to start a round the plan cannot finish. It is deliberately
# NOT used to price a round. Plan quota is a plan-wide counter — concurrent
# rounds and other sessions move it too — so a before/after delta around one
# round measures the machine, not the round. The per-round figure that IS
# attributable is the token count in the log's `usage`.
QUOTA_SH="$SKILL_DIR/bin/quota.sh"

if [ -n "$REQUIRE_QUOTA" ]; then
  [ -x "$QUOTA_SH" ] || { echo "outsource: --require-quota needs $QUOTA_SH to be present and executable" >&2; exit 64; }
  set +e
  "$QUOTA_SH" --provider "$PROVIDER" --quiet --require-window "$REQUIRE_QUOTA"
  QUOTA_RC=$?
  set -e
  case "$QUOTA_RC" in
  0) ;;
  3) echo "outsource: refusing to launch — provider '$PROVIDER' is below the --require-quota $REQUIRE_QUOTA% floor (reason above). Wait for the reset or run this track on another provider." >&2
     exit 66 ;;
  # quota.sh knows a different provider set: it reads *plan* quotas, so it
  # covers the subscription backends (zai, grok) and not the pay-per-token
  # api-key ones (xai), which have no plan window to be below.
  64) echo "outsource: --require-quota is not available for provider '$PROVIDER' — bin/quota.sh reads plan quotas and this provider bills per token. Drop the flag for this track." >&2
     exit 66 ;;
  # Fail closed: a gate that cannot be evaluated is not a gate that passed.
  *) echo "outsource: refusing to launch — --require-quota could not be evaluated (quota.sh exit $QUOTA_RC, reason above)" >&2
     exit 66 ;;
  esac
fi

if [ -n "$MAX_SECONDS" ] && ! [[ "$MAX_SECONDS" =~ ^[1-9][0-9]*$ ]]; then
  echo "--max-seconds wants a positive whole number of seconds, got: $MAX_SECONDS" >&2; exit 64
fi

SID=""
MODEL_ACTUAL=""

# ---- wall-clock watchdog ---------------------------------------------------
# `timeout(1)` is GNU coreutils and absent from a stock macOS, so the ceiling
# is built here. Two details make it actually stop a harness:
#
#   * `set -m` before backgrounding puts the harness in its own process
#     group, so the signal can be sent to the group (`kill -- -PGID`). The
#     harnesses spawn children — a TERM to the shell alone leaves the model
#     CLI running and the round only *looks* stopped.
#   * The watchdog reports through a file, not a variable: it runs in a
#     subshell and cannot assign to this one, and "the harness exited 143"
#     must be distinguishable from "we killed it".
TIMED_OUT_FLAG=""
WATCHDOG_PID=""

watchdog_start() {  # <pid of the backgrounded harness>
  [ -n "$MAX_SECONDS" ] || return 0
  TIMED_OUT_FLAG="$CONFIG_DIR/.timed-out.$$"
  rm -f "$TIMED_OUT_FLAG"
  local pid="$1"
  (
    sleep "$MAX_SECONDS"
    kill -0 "$pid" 2>/dev/null || exit 0
    : > "$TIMED_OUT_FLAG"
    kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null
    sleep 10
    kill -0 "$pid" 2>/dev/null || exit 0
    kill -KILL -- "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null
  ) &
  WATCHDOG_PID=$!
}

watchdog_stop() {  # returns 0 when the ceiling fired
  [ -n "$WATCHDOG_PID" ] && { kill "$WATCHDOG_PID" 2>/dev/null; wait "$WATCHDOG_PID" 2>/dev/null; }
  WATCHDOG_PID=""
  [ -n "$TIMED_OUT_FLAG" ] && [ -f "$TIMED_OUT_FLAG" ] && { rm -f "$TIMED_OUT_FLAG"; return 0; }
  return 1
}

timed_out_note() {  # one message, both harnesses
  echo "outsource: --max-seconds $MAX_SECONDS reached; the $HARNESS harness was killed mid-round (exit 124). Whatever it had already written to $CWD is still there — review the tree, and treat the round as unfinished." >&2
}

# ---- run registry ----------------------------------------------------------
# bin/runs.sh owns the record format; this file only says "a round started"
# and "it ended with rc". Bookkeeping must never be able to fail a round, so
# every call here is best-effort.
RUNS_SH="$SKILL_DIR/bin/runs.sh"
RUN_ID=""

runs_note_finish() {  # <rc> — idempotent; the EXIT trap and finish() both call it
  [ -n "$RUN_ID" ] || return 0
  local id="$RUN_ID"
  RUN_ID=""
  "$RUNS_SH" finish "$id" --rc "$1" --session "$SID" --model-actual "$MODEL_ACTUAL" \
    >/dev/null 2>&1 || true
}

finish() {  # <exit-code> — sentinel + SESSION line + exit, both harnesses
  runs_note_finish "$1"
  if [ -n "$LOG" ]; then
    # rc is a *lifecycle* signal: the harness exited cleanly. It says nothing
    # about whether the round did its job. Both halves of that gap have been
    # measured on the same day (2026-08-16): one round exited rc=0 having
    # written no code at all, and another exited rc=0 with no edits because the
    # spec's own precondition check told it to stop — the first is a failure,
    # the second is correct, and rc cannot tell them apart. When the lead names
    # the spec's completion marker with --done-marker, record whether the
    # transcript actually carries it, so the difference is one file read away
    # instead of a transcript hunt.
    marker_line=""
    if [ -n "$DONE_MARKER" ]; then
      if [ -s "$LOG" ] && grep -qF -- "$DONE_MARKER" "$LOG" 2>/dev/null; then
        marker_line="done_marker=found"
      else
        marker_line="done_marker=absent"
      fi
      marker_line="$marker_line ($DONE_MARKER)"$'\n'
    fi
    if ! printf 'rc=%s\nfinished=%s\nharness=%s\nprovider=%s\nmodel_requested=%s\nmodel_actual=%s\nsession=%s\n%s' \
        "$1" "$(date -u +%FT%TZ)" "$HARNESS" "$PROVIDER" "$MODEL" "$MODEL_ACTUAL" "$SID" "$marker_line" \
        > "$LOG.rc"; then
      echo "outsource: warning: could not write sentinel $LOG.rc" >&2
    fi
  fi
  echo "SESSION ${SID:-unknown}"
  exit "$1"
}

# Register once the round is actually going to be attempted — after the
# vision and quota guards, before the harness is dispatched. A guard that
# refuses to launch has not started a round, and recording one would make the
# registry lie about what is running.
# The EXIT trap covers the paths finish() does not: a missing CLI, a killed
# launcher, an unexpected error under `set -e`. Without it those rounds would
# sit in the registry as "running" forever.

# What to call this track when --label was not given. The spec's basename is
# the obvious guess and the wrong one on its own: this skill's own documented
# invocation writes every track's spec to `$SP/spec.md`, one scratch dir per
# track, so three parallel rounds would all register as "spec" — the exact
# case the label is for. A generic basename therefore defers to the directory
# holding it, which is where the track name actually lives.
default_label() {
  local base parent
  base="$(basename -- "${SPEC%.*}")"
  case "$base" in
    spec|task|prompt|input|round|delegate)
      parent="$(basename -- "$(dirname -- "$SPEC")")"
      case "$parent" in
        ''|.|/|tmp|temp|scratch|sp|specs) ;;   # no more specific than the basename
        *) base="$parent" ;;
      esac ;;
  esac
  printf '%s' "$base"
}

# Where this round leaves a live trail, so `runs.sh` can tell a round that is
# working from one that is stuck without ever interrupting either. Both
# harnesses write continuously into their own data directory — crush into
# `crush.db-wal` and `logs/crush.log` every few seconds, the claude-code
# harness into `projects/**.jsonl` every turn. Neither path is the `--log`
# file: the claude-code harness writes that only once, at the end, so a
# perfectly healthy round shows an empty log for its entire life.
# Both are derived from CONFIG_DIR, which is already fixed at this point.
case "$HARNESS" in
  claude-code) PROGRESS_DIR="$CONFIG_DIR/claude/projects" ;;
  crush)       PROGRESS_DIR="$CONFIG_DIR/data" ;;
  *)           PROGRESS_DIR="" ;;
esac

trap 'runs_note_finish "$?"' EXIT
RUN_ID="$("$RUNS_SH" start \
  --pid "$$" \
  --label "${LABEL:-$(default_label)}" \
  --provider "$PROVIDER" \
  --harness "$HARNESS" \
  --model "${MODEL:-$(provider_field "$PROVIDER" "$T_MODEL")}" \
  --cwd "$CWD" --spec "$SPEC" --log "$LOG" \
  --progress-dir "$PROGRESS_DIR" 2>/dev/null)" || RUN_ID=""

case "$HARNESS" in
claude-code)
  command -v claude >/dev/null 2>&1 || { echo "harness claude-code needs the 'claude' CLI on PATH" >&2; exit 69; }
  MODEL="${MODEL:-$(provider_field "$PROVIDER" "$T_MODEL")}"

  # Credential from the table's source; zai keeps the original lookup path.
  # One owner for credentials; its message already names every place it
  # tried and how to set the key, so pass it straight through.
  KEY="$("$CREDENTIAL_SH" "$PROVIDER")" || exit 1

  # An isolated CLAUDE_CONFIG_DIR keeps the user's own Claude Code untouched
  # and gives this track its own settings/session store.
  CC_HOME="$CONFIG_DIR/claude"
  mkdir -p "$CC_HOME"
  # Same guard as the crush harness, attached the way this harness wants it:
  # the hook receives the tool call as JSON on stdin (git-guard reads both).
  python3 - "$CC_HOME/settings.json" "$SKILL_DIR/bin/git-guard.sh" <<'PY'
import json, sys
path, guard = sys.argv[1], sys.argv[2]
json.dump({
    "hooks": {
        "PreToolUse": [
            {"matcher": "Bash", "hooks": [{"type": "command", "command": guard, "timeout": 10}]}
        ]
    }
}, open(path, "w"), indent=2)
PY

  # The env prefix cannot decorate a subshell, so export into this branch
  # only; the vars die with the launcher process.
  # The table declares the provider's default; credential.sh may point it at
  # the same account's other region (the z.ai coding plan ships on api.z.ai
  # globally and open.bigmodel.cn in mainland China, and the vendor's own
  # installer records which one you bought).
  BASE_URL="$("$CREDENTIAL_SH" "$PROVIDER" --base-url "$(provider_field "$PROVIDER" "$T_URL")")"
  if [ "$PROVIDER" = zai ] && [ -n "$ZAI_ANTHROPIC_BASE" ]; then
    BASE_URL="$ZAI_ANTHROPIC_BASE"  # back-compat env override, zai only
  fi
  export ANTHROPIC_BASE_URL="$BASE_URL"
  export ANTHROPIC_AUTH_TOKEN="$KEY"
  export ANTHROPIC_MODEL="$MODEL"
  export CLAUDE_CONFIG_DIR="$CC_HOME"

  # Keep stderr out of the log: this harness prints diagnostics there (e.g.
  # `[claude-code:unrecognized_model]` for a non-Anthropic model id), and one
  # such line ahead of the JSON makes the whole log unparseable.
  ERRLOG="${LOG:+$LOG.err}"
  set +e
  set -m   # own process group, so the watchdog can signal the whole tree
  if [ -n "$SESSION" ]; then
    (cd "$CWD" && claude -p --resume "$SESSION" --permission-mode bypassPermissions \
      --output-format json) < "$SPEC" > "${LOG:-/dev/stdout}" 2> "${ERRLOG:-/dev/stderr}" &
  else
    (cd "$CWD" && claude -p --permission-mode bypassPermissions \
      --output-format json) < "$SPEC" > "${LOG:-/dev/stdout}" 2> "${ERRLOG:-/dev/stderr}" &
  fi
  HARNESS_PID=$!
  set +m
  watchdog_start "$HARNESS_PID"
  wait "$HARNESS_PID"
  RC_EXIT=$?
  if watchdog_stop; then
    # A killed round has a truncated log, so the model-identity assertion
    # would fail on it and report a mismatch that never happened. The
    # ceiling is the finding here; say so and stop.
    timed_out_note
    set -e
    finish 124
  fi
  set -e

  # One read-only pass over the JSON log and the session transcript: session
  # id, real token counts, Anthropic-priced cost, and the model-identity
  # verdict. Never writes back.
  # Measured 2026-08-16: `modelUsage` in the log echoes the REQUESTED id — a
  # run that requested claude-opus-5 and was answered by glm-4.7 still logged
  # modelUsage {"claude-opus-5": …}. The model that actually answered is the
  # per-turn `message.model` in the session transcript (isolated config dir,
  # located by session id), so that is the primary evidence; modelUsage keys
  # are only a labelled fallback when no transcript can be found.
  ANALYSIS="$(python3 - "$LOG" "$MODEL" "$CC_HOME" 2>/dev/null <<'PY' || true
import glob, json, os, sys
out = {"session": "", "usage": "", "cost": "", "actual": "", "assert": "nolog", "source": ""}
logpath, req, cchome = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    with open(logpath) as f:
        d = json.load(f)
    if not isinstance(d, dict):
        raise ValueError("log root is not a JSON object")
except Exception:
    out["assert"] = "unreadable"
    print("assert\tunreadable")
    sys.exit(0)
out["session"] = str(d.get("session_id") or "")
u = d.get("usage")
if isinstance(u, dict):
    out["usage"] = " ".join(f"{k}={v}" for k, v in sorted(u.items()))
cost = d.get("total_cost_usd")
out["cost"] = "" if cost is None else str(cost)

def uniq(seq):
    seen, keep = set(), []
    for x in seq:
        if x not in seen:
            seen.add(x); keep.append(x)
    return keep

answered = []
sid = out["session"]
if sid:
    hits = glob.glob(os.path.join(cchome, "projects", "**", sid + ".jsonl"), recursive=True)
    if hits:
        for line in open(hits[0]):
            try:
                o = json.loads(line)
            except Exception:
                continue
            if isinstance(o, dict) and o.get("type") == "assistant":
                m = (o.get("message") or {}).get("model")
                if m:
                    answered.append(str(m))
        out["source"] = "transcript " + hits[0]
from_transcript = bool(answered)
if not answered:
    mu = d.get("modelUsage")
    if isinstance(mu, dict) and mu:
        answered = [str(k) for k in mu.keys()]
        out["source"] = "modelUsage (request-side; no transcript found)"
if not answered:
    out["assert"] = "absent"
else:
    models = uniq(answered)
    out["actual"] = ",".join(models)
    # every answering model must be the requested id or an annotated variant
    # of it (e.g. claude-opus-5[1m]) — a partial match is still a remap
    matched = all(m == req or m.startswith(req) for m in models)
    if matched and not from_transcript:
        # modelUsage echoes the REQUESTED id, so a match there proves
        # nothing — it is exactly what a silently remapped run also
        # produces. Only the transcript can clear the round; a modelUsage
        # match is "unverifiable", never a pass. (A *mismatch* there is
        # still real evidence and is reported as one.)
        out["assert"] = "unverifiable"
    else:
        out["assert"] = "ok" if matched else "mismatch"
for k in ("session", "usage", "cost", "actual", "assert", "source"):
    print(f"{k}\t{out[k]}")
PY
)"
  A_SESSION=""; A_USAGE=""; A_COST=""; A_ACTUAL=""; A_ASSERT=""; A_SOURCE=""
  while IFS=$'\t' read -r k v; do
    case "$k" in
      session) A_SESSION="$v" ;;
      usage) A_USAGE="$v" ;;
      cost) A_COST="$v" ;;
      actual) A_ACTUAL="$v" ;;
      assert) A_ASSERT="$v" ;;
      source) A_SOURCE="$v" ;;
    esac
  done <<EOF
$ANALYSIS
EOF
  SID="$A_SESSION"
  TRANSCRIPT_NOTE="$A_SOURCE"

  # Cost honesty. The token counts in `usage` are this round's and are the
  # only per-round figure worth quoting; `total_cost_usd` is Claude Code's
  # Anthropic-priced estimate, not what the provider charges. Plan credits
  # are deliberately absent here — they are plan-wide, not per-round.
  if [ "$A_ASSERT" != "nolog" ] && [ "$A_ASSERT" != "unreadable" ]; then
    echo "outsource: usage ${A_USAGE:-absent}; total_cost_usd=${A_COST:-absent} is Claude Code's Anthropic-priced estimate, not what provider '$PROVIDER' charges" >&2
  fi

  # C2: model-identity assertion. A round that silently ran the wrong model
  # is a failed round — exit 70 even when the run itself succeeded.
  ASSERT_CODE=0
  if [ "$RC_EXIT" -ne 0 ]; then
    echo "outsource: run failed (rc=$RC_EXIT); model-identity assertion skipped" >&2
  elif [ -z "$LOG" ]; then
    echo "outsource: no --log given; model-identity assertion skipped (nothing to verify against)" >&2
  else
    case "$A_ASSERT" in
    ok) ;;
    mismatch)
      echo "outsource: MODEL MISMATCH — requested '$MODEL' but the run was answered by: ${A_ACTUAL:-unknown} (evidence: ${TRANSCRIPT_NOTE:-none}); failing the round (exit 70)" >&2
      ASSERT_CODE=70 ;;
    unverifiable)
      echo "outsource: MODEL ASSERTION FAILED — no session transcript for session '${A_SESSION:-unknown}', and modelUsage only echoes the requested id, so it cannot prove '$MODEL' actually answered; not claiming a pass (exit 70)" >&2
      ASSERT_CODE=70 ;;
    absent|unreadable|*)
      echo "outsource: MODEL ASSERTION FAILED — no model-identity evidence in $LOG (modelUsage absent/unparseable and no session transcript); cannot verify that '$MODEL' answered, so not claiming a pass (exit 70)" >&2
      ASSERT_CODE=70 ;;
    esac
    MODEL_ACTUAL="$A_ACTUAL"
  fi

  if [ "$RC_EXIT" -ne 0 ]; then
    finish "$RC_EXIT"
  fi
  finish "$ASSERT_CODE"
  ;;

crush)
  command -v crush >/dev/null 2>&1 || { echo "harness crush needs the 'crush' CLI on PATH" >&2; exit 69; }
  MODEL="${MODEL:-$PROVIDER/$(provider_field "$PROVIDER" "$T_MODEL")}"

  # crush's data_directory defaults to `.crush` *relative to the working
  # directory*, so an unqualified run drops a multi-MB session DB into the tree
  # it is editing. Keep it in scratch: the target repo stays clean and
  # `crush session list` becomes scoped to this track (it is keyed by data dir,
  # not by --cwd), which is what makes resume reliable.
  DATA_DIR="$CONFIG_DIR/data"
  mkdir -p "$DATA_DIR"

  MPREFIX="${MODEL%%/*}"
  if [ "$MPREFIX" = "$MODEL" ]; then
    echo "--model must be provider/id for the crush harness, got: $MODEL" >&2; exit 64;
  fi
  [ "$MPREFIX" = "$PROVIDER" ] || {
    echo "--model $MODEL does not match --provider $PROVIDER" >&2; exit 64; }

  # The isolated config replaces the user's global one, so the provider (and its
  # key) has to be re-declared. The key is resolved inside the crushrc at load
  # time from the source the provider table names — config: reads the user's
  # crush config, env: reads the variable — so the secret never transits a file
  # we write and never reaches a log.
  cat > "$CONFIG_DIR/crushrc" <<RC
#!/usr/bin/env bash
set -euo pipefail

RC
  # The crushrc resolves the key at load time through the same single owner,
  # so the secret never transits a file we write and never reaches a log.
  cat >> "$CONFIG_DIR/crushrc" <<RC
_key="\$("$CREDENTIAL_SH" "$PROVIDER")" || exit 1
RC
  cat >> "$CONFIG_DIR/crushrc" <<RC
provider add "$PROVIDER" --api-key "\$_key"

# xhigh is this model's own default_reasoning_effort (providers.json), and the
# crushrc flag validates against low|medium|high — so the slot is set without
# --reasoning-effort and the provider default carries it.
model large "$MODEL"

# = grok --always-approve. Denied tools are hidden entirely, so bash stays
# allowed here and the git ban lives in the PreToolUse hook instead.
permissions allow bash view ls grep glob edit write multiedit fetch download diagnostics sourcegraph
RC

  if [ "$ALLOW_AGENT" -eq 0 ]; then
    # Hooks fire only on the top-level agent's tool calls, so a sub-agent's
    # bash would bypass the git guard.
    cat >> "$CONFIG_DIR/crushrc" <<'RC'
permissions deny agent task
RC
  fi

  cat >> "$CONFIG_DIR/crushrc" <<RC

hook add PreToolUse --matcher "^bash\$" --command "$SKILL_DIR/bin/git-guard.sh" --name git-guard --timeout 10
option progress false
RC

  set +e
  set -m   # own process group, so the watchdog can signal the whole tree
  if [ -n "$SESSION" ]; then
    CRUSH_GLOBAL_CONFIG="$CONFIG_DIR" crush run -q -c "$CWD" -D "$DATA_DIR" -s "$SESSION" < "$SPEC" \
      > "${LOG:-/dev/stdout}" 2>&1 &
  else
    CRUSH_GLOBAL_CONFIG="$CONFIG_DIR" crush run -q -c "$CWD" -D "$DATA_DIR" < "$SPEC" \
      > "${LOG:-/dev/stdout}" 2>&1 &
  fi
  HARNESS_PID=$!
  set +m
  watchdog_start "$HARNESS_PID"
  wait "$HARNESS_PID"
  RC_EXIT=$?
  if watchdog_stop; then
    timed_out_note
    # The session id is still worth recovering: crush wrote it, and it is
    # what a follow-up round would resume from.
    SID="$(CRUSH_GLOBAL_CONFIG="$CONFIG_DIR" crush session last --json -c "$CWD" -D "$DATA_DIR" 2>/dev/null \
           | python3 -c 'import json,sys; d=json.load(sys.stdin); print((d.get("meta") or d).get("id",""))' 2>/dev/null || true)"
    set -e
    finish 124
  fi
  set -e

  # crush logs carry no model-identity field (no modelUsage equivalent), so
  # the assertion is skipped here — reported, never fabricated.
  echo "outsource: crush harness — model-identity assertion skipped (no modelUsage equivalent in crush logs)" >&2

  SID="$(CRUSH_GLOBAL_CONFIG="$CONFIG_DIR" crush session last --json -c "$CWD" -D "$DATA_DIR" 2>/dev/null \
         | python3 -c 'import json,sys; d=json.load(sys.stdin); print((d.get("meta") or d).get("id",""))' 2>/dev/null || true)"
  finish "$RC_EXIT"
  ;;

*)
  echo "--harness must be claude-code or crush, got: $HARNESS" >&2; exit 64 ;;
esac

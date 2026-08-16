#!/usr/bin/env bash
# Launch a delegated run on a third-party provider, on one of two harnesses.
# The provider is a table entry, not a hardcoded constant, and the launcher
# asserts which model actually answered before calling the round a success.
#
#   outsource-run.sh --cwd <dir> --spec <file> [--provider zai|xai]
#                    [--harness crush|claude-code] [--log <file>]
#                    [--session <id>] [--model <id>] [--config-dir <dir>]
#                    [--allow-agent] [--no-vision-check]
#                    [--require-quota <N%>]
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
# Exit codes: 64 usage (unknown flag/provider/harness, bare --model on crush)
#             65 vision-spec refusal (provider cannot see images)
#             66 --require-quota floor missed, or not evaluable
#             69 harness CLI missing
#             70 model-identity assertion failed (mismatch or unverifiable)
#              1 missing credential
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CWD=""; SPEC=""; LOG=""; SESSION=""; CONFIG_DIR=""; ALLOW_AGENT=0; NO_VISION_CHECK=0
REQUIRE_QUOTA=""
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
    --allow-agent) ALLOW_AGENT=1; shift ;;
    --no-vision-check) NO_VISION_CHECK=1; shift ;;
    --require-quota) REQUIRE_QUOTA="$2"; shift 2 ;;
    *) echo "unknown flag: $1" >&2; exit 64 ;;
  esac
done

[ -n "$CWD" ]  || { echo "--cwd is required" >&2; exit 64; }
[ -d "$CWD" ]  || { echo "--cwd does not exist: $CWD" >&2; exit 64; }
[ -n "$SPEC" ] || { echo "--spec is required" >&2; exit 64; }
[ -f "$SPEC" ] || { echo "--spec does not exist: $SPEC" >&2; exit 64; }

# ---- provider table (the one place a provider is defined; both harnesses
# read it). One line per provider:
#   name | Anthropic-compatible base URL | credential source | default model
#   (bare id; the crush harness qualifies it to <name>/<model>) | vision
# Credentials are NOT in this table: bin/credential.sh is their single owner
# (env var first, then this skill's own 0600 store, then discovery of files
# another tool already wrote). Adding a provider here means adding its
# resolution there too — one place, not two.
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

SID=""
MODEL_ACTUAL=""

finish() {  # <exit-code> — sentinel + SESSION line + exit, both harnesses
  if [ -n "$LOG" ]; then
    if ! printf 'rc=%s\nfinished=%s\nharness=%s\nprovider=%s\nmodel_requested=%s\nmodel_actual=%s\nsession=%s\n' \
        "$1" "$(date -u +%FT%TZ)" "$HARNESS" "$PROVIDER" "$MODEL" "$MODEL_ACTUAL" "$SID" \
        > "$LOG.rc"; then
      echo "outsource: warning: could not write sentinel $LOG.rc" >&2
    fi
  fi
  echo "SESSION ${SID:-unknown}"
  exit "$1"
}

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
  BASE_URL="$(provider_field "$PROVIDER" "$T_URL")"
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
  if [ -n "$SESSION" ]; then
    (cd "$CWD" && claude -p --resume "$SESSION" --permission-mode bypassPermissions \
      --output-format json) < "$SPEC" > "${LOG:-/dev/stdout}" 2> "${ERRLOG:-/dev/stderr}"
  else
    (cd "$CWD" && claude -p --permission-mode bypassPermissions \
      --output-format json) < "$SPEC" > "${LOG:-/dev/stdout}" 2> "${ERRLOG:-/dev/stderr}"
  fi
  RC_EXIT=$?
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
  if [ -n "$SESSION" ]; then
    CRUSH_GLOBAL_CONFIG="$CONFIG_DIR" crush run -q -c "$CWD" -D "$DATA_DIR" -s "$SESSION" < "$SPEC" \
      > "${LOG:-/dev/stdout}" 2>&1
  else
    CRUSH_GLOBAL_CONFIG="$CONFIG_DIR" crush run -q -c "$CWD" -D "$DATA_DIR" < "$SPEC" \
      > "${LOG:-/dev/stdout}" 2>&1
  fi
  RC_EXIT=$?
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

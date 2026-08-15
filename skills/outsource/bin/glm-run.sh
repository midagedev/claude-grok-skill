#!/usr/bin/env bash
# Launch a delegated GLM run (z.ai coding plan) on one of two harnesses.
#
#   glm-run.sh --cwd <dir> --spec <file> [--harness crush|claude-code]
#              [--log <file>] [--session <id>] [--model <id>]
#              [--config-dir <dir>] [--allow-agent]
#
# The model is the point; the harness is how it is driven headlessly:
#
#   claude-code (default) — `claude -p` against z.ai's Anthropic-compatible
#     endpoint. Field-measured: ANTHROPIC_BASE_URL/AUTH_TOKEN are honoured
#     (an invalid token 401s), CLAUDE_CONFIG_DIR isolates the run from the
#     user's own Claude Code, and the git guard attaches as a PreToolUse
#     hook. **ANTHROPIC_MODEL must be set** — z.ai maps an unqualified
#     `claude-*` request onto the plan default (measured: glm-4.7), so the
#     model you think you asked for is not the one you get.
#   crush — the crush CLI with an isolated CRUSH_GLOBAL_CONFIG directory.
#
# Either way the API key is read from the user's crush config at launch time;
# it is never written into a file we create and never reaches a log.
#
# Prints "SESSION <id>" on the last line so the caller can resume.
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CWD=""; SPEC=""; LOG=""; SESSION=""; CONFIG_DIR=""; ALLOW_AGENT=0
HARNESS="${OUTSOURCE_HARNESS:-claude-code}"
MODEL="${GLM_DELEGATE_MODEL:-}"
USER_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/crush/crush.json"
ZAI_ANTHROPIC_BASE="${ZAI_ANTHROPIC_BASE:-https://api.z.ai/api/anthropic}"

while [ $# -gt 0 ]; do
  case "$1" in
    --cwd) CWD="$2"; shift 2 ;;
    --spec) SPEC="$2"; shift 2 ;;
    --log) LOG="$2"; shift 2 ;;
    --session) SESSION="$2"; shift 2 ;;
    --model) MODEL="$2"; shift 2 ;;
    --harness) HARNESS="$2"; shift 2 ;;
    --config-dir) CONFIG_DIR="$2"; shift 2 ;;
    --allow-agent) ALLOW_AGENT=1; shift ;;
    *) echo "unknown flag: $1" >&2; exit 64 ;;
  esac
done

[ -n "$CWD" ]  || { echo "--cwd is required" >&2; exit 64; }
[ -d "$CWD" ]  || { echo "--cwd does not exist: $CWD" >&2; exit 64; }
[ -n "$SPEC" ] || { echo "--spec is required" >&2; exit 64; }
[ -f "$SPEC" ] || { echo "--spec does not exist: $SPEC" >&2; exit 64; }

CONFIG_DIR="${CONFIG_DIR:-${TMPDIR:-/tmp}/outsource-glm-cfg}"
mkdir -p "$CONFIG_DIR"

read_key() {  # provider name -> api key on stdout; never echoed elsewhere
  python3 -c 'import json,sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
print((((d.get("providers") or {}).get(sys.argv[2])) or {}).get("api_key", ""))' "$USER_CONFIG" "$1" 2>/dev/null || true
}

case "$HARNESS" in
claude-code)
  command -v claude >/dev/null 2>&1 || { echo "harness claude-code needs the 'claude' CLI on PATH" >&2; exit 69; }
  MODEL="${MODEL:-glm-5.3}"
  KEY="$(read_key zai)"
  [ -n "$KEY" ] || { echo "outsource: no api_key for provider 'zai' in $USER_CONFIG" >&2; exit 1; }

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
  export ANTHROPIC_BASE_URL="$ZAI_ANTHROPIC_BASE"
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

  SID=""
  if [ -n "$LOG" ] && [ -f "$LOG" ]; then
    SID="$(python3 -c 'import json,sys
try:
    print(json.load(open(sys.argv[1])).get("session_id",""))
except Exception:
    pass' "$LOG" 2>/dev/null || true)"
  fi
  echo "SESSION ${SID:-unknown}"
  exit $RC_EXIT
  ;;

crush)
  command -v crush >/dev/null 2>&1 || { echo "harness crush needs the 'crush' CLI on PATH" >&2; exit 69; }
  MODEL="${MODEL:-zai/glm-5.3}"

  # crush's data_directory defaults to `.crush` *relative to the working
  # directory*, so an unqualified run drops a multi-MB session DB into the tree
  # it is editing. Keep it in scratch: the target repo stays clean and
  # `crush session list` becomes scoped to this track (it is keyed by data dir,
  # not by --cwd), which is what makes resume reliable.
  DATA_DIR="$CONFIG_DIR/data"
  mkdir -p "$DATA_DIR"

  PROVIDER="${MODEL%%/*}"
  [ "$PROVIDER" != "$MODEL" ] || { echo "--model must be provider/id for the crush harness, got: $MODEL" >&2; exit 64; }

  # The isolated config replaces the user's global one, so the provider (and its
  # key) has to be re-declared. Read it from the real config at load time rather
  # than copying the secret into a file we write — nothing lands on disk here and
  # nothing reaches a log.
  cat > "$CONFIG_DIR/crushrc" <<RC
#!/usr/bin/env bash
set -euo pipefail

_key="\$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["providers"]["$PROVIDER"]["api_key"])' "$USER_CONFIG" 2>/dev/null || true)"
[ -n "\$_key" ] || { echo "outsource: no api_key for provider '$PROVIDER' in $USER_CONFIG" >&2; exit 1; }
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

  SID="$(CRUSH_GLOBAL_CONFIG="$CONFIG_DIR" crush session last --json -c "$CWD" -D "$DATA_DIR" 2>/dev/null \
         | python3 -c 'import json,sys; d=json.load(sys.stdin); print((d.get("meta") or d).get("id",""))' 2>/dev/null || true)"
  echo "SESSION ${SID:-unknown}"
  exit $RC_EXIT
  ;;

*)
  echo "--harness must be claude-code or crush, got: $HARNESS" >&2; exit 64 ;;
esac

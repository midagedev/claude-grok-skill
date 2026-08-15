#!/usr/bin/env bash
# Launch a delegated GLM-5.3 run (via the crush CLI) with an isolated config.
#
# Why a launcher exists at all: `crush run` has no --yolo, no --deny, no
# --prompt-file and no --max-turns. Every one of those grok flags maps to
# config instead, and config is discovered from the *directory* named by
# CRUSH_GLOBAL_CONFIG. This script builds that directory in scratch so the
# user's own ~/.config/crush stays untouched and interactive crush keeps
# prompting normally.
#
#   crush-run.sh --cwd <dir> --spec <file> [--log <file>] [--session <id>]
#                [--model <provider/id>] [--config-dir <dir>] [--allow-agent]
#
# Prints "SESSION <id>" on the last line so the caller can resume.
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CWD=""; SPEC=""; LOG=""; SESSION=""; CONFIG_DIR=""; ALLOW_AGENT=0
MODEL="${GLM_DELEGATE_MODEL:-zai/glm-5.3}"
USER_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/crush/crush.json"

while [ $# -gt 0 ]; do
  case "$1" in
    --cwd) CWD="$2"; shift 2 ;;
    --spec) SPEC="$2"; shift 2 ;;
    --log) LOG="$2"; shift 2 ;;
    --session) SESSION="$2"; shift 2 ;;
    --model) MODEL="$2"; shift 2 ;;
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

# crush's data_directory defaults to `.crush` *relative to the working
# directory*, so an unqualified run drops a multi-MB session DB into the tree
# it is editing. Keep it in scratch: the target repo stays clean and
# `crush session list` becomes scoped to this track (it is keyed by data dir,
# not by --cwd), which is what makes resume reliable.
DATA_DIR="$CONFIG_DIR/data"
mkdir -p "$DATA_DIR"

PROVIDER="${MODEL%%/*}"
[ "$PROVIDER" != "$MODEL" ] || { echo "--model must be provider/id, got: $MODEL" >&2; exit 64; }

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
  # = grok --no-subagents. Not cosmetic: hooks fire only on the top-level
  # agent's tool calls, so a sub-agent's bash would bypass the git guard.
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

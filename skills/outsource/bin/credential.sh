#!/usr/bin/env bash
# Resolve one provider's API key and print it on stdout. The single owner of
# "where does the key come from" — the launcher, the crush config it
# generates, and bin/quota.sh all call this rather than each carrying a copy.
#
#   credential.sh <provider>                     # key on stdout, or exit 1
#   credential.sh <provider> --where             # name the source, never the key
#   credential.sh <provider> --base-url <deflt>  # the provider's base URL
#
# Resolution order (first non-empty wins):
#
#   1. the provider's environment variable — ZAI_API_KEY / XAI_API_KEY.
#      This is the documented way. A published skill must not require some
#      other CLI's config file to be where your key lives.
#   2. ~/.config/outsource/credentials — this skill's own store, written by
#      bin/setup-key.sh with mode 0600. Plain `NAME=value` lines.
#   3. discovery, per provider, of files another tool already wrote (below).
#
# When nothing is found, the message names every place that was tried and
# points at `bin/setup-key.sh`, which is the interactive half. Nothing here
# ever prompts: the launcher runs headless in the background, and a prompt
# there would hang a round instead of failing it.
#
# The key is printed to stdout and nowhere else — never to a log, never into
# a file this script writes, never on a command line.
set -euo pipefail

PROVIDER="${1:-}"
MODE="${2:-}"
[ -n "$PROVIDER" ] || { echo "usage: credential.sh <provider> [--where]" >&2; exit 64; }

CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
STORE="$CONFIG_HOME/outsource/credentials"
CRUSH_CONFIG="$CONFIG_HOME/crush/crush.json"
CLAUDE_SETTINGS="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
# z.ai's own installer (`npx @z_ai/coding-helper`) keeps the key and the plan
# here. It is the vendor's documented path, so it is the first place worth
# looking after this skill's own store.
CHELPER_CONFIG="$HOME/.chelper/config.yaml"

case "$PROVIDER" in
  zai) ENV_VAR="ZAI_API_KEY" ;;
  xai) ENV_VAR="XAI_API_KEY" ;;
  *)   echo "credential.sh: unknown provider '$PROVIDER' (known: zai xai)" >&2; exit 64 ;;
esac

# chelper_field reads one scalar out of the helper's config.yaml without
# needing a YAML parser: the file is flat `key: value`, written by js-yaml.
chelper_field() {
  [ -r "$CHELPER_CONFIG" ] || return 0
  sed -n "s/^$1:[[:space:]]*//p" "$CHELPER_CONFIG" | head -n1 | tr -d '"'"'"'\r'
}

# --base-url resolves which host this provider's account actually lives on. The
# z.ai coding plan ships in two regions with different hosts — api.z.ai for the
# global plan, open.bigmodel.cn for the mainland-China one — and the helper
# records which one you bought as `plan:`. Reading it here means a China-plan
# key is not silently pointed at the global host, where it 401s.
#
# The argument is the provider table's own default; it is returned unchanged
# unless something concrete says otherwise, so the table stays the one place a
# new provider is declared.
if [ "$MODE" = "--base-url" ]; then
  DEFAULT="${3:-}"
  [ -n "$DEFAULT" ] || { echo "credential.sh: --base-url needs the provider's default URL" >&2; exit 64; }
  case "$PROVIDER" in
    zai) OVERRIDE="${ZAI_BASE_URL:-}" ;;
    xai) OVERRIDE="${XAI_BASE_URL:-}" ;;
    *)   OVERRIDE="" ;;
  esac
  if [ -n "$OVERRIDE" ]; then
    printf '%s\n' "$OVERRIDE"
    exit 0
  fi
  HOST=""
  if [ "$PROVIDER" = zai ]; then
    case "$(chelper_field plan)" in
      "") ;;
      glm_coding_plan_global) HOST="https://api.z.ai" ;;
      # Every other plan value the helper writes is a mainland one; it sends
      # those to open.bigmodel.cn (dist/lib/claude-code-manager.js).
      *) HOST="https://open.bigmodel.cn" ;;
    esac
    if [ -z "$HOST" ] && [ -r "$CLAUDE_SETTINGS" ]; then
      HOST="$(python3 -c 'import json,sys
from urllib.parse import urlsplit
try:
    env = (json.load(open(sys.argv[1])).get("env") or {})
except Exception:
    sys.exit(0)
u = urlsplit(str(env.get("ANTHROPIC_BASE_URL") or ""))
if u.hostname in ("api.z.ai", "open.bigmodel.cn", "dev.bigmodel.cn"):
    print(f"{u.scheme}://{u.netloc}")' "$CLAUDE_SETTINGS" 2>/dev/null || true)"
    fi
  fi
  if [ -z "$HOST" ]; then
    printf '%s\n' "$DEFAULT"
  else
    # Keep the table's path, swap only the host it hangs off.
    printf '%s\n' "$HOST$(printf '%s' "$DEFAULT" | sed -E 's#^[a-z]+://[^/]*##')"
  fi
  exit 0
fi

FOUND=""; SOURCE=""; TRIED=""
note() { TRIED="$TRIED
  - $1"; }

take() {  # <value> <source label> -> record it if non-empty
  [ -n "$1" ] || return 0
  [ -z "$FOUND" ] || return 0
  FOUND="$1"; SOURCE="$2"
}

# 1. environment
note "\$$ENV_VAR (environment)"
take "$(printenv "$ENV_VAR" 2>/dev/null || true)" "\$$ENV_VAR"

# 2. this skill's own store
note "$STORE (written by bin/setup-key.sh)"
if [ -z "$FOUND" ] && [ -r "$STORE" ]; then
  take "$(sed -n "s/^${ENV_VAR}=//p" "$STORE" | head -n1)" "$STORE"
fi

# 3. discovery — files another tool already wrote. Read-only; nothing here
# is ever modified, and each source is guarded so we cannot pick up a
# credential that belongs to a different service.
if [ "$PROVIDER" = zai ]; then
  # z.ai's own installer writes the key it verified into its config. Reading it
  # is what makes `npx @z_ai/coding-helper` count as having set this skill up
  # too — the vendor's documented path should not need a second paste.
  note "$CHELPER_CONFIG (api_key, written by npx @z_ai/coding-helper)"
  if [ -z "$FOUND" ]; then
    take "$(chelper_field api_key)" "$CHELPER_CONFIG"
  fi

  note "$CRUSH_CONFIG (providers.zai.api_key)"
  if [ -z "$FOUND" ] && [ -r "$CRUSH_CONFIG" ]; then
    take "$(python3 -c 'import json,sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
print((((d.get("providers") or {}).get("zai")) or {}).get("api_key", ""))' "$CRUSH_CONFIG" 2>/dev/null || true)" "$CRUSH_CONFIG"
  fi

  # z.ai's official helper writes ANTHROPIC_AUTH_TOKEN + ANTHROPIC_BASE_URL
  # into Claude Code's settings. Only harvest the token when the base URL
  # actually points at z.ai — otherwise this would lift the user's real
  # Anthropic subscription token and send it to a third party.
  note "$CLAUDE_SETTINGS (env.ANTHROPIC_AUTH_TOKEN, only when env.ANTHROPIC_BASE_URL is a z.ai host)"
  if [ -z "$FOUND" ] && [ -r "$CLAUDE_SETTINGS" ]; then
    take "$(python3 -c 'import json,sys
try:
    env = (json.load(open(sys.argv[1])).get("env") or {})
except Exception:
    sys.exit(0)
base = str(env.get("ANTHROPIC_BASE_URL") or "")
if any(h in base for h in ("api.z.ai", "open.bigmodel.cn", "dev.bigmodel.cn")):
    print(env.get("ANTHROPIC_AUTH_TOKEN", ""))' "$CLAUDE_SETTINGS" 2>/dev/null || true)" "$CLAUDE_SETTINGS"
  fi
fi

if [ -z "$FOUND" ]; then
  cat >&2 <<MSG
outsource: no API key for provider '$PROVIDER'. Tried, in order:$TRIED

Set it once, interactively:

  $(dirname "$0")/setup-key.sh $PROVIDER

or export it yourself:

  export $ENV_VAR=...
MSG
  exit 1
fi

if [ "$MODE" = "--where" ]; then
  echo "$SOURCE"
else
  printf '%s\n' "$FOUND"
fi

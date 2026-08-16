#!/usr/bin/env bash
# The interactive half of credential handling: find a provider's key, or ask
# for one, then store it where bin/credential.sh will find it next time.
#
#   setup-key.sh <provider>            # zai | xai
#   setup-key.sh <provider> --force    # re-ask even if a key is already found
#
# Run this yourself in a terminal. The launcher never prompts — it runs
# headless in the background, where a prompt hangs a round instead of
# failing it, so it points here instead.
#
# The key is read with echo off, stored at ~/.config/outsource/credentials
# with mode 0600, and never printed, logged, or passed on a command line.
set -euo pipefail

BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROVIDER="${1:-}"
FORCE=0
[ "${2:-}" = "--force" ] && FORCE=1

case "$PROVIDER" in
  zai|xai) ;;
  *) echo "usage: setup-key.sh <zai|xai> [--force]" >&2; exit 64 ;;
esac

case "$PROVIDER" in
  zai) ENV_VAR="ZAI_API_KEY"; WHERE="https://z.ai — API keys in your account settings" ;;
  xai) ENV_VAR="XAI_API_KEY"; WHERE="https://console.x.ai — API keys" ;;
esac

CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
STORE="$CONFIG_HOME/outsource/credentials"

# Already resolvable? Say where from, without printing it.
if [ "$FORCE" -eq 0 ] && SRC="$("$BIN/credential.sh" "$PROVIDER" --where 2>/dev/null)"; then
  echo "outsource: '$PROVIDER' already resolves from: $SRC"
  echo "nothing to do. Re-run with --force to replace it."
  exit 0
fi

echo "outsource: no key found for '$PROVIDER'."
echo "Get one at: $WHERE"
echo

[ -t 0 ] || { echo "setup-key.sh needs a terminal — run it yourself, not from a script." >&2; exit 1; }

printf 'Paste the %s key (input hidden): ' "$ENV_VAR" >&2
IFS= read -rs KEY </dev/tty
printf '\n' >&2
[ -n "$KEY" ] || { echo "setup-key.sh: nothing entered; no change made." >&2; exit 1; }

# Validate before storing, so a typo fails here instead of mid-round.
# Only zai has a free read-only endpoint to check against; xai's would cost
# a real request, so it is stored unverified and said so.
if [ "$PROVIDER" = zai ]; then
  printf 'checking the key against z.ai... ' >&2
  BODY="$(printf 'header = "Authorization: Bearer %s"\n' "$KEY" \
          | curl -sS --max-time 20 -K - https://api.z.ai/api/monitor/usage/quota/limit 2>/dev/null || true)"
  # This endpoint answers a bad credential with HTTP 200 and success:false,
  # so the body decides, not the status line.
  if ! printf '%s' "$BODY" | python3 -c 'import json,sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
sys.exit(0 if d.get("success") is True and d.get("code") == 200 else 1)' 2>/dev/null; then
    MSG="$(printf '%s' "$BODY" | python3 -c 'import json,sys
try:
    print(json.load(sys.stdin).get("msg") or "")
except Exception:
    print("")' 2>/dev/null || true)"
    printf 'rejected.\n' >&2
    echo "setup-key.sh: z.ai did not accept that key${MSG:+ ($MSG)}. Nothing stored." >&2
    exit 1
  fi
  printf 'accepted.\n' >&2
else
  echo "note: '$PROVIDER' has no free endpoint to verify against, so this key is stored unverified." >&2
fi

umask 077
mkdir -p "$(dirname "$STORE")"
TMP="$(mktemp "$STORE.XXXXXX")"
# Rewrite without this provider's line, then append the new one, so a
# partial write can never leave a half-file where the key used to be.
[ ! -f "$STORE" ] || grep -v "^${ENV_VAR}=" "$STORE" > "$TMP" || true
printf '%s=%s\n' "$ENV_VAR" "$KEY" >> "$TMP"
chmod 600 "$TMP"
mv "$TMP" "$STORE"

echo "stored in $STORE (mode 600)."
echo "bin/credential.sh $PROVIDER will find it from now on; exporting \$$ENV_VAR still takes precedence."

#!/usr/bin/env sh
# install.sh — copy the grok-delegate skill into Claude Code's skill directory.
#
# Usage:
#   ./install.sh            install into ~/.claude/skills/grok-delegate/
#   ./install.sh --project  install into ./.claude/skills/grok-delegate/ (cwd)
#   ./install.sh --print    show the plan without writing
#   ./install.sh --force    overwrite even if the install was hand-edited
#
# Upgrades over an unmodified install proceed without --force: each install
# writes a checksum manifest (.install-checksums), and the next run refuses
# only when files changed since the LAST INSTALL (i.e. someone hand-edited
# the installed copy). references/local-overlay.md is always preserved and
# never checksummed.
set -eu

SRC="$(cd "$(dirname "$0")" && pwd)/skills/grok-delegate"
DEST="$HOME/.claude/skills/grok-delegate"
MANIFEST=".install-checksums"
PRINT=0
FORCE=0

for arg in "$@"; do
  case "$arg" in
    --project) DEST="$(pwd)/.claude/skills/grok-delegate" ;;
    --print)   PRINT=1 ;;
    --force)   FORCE=1 ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

checksum() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$@"; else shasum -a 256 "$@"; fi
}

echo "install: $SRC -> $DEST"
[ "$PRINT" -eq 1 ] && exit 0

# Tamper check: refuse to clobber local edits unless --force.
if [ -d "$DEST" ] && [ "$FORCE" -ne 1 ]; then
  if [ -f "$DEST/$MANIFEST" ]; then
    if ! (cd "$DEST" && checksum -c "$MANIFEST" >/dev/null 2>&1); then
      echo "refusing: $DEST was modified since the last install." >&2
      echo "use --force to discard those local edits (local-overlay.md survives either way)." >&2
      exit 1
    fi
  elif ! diff -rq -x local-overlay.md -x "$MANIFEST" "$SRC" "$DEST" >/dev/null 2>&1; then
    echo "refusing: $DEST differs and has no install manifest (pre-manifest install)." >&2
    echo "use --force once; upgrades after that won't need it." >&2
    exit 1
  fi
fi

# Preserve a user's local overlay across upgrades (never shipped by this repo).
OVERLAY="$DEST/references/local-overlay.md"
TMP_OVERLAY=""
if [ -f "$OVERLAY" ]; then
  TMP_OVERLAY="$(mktemp)"
  cp "$OVERLAY" "$TMP_OVERLAY"
fi

# Clean install so files removed upstream don't linger.
rm -rf "$DEST"
mkdir -p "$DEST"
cp -R "$SRC/." "$DEST/"

if [ -n "$TMP_OVERLAY" ]; then
  mkdir -p "$DEST/references"
  cp "$TMP_OVERLAY" "$OVERLAY"
  rm -f "$TMP_OVERLAY"
  echo "preserved local overlay: $OVERLAY"
fi

# Record what this install shipped, so the next run can tell "upgrade over
# a clean install" (fine) from "someone hand-edited the copy" (refuse).
(
  cd "$DEST" &&
  find . -type f ! -name "$MANIFEST" ! -path "./references/local-overlay.md" \
    | LC_ALL=C sort \
    | while IFS= read -r f; do checksum "$f"; done
) > "$DEST/$MANIFEST"

echo "installed. In Claude Code, invoke with /grok-delegate (requires an authenticated grok CLI)."

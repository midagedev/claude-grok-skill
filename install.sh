#!/usr/bin/env sh
# install.sh — copy the grok-delegate skill into Claude Code's skill directory.
#
# Usage:
#   ./install.sh            install into ~/.claude/skills/grok-delegate/
#   ./install.sh --project  install into ./.claude/skills/grok-delegate/ (cwd)
#   ./install.sh --print    show the plan without writing
#   ./install.sh --force    overwrite an existing differing install
set -eu

SRC="$(cd "$(dirname "$0")" && pwd)/skills/grok-delegate"
DEST="$HOME/.claude/skills/grok-delegate"
PRINT=0
FORCE=0

for arg in "$@"; do
  case "$arg" in
    --project) DEST="$(pwd)/.claude/skills/grok-delegate" ;;
    --print)   PRINT=1 ;;
    --force)   FORCE=1 ;;
    -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

echo "install: $SRC -> $DEST"
[ "$PRINT" -eq 1 ] && exit 0

if [ -d "$DEST" ] && [ "$FORCE" -ne 1 ]; then
  if ! diff -rq "$SRC" "$DEST" >/dev/null 2>&1; then
    echo "refusing to overwrite a differing install at $DEST (use --force)" >&2
    exit 1
  fi
fi

mkdir -p "$DEST"
cp -R "$SRC/." "$DEST/"
echo "installed. In Claude Code, invoke with /grok-delegate (requires an authenticated grok CLI)."

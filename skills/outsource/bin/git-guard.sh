#!/usr/bin/env bash
# PreToolUse guard for delegated runs. Harness-agnostic: it reads the actual
# command string, which is strictly stronger than glob denies — `git -C <path>
# commit` and `env ... git push` are caught too.
#
# Two call conventions, both supported so one guard serves every harness:
#   crush        — command arrives in $CRUSH_TOOL_INPUT_COMMAND
#   claude-code  — hook JSON arrives on stdin as {"tool_input":{"command":…}}
#
# Exit 2 = block this one call; the agent sees stderr and can try again.
set -uo pipefail

cmd="${CRUSH_TOOL_INPUT_COMMAND:-}"
if [ -z "$cmd" ] && [ ! -t 0 ]; then
  # Claude Code hands the tool call to hooks as JSON on stdin.
  cmd="$(python3 -c 'import json,sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
ti = d.get("tool_input") or {}
print(ti.get("command", "") if isinstance(ti, dict) else "")' 2>/dev/null)"
fi
[ -n "$cmd" ] || exit 0

# git subcommands that change repository state. Read-only git (log/show/diff/
# blame/status/ls-files/rev-parse/worktree list) stays available on purpose:
# blanket bans cripple investigation work.
deny_git='commit|push|checkout|switch|stash|restore|add|rm|mv|reset|rebase|merge|cherry-pick|revert|tag|branch|worktree|clean|filter-branch|update-ref|apply|am|fetch|pull|clone|remote|submodule|config|gc|prune|reflog|notes|replace|sparse-checkout|bisect'

# Global flags that may sit between `git` and the subcommand. Two shapes:
# a flag that swallows the next word (`-C <path>`, `-c <k=v>`) and a long flag
# that carries its value inline (`--git-dir=…`).
#
# ONE definition, used by both passes below. That is the whole point: the two
# passes used to spell this differently — the deny pass understood `-C <path>`
# and the allow pass did not — so `git -C <repo> worktree list` had its
# read-only form left un-erased and then tripped the deny pass on `worktree`.
# A delegate that opens by proving which tree it is in was blocked for doing
# exactly what the specs ask of it (measured 2026-08-16).
git_flags='([[:space:]]+(-[A-Za-z-]+([[:space:]]+[^[:space:]]+)?|--[a-z-]+(=[^[:space:]]+)?))*'

# Listing forms of otherwise-mutating subcommands. Delegation specs routinely
# open with `git worktree list` to prove which tree the agent is in, so these
# must survive the deny pass.
# Erase the read-only forms, then run the deny pass on what is left. A line
# that pairs a listing with a mutation (`git worktree list && git commit -am x`)
# still trips the deny pass, because only the listing half is erased.
allow_ro='(worktree[[:space:]]+list|branch[[:space:]]+(-[alvr]+|--list)|remote[[:space:]]+(-v|--verbose|show)|config[[:space:]]+(--get|--get-all|--list|-l))'
scan=$(printf '%s' "$cmd" | sed -E "s/git${git_flags}[[:space:]]+$allow_ro/GIT_RO/gI")

# `git` anywhere in the pipeline, with flags like -C/-c/--git-dir before the
# subcommand, and ignoring a leading `sudo`/`env VAR=...`.
if printf '%s' "$scan" | grep -qiE "(^|[;&|(]|\bsudo\b|\benv\b[^;&|]*)[[:space:]]*git${git_flags}[[:space:]]+($deny_git)\b"; then
  echo "BLOCKED: git 상태 변경은 리드 전용이다. 읽기 전용 git(log/show/diff/blame/status)만 허용된다. 복원이 필요하면 리드에게 요청하라." >&2
  exit 2
fi

# gh commands that publish or mutate remote state.
if printf '%s' "$scan" | grep -qiE "(^|[;&|(])[[:space:]]*gh[[:space:]]+(pr[[:space:]]+(create|merge|close|edit|ready|review)|repo[[:space:]]+(create|delete|edit|fork|sync)|release|workflow[[:space:]]+run|api[[:space:]]+-X[[:space:]]*(POST|PATCH|PUT|DELETE))"; then
  echo "BLOCKED: PR/릴리스/원격 변경은 리드 전용이다. 읽기(gh pr list/view, gh api GET)만 허용된다." >&2
  exit 2
fi

exit 0

#!/usr/bin/env bash
# A Claude Code status line for a lead who delegates: the two budgets that
# stop *this* session, the delegation budgets that stop the next round, and
# the rounds that are running right now.
#
# Wire it up once, in ~/.claude/settings.json:
#
#   "statusLine": {
#     "type": "command",
#     "command": "bash ~/.claude/skills/outsource/bin/statusline.sh"
#   }
#
# It renders two lines, split by who the number is about — which is also how
# fast each half changes:
#
#   opus │ you@example.com │ CTX 12% │ 5H 8%/3h20m │ 1W 38%/4d2h
#   z.ai 28%/6d5h │ grok 98%/2h32m │ 🛠2 ▶api zai·crush 12m │ repo (main)
#
# Every budget is one token: NAME used%/until-it-resets. The percentage says
# how much is gone, the second half says how long until it comes back, and
# neither is actionable without the other — a bar renders the first half in
# thirty columns and the second half not at all, so there is no bar here.
# Colour carries the alarm instead: green under 50, yellow under 80, red at
# 80 and above.
#
# Everything degrades to silence. No z.ai key, never signed in to grok, no
# delegated run on record — the segment disappears rather than printing a
# zero that reads like bad news.
#
# ---- why the quota numbers are cached ---------------------------------------
# A status line runs on every render and must return in milliseconds; the
# provider quota APIs take one to two seconds. So the foreground never calls
# them. It reads a small key=value cache, and when that cache is older than
# $OUTSOURCE_STATUSLINE_TTL it detaches one background refresh — guarded by a
# lock directory, so a burst of renders produces one fetch and not thirty.
# Until the first refresh lands the segment shows "…", which is honest: it
# means "not measured yet", not "zero". A number that has gone stale because
# refreshes keep failing is prefixed "~" rather than quietly kept.
#
# Environment (all optional):
#   OUTSOURCE_STATUSLINE_PROVIDERS  default "zai grok"; "" disables the row
#   OUTSOURCE_STATUSLINE_TTL        cache lifetime in seconds, default 180
#   OUTSOURCE_STATUSLINE_CACHE      cache dir, default
#                                   ${XDG_CACHE_HOME:-~/.cache}/outsource/statusline
#
# Requires: jq (Claude Code's own status-line convention) and python3, which
# bin/quota.sh already needs.
set -uo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
QUOTA_SH="$SKILL_DIR/bin/quota.sh"
RUNS_SH="$SKILL_DIR/bin/runs.sh"

PROVIDERS="${OUTSOURCE_STATUSLINE_PROVIDERS-zai grok}"
TTL="${OUTSOURCE_STATUSLINE_TTL:-180}"
CACHE_DIR="${OUTSOURCE_STATUSLINE_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/outsource/statusline}"

have() { command -v "$1" >/dev/null 2>&1; }

# ---- the background half ----------------------------------------------------
# quota.sh's JSON is digested here, once per refresh, into the flat key=value
# file the foreground reads — so the hot path parses no JSON and needs no jq
# for this segment at all.
#
# This dispatch comes before the status line reads its stdin, and that
# ordering is load-bearing: the refresher is this same file re-invoked, it
# inherits the caller's stdin, and `input=$(cat)` would block on it forever —
# holding the lock and leaving the number stuck at "…" for good.
refresh_provider() {  # <provider>
  local p="$1" out prev=""
  out="$("$QUOTA_SH" --provider "$p" --json 2>/dev/null)" || out=""
  # A failed refresh must not erase the last good numbers. Silence in this
  # status line means "this backend is not set up here"; a backend that was
  # working and stopped — an expired grok sign-in, a network blip — is a
  # different thing entirely, and vanishing would report it as the first.
  # The previous measurement is carried forward and marked stale instead.
  [ -n "$out" ] || prev="$(cat "$CACHE_DIR/$p.kv" 2>/dev/null || true)"
  # The JSON rides in as an argument, not on stdin: the digest program is
  # itself delivered on stdin (`python3 -` + heredoc), so a pipe into the
  # same process is read as program text and the payload silently vanishes.
  python3 - "$(date +%s)" "$out" "$prev" > "$CACHE_DIR/$p.kv.tmp$$" 2>/dev/null <<'PY'
import json, sys
now, raw, prev = sys.argv[1], sys.argv[2], sys.argv[3]
# fetchedAt is when we last *tried*; measuredAt is when the numbers below
# were actually true. Staleness is the gap between them.
print("fetchedAt=%s" % now)
try:
    d = json.loads(raw)
except Exception:
    print("error=1")
    for line in prev.splitlines():          # carry the last good measurement
        if line.split("=", 1)[0] in ("label", "percentage", "resetEpoch",
                                     "plan", "measuredAt"):
            print(line)
    sys.exit(0)
print("measuredAt=%s" % now)
ws = d.get("windows") or []
# The weekly window is the one a plan is actually rationed by, so prefer it;
# grok's unified-billing accounts expose only a monthly budget, and an
# account with neither still has a shortest window worth showing.
week = next((w for w in ws if str(w.get("label", "")).endswith("w")), None)
w = week or next((w for w in ws if str(w.get("label", "")) == "1mo"), None) \
    or (ws[0] if ws else None)
if not w:
    print("error=1"); sys.exit(0)
print("label=%s" % w.get("label", "?"))
pct = w.get("percentage")
print("percentage=%s" % ("" if pct is None else round(float(pct))))
ms = w.get("nextResetTime") or 0
print("resetEpoch=%s" % (int(ms) // 1000 if ms else ""))
sub = (d.get("subscription") or {}).get("productName") or d.get("level") or ""
print("plan=%s" % str(sub).replace("\n", " "))
PY
  mv "$CACHE_DIR/$p.kv.tmp$$" "$CACHE_DIR/$p.kv" 2>/dev/null || rm -f "$CACHE_DIR/$p.kv.tmp$$"
}

# Re-entered through this same file (--refresh <provider>) rather than a
# second script, so the digest format has one owner.
if [ "${1:-}" = "--refresh" ] && [ -n "${2:-}" ]; then
  mkdir -p "$CACHE_DIR" 2>/dev/null || exit 0
  refresh_provider "$2"
  rmdir "$CACHE_DIR/$2.lock" 2>/dev/null
  exit 0
fi

input=$(cat)

# jq is the one hard dependency of the foreground path. Without it there is
# nothing truthful left to print, so name the missing tool instead of
# rendering a line of blanks.
if ! have jq; then
  printf 'statusline: jq is not on PATH'
  exit 0
fi

CYAN='\033[0;36m'; YELLOW='\033[0;33m'; GREEN='\033[0;32m'; RED='\033[0;31m'
MAGENTA='\033[0;35m'; DIM='\033[2m'; RESET='\033[0m'
SEP=" ${DIM}│${RESET} "

# ---- shared renderers -------------------------------------------------------

# A percentage that is not a number is missing data, and missing data must
# never render as 0% — that reads as "plenty left", the most expensive
# possible way to be wrong here.
is_num() { case "${1:-}" in ''|*[!0-9.]*) return 1 ;; *) return 0 ;; esac; }

pct_color() {  # <percent> — the alarm the bar used to carry
  local p
  p=$(printf '%.0f' "${1:-0}" 2>/dev/null) || p=0
  if   [ "$p" -ge 80 ]; then printf '%s' "$RED"
  elif [ "$p" -ge 50 ]; then printf '%s' "$YELLOW"
  else                       printf '%s' "$GREEN"
  fi
}

# epoch seconds -> 35m · 3h20m · 4d2h. Past a day the minutes stop mattering
# and the days start to, so the unit pair shifts with the magnitude; that is
# what keeps a week-long window readable in five columns.
until_str() {  # <epoch-seconds>
  local epoch="${1:-}" now
  is_num "$epoch" || return 0
  now=$(date +%s)
  awk -v epoch="$epoch" -v now="$now" 'BEGIN {
    s = epoch - now
    if (s <= 0)      { printf "now" }
    else if (s < 3600)  { printf "%dm", int(s/60) }
    else if (s < 86400) { printf "%dh%02dm", int(s/3600), int(s%3600/60) }
    else                { printf "%dd%dh", int(s/86400), int(s%86400/3600) }
  }'
}

budget() {  # <label> <percent> <reset-epoch> -> "5H 8%/3h20m"
  local label="$1" pct="$2" reset="$3" until
  is_num "$pct" || return 0
  until=$(until_str "$reset")
  printf '%s%s%s %s%s%%%s%s' "$DIM" "$label" "$RESET" \
    "$(pct_color "$pct")" "$(printf '%.0f' "$pct")" "$RESET" \
    "${until:+${DIM}/${until}${RESET}}"
}

# ---- the session's own numbers ----------------------------------------------
# One jq pass, not one per field: a status line re-renders constantly, and
# six process spawns per render is most of its cost. Fixed field order, with
# `empty` widened to "" so the count never shifts.
#
# The separator is US (), not a tab: when IFS holds only whitespace,
# bash collapses runs of it, so a session with no rate limits — six empty
# fields in a row — would shift `cwd` up into the context slot and print the
# working directory as a percentage. A non-whitespace IFS does not collapse.
IFS=$'\037' read -r model_raw ctx_used five_pct five_reset week_pct week_reset cwd branch session_id <<EOF
$(printf '%s' "$input" | jq -r '[
    (.model.display_name // .model.id // ""),
    (.context_window.used_percentage // ""),
    (.rate_limits.five_hour.used_percentage // ""),
    (.rate_limits.five_hour.resets_at // ""),
    (.rate_limits.seven_day.used_percentage // ""),
    (.rate_limits.seven_day.resets_at // ""),
    (.cwd // .workspace.current_dir // ""),
    (.workspace.git_worktree // ""),
    (.session_id // "")
  ] | map(tostring) | join("")')
EOF

# ---- line 1: this session ---------------------------------------------------

# Model, short. The display name carries marketing ("Opus 5 (1M context)");
# what a lead checks at a glance is the family, so that is all this prints.
model_short=$(printf '%s' "$model_raw" | tr '[:upper:]' '[:lower:]' | awk '{
  for (i = 1; i <= NF; i++) {
    if ($i ~ /fable/)  { print "fable";  exit }
    if ($i ~ /opus/)   { print "opus";   exit }
    if ($i ~ /sonnet/) { print "sonnet"; exit }
    if ($i ~ /haiku/)  { print "haiku";  exit }
  }
  print $1
}')
model_part=""
[ -n "$model_short" ] && model_part="${MAGENTA}${model_short}${RESET}"

# Account email — which account is spending, when several are in play.
# ~/.claude.json is large and rewritten constantly, so the extraction is
# cached against its mtime rather than re-parsed on every render.
account_email() {
  local src="$HOME/.claude.json" cache="$CACHE_DIR/account.kv"
  [ -r "$src" ] || return 0
  if [ -r "$cache" ] && [ "$cache" -nt "$src" ]; then
    cat "$cache"; return 0
  fi
  have python3 || return 0
  mkdir -p "$CACHE_DIR" 2>/dev/null || return 0
  python3 - "$src" 2>/dev/null <<'PY' > "$cache.tmp$$" || { rm -f "$cache.tmp$$"; return 0; }
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
e = (d.get("oauthAccount") or {}).get("emailAddress") or ""
if not e:
    sys.exit(1)
sys.stdout.write(e)
PY
  mv "$cache.tmp$$" "$cache" 2>/dev/null || { rm -f "$cache.tmp$$"; return 0; }
  cat "$cache"
}
email=$(account_email)
email_part=""
[ -n "$email" ] && email_part="${DIM}${email}${RESET}"

# The context window has no reset time — it ends when the session does — so
# it is the one budget printed as a bare percentage.
ctx_part=""
is_num "$ctx_used" && ctx_part="${DIM}CTX${RESET} $(pct_color "$ctx_used")$(printf '%.0f' "$ctx_used")%${RESET}"

five_part=$(budget "5H" "$five_pct" "$five_reset")
week_part=$(budget "1W" "$week_pct" "$week_reset")

# ---- line 2: the delegation -------------------------------------------------

maybe_refresh() {  # <provider> — at most one detached fetch in flight
  local p="$1" cache="$CACHE_DIR/$p.kv" lock="$CACHE_DIR/$p.lock" age now fetched="" lock_age
  now=$(date +%s)
  [ -r "$cache" ] && fetched=$(awk -F= '$1=="fetchedAt"{print $2}' "$cache" 2>/dev/null | tail -1)
  age=$(( now - ${fetched:-0} ))
  [ "$age" -ge "$TTL" ] || return 0
  # A lock left behind by a killed refresher would freeze the number forever,
  # so one older than a minute is treated as abandoned.
  if [ -d "$lock" ]; then
    lock_age=$(( now - $(stat -f %m "$lock" 2>/dev/null || stat -c %Y "$lock" 2>/dev/null || echo "$now") ))
    [ "$lock_age" -gt 60 ] || return 0
    rmdir "$lock" 2>/dev/null
  fi
  mkdir "$lock" 2>/dev/null || return 0
  # stdin is closed explicitly: the child is this same script, and an
  # inherited stdin is what would make it block instead of fetching.
  ( bash "$0" --refresh "$p" </dev/null >/dev/null 2>&1 & ) &
  disown 2>/dev/null || true
}

provider_part() {  # <provider> <display name>
  local p="$1" name="$2" cache="$CACHE_DIR/$p.kv"
  local k v measured="" pct="" reset="" now age stale=""
  [ -r "$cache" ] || { printf '%s%s …%s' "$DIM" "$name" "$RESET"; return 0; }
  while IFS='=' read -r k v; do
    case "$k" in
      measuredAt) measured="$v" ;;
      percentage) pct="$v" ;;
      resetEpoch) reset="$v" ;;
    esac
  done < "$cache"
  # No measurement ever taken here means no credential for this backend —
  # not a problem to report, just a backend this user does not use. But once
  # a number has existed it keeps being shown, marked stale, however the
  # refresh is failing now.
  is_num "$pct" || return 0
  now=$(date +%s); age=$(( now - ${measured:-0} ))
  [ "$age" -gt $(( TTL * 4 )) ] && stale="${DIM}~${RESET}"
  printf '%s%s' "$stale" "$(budget "$name" "$pct" "$reset")"
}

quota_parts=""
if [ -n "$PROVIDERS" ] && [ -x "$QUOTA_SH" ]; then
  mkdir -p "$CACHE_DIR" 2>/dev/null
  for p in $PROVIDERS; do
    maybe_refresh "$p"
    case "$p" in
      zai)  disp="z.ai" ;;
      *)    disp="$p" ;;
    esac
    part=$(provider_part "$p" "$disp")
    [ -n "$part" ] && quota_parts="${quota_parts}${quota_parts:+$SEP}${part}"
  done
fi

# Live delegated rounds, straight from the registry the launcher writes —
# scoped to this session. The registry is machine-wide, and it should be: an
# orphaned round has to be findable from wherever you are. But a status line
# is a report on *your* window, so another window's rounds appearing here
# read as your own work and are worse than showing nothing. Two windows open
# on two repos otherwise narrate each other.
#
# Ownership is matched on the session id and on the Claude Code process, so
# a round an in-process teammate launched still counts as this session's.
# OUTSOURCE_STATUSLINE_SCOPE=all opts back out to the whole machine.
runs_part=""
if [ -x "$RUNS_SH" ]; then
  runs_scope=(); runs_ok=1
  if [ "${OUTSOURCE_STATUSLINE_SCOPE:-session}" != all ]; then
    owner="${session_id:-${CLAUDE_CODE_SESSION_ID:-}}"
    owner_pid="${CLAUDE_PID:-}"
    if [ -n "$owner" ] || [ -n "$owner_pid" ]; then
      runs_scope=(--owner "$owner" --owner-claude-pid "$owner_pid")
    else
      # No identity at all: an empty filter means "no filter" downstream, so
      # asking anyway would print the whole machine — precisely what scoping
      # is here to prevent. Claim nothing instead; `runs.sh` still has it.
      runs_ok=0
    fi
  fi
  if [ "$runs_ok" -eq 1 ]; then
    runs_line=$("$RUNS_SH" line "${runs_scope[@]+"${runs_scope[@]}"}" 2>/dev/null)
    [ -n "$runs_line" ] && runs_part="${CYAN}${runs_line}${RESET}"
  fi
fi

# Where you are, de-emphasised and last: it is the one thing on this line you
# already know.
base_cwd=$(basename -- "$cwd" 2>/dev/null)
location_part=""
[ -n "$base_cwd" ] && location_part="${DIM}${base_cwd}${branch:+ (${branch})}${RESET}"

# ---- assemble ---------------------------------------------------------------
join() {  # non-empty arguments, separated
  local out="" a
  for a in "$@"; do [ -n "$a" ] && out="${out}${out:+$SEP}${a}"; done
  printf '%s' "$out"
}

line1=$(join "$model_part" "$email_part" "$ctx_part" "$five_part" "$week_part")
line2=$(join "$quota_parts" "$runs_part" "$location_part")

if [ -n "$line2" ]; then
  printf "%b\n%b" "$line1" "$line2"
else
  printf "%b" "$line1"
fi

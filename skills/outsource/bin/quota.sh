#!/usr/bin/env bash
# Read a delegation backend's remaining plan quota, so a round can be sized
# (or refused) before it is launched instead of dying mid-flight.
# Read-only; keeps no state.
#
#   quota.sh [--provider zai|grok] [--json] [--quiet] [--require-window <N%>]
#
# Providers, and where each one's numbers come from:
#
#   zai   the coding plan's own console API, authenticated with the api key
#         bin/credential.sh resolves:
#           /api/monitor/usage/quota/limit   data.level + data.limits[]
#           /api/biz/subscription/list       plan name/status/validity
#         Two rolling windows (5-hour and weekly) with real credit counts.
#
#   grok  the Grok CLI's own billing proxy, authenticated with the OAuth
#         access token the CLI stores — grok has no api key:
#           /v1/billing?format=credits   weekly credit usage percent
#           /v1/billing                  monthly included budget (fallback)
#         Percent only: xAI exposes no credit counts here, so allowance/
#         consumed/remaining are null and the percentage is the whole signal.
#
# The zai key comes from bin/credential.sh, the single owner of credential
# resolution (env var first, then this skill's 0600 store, then discovery).
# Neither credential is ever echoed, written to a file this script creates,
# or passed on a command line — both ride curl's stdin as a config file.
# The Grok auth file also holds the account's email and user id; this script
# reads them for the request header only and never prints them.
#
# --json emits one compact line (the launcher snapshots it before and after
# a round to price the round; another script depends on this shape — keep it
# stable):
#
#   {"fetchedAt":"2026-08-16T09:41:02Z","provider":"zai","level":"max",
#    "subscription":{"productName":"…","status":"…","valid":"…","error":null},
#    "windows":[…]}                        # shortest window first
#
#   window = {"label":"5h","unit":3,"number":5,"allowance":28000,
#             "consumed":2571,"remaining":25428,"percentage":9,
#             "remainingPercent":90.8,"nextResetTime":1786850669412,
#             "nextResetTimeIso":"2026-08-14T…Z"}
#
# allowance/consumed/remaining are null when the provider reports only a
# percentage (grok). percentage and remainingPercent are always present —
# that is what --require-window gates on, so the gate works on both.
#
# z.ai field semantics measured 2026-08-16 from two live captures minutes
# apart: usage = the window's allowance, currentValue = consumed,
# remaining = left, percentage = consumed %, nextResetTime = epoch
# milliseconds. subscription.error is null normally and carries the
# degrade note when the identity call failed (the quota numbers still
# print — they are the load-bearing part).
#
# --quiet suppresses the whole report, human or JSON, on success; a
# --require-window failure reason always reaches stderr.
#
# Exit codes: 0 ok · 1 no usable credential · 2 endpoint/network/body failure
#             (the message says which) · 3 --require-window floor missed
#             · 64 usage error.
set -euo pipefail

PROVIDER="zai"; MODE="human"; QUIET=0; REQUIRE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --provider)       [ $# -ge 2 ] || { echo "--provider needs a value" >&2; exit 64; }
                      PROVIDER="$2"; shift 2 ;;
    --json)           MODE="json"; shift ;;
    --quiet)          QUIET=1; shift ;;
    --require-window) [ $# -ge 2 ] || { echo "--require-window needs a value" >&2; exit 64; }
                      REQUIRE="$2"; shift 2 ;;
    *)                echo "unknown flag: $1" >&2; exit 64 ;;
  esac
done

case "$PROVIDER" in
  zai|grok) ;;
  *) echo "--provider must be zai or grok, got: $PROVIDER" >&2; exit 64 ;;
esac
# Shape only, not range: a floor above 100 is unmeetable and saying so
# with exit 3 is the honest outcome, not a usage error.
if [ -n "$REQUIRE" ] && ! [[ "$REQUIRE" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  echo "--require-window wants a percentage, got: $REQUIRE" >&2; exit 64
fi

# ---- credentials -----------------------------------------------------------
# Each branch fills HEADERS (curl -K config lines, one "header =" per line).
# HEADERS holds the secret; it is never printed and never leaves this process.

# The Grok CLI stores OAuth sessions in auth.json keyed by issuer. Prefer the
# default xAI issuer (bare or "issuer::<id>"); alternate issuers are a
# compatibility fallback only when no default entry exists. Emits two lines,
# token then user id — read into variables, never printed.
read_grok_session() {
  python3 -c 'import json,os,sys
home = os.environ.get("GROK_HOME") or os.path.expanduser("~/.grok")
try:
    d = json.load(open(os.path.join(home, "auth.json")))
except Exception:
    sys.exit(0)
if not isinstance(d, dict):
    sys.exit(0)
PREF = "https://auth.x.ai"
pref = fallback = None
for k, e in d.items():
    if not isinstance(e, dict) or not e.get("key"):
        continue
    if k == PREF or k.startswith(PREF + "::"):
        pref = pref or e
    elif fallback is None:
        fallback = e
e = pref or fallback
if not e:
    sys.exit(0)
print(e["key"])
print(e.get("user_id") or "")
print(e.get("expires_at") or "")' 2>/dev/null || true
}

BASE=""; URLS=(); HEADERS=""
case "$PROVIDER" in
zai)
  # The monitor endpoints hang off the same host that serves the account —
  # api.z.ai for the global coding plan, open.bigmodel.cn for the mainland one
  # — so the host comes from credential.sh rather than being assumed here.
  # (z.ai's own usage script derives it the same way, from ANTHROPIC_BASE_URL.)
  BASE="${ZAI_QUOTA_BASE:-$("$(dirname "${BASH_SOURCE[0]}")/credential.sh" zai --base-url https://api.z.ai)}"
  # ZAI_QUOTA_KEY / ZAI_QUOTA_BASE are test hooks for this script's own
  # verification, not part of the CLI surface.
  KEY="${ZAI_QUOTA_KEY:-$("$(dirname "${BASH_SOURCE[0]}")/credential.sh" zai || true)}"
  [ -n "$KEY" ] || exit 1   # credential.sh already said where it looked
  HEADERS="$(printf 'header = "Authorization: Bearer %s"\n' "$KEY")"
  URLS=("$BASE/api/monitor/usage/quota/limit" "$BASE/api/biz/subscription/list")
  ;;
grok)
  BASE="${GROK_QUOTA_BASE:-https://cli-chat-proxy.grok.com/v1}"
  GS="$(read_grok_session)"
  GTOKEN="$(printf '%s\n' "$GS" | sed -n 1p)"
  GUSER="$(printf '%s\n' "$GS" | sed -n 2p)"
  GEXP="$(printf '%s\n' "$GS" | sed -n 3p)"
  [ -n "$GTOKEN" ] || { echo "quota.sh: not signed in to Grok — run 'grok' and sign in if prompted" >&2; exit 1; }
  # A stored-but-stale token is not a sign-out: the CLI refreshes it on its
  # next run, so say that instead of sending a request that will 401.
  if [ -n "$GEXP" ] && ! python3 -c 'import sys,time,datetime
try:
    t = datetime.datetime.fromisoformat(sys.argv[1].replace("Z", "+00:00")).timestamp()
except Exception:
    sys.exit(0)          # unparseable expiry: let the request decide
sys.exit(0 if t - time.time() > 300 else 1)' "$GEXP"; then
    echo "quota.sh: Grok sign-in expired — run 'grok' once on this machine to refresh it (no chat message needed)" >&2
    exit 1
  fi
  # The CLI-proxy rejects requests that do not look like the Grok CLI.
  HEADERS="$(printf 'header = "Authorization: Bearer %s"\nheader = "X-XAI-Token-Auth: xai-grok-cli"\n' "$GTOKEN")"
  [ -z "$GUSER" ] || HEADERS="$HEADERS$(printf 'header = "x-userid: %s"\n' "$GUSER")"
  # Both views are fetched up front: the credits view carries the weekly
  # percent, and unified-billing accounts expose a monthly included budget
  # only in the default view.
  URLS=("$BASE/billing?format=credits" "$BASE/billing")
  ;;
esac

# ---- transport -------------------------------------------------------------
# One GET. First stdout line is "OK <http code>" or "ERR <why>", the rest is
# the body — a status channel that survives the command substitution. The
# credential rides curl's stdin as a config file (-K -) so it never shows up
# in a process listing, an output file, or this script's argv.
fetch() {
  local out rc
  set +e
  out="$(printf '%s\n' "$HEADERS" | curl -sS --max-time 30 -K - -H 'Accept: application/json' \
         -w '\n%{http_code}' "$1")"
  rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    printf 'ERR network failure (curl exit %s)\n' "$rc"
    return 0
  fi
  printf 'OK %s\n%s' "${out##*$'\n'}" "${out%$'\n'*}"
}

primary_resp="$(fetch "${URLS[0]}")"
primary_status="${primary_resp%%$'\n'*}"
case "$primary_status" in
  "OK "*) P_HTTP="${primary_status#OK }"; P_BODY="${primary_resp#*$'\n'}" ;;
  *)      echo "quota.sh: quota endpoint ${primary_status#ERR }" >&2; exit 2 ;;
esac

# The second call is decoration on both providers — plan identity on zai, the
# monthly fallback on grok. A failure here degrades to a note; the primary
# numbers still print, because they are the load-bearing part.
second_resp="$(fetch "${URLS[1]}")"
second_status="${second_resp%%$'\n'*}"
case "$second_status" in
  "OK "*) S_HTTP="${second_status#OK }"; S_BODY="${second_resp#*$'\n'}"; S_NOTE="" ;;
  *)      S_HTTP=""; S_BODY=""; S_NOTE="${second_status#ERR }" ;;
esac

exec python3 - "$PROVIDER" "$MODE" "$QUIET" "$REQUIRE" "$P_HTTP" "$P_BODY" \
                "$S_HTTP" "$S_NOTE" "$S_BODY" <<'PY'
import json, sys
from datetime import datetime, timezone

(provider, mode, quiet, require, p_http, p_body,
 s_http, s_note, s_body) = sys.argv[1:10]


def fail(msg):
    sys.stderr.write("quota.sh: %s\n" % msg)
    sys.exit(2)


def load(body, http, what):
    try:
        return json.loads(body)
    except Exception:
        fail("%s returned a non-JSON body (HTTP %s)" % (what, http))


def as_int(x, default):
    try:
        return int(x)
    except (TypeError, ValueError):
        return default


def as_float(x):
    if isinstance(x, bool) or not isinstance(x, (int, float)):
        return None
    return float(x)


def as_money(v):
    # Grok's money values arrive as {"val": …} where val is a number on some
    # accounts and a decimal string on others — reject one and the monthly
    # budget silently disappears.
    if not isinstance(v, dict):
        return None
    raw = v.get("val")
    if isinstance(raw, bool):
        return None
    if isinstance(raw, (int, float)):
        return float(raw)
    if isinstance(raw, str):
        try:
            return float(raw.strip())
        except ValueError:
            return None
    return None


def parse_iso(s):
    if not isinstance(s, str) or not s:
        return None
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp() * 1000.0
    except Exception:
        return None


now = datetime.now(timezone.utc)


def window(label, ms, percentage, allowance=None, consumed=None, remaining=None,
           unit=None, number=None):
    # percentage is consumed %; remainingPercent is what --require-window
    # gates on. Prefer real counts when the provider gives them, because
    # 91 vs 90.8 is the difference between a report and a gate agreeing.
    if allowance:
        remaining_pct = round(100.0 * (remaining or 0) / allowance, 1)
    elif percentage is not None:
        remaining_pct = round(100.0 - percentage, 1)
    else:
        remaining_pct = 100.0
    ms = as_int(ms, 0)
    return {
        "label": label,
        "unit": unit,
        "number": number,
        "allowance": allowance,
        "consumed": consumed,
        "remaining": remaining,
        "percentage": percentage,
        "remainingPercent": remaining_pct,
        "nextResetTime": ms,
        "nextResetTimeIso": datetime.fromtimestamp(ms / 1000.0, timezone.utc)
                                    .strftime("%Y-%m-%dT%H:%M:%SZ") if ms else None,
        "_hhmm": datetime.fromtimestamp(ms / 1000.0).strftime("%H:%M") if ms else "?",
        "_rel": relative(ms),
    }


def relative(ms):
    if not ms:
        return "reset time unknown"
    delta = ms / 1000.0 - now.timestamp()
    if delta <= 0:
        return "now"  # defensive: a live rolling window always resets ahead
    return "in %dh %dm" % (int(delta // 3600), int(delta % 3600 // 60))


sub = {"productName": None, "status": None, "valid": None, "error": None}
identity_note = ""
level = None
windows = []

if provider == "zai":
    # C2: this endpoint reports auth failure as HTTP 200 + success:false, so
    # the body — not the status line — decides success.
    q = load(p_body, p_http, "quota endpoint")
    if p_http != "200":
        fail("quota endpoint answered HTTP %s, expected 200" % p_http)
    if q.get("success") is not True or q.get("code") != 200:
        fail("quota endpoint reported failure: %s (code %s, HTTP %s)"
             % (q.get("msg") or "(no msg)", q.get("code"), p_http))

    data = q.get("data") or {}
    level = data.get("level")
    limits = data.get("limits")
    if not isinstance(limits, list) or not limits:
        fail("quota response carried no windows in data.limits[] (HTTP %s)" % p_http)

    # Window-length units. 3 ~ hour and 6 ~ week are INFERRED from the plan's
    # advertised 5-hour/weekly windows matching the two observed rows (two
    # live samples, 2026-08-16) — so an unknown unit degrades to its raw
    # number/unit pair, never a guess. Second tuple element is the unit's
    # length in seconds; it orders the windows shortest-first.
    UNITS = {3: ("h", 3600), 6: ("w", 604800)}

    def label_of(w):
        known = UNITS.get(as_int(w.get("unit"), -1))
        number = w.get("number")
        if known and isinstance(number, (int, float)) and not isinstance(number, bool):
            return "%s%s" % (number, known[0])
        return "number=%s,unit=%s" % (number, w.get("unit"))

    def sort_key(w):  # shortest window first; unknown units after known ones
        known = UNITS.get(as_int(w.get("unit"), -1))
        reset = as_int(w.get("nextResetTime"), 0)
        if known:
            return (0, as_int(w.get("number"), 0) * known[1], reset)
        return (1, 0, reset)

    for w in sorted(limits, key=sort_key):
        windows.append(window(
            label_of(w), w.get("nextResetTime"), w.get("percentage"),
            allowance=w.get("usage") or 0, consumed=w.get("currentValue"),
            remaining=w.get("remaining") or 0,
            unit=w.get("unit"), number=w.get("number")))

    # Plan identity: every failure mode becomes a note, never an abort.
    if not s_note:
        try:
            s = json.loads(s_body)
            if s_http != "200":
                s_note = "HTTP %s" % s_http
            elif s.get("success") is not True or s.get("code") != 200:
                s_note = "API error: %s (code %s)" % (s.get("msg") or "(no msg)", s.get("code"))
            elif isinstance(s.get("data"), list) and s["data"]:
                # First entry; no selector semantics are known for this list.
                e = s["data"][0]
                sub.update({"productName": e.get("productName"),
                            "status": e.get("status"), "valid": e.get("valid")})
            else:
                s_note = "no entries in data[]"
        except Exception:
            s_note = "non-JSON body (HTTP %s)" % (s_http or "?")

else:  # grok
    # This proxy uses the HTTP status honestly (401/403 on a bad token), so
    # unlike z.ai there is no success flag in the body to second-guess it.
    if p_http in ("401", "403"):
        fail("Grok billing rejected the CLI token (HTTP %s) — run 'grok' once to refresh it" % p_http)
    if p_http != "200":
        fail("Grok billing answered HTTP %s, expected 200" % p_http)
    b = load(p_body, p_http, "Grok billing")
    cfg = b.get("config") if isinstance(b.get("config"), dict) else b
    if not isinstance(cfg, dict):
        fail("Grok billing response carried no config object (HTTP %s)" % p_http)

    tier = cfg.get("subscriptionTier")
    if isinstance(tier, str) and tier.strip():
        sub["productName"] = tier.strip()
    else:
        # Kept out of s_note: that variable means "the second fetch failed",
        # and the monthly fallback below is gated on it. Folding a cosmetic
        # note into it silently disabled the fallback for every account
        # whose billing API omits the tier.
        identity_note = "plan tier not reported by the billing API"

    period = cfg.get("currentPeriod") if isinstance(cfg.get("currentPeriod"), dict) else {}
    period_end = period.get("end") or cfg.get("billingPeriodEnd")

    pct = as_float(cfg.get("creditUsagePercent"))
    if pct is None:
        # Grok omits creditUsagePercent when it is exactly zero (a protobuf
        # zero value is not serialized). Matching billing bounds identify
        # that case unambiguously — otherwise a fresh week reads as "no
        # quota data" instead of "nothing used yet".
        same = (period.get("type") == "USAGE_PERIOD_TYPE_WEEKLY"
                and parse_iso(period.get("start")) == parse_iso(cfg.get("billingPeriodStart"))
                and parse_iso(period.get("end")) == parse_iso(cfg.get("billingPeriodEnd")))
        if same:
            pct = 0.0
    if pct is not None:
        windows.append(window("1w", parse_iso(period_end), round(pct, 1)))

    # Unified-billing accounts expose only a monthly included budget, which
    # the credits view omits; it lives in the default view fetched alongside.
    if not windows and not s_note:
        try:
            d2 = json.loads(s_body)
            c2 = d2.get("config") if isinstance(d2.get("config"), dict) else d2
            limit = as_money(c2.get("monthlyLimit"))
            used = as_money(c2.get("used"))
            if limit and limit > 0 and used is not None:
                p2 = c2.get("currentPeriod") if isinstance(c2.get("currentPeriod"), dict) else {}
                windows.append(window("1mo", parse_iso(p2.get("end") or c2.get("billingPeriodEnd")),
                                      round(100.0 * used / limit, 1)))
        except Exception:
            pass

    if not windows:
        fail("Grok billing reported no credit usage for this account "
             "(no weekly credits and no monthly included budget)")

# s_note is a fetch failure; identity_note is a cosmetic gap. Either
# explains an absent plan name, so report whichever we have.
if s_note or identity_note:
    sub["error"] = s_note or identity_note

# The pre-flight gate keys on the *tightest* window, not the shortest one.
# Measured 2026-08-16: the weekly window sat at 81.7% remaining while the
# 5-hour one sat at 83.8% — keying on the shortest would have cleared a
# round that the weekly allowance is the one to actually stop. Whichever
# window has the least headroom is the constraint that ends the round.
tightest = min(windows, key=lambda w: w["remainingPercent"])
gated = bool(require) and tightest["remainingPercent"] < float(require)
if gated:
    w = tightest
    sys.stderr.write("quota.sh: tightest window %s has %s%% remaining, below the %s%% floor; resets at %s (%s)\n"
                     % (w["label"], w["remainingPercent"], require, w["_hhmm"], w["_rel"]))

if quiet != "1":
    if mode == "json":
        print(json.dumps({
            "fetchedAt": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
            "provider": provider,
            "level": level,
            "subscription": sub,
            "windows": [{k: v for k, v in w.items() if not k.startswith("_")} for w in windows],
        }, separators=(",", ":")))
    else:
        head = "z.ai coding plan" if provider == "zai" else "Grok CLI plan"
        if level:
            head += ": level %s" % level
        if sub["productName"] and sub["status"]:
            print("%s — %s (status %s, valid %s)"
                  % (head, sub["productName"], sub["status"], sub["valid"]))
        elif sub["productName"]:
            print("%s — %s" % (head, sub["productName"]))
        else:
            print("%s — plan identity unavailable (%s)" % (head, sub["error"]))
        for w in windows:
            pct = w["percentage"] if w["percentage"] is not None else "?"
            if w["allowance"]:
                counts = "%s/%s consumed, %s remaining, " % (
                    w["consumed"], w["allowance"], w["remaining"])
            else:
                # grok reports a percentage only — say so rather than
                # printing zeros that would read as "nothing left".
                counts = "exact counts not exposed by this API, "
            # "left" is the same computed figure the gate compares against,
            # not 100 minus the API's rounded integer — otherwise a report
            # reading "84% left" contradicts a gate that tripped at 83.8.
            print("%s window: %s%s%% used / %s%% left, resets at %s (%s)%s"
                  % (w["label"], counts, pct, w["remainingPercent"],
                     w["_hhmm"], w["_rel"],
                     "  <- tightest" if w is tightest and len(windows) > 1 else ""))

sys.exit(3 if gated else 0)
PY

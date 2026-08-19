package quota

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// ---- zai -------------------------------------------------------------------

// unitInfo maps z.ai's window-length units. 3 ~ hour and 6 ~ week are INFERRED
// from the plan's advertised 5-hour/weekly windows matching the two observed
// rows (two live samples, 2026-08-16) — so an unknown unit degrades to its raw
// number/unit pair, never a guess. The seconds value orders windows
// shortest-first.
var unitInfo = map[int64]struct {
	suffix  string
	seconds int64
}{
	3: {"h", 3600},
	6: {"w", 604800},
}

func fetchZai(now time.Time) (*Report, error) {
	base := os.Getenv("ZAI_QUOTA_BASE")
	if base == "" {
		// The monitor endpoints hang off the same host that serves the account —
		// api.z.ai for the global coding plan, open.bigmodel.cn for the mainland
		// one — so the host comes from credential.sh rather than being assumed.
		b, err := credential("zai", "--base-url", "https://api.z.ai")
		if err != nil || b == "" {
			return nil, errNoCredential
		}
		base = b
	}
	// ZAI_QUOTA_KEY / ZAI_QUOTA_BASE are test hooks for this tool's own
	// verification, not part of the CLI surface.
	key := os.Getenv("ZAI_QUOTA_KEY")
	if key == "" {
		k, err := credential("zai")
		if err != nil || k == "" {
			return nil, errNoCredential // credential.sh already said where it looked
		}
		key = k
	}
	headers := map[string]string{"Authorization": "Bearer " + key}

	primary := get(base+"/api/monitor/usage/quota/limit", headers)
	if primary.err != nil {
		return nil, fail("quota endpoint network failure (%v)", primary.err)
	}
	var q map[string]any
	if decodeJSON(primary.body, &q) != nil {
		return nil, fail("quota endpoint returned a non-JSON body (HTTP %d)", primary.status)
	}
	if primary.status != 200 {
		return nil, fail("quota endpoint answered HTTP %d, expected 200", primary.status)
	}
	// This endpoint reports auth failure as HTTP 200 + success:false, so the
	// body — not the status line — decides success.
	code, _ := asInt(q["code"])
	if ok, _ := q["success"].(bool); !ok || code != 200 {
		msg := "(no msg)"
		if s, ok := q["msg"].(string); ok && s != "" {
			msg = s
		}
		return nil, fail("quota endpoint reported failure: %s (code %v, HTTP %d)", msg, jsonNum(q["code"]), primary.status)
	}

	rep := &Report{Provider: "zai", FetchedAt: now.UTC().Format("2006-01-02T15:04:05Z")}
	data, _ := q["data"].(map[string]any)
	if lvl, ok := data["level"].(string); ok {
		rep.Level = strPtr(lvl)
	}
	rawLimits, _ := data["limits"].([]any)
	if len(rawLimits) == 0 {
		return nil, fail("quota response carried no windows in data.limits[] (HTTP %d)", primary.status)
	}

	type row struct {
		m      map[string]any
		unit   int64
		unitOK bool
		number float64
		numOK  bool
		reset  int64
	}
	rows := make([]row, 0, len(rawLimits))
	for _, r := range rawLimits {
		m, ok := r.(map[string]any)
		if !ok {
			continue
		}
		u, uok := asInt(m["unit"])
		n, nok := asFloat(m["number"])
		reset, _ := asInt(m["nextResetTime"])
		rows = append(rows, row{m: m, unit: u, unitOK: uok, number: n, numOK: nok, reset: reset})
	}
	// Shortest window first; unknown units after known ones.
	sort.SliceStable(rows, func(i, j int) bool {
		ki, oki := unitInfo[rows[i].unit]
		kj, okj := unitInfo[rows[j].unit]
		gi, gj := 1, 1
		var li, lj int64
		if oki && rows[i].unitOK {
			gi, li = 0, int64(rows[i].number)*ki.seconds
		}
		if okj && rows[j].unitOK {
			gj, lj = 0, int64(rows[j].number)*kj.seconds
		}
		if gi != gj {
			return gi < gj
		}
		if li != lj {
			return li < lj
		}
		return rows[i].reset < rows[j].reset
	})

	for _, r := range rows {
		label := fmt.Sprintf("number=%v,unit=%v", jsonNum(r.m["number"]), jsonNum(r.m["unit"]))
		if info, ok := unitInfo[r.unit]; ok && r.unitOK && r.numOK {
			label = fmt.Sprintf("%s%s", trimFloat(r.number), info.suffix)
		}
		// Measured 2026-08-16 from two live captures minutes apart: usage = the
		// window's allowance, currentValue = consumed, remaining = left,
		// percentage = consumed %, nextResetTime = epoch milliseconds.
		allowance, _ := asInt(r.m["usage"])
		consumed, cok := asInt(r.m["currentValue"])
		remaining, _ := asInt(r.m["remaining"])
		var pct *pyNum
		if n, ok := asNumber(r.m["percentage"]); ok {
			pct = pyPtr(n)
		}
		var unitP *int64
		if r.unitOK {
			u := r.unit
			unitP = &u
		}
		var numP *pyNum
		if n, ok := asNumber(r.m["number"]); ok && r.numOK {
			numP = pyPtr(n)
		}
		var consP *int64
		if cok {
			c := consumed
			consP = &c
		}
		rep.Windows = append(rep.Windows, newWindow(label, r.reset, pct,
			&allowance, consP, &remaining, unitP, numP, now))
	}

	// Plan identity: every failure mode becomes a note, never an abort.
	second := get(base+"/api/biz/subscription/list", headers)
	note := ""
	switch {
	case second.err != nil:
		note = fmt.Sprintf("network failure (%v)", second.err)
	default:
		var s map[string]any
		if decodeJSON(second.body, &s) != nil {
			note = fmt.Sprintf("non-JSON body (HTTP %d)", second.status)
		} else if second.status != 200 {
			note = fmt.Sprintf("HTTP %d", second.status)
		} else if code, _ := asInt(s["code"]); func() bool { ok, _ := s["success"].(bool); return !ok }() || code != 200 {
			msg := "(no msg)"
			if m, ok := s["msg"].(string); ok && m != "" {
				msg = m
			}
			note = fmt.Sprintf("API error: %s (code %v)", msg, jsonNum(s["code"]))
		} else if arr, ok := s["data"].([]any); ok && len(arr) > 0 {
			// First entry; no selector semantics are known for this list.
			if e, ok := arr[0].(map[string]any); ok {
				if v, ok := e["productName"].(string); ok {
					rep.Subscription.ProductName = strPtr(v)
				}
				if v, ok := e["status"].(string); ok {
					rep.Subscription.Status = strPtr(v)
				}
				if v, ok := e["valid"].(string); ok {
					rep.Subscription.Valid = strPtr(v)
				}
			}
		} else {
			note = "no entries in data[]"
		}
	}
	if note != "" {
		rep.Subscription.Error = strPtr(note)
	}
	return rep, nil
}

// ---- grok ------------------------------------------------------------------

// grokSession reads the OAuth session the Grok CLI stores, keyed by issuer.
// Prefer the default xAI issuer (bare or "issuer::<id>"); alternate issuers are a
// compatibility fallback only when no default entry exists. The auth file also
// holds the account's email and user id; only the token and user id are read,
// and neither is ever printed.
func grokSession() (token, userID, expires string) {
	home := os.Getenv("GROK_HOME")
	if home == "" {
		h, err := os.UserHomeDir()
		if err != nil {
			return "", "", ""
		}
		home = filepath.Join(h, ".grok")
	}
	b, err := os.ReadFile(filepath.Join(home, "auth.json"))
	if err != nil {
		return "", "", ""
	}
	var d map[string]map[string]any
	if json.Unmarshal(b, &d) != nil {
		return "", "", ""
	}
	const pref = "https://auth.x.ai"
	var preferred, fallback map[string]any
	keys := make([]string, 0, len(d))
	for k := range d {
		keys = append(keys, k)
	}
	sort.Strings(keys) // stable choice of fallback, unlike map order
	for _, k := range keys {
		e := d[k]
		if s, ok := e["key"].(string); !ok || s == "" {
			continue
		}
		if k == pref || strings.HasPrefix(k, pref+"::") {
			if preferred == nil {
				preferred = e
			}
		} else if fallback == nil {
			fallback = e
		}
	}
	e := preferred
	if e == nil {
		e = fallback
	}
	if e == nil {
		return "", "", ""
	}
	token, _ = e["key"].(string)
	userID, _ = e["user_id"].(string)
	expires, _ = e["expires_at"].(string)
	return token, userID, expires
}

func fetchGrok(now time.Time) (*Report, error) {
	base := os.Getenv("GROK_QUOTA_BASE")
	if base == "" {
		base = "https://cli-chat-proxy.grok.com/v1"
	}
	token, userID, expires := grokSession()
	if token == "" {
		return nil, sessionError{"quota: not signed in to Grok — run 'grok' and sign in if prompted"}
	}
	// A stored-but-stale token is not a sign-out: the CLI refreshes it on its next
	// run, so say that instead of sending a request that will 401. An unparseable
	// expiry lets the request decide.
	if expires != "" {
		if ms, ok := parseISOMillis(expires); ok {
			if time.UnixMilli(int64(ms)).Sub(now) <= 300*time.Second {
				return nil, sessionError{"quota: Grok sign-in expired — run 'grok' once on this machine to refresh it (no chat message needed)"}
			}
		}
	}
	headers := map[string]string{
		"Authorization": "Bearer " + token,
		// The CLI-proxy rejects requests that do not look like the Grok CLI.
		"X-XAI-Token-Auth": "xai-grok-cli",
	}
	if userID != "" {
		headers["x-userid"] = userID
	}

	primary := get(base+"/billing?format=credits", headers)
	if primary.err != nil {
		return nil, fail("Grok billing network failure (%v)", primary.err)
	}
	// This proxy uses the HTTP status honestly (401/403 on a bad token), so unlike
	// z.ai there is no success flag in the body to second-guess it.
	if primary.status == 401 || primary.status == 403 {
		return nil, fail("Grok billing rejected the CLI token (HTTP %d) — run 'grok' once to refresh it", primary.status)
	}
	if primary.status != 200 {
		return nil, fail("Grok billing answered HTTP %d, expected 200", primary.status)
	}
	var b map[string]any
	if decodeJSON(primary.body, &b) != nil {
		return nil, fail("Grok billing returned a non-JSON body (HTTP %d)", primary.status)
	}
	cfg, ok := b["config"].(map[string]any)
	if !ok {
		cfg = b
	}
	if cfg == nil {
		return nil, fail("Grok billing response carried no config object (HTTP %d)", primary.status)
	}

	rep := &Report{Provider: "grok", FetchedAt: now.UTC().Format("2006-01-02T15:04:05Z")}
	identityNote := ""
	if tier, ok := cfg["subscriptionTier"].(string); ok && strings.TrimSpace(tier) != "" {
		rep.Subscription.ProductName = strPtr(strings.TrimSpace(tier))
	} else {
		// Kept out of the fetch-failure note: that one gates the monthly fallback
		// below, and folding a cosmetic gap into it silently disabled the fallback
		// for every account whose billing API omits the tier.
		identityNote = "plan tier not reported by the billing API"
	}

	period, _ := cfg["currentPeriod"].(map[string]any)
	periodEnd := period["end"]
	if periodEnd == nil {
		periodEnd = cfg["billingPeriodEnd"]
	}
	var pct *float64
	if f, ok := asFloat(cfg["creditUsagePercent"]); ok {
		pct = &f
	} else {
		// Grok omits creditUsagePercent when it is exactly zero (a protobuf zero
		// value is not serialized). Matching billing bounds identify that case
		// unambiguously — otherwise a fresh week reads as "no quota data" instead
		// of "nothing used yet".
		ps, pok := parseISOMillis(period["start"])
		bs, bok := parseISOMillis(cfg["billingPeriodStart"])
		pe, peok := parseISOMillis(period["end"])
		be, beok := parseISOMillis(cfg["billingPeriodEnd"])
		if t, _ := period["type"].(string); t == "USAGE_PERIOD_TYPE_WEEKLY" &&
			pok && bok && peok && beok && ps == bs && pe == be {
			z := 0.0
			pct = &z
		}
	}
	if pct != nil {
		ms, _ := parseISOMillis(periodEnd)
		rep.Windows = append(rep.Windows, newWindow("1w", int64(ms), pyPtr(computed1(round1(*pct))), nil, nil, nil, nil, nil, now))
	}

	// Unified-billing accounts expose only a monthly included budget, which the
	// credits view omits; it lives in the default view fetched alongside.
	fetchNote := ""
	if len(rep.Windows) == 0 {
		second := get(base+"/billing", headers)
		if second.err != nil {
			fetchNote = fmt.Sprintf("network failure (%v)", second.err)
		} else {
			var d2 map[string]any
			if decodeJSON(second.body, &d2) == nil {
				c2, ok := d2["config"].(map[string]any)
				if !ok {
					c2 = d2
				}
				limit, lok := asMoney(c2["monthlyLimit"])
				used, uok := asMoney(c2["used"])
				if lok && uok && limit > 0 {
					p2, _ := c2["currentPeriod"].(map[string]any)
					end := p2["end"]
					if end == nil {
						end = c2["billingPeriodEnd"]
					}
					ms, _ := parseISOMillis(end)
					rep.Windows = append(rep.Windows, newWindow("1mo", int64(ms),
						pyPtr(computed1(round1(100.0*used/limit))), nil, nil, nil, nil, nil, now))
				}
			}
		}
	}
	if len(rep.Windows) == 0 {
		return nil, fail("Grok billing reported no credit usage for this account (no weekly credits and no monthly included budget)")
	}
	// A fetch failure and a cosmetic gap both explain an absent plan name, so
	// report whichever we have.
	if fetchNote != "" {
		rep.Subscription.Error = strPtr(fetchNote)
	} else if identityNote != "" {
		rep.Subscription.Error = strPtr(identityNote)
	}
	return rep, nil
}

// sessionError is "no usable credential" with a specific reason worth printing.
type sessionError struct{ msg string }

func (s sessionError) Error() string { return s.msg }

// jsonNum renders a decoded JSON number the way Python's str() would, so
// diagnostic text matches: 200 not 200.0.
func jsonNum(v any) string {
	switch t := v.(type) {
	case nil:
		return "None"
	case float64:
		return trimFloat(t)
	case string:
		return t
	case bool:
		if t {
			return "True"
		}
		return "False"
	}
	return fmt.Sprintf("%v", v)
}

func trimFloat(f float64) string {
	if f == float64(int64(f)) {
		return strconvI(int64(f))
	}
	return strings.TrimRight(strings.TrimRight(fmt.Sprintf("%f", f), "0"), ".")
}

func strconvI(i int64) string { return fmt.Sprintf("%d", i) }

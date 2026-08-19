package quota

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// TestPyNumRemembersHowPythonWouldPrintIt is the seam that mattered most, and it
// was caught by eye on a live smoke test rather than by a test — the first draft
// printed "89% used / 11% left" where the shell said "89.0% / 11.0%", because
// Python's str() keeps a float's decimal and drops an int's. The difference
// reached the --json shape too, so a consumer parsing it would have seen a
// different type.
func TestPyNumRemembersHowPythonWouldPrintIt(t *testing.T) {
	for _, c := range []struct{ token, want string }{
		{"23", "23"},     // an int from the API stays an int
		{"23.5", "23.5"}, // a float keeps its own precision
		{"0", "0"},
		{"78", "78"},
	} {
		got := fromToken(json.Number(c.token))
		if got.String() != c.want {
			t.Errorf("fromToken(%q) = %q, want %q", c.token, got, c.want)
		}
		b, _ := json.Marshal(got)
		if string(b) != c.want {
			t.Errorf("json of %q = %s, want %s", c.token, b, c.want)
		}
	}
	// A computed percentage is always a float, so it always shows a decimal.
	for _, c := range []struct {
		in   float64
		want string
	}{{12, "12.0"}, {76.9, "76.9"}, {100, "100.0"}, {0, "0.0"}, {21.1, "21.1"}} {
		if got := computed1(c.in); got.String() != c.want {
			t.Errorf("computed1(%v) = %q, want %q", c.in, got, c.want)
		}
	}
}

func TestRemainingPercentPrefersRealCounts(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	// With counts, the figure comes from them: 91 vs 90.8 is the difference
	// between a report and a gate agreeing.
	al, cons, rem := int64(28000), int64(6471), int64(21529)
	w := newWindow("5h", 0, pyPtr(fromToken("23")), &al, &cons, &rem, nil, nil, now)
	if w.RemainingPercent.String() != "76.9" {
		t.Errorf("from counts = %q, want 76.9", w.RemainingPercent)
	}
	// Without counts, from the percentage.
	w = newWindow("1w", 0, pyPtr(computed1(88.0)), nil, nil, nil, nil, nil, now)
	if w.RemainingPercent.String() != "12.0" {
		t.Errorf("from percentage = %q, want 12.0", w.RemainingPercent)
	}
	// With neither, a full window rather than an empty one — never report a
	// missing measurement as exhausted.
	w = newWindow("1w", 0, nil, nil, nil, nil, nil, nil, now)
	if w.RemainingPercent.String() != "100.0" {
		t.Errorf("from nothing = %q, want 100.0", w.RemainingPercent)
	}
}

func TestRelativeAndResetRendering(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	if got := relative(0, now); got != "reset time unknown" {
		t.Errorf("no reset = %q", got)
	}
	// Defensive: a live rolling window always resets ahead, so a past reset is a
	// clock problem, not a negative countdown.
	if got := relative(now.Add(-time.Hour).UnixMilli(), now); got != "now" {
		t.Errorf("past reset = %q, want now", got)
	}
	if got := relative(now.Add(2*time.Hour+18*time.Minute).UnixMilli(), now); got != "in 2h 18m" {
		t.Errorf("future reset = %q", got)
	}
	w := newWindow("5h", now.Add(time.Hour).UnixMilli(), nil, nil, nil, nil, nil, nil, now)
	if w.NextResetTimeIso == nil {
		t.Fatal("a reset time must produce an ISO string")
	}
}

func TestAsMoneyAcceptsBothShapes(t *testing.T) {
	// Grok's money values arrive as {"val": …} where val is a number on some
	// accounts and a decimal string on others — reject one and the monthly budget
	// silently disappears.
	for _, raw := range []string{`{"val":25}`, `{"val":"25"}`, `{"val":"25.0"}`, `{"val":25.0}`} {
		var m map[string]any
		if err := decodeJSON([]byte(`{"x":`+raw+`}`), &m); err != nil {
			t.Fatal(err)
		}
		if f, ok := asMoney(m["x"]); !ok || f != 25 {
			t.Errorf("asMoney(%s) = %v, %v; want 25, true", raw, f, ok)
		}
	}
	for _, raw := range []string{`{"val":null}`, `{"val":"abc"}`, `{}`, `5`, `"x"`} {
		var m map[string]any
		_ = decodeJSON([]byte(`{"x":`+raw+`}`), &m)
		if _, ok := asMoney(m["x"]); ok {
			t.Errorf("asMoney(%s) must fail", raw)
		}
	}
}

func TestGrokSessionPrefersDefaultIssuer(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("GROK_HOME", dir)
	write := func(s string) {
		if err := os.WriteFile(filepath.Join(dir, "auth.json"), []byte(s), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	// The default xAI issuer wins over an alternate one, whichever order they
	// appear in — map iteration order must not decide which token is used.
	write(`{"https://other.example":{"key":"alt"},"https://auth.x.ai":{"key":"pref","user_id":"u1"}}`)
	if tok, uid, _ := grokSession(); tok != "pref" || uid != "u1" {
		t.Errorf("got %q/%q, want pref/u1", tok, uid)
	}
	// An issuer-scoped default still counts as the default.
	write(`{"https://auth.x.ai::acct-2":{"key":"scoped"}}`)
	if tok, _, _ := grokSession(); tok != "scoped" {
		t.Errorf("scoped issuer = %q", tok)
	}
	// Alternates are a compatibility fallback only.
	write(`{"https://other.example":{"key":"alt"}}`)
	if tok, _, _ := grokSession(); tok != "alt" {
		t.Errorf("fallback = %q", tok)
	}
	// An entry with no key is not a session.
	write(`{"https://auth.x.ai":{"user_id":"u"}}`)
	if tok, _, _ := grokSession(); tok != "" {
		t.Errorf("keyless entry = %q, want empty", tok)
	}
	for _, bad := range []string{`not json`, `[]`, `null`, ``} {
		write(bad)
		if tok, _, _ := grokSession(); tok != "" {
			t.Errorf("payload %q = %q, want empty", bad, tok)
		}
	}
}

func TestJSONNumRendersLikePythonStr(t *testing.T) {
	// These strings appear inside diagnostic messages compared against the shell.
	for _, c := range []struct {
		in   any
		want string
	}{{nil, "None"}, {json.Number("200"), "200"}, {json.Number("9"), "9"},
		{"msg", "msg"}, {true, "True"}, {false, "False"}} {
		if got := jsonNum(c.in); got != c.want {
			t.Errorf("jsonNum(%v) = %q, want %q", c.in, got, c.want)
		}
	}
}

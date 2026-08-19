package statusline

import (
	"bytes"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/midagedev/outsource/internal/human"
)

func TestUntilStrIsNotHumanSecs(t *testing.T) {
	// These two look like duplicates and must not be merged. A budget resetting
	// in 40 seconds is "0m" — a status line should not flicker through a
	// seconds countdown — while a round that has been running 40 seconds is
	// "40s". Pin the divergence so a future tidy-up cannot quietly unify them.
	if got, other := untilStr(40, 0), human.Secs(40); got != "0m" || other != "40s" {
		t.Errorf("untilStr(40)=%q human.Secs(40)=%q, want 0m / 40s", got, other)
	}
	for _, c := range []struct {
		in   int64
		want string
	}{
		{-10, "now"}, {0, "now"},
		{59, "0m"}, {60, "1m"}, {2100, "35m"},
		{3600, "1h00m"}, {12000, "3h20m"},
		{86400, "1d0h"}, {352800, "4d2h"},
	} {
		if got := untilStr(c.in, 0); got != c.want {
			t.Errorf("untilStr(%d) = %q, want %q", c.in, got, c.want)
		}
	}
}

func TestBudgetNeverRendersMissingDataAsZero(t *testing.T) {
	// The most expensive possible way to be wrong here is printing 0%, which
	// reads as "plenty left". Missing data produces no segment at all.
	if got := budget("5H", nil, nil, 0); got != "" {
		t.Errorf("budget with no percentage = %q, want empty", got)
	}
	p := 0.0
	if got := budget("5H", &p, nil, 0); !strings.Contains(got, "0%") {
		t.Errorf("a real zero must still render: %q", got)
	}
}

func TestPctColorBoundaries(t *testing.T) {
	for _, c := range []struct {
		in   float64
		want string
	}{
		{0, green}, {49, green}, {49.4, green},
		{49.5, yellow}, {50, yellow}, {79, yellow}, {79.4, yellow},
		{79.5, red}, {80, red}, {100, red},
	} {
		if got := pctColor(c.in); got != c.want {
			t.Errorf("pctColor(%v) wrong (rounds to %.0f)", c.in, c.in)
		}
	}
}

func TestModelShort(t *testing.T) {
	for in, want := range map[string]string{
		"Opus 5 (1M context)": "opus",
		"Claude Fable 5":      "fable",
		"Sonnet 4.5":          "sonnet",
		"Haiku 4.5":           "haiku",
		"claude-fable-5":      "fable",
		"Gizmo 9 Ultra":       "gizmo", // unknown family: first word, not a guess
		"":                    "",
	} {
		if got := modelShort(in); got != want {
			t.Errorf("modelShort(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestProvidersEnvSemantics(t *testing.T) {
	// Unset means the default pair; an explicitly EMPTY value disables the row.
	// Those are different things, which is why this reads LookupEnv.
	os.Unsetenv("OUTSOURCE_STATUSLINE_PROVIDERS")
	if got := providers(); len(got) != 2 || got[0] != "zai" || got[1] != "grok" {
		t.Errorf("unset = %v, want [zai grok]", got)
	}
	t.Setenv("OUTSOURCE_STATUSLINE_PROVIDERS", "")
	if got := providers(); len(got) != 0 {
		t.Errorf("empty = %v, want none", got)
	}
	t.Setenv("OUTSOURCE_STATUSLINE_PROVIDERS", "zai")
	if got := providers(); len(got) != 1 || got[0] != "zai" {
		t.Errorf("single = %v, want [zai]", got)
	}
}

func TestProviderPartDistinguishesNotYetFromNotConfigured(t *testing.T) {
	// Three states that must never look alike: no measurement yet ("…"), a
	// measurement that found no credential (silent), and a measurement too old
	// to trust (carried forward, marked "~"). The last rule was written after
	// shipping without it: an expired sign-in made the segment vanish,
	// reporting a backend that had just broken exactly like one never set up.
	dir := t.TempDir()
	t.Setenv("OUTSOURCE_STATUSLINE_CACHE", dir)
	now := int64(1_000_000)

	if got := providerPart("zai", now); !strings.Contains(got, "…") {
		t.Errorf("no cache must render …, got %q", got)
	}

	os.WriteFile(filepath.Join(dir, "zai.kv"), []byte("fetchedAt=999999\nerror=1\n"), 0o644)
	if got := providerPart("zai", now); got != "" {
		t.Errorf("errored cache with no number must be silent, got %q", got)
	}

	os.WriteFile(filepath.Join(dir, "zai.kv"),
		[]byte("fetchedAt=999999\nmeasuredAt=999990\npercentage=29\nresetEpoch=1000600\n"), 0o644)
	got := providerPart("zai", now)
	if !strings.Contains(got, "29%") || strings.Contains(got, "~") {
		t.Errorf("fresh measurement = %q, want 29%% and no stale mark", got)
	}

	os.WriteFile(filepath.Join(dir, "zai.kv"),
		[]byte("fetchedAt=999999\nmeasuredAt=1\npercentage=29\nresetEpoch=1000600\n"), 0o644)
	if got := providerPart("zai", now); !strings.Contains(got, "~") {
		t.Errorf("stale measurement must be marked ~, got %q", got)
	}
}

func TestRenderSurvivesGarbageAndNeverInventsNumbers(t *testing.T) {
	// The failure this pins: a session with no rate limits once shifted the
	// working directory into the context slot and printed it as a percentage.
	t.Setenv("OUTSOURCE_STATUSLINE_PROVIDERS", "")
	t.Setenv("OUTSOURCE_STATUSLINE_CACHE", t.TempDir())
	t.Setenv("OUTSOURCE_RUNS_DIR", filepath.Join(t.TempDir(), "runs"))
	t.Setenv("HOME", t.TempDir())

	for _, payload := range []string{
		`{not json`, ``, `{}`, `[]`, `null`,
		`{"model":{"display_name":"Opus"},"cwd":"/tmp/only-a-path"}`,
	} {
		var out bytes.Buffer
		if code := Render(strings.NewReader(payload), &out, "/nonexistent/quota.sh"); code != 0 {
			t.Errorf("payload %q: exit %d, want 0", payload, code)
		}
		if strings.Contains(out.String(), "CTX") {
			t.Errorf("payload %q rendered a context percentage it was never given: %q", payload, out.String())
		}
	}
}

func TestRenderRunsClaimsNothingWithoutIdentity(t *testing.T) {
	// An empty filter means "no filter" downstream, so a caller with no identity
	// must skip the call rather than pass empty flags — otherwise scoping
	// degrades to the whole machine, which is the bug it exists to prevent.
	t.Setenv("OUTSOURCE_RUNS_DIR", filepath.Join(t.TempDir(), "runs"))
	os.Unsetenv("CLAUDE_CODE_SESSION_ID")
	os.Unsetenv("CLAUDE_PID")
	os.Unsetenv("OUTSOURCE_STATUSLINE_SCOPE")
	if got := renderRuns(""); got != "" {
		t.Errorf("no identity must claim nothing, got %q", got)
	}
}

var _ = io.Discard

package telemetry

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// The privacy rule is the load-bearing property of this package, so it is the
// first test: flag NAMES are the signal, flag VALUES are not, and the only values
// recorded are from closed sets this repo defines.
func TestOnlyFlagNamesAndAllowlistedValues(t *testing.T) {
	args := []string{
		"--cwd", "/Users/someone/private/repo",
		"--spec", "/tmp/scratch/secret-plan.md",
		"--done-marker", "DONE-CONFIDENTIAL-PROJECT",
		"--harness", "crush",
		"--provider", "zai",
		"--model", "zai/glm-5.3",
		"--label", "acquisition-diligence",
		"--max-seconds", "600",
	}
	names, vals := flagNames(args)

	joined := strings.Join(names, " ")
	for k, v := range vals {
		joined += " " + k + "=" + v
	}
	for _, leak := range []string{
		"/Users/someone", "private", "secret-plan", "CONFIDENTIAL",
		"acquisition-diligence", "600",
	} {
		if strings.Contains(joined, leak) {
			t.Errorf("value leaked into telemetry: %q", leak)
		}
	}
	// The names must all be there — that is what makes the log useful.
	for _, want := range []string{"--cwd", "--spec", "--done-marker", "--label", "--max-seconds"} {
		found := false
		for _, n := range names {
			if n == want {
				found = true
			}
		}
		if !found {
			t.Errorf("flag name %q was not recorded", want)
		}
	}
	// Exactly the allowlist, and nothing else.
	if vals["harness"] != "crush" || vals["provider"] != "zai" {
		t.Errorf("allowlisted enums missing: %v", vals)
	}
	if _, ok := vals["model"]; ok {
		t.Error("--model is user-supplied and must not be recorded by value")
	}
	if len(vals) != 2 {
		t.Errorf("recorded %d values, want exactly the 2 allowlisted enums: %v", len(vals), vals)
	}
}

// A flag written as --k=v must still be reduced to its name.
func TestInlineValueIsStripped(t *testing.T) {
	names, vals := flagNames([]string{"--json-schema={\"secret\":1}", "--quiet"})
	for _, n := range names {
		if strings.Contains(n, "secret") || strings.Contains(n, "=") {
			t.Errorf("inline value survived: %q", n)
		}
	}
	if len(vals) != 0 {
		t.Errorf("no values should be recorded here: %v", vals)
	}
}

// The two high-frequency tools would bury the log and grow it by megabytes a day
// if their successes were recorded.
func TestHighFrequencyToolsRecordOnlyFailures(t *testing.T) {
	for _, tool := range []string{"guard", "statusline"} {
		if worthRecording(tool, 0) {
			t.Errorf("%s must not record a successful call", tool)
		}
		if !worthRecording(tool, 2) {
			t.Errorf("%s must record a failure", tool)
		}
	}
	if !worthRecording("outsource-run", 0) {
		t.Error("a launcher's successful round is worth a line")
	}
}

func TestDisabledByEnv(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "t.jsonl")
	t.Setenv("OUTSOURCE_TELEMETRY_FILE", path)
	t.Setenv("OUTSOURCE_TELEMETRY", "0")
	Record("runs", []string{"list"}, 0, time.Now())
	if _, err := os.Stat(path); err == nil {
		t.Error("OUTSOURCE_TELEMETRY=0 must write nothing at all")
	}
	t.Setenv("OUTSOURCE_TELEMETRY", "")
	Record("runs", []string{"list"}, 0, time.Now())
	if _, err := os.Stat(path); err != nil {
		t.Error("recording should be on by default")
	}
}

func TestRecordShapeAndFileMode(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "t.jsonl")
	t.Setenv("OUTSOURCE_TELEMETRY_FILE", path)
	t.Setenv("OUTSOURCE_TELEMETRY", "")
	Note("why", "a named reason")
	Record("outsource-run", []string{"--harness", "crush"}, 72, time.Now().Add(-2*time.Second))

	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var e Event
	if err := json.Unmarshal(b[:len(b)-1], &e); err != nil {
		t.Fatalf("each line must be one JSON object: %v", err)
	}
	if e.Tool != "outsource-run" || e.RC != 72 || e.Details["why"] != "a named reason" {
		t.Errorf("unexpected event: %+v", e)
	}
	if e.MS < 1900 {
		t.Errorf("duration not measured: %dms", e.MS)
	}
	// The log can hold a reason a user wrote, so it is theirs to read and nobody
	// else's.
	fi, _ := os.Stat(path)
	if fi.Mode().Perm() != 0o600 {
		t.Errorf("mode is %v, want 0600", fi.Mode().Perm())
	}
}

func TestRollKeepsOneGeneration(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "t.jsonl")
	big := make([]byte, maxBytes+1)
	os.WriteFile(path, big, 0o600)
	roll(path)
	if _, err := os.Stat(path + ".1"); err != nil {
		t.Error("an oversized log must roll aside, not be truncated")
	}
	if _, err := os.Stat(path); err == nil {
		t.Error("the live file should be gone after a roll, ready to be recreated")
	}
}

func TestMeaningFallsBackFromToolToCode(t *testing.T) {
	if m := meaning("guard", 2); !strings.Contains(m, "not allowed") {
		t.Errorf("tool-specific meaning missing: %q", m)
	}
	if m := meaning("outsource-run", 70); !strings.Contains(m, "model") {
		t.Errorf("shared code meaning missing: %q", m)
	}
	if m := meaning("runs", 999); m != "" {
		t.Errorf("an unknown code must not invent a meaning: %q", m)
	}
}

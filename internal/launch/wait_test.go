package launch

import (
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestWaitCollectsSentinelsAndRefusesMissingLogs(t *testing.T) {
	dir := t.TempDir()
	a := filepath.Join(dir, "a.ndjson")
	b := filepath.Join(dir, "b.ndjson")
	for _, l := range []string{a, b} {
		if err := os.WriteFile(l, []byte("{}\n"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(a+".rc", []byte("rc=0\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	go func() {
		time.Sleep(100 * time.Millisecond)
		_ = os.WriteFile(b+".rc", []byte("rc=1\n"), 0o644)
	}()
	var out strings.Builder
	if rc := WaitMain([]string{"--interval", "1", a, b}, &out, io.Discard); rc != 0 {
		t.Fatalf("rc = %d, want 0\n%s", rc, out.String())
	}
	if !strings.Contains(out.String(), "rc=0") || !strings.Contains(out.String(), "rc=1") {
		t.Fatalf("missing sentinel content:\n%s", out.String())
	}

	// A mistyped log path must refuse, not poll forever.
	if rc := WaitMain([]string{filepath.Join(dir, "nope.ndjson")}, io.Discard, io.Discard); rc != ExitUsage {
		t.Fatalf("missing log rc = %d, want %d", rc, ExitUsage)
	}

	// Timeout names the round still pending.
	c := filepath.Join(dir, "c.ndjson")
	if err := os.WriteFile(c, []byte("{}\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	var errb strings.Builder
	if rc := WaitMain([]string{"--interval", "1", "--timeout", "1", c}, io.Discard, &errb); rc != 124 {
		t.Fatalf("timeout rc = %d, want 124", rc)
	}
	if !strings.Contains(errb.String(), "c.ndjson") {
		t.Fatalf("timeout must name the pending round:\n%s", errb.String())
	}
}

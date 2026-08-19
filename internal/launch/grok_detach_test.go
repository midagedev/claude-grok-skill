package launch

import (
	"io"
	"os"
	"path/filepath"
	"testing"
)

// --detach must not swallow usage errors: everything checkable before the
// re-exec (here: a done-marker the spec never contains) still fails
// synchronously on the caller's terminal.
func TestDetachKeepsUsageErrorsSynchronous(t *testing.T) {
	dir := t.TempDir()
	spec := filepath.Join(dir, "spec.md")
	if err := os.WriteFile(spec, []byte("do the thing\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	// A fake grok on PATH so LookPath (which precedes the marker check) passes.
	fake := filepath.Join(dir, "grok")
	if err := os.WriteFile(fake, []byte("#!/bin/sh\nexit 0\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))

	rc := GrokMain([]string{
		"--detach",
		"--cwd", dir, "--spec", spec, "--log", filepath.Join(dir, "run.ndjson"),
		"--done-marker", "DONE-NEVER-IN-SPEC",
	}, io.Discard, io.Discard)
	if rc != ExitUsage {
		t.Fatalf("want ExitUsage (%d) before any detach, got %d", ExitUsage, rc)
	}
	if _, err := os.Stat(filepath.Join(dir, "run.ndjson.rc")); err == nil {
		t.Fatal("a refused launch must not write a sentinel")
	}
}

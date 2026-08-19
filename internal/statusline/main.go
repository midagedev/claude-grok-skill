package statusline

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
)

// Main is the statusline entry point.
//
// The --refresh dispatch comes before anything reads stdin, and that ordering
// is load-bearing: the refresher is this same program re-invoked, it inherits
// the caller's stdin, and reading stdin first would block it forever — holding
// the lock and leaving the number stuck at "…" for good. The shell version
// shipped with that bug once.
func Main(args []string, stdin io.Reader, stdout, stderr io.Writer) int {
	quotaSh := siblingScript("quota.sh")
	if len(args) >= 2 && args[0] == "--refresh" && args[1] != "" {
		if err := Refresh(args[1], quotaSh); err != nil {
			fmt.Fprintf(stderr, "statusline: refresh %s: %v\n", args[1], err)
			return 1
		}
		return 0
	}
	return Render(stdin, stdout, quotaSh)
}

// siblingScript resolves a tool that still lives beside the binary. During the
// port some tools are Go and some are still shell; this is the seam, and it
// disappears as each one moves.
func siblingScript(name string) string {
	exe, err := os.Executable()
	if err != nil {
		return name
	}
	return filepath.Join(filepath.Dir(exe), name)
}

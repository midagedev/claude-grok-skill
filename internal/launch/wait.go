package launch

import (
	"fmt"
	"io"
	"os"
	"strconv"
	"strings"
	"time"
)

// WaitMain blocks until every named round has written its <log>.rc sentinel,
// then prints each sentinel. Before it existed, every orchestrating session
// hand-wrote `while [ ! -f $log.rc ]; do sleep 30; done` per lane (measured
// 2026-08-20: six copies in one session) — and a typo'd path in that loop
// waits forever without saying why. Here a log whose directory does not
// exist is refused up front.
//
//	outsource wait [--interval N] [--timeout N] <log.ndjson>...
//
// Exit 0 when all sentinels exist; 124 on timeout (remaining rounds named);
// 64 on usage. Completion evidence stays the sentinel content — this tool
// only saves the caller the polling loop, it does not interpret rc values.
func WaitMain(args []string, stdout, stderr io.Writer) int {
	interval, timeout := 15*time.Second, time.Duration(0)
	var logs []string
	for i := 0; i < len(args); i++ {
		switch args[i] {
		case "--interval", "--timeout":
			if i+1 >= len(args) {
				fmt.Fprintf(stderr, "wait: %s needs seconds\n", args[i])
				return ExitUsage
			}
			n, err := strconv.Atoi(args[i+1])
			if err != nil || n <= 0 {
				fmt.Fprintf(stderr, "wait: %s needs positive seconds, got %q\n", args[i], args[i+1])
				return ExitUsage
			}
			if args[i] == "--interval" {
				interval = time.Duration(n) * time.Second
			} else {
				timeout = time.Duration(n) * time.Second
			}
			i++
		default:
			if strings.HasPrefix(args[i], "-") {
				fmt.Fprintf(stderr, "wait: unknown flag: %s\n", args[i])
				return ExitUsage
			}
			logs = append(logs, args[i])
		}
	}
	if len(logs) == 0 {
		fmt.Fprintln(stderr, "usage: outsource wait [--interval N] [--timeout N] <log.ndjson>...")
		return ExitUsage
	}
	for _, l := range logs {
		if fi, err := os.Stat(l); err != nil || fi.IsDir() {
			// The log itself must exist: a mistyped path would otherwise
			// poll forever for a sentinel no round will ever write.
			fmt.Fprintf(stderr, "wait: no such log: %s (the launcher creates it — check the path)\n", l)
			return ExitUsage
		}
	}
	deadline := time.Time{}
	if timeout > 0 {
		deadline = time.Now().Add(timeout)
	}
	pending := append([]string(nil), logs...)
	for {
		var still []string
		for _, l := range pending {
			if _, err := os.Stat(l + ".rc"); err != nil {
				still = append(still, l)
				continue
			}
			b, err := os.ReadFile(l + ".rc")
			if err != nil {
				still = append(still, l)
				continue
			}
			fmt.Fprintf(stdout, "== %s.rc\n%s", l, string(b))
		}
		pending = still
		if len(pending) == 0 {
			return 0
		}
		if !deadline.IsZero() && time.Now().After(deadline) {
			fmt.Fprintf(stderr, "wait: timed out; still running: %s\n", strings.Join(pending, " "))
			return 124
		}
		time.Sleep(interval)
	}
}

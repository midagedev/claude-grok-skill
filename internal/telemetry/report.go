package telemetry

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"sort"
	"strconv"
	"strings"
	"time"
)

// meanings turns an exit code back into the finding it represents. Without this
// the log is a column of numbers; with it, a count is a sentence about how rounds
// are being launched.
//
// Keyed by tool where a code means different things (2 is a guard block, but
// nothing special elsewhere), and by code alone where the vocabulary is shared.
// meanings turns an exit code back into the finding it represents. Without this
// the log is a column of numbers; with it, a count is a sentence about how rounds
// are being launched.
//
// Keyed by tool, ALMOST always. The first version had a `*/65`-style fallback for
// every code and it produced a report that lied: `runs` exit 65 is "no such run
// id", but the fallback labelled it "a spec that needs eyes was sent to a backend
// that has none", and 66 became a quota refusal. Different tools legitimately
// reuse small integers for different facts, so a shared label is only correct
// where the fact really is shared.
//
// 64 is the one genuinely universal code here — every tool means "usage" by it —
// so it keeps a fallback. Everything else must be spelled out per tool, and a
// pair with no entry prints no meaning at all rather than a borrowed one.
var meanings = map[string]string{
	"*/64": "the caller passed a flag or a contract the tool refused (usage)",

	"guard/2": "a delegate tried a git/gh command it is not allowed",

	"outsource-run/1":   "no usable credential for the provider",
	"outsource-run/65":  "a spec that needs eyes was sent to a backend that has none",
	"outsource-run/66":  "refused before launching: the plan could not finish the round",
	"outsource-run/69":  "the harness CLI is not on PATH",
	"outsource-run/70":  "the model that answered was not the one requested, or unverifiable",
	"outsource-run/72":  "the round ran and its completion marker never appeared",
	"outsource-run/124": "the round was killed by its own --max-seconds ceiling",

	"grok-run/66": "no such --cwd, or an unreadable --spec",
	"grok-run/69": "the grok CLI is not on PATH, or it produced no output at all",
	"grok-run/71": "the launcher exited without writing a sentinel (a bug in the launcher)",
	"grok-run/72": "the round ran and its completion marker never appeared",

	"runs/65": "no such run id",
	"runs/66": "refused: that round is still running, so it is work and not residue",

	"last-report/65": "a log held no report — the round died mid-run",
	"last-report/66": "the log file could not be read",

	"spec-lint/1": "a spec carried a wrong premise (findings)",
	"spec-lint/2": "the linter could not run: a bad --root, or an unreadable spec",

	"quota/1": "no usable credential for the provider",
	"quota/2": "the provider's endpoint failed, or answered something unreadable",
	"quota/3": "the plan is below the --require-window floor",

	"credential/1": "no key found for the provider, anywhere in the chain",

	"verify-key/1": "the provider rejected the key",
	"verify-key/2": "the provider could not be reached to check the key",
	"verify-key/3": "that provider has no free endpoint to verify against",

	"statusline/1": "the status line could not render",
	"telemetry/66": "the telemetry log could not be read",
}

func meaning(tool string, rc int) string {
	if m, ok := meanings[fmt.Sprintf("%s/%d", tool, rc)]; ok {
		return m
	}
	// Only 64 falls back. See the table's note: a borrowed label is worse than none.
	if rc == 64 {
		return meanings["*/64"]
	}
	return ""
}

type stat struct {
	calls, fails int
	ms           []int64
	codes        map[int]int
	notes        map[string]int
}

// ReportMain summarizes the log.
//
//	outsource telemetry [--since <N>d|<N>h] [--json] [--tail N]
func ReportMain(args []string, stdout, stderr io.Writer) int {
	since := time.Duration(0)
	asJSON := false
	tail := 0
	for i := 0; i < len(args); i++ {
		switch args[i] {
		case "--since":
			if i+1 >= len(args) {
				fmt.Fprintln(stderr, "telemetry: --since needs a value like 7d or 12h")
				return 64
			}
			d, err := parseWindow(args[i+1])
			if err != nil {
				fmt.Fprintf(stderr, "telemetry: %v\n", err)
				return 64
			}
			since = d
			i++
		case "--json":
			asJSON = true
		case "--tail":
			if i+1 >= len(args) {
				fmt.Fprintln(stderr, "telemetry: --tail needs a count")
				return 64
			}
			n, err := strconv.Atoi(args[i+1])
			if err != nil || n < 1 {
				fmt.Fprintf(stderr, "telemetry: --tail wants a positive count, got: %s\n", args[i+1])
				return 64
			}
			tail = n
			i++
		case "-h", "--help":
			fmt.Fprint(stdout, `Summarize what this skill's tools were asked to do and how it went.

  telemetry [--since 7d|12h] [--tail N] [--json]

Local only: this reads a file under your own state directory. Nothing is ever
uploaded. Disable recording entirely with OUTSOURCE_TELEMETRY=0.
`)
			return 0
		default:
			fmt.Fprintf(stderr, "telemetry: unknown flag: %s\n", args[i])
			return 64
		}
	}

	events, err := load(since)
	if err != nil {
		fmt.Fprintf(stderr, "telemetry: %v\n", err)
		return 66
	}
	if len(events) == 0 {
		fmt.Fprintf(stdout, "no telemetry recorded yet (%s)\n", Path())
		return 0
	}
	if asJSON {
		enc := json.NewEncoder(stdout)
		for _, e := range events {
			if enc.Encode(e) != nil {
				return 1
			}
		}
		return 0
	}
	if tail > 0 {
		writeTail(stdout, events, tail)
		return 0
	}
	writeSummary(stdout, events)
	return 0
}

func parseWindow(s string) (time.Duration, error) {
	if s == "" {
		return 0, fmt.Errorf("empty window")
	}
	unit := s[len(s)-1]
	n, err := strconv.Atoi(s[:len(s)-1])
	if err != nil || n < 1 {
		return 0, fmt.Errorf("window wants a count and a unit, like 7d or 12h, got: %s", s)
	}
	switch unit {
	case 'd':
		return time.Duration(n) * 24 * time.Hour, nil
	case 'h':
		return time.Duration(n) * time.Hour, nil
	case 'm':
		return time.Duration(n) * time.Minute, nil
	}
	return 0, fmt.Errorf("window unit must be m, h or d, got: %s", s)
}

// load reads both the live file and the rolled generation, so a window that spans
// a roll does not silently lose its older half.
func load(since time.Duration) ([]Event, error) {
	var out []Event
	cutoff := time.Time{}
	if since > 0 {
		cutoff = time.Now().Add(-since)
	}
	for _, p := range []string{Path() + ".1", Path()} {
		f, err := os.Open(p)
		if err != nil {
			continue
		}
		sc := bufio.NewScanner(f)
		sc.Buffer(make([]byte, 0, 64*1024), 1<<20)
		for sc.Scan() {
			var e Event
			if json.Unmarshal(sc.Bytes(), &e) != nil {
				continue // a partial line from a crash is skipped, never fatal
			}
			if !cutoff.IsZero() {
				if t, err := time.Parse("2006-01-02T15:04:05Z", e.TS); err == nil && t.Before(cutoff) {
					continue
				}
			}
			out = append(out, e)
		}
		f.Close()
	}
	return out, nil
}

func writeSummary(w io.Writer, events []Event) {
	byTool := map[string]*stat{}
	for _, e := range events {
		s := byTool[e.Tool]
		if s == nil {
			s = &stat{codes: map[int]int{}, notes: map[string]int{}}
			byTool[e.Tool] = s
		}
		s.calls++
		s.ms = append(s.ms, e.MS)
		if e.RC != 0 {
			s.fails++
			s.codes[e.RC]++
		}
		for k, v := range e.Details {
			// Only the reason keys are aggregated; the enum values (harness,
			// provider) are context on an individual line, not a finding.
			if k == "why" {
				s.notes[v]++
			}
		}
	}
	fmt.Fprintf(w, "%d events, %s → %s\n\n", len(events), events[0].TS, events[len(events)-1].TS)
	fmt.Fprintf(w, "%-14s %6s %6s %6s %8s %8s\n", "TOOL", "CALLS", "FAIL", "RATE", "p50", "p95")
	tools := make([]string, 0, len(byTool))
	for t := range byTool {
		tools = append(tools, t)
	}
	sort.Slice(tools, func(i, j int) bool { return byTool[tools[i]].calls > byTool[tools[j]].calls })
	for _, t := range tools {
		s := byTool[t]
		sort.Slice(s.ms, func(i, j int) bool { return s.ms[i] < s.ms[j] })
		fmt.Fprintf(w, "%-14s %6d %6d %5.0f%% %8s %8s\n", t, s.calls, s.fails,
			100*float64(s.fails)/float64(s.calls), dur(pct(s.ms, 50)), dur(pct(s.ms, 95)))
	}

	// The part that is actually actionable: which failures, and what they mean.
	type row struct {
		tool string
		rc   int
		n    int
	}
	var rows []row
	for t, s := range byTool {
		for rc, n := range s.codes {
			rows = append(rows, row{t, rc, n})
		}
	}
	if len(rows) > 0 {
		sort.Slice(rows, func(i, j int) bool { return rows[i].n > rows[j].n })
		fmt.Fprintf(w, "\nfailures by kind\n")
		for _, r := range rows {
			m := meaning(r.tool, r.rc)
			if m == "" {
				m = "(no recorded meaning for this code)"
			}
			fmt.Fprintf(w, "  %3d x %-14s exit %-4d %s\n", r.n, r.tool, r.rc, m)
		}
	}

	// Merged across tools, not per tool. Two launchers name the same reason — "the
	// completion marker never appeared" — and the first version printed it twice
	// with the counts split, which is the opposite of what a summary is for.
	merged := map[string]int{}
	for _, s := range byTool {
		for why, n := range s.notes {
			merged[why] += n
		}
	}
	var reasons []struct {
		why string
		n   int
	}
	for why, n := range merged {
		reasons = append(reasons, struct {
			why string
			n   int
		}{why, n})
	}
	if len(reasons) > 0 {
		sort.Slice(reasons, func(i, j int) bool { return reasons[i].n > reasons[j].n })
		fmt.Fprintf(w, "\nreasons the tools named\n")
		for _, r := range reasons {
			fmt.Fprintf(w, "  %3d x %s\n", r.n, r.why)
		}
	}
}

func writeTail(w io.Writer, events []Event, n int) {
	if len(events) > n {
		events = events[len(events)-n:]
	}
	for _, e := range events {
		extra := ""
		if len(e.Details) > 0 {
			keys := make([]string, 0, len(e.Details))
			for k := range e.Details {
				keys = append(keys, k)
			}
			sort.Strings(keys)
			parts := make([]string, 0, len(keys))
			for _, k := range keys {
				parts = append(parts, k+"="+e.Details[k])
			}
			extra = "  " + strings.Join(parts, " ")
		}
		fmt.Fprintf(w, "%s %-14s rc=%-4d %7s%s\n", e.TS, e.Tool, e.RC, dur(e.MS), extra)
	}
}

func pct(sorted []int64, p int) int64 {
	if len(sorted) == 0 {
		return 0
	}
	i := (len(sorted) - 1) * p / 100
	return sorted[i]
}

func dur(ms int64) string {
	switch {
	case ms < 1000:
		return fmt.Sprintf("%dms", ms)
	case ms < 60000:
		return fmt.Sprintf("%.1fs", float64(ms)/1000)
	default:
		return fmt.Sprintf("%dm%02ds", ms/60000, ms%60000/1000)
	}
}

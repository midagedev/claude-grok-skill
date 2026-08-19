package quota

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"regexp"
	"strconv"
	"time"
)

const usage = `Read a delegation backend's remaining plan quota, so a round can be sized (or
refused) before it is launched instead of dying mid-flight. Read-only.

  quota [--provider zai|grok] [--json] [--quiet] [--require-window <N%>]

--json emits one compact line; another script depends on that shape, so it is
kept stable. --quiet suppresses the whole report on success; a --require-window
failure reason always reaches stderr.

Exit codes: 0 ok · 1 no usable credential · 2 endpoint/network/body failure
            · 3 --require-window floor missed · 64 usage error.
`

var floorShape = regexp.MustCompile(`^[0-9]+(\.[0-9]+)?$`)

// Main is the quota entry point.
func Main(args []string, stdout, stderr io.Writer) int {
	provider, mode, quiet, require := "zai", "human", false, ""
	for i := 0; i < len(args); i++ {
		switch args[i] {
		case "--provider":
			if i+1 >= len(args) {
				fmt.Fprintln(stderr, "quota: --provider needs a value")
				return ExitUsage
			}
			provider = args[i+1]
			i++
		case "--json":
			mode = "json"
		case "--quiet":
			quiet = true
		case "--require-window":
			if i+1 >= len(args) {
				fmt.Fprintln(stderr, "quota: --require-window needs a value")
				return ExitUsage
			}
			require = args[i+1]
			i++
		case "-h", "--help":
			fmt.Fprint(stdout, usage)
			return ExitOK
		default:
			fmt.Fprintf(stderr, "quota: unknown flag: %s\n", args[i])
			return ExitUsage
		}
	}
	switch provider {
	case "zai", "grok":
	default:
		fmt.Fprintf(stderr, "quota: --provider must be zai or grok, got: %s\n", provider)
		return ExitUsage
	}
	// Shape only, not range: a floor above 100 is unmeetable, and saying so with
	// exit 3 is the honest outcome rather than a usage error.
	if require != "" && !floorShape.MatchString(require) {
		fmt.Fprintf(stderr, "quota: --require-window wants a percentage, got: %s\n", require)
		return ExitUsage
	}

	now := time.Now()
	var rep *Report
	var err error
	if provider == "zai" {
		rep, err = fetchZai(now)
	} else {
		rep, err = fetchGrok(now)
	}
	if err != nil {
		var se sessionError
		switch {
		case errors.Is(err, errNoCredential):
			// credential.sh already named every place it looked and how to set the
			// key, so nothing is added here.
			return ExitNoCredential
		case errors.As(err, &se):
			fmt.Fprintln(stderr, se.msg)
			return ExitNoCredential
		default:
			fmt.Fprintf(stderr, "quota: %v\n", err)
			return ExitEndpoint
		}
	}

	// The pre-flight gate keys on the TIGHTEST window, not the shortest one.
	// Measured 2026-08-16: the weekly window sat at 81.7% remaining while the
	// 5-hour one sat at 83.8% — keying on the shortest would have cleared a round
	// that the weekly allowance is the one to actually stop.
	tightest := 0
	for i := range rep.Windows {
		if rep.Windows[i].RemainingPercent.Float() < rep.Windows[tightest].RemainingPercent.Float() {
			tightest = i
		}
	}
	gated := false
	if require != "" {
		floor, _ := strconv.ParseFloat(require, 64)
		if rep.Windows[tightest].RemainingPercent.Float() < floor {
			gated = true
			w := rep.Windows[tightest]
			fmt.Fprintf(stderr, "quota: tightest window %s has %s%% remaining, below the %s%% floor; resets at %s (%s)\n",
				w.Label, w.RemainingPercent, require, w.hhmm, w.rel)
		}
	}

	if !quiet {
		if mode == "json" {
			b, err := json.Marshal(rep)
			if err != nil {
				fmt.Fprintf(stderr, "quota: could not encode report: %v\n", err)
				return ExitEndpoint
			}
			fmt.Fprintf(stdout, "%s\n", b)
		} else {
			writeHuman(stdout, rep, tightest)
		}
	}
	if gated {
		return ExitGated
	}
	return ExitOK
}

func writeHuman(w io.Writer, rep *Report, tightest int) {
	head := "Grok CLI plan"
	if rep.Provider == "zai" {
		head = "z.ai coding plan"
	}
	if rep.Level != nil {
		head += ": level " + *rep.Level
	}
	s := rep.Subscription
	switch {
	case s.ProductName != nil && s.Status != nil:
		fmt.Fprintf(w, "%s — %s (status %s, valid %s)\n", head, *s.ProductName, *s.Status, derefOrNone(s.Valid))
	case s.ProductName != nil:
		fmt.Fprintf(w, "%s — %s\n", head, *s.ProductName)
	default:
		fmt.Fprintf(w, "%s — plan identity unavailable (%s)\n", head, derefOrNone(s.Error))
	}
	for i, win := range rep.Windows {
		pct := "?"
		if win.Percentage != nil {
			pct = win.Percentage.String()
		}
		counts := "exact counts not exposed by this API, "
		if win.Allowance != nil && *win.Allowance != 0 {
			// grok reports a percentage only — say so rather than printing zeros
			// that would read as "nothing left".
			counts = fmt.Sprintf("%s/%s consumed, %s remaining, ",
				intOrNone(win.Consumed), intOrNone(win.Allowance), intOrNone(win.Remaining))
		}
		mark := ""
		if i == tightest && len(rep.Windows) > 1 {
			mark = "  <- tightest"
		}
		// "left" is the same computed figure the gate compares against, not 100
		// minus the API's rounded integer — otherwise a report reading "84% left"
		// contradicts a gate that tripped at 83.8.
		fmt.Fprintf(w, "%s window: %s%s%% used / %s%% left, resets at %s (%s)%s\n",
			win.Label, counts, pct, win.RemainingPercent, win.hhmm, win.rel, mark)
	}
}

// derefOrNone renders an absent value as Python's None did, because these strings
// are compared against the shell implementation's output.
func derefOrNone(s *string) string {
	if s == nil {
		return "None"
	}
	return *s
}

func intOrNone(i *int64) string {
	if i == nil {
		return "None"
	}
	return strconvI(*i)
}

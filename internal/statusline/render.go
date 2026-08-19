package statusline

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"math"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/midagedev/outsource/internal/runs"
)

const (
	cyan    = "\033[0;36m"
	yellow  = "\033[0;33m"
	green   = "\033[0;32m"
	red     = "\033[0;31m"
	magenta = "\033[0;35m"
	dim     = "\033[2m"
	reset   = "\033[0m"
)

var sep = " " + dim + "│" + reset + " "

// input is the JSON Claude Code hands a status-line command on stdin. Only the
// fields this line renders are named. Parsing it here retires jq, which was
// this file's only use of it and therefore the whole repo's.
type input struct {
	Model struct {
		DisplayName string `json:"display_name"`
		ID          string `json:"id"`
	} `json:"model"`
	ContextWindow struct {
		UsedPercentage *float64 `json:"used_percentage"`
	} `json:"context_window"`
	RateLimits struct {
		FiveHour struct {
			UsedPercentage *float64 `json:"used_percentage"`
			ResetsAt       *int64   `json:"resets_at"`
		} `json:"five_hour"`
		SevenDay struct {
			UsedPercentage *float64 `json:"used_percentage"`
			ResetsAt       *int64   `json:"resets_at"`
		} `json:"seven_day"`
	} `json:"rate_limits"`
	Cwd       string `json:"cwd"`
	Workspace struct {
		CurrentDir  string `json:"current_dir"`
		GitWorktree string `json:"git_worktree"`
	} `json:"workspace"`
	SessionID string `json:"session_id"`
}

// pctColor is the alarm the bar used to carry.
func pctColor(p float64) string {
	switch r := math.Round(p); {
	case r >= 80:
		return red
	case r >= 50:
		return yellow
	default:
		return green
	}
}

// untilStr renders a reset time: now · 35m · 3h20m · 4d2h.
//
// Deliberately NOT human.Secs, which this could look like a duplicate of. That
// one renders seconds below a minute ("45s"), which is right for how long a
// round has been running and wrong for a budget: a window resetting in 40
// seconds is "0m", and a status line that flickers through a seconds countdown
// costs attention for nothing. Past a day the minutes stop mattering and the
// days start to, which is what keeps a week-long window readable in five
// columns.
func untilStr(epoch int64, now int64) string {
	s := epoch - now
	switch {
	case s <= 0:
		return "now"
	case s < 3600:
		return fmt.Sprintf("%dm", s/60)
	case s < 86400:
		return fmt.Sprintf("%dh%02dm", s/3600, s%3600/60)
	default:
		return fmt.Sprintf("%dd%dh", s/86400, s%86400/3600)
	}
}

// budget renders one token: "5H 8%/3h20m". A percentage that is not a number is
// missing data, and missing data must never render as 0% — that reads as
// "plenty left", the most expensive possible way to be wrong here. So a nil
// percentage produces no segment at all.
func budget(label string, pct *float64, resetEpoch *int64, now int64) string {
	if pct == nil {
		return ""
	}
	tail := ""
	if resetEpoch != nil && *resetEpoch != 0 {
		tail = dim + "/" + untilStr(*resetEpoch, now) + reset
	}
	return fmt.Sprintf("%s%s%s %s%d%%%s%s",
		dim, label, reset, pctColor(*pct), int64(math.Round(*pct)), reset, tail)
}

// modelShort keeps the family and drops the marketing. The display name carries
// things like "Opus 5 (1M context)"; what a lead checks at a glance is which
// family is spending, so that is all this prints.
func modelShort(raw string) string {
	low := strings.ToLower(raw)
	for _, f := range []string{"fable", "opus", "sonnet", "haiku"} {
		for _, w := range strings.Fields(low) {
			if strings.Contains(w, f) {
				return f
			}
		}
	}
	if fields := strings.Fields(low); len(fields) > 0 {
		return fields[0]
	}
	return ""
}

// accountEmail says which account is spending, when several are in play.
// ~/.claude.json is large and rewritten constantly, so the extraction is cached
// against its mtime rather than re-parsed on every render.
func accountEmail() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	src := filepath.Join(home, ".claude.json")
	si, err := os.Stat(src)
	if err != nil {
		return ""
	}
	cf := filepath.Join(cacheDir(), "account.kv")
	if ci, err := os.Stat(cf); err == nil && ci.ModTime().After(si.ModTime()) {
		if b, err := os.ReadFile(cf); err == nil {
			return strings.TrimSpace(string(b))
		}
	}
	b, err := os.ReadFile(src)
	if err != nil {
		return ""
	}
	var d struct {
		OauthAccount struct {
			EmailAddress string `json:"emailAddress"`
		} `json:"oauthAccount"`
	}
	if json.Unmarshal(b, &d) != nil || d.OauthAccount.EmailAddress == "" {
		return ""
	}
	if os.MkdirAll(cacheDir(), 0o755) == nil {
		_ = writeCache(cacheDir(), "account", d.OauthAccount.EmailAddress)
	}
	return d.OauthAccount.EmailAddress
}

func providers() []string {
	v, ok := os.LookupEnv("OUTSOURCE_STATUSLINE_PROVIDERS")
	if !ok {
		return []string{"zai", "grok"}
	}
	return strings.Fields(v) // an explicit empty value disables the row
}

func displayName(p string) string {
	if p == "zai" {
		return "z.ai"
	}
	return p
}

// providerPart renders one delegation budget from cache only; it never fetches.
func providerPart(p string, now int64) string {
	c, ok := readCache(p)
	if !ok {
		// No cache file at all means no refresh has landed yet — honest "not
		// measured", never a zero.
		return dim + displayName(p) + " …" + reset
	}
	pctF, err := strconv.ParseFloat(c.percentage, 64)
	if c.percentage == "" || err != nil {
		// A measurement was attempted and produced no number: this backend has
		// no credential here. Not a problem to report — just a backend this
		// user does not use.
		return ""
	}
	stale := ""
	if now-c.measuredAt > ttl()*4 {
		stale = dim + "~" + reset
	}
	var resetPtr *int64
	if n, err := strconv.ParseInt(c.resetEpoch, 10, 64); err == nil {
		resetPtr = &n
	}
	// The cached window label ("1w", "1mo") is deliberately not shown: the
	// segment is identified by the provider, and which window it came from is
	// quota.sh's choice, not information a lead acts on in five columns.
	return stale + budget(displayName(p), &pctF, resetPtr, now)
}

func join(parts ...string) string {
	out := make([]string, 0, len(parts))
	for _, p := range parts {
		if p != "" {
			out = append(out, p)
		}
	}
	return strings.Join(out, sep)
}

// Render writes the status line. quotaSh is the path to bin/quota.sh, which
// still owns talking to the providers.
func Render(stdin io.Reader, stdout io.Writer, quotaSh string) int {
	raw, _ := io.ReadAll(stdin)
	var in input
	_ = json.Unmarshal(raw, &in) // a malformed payload renders what it can
	now := time.Now().Unix()

	// ---- line 1: this session ----
	modelPart := ""
	name := in.Model.DisplayName
	if name == "" {
		name = in.Model.ID
	}
	if s := modelShort(name); s != "" {
		modelPart = magenta + s + reset
	}
	emailPart := ""
	if e := accountEmail(); e != "" {
		emailPart = dim + e + reset
	}
	// The context window has no reset time — it ends when the session does — so
	// it is the one budget printed as a bare percentage.
	ctxPart := ""
	if p := in.ContextWindow.UsedPercentage; p != nil {
		ctxPart = fmt.Sprintf("%sCTX%s %s%d%%%s", dim, reset, pctColor(*p), int64(math.Round(*p)), reset)
	}
	fivePart := budget("5H", in.RateLimits.FiveHour.UsedPercentage, in.RateLimits.FiveHour.ResetsAt, now)
	weekPart := budget("1W", in.RateLimits.SevenDay.UsedPercentage, in.RateLimits.SevenDay.ResetsAt, now)

	// ---- line 2: the delegation ----
	quotaParts := ""
	if ps := providers(); len(ps) > 0 {
		if fi, err := os.Stat(quotaSh); err == nil && fi.Mode()&0o111 != 0 {
			_ = os.MkdirAll(cacheDir(), 0o755)
			segs := []string{}
			for _, p := range ps {
				maybeRefresh(p)
				if s := providerPart(p, now); s != "" {
					segs = append(segs, s)
				}
			}
			quotaParts = strings.Join(segs, sep)
		}
	}

	runsPart := renderRuns(in.SessionID)

	// Where you are, de-emphasised and last: it is the one thing on this line
	// you already know.
	cwd := in.Cwd
	if cwd == "" {
		cwd = in.Workspace.CurrentDir
	}
	locationPart := ""
	if base := filepath.Base(cwd); base != "" && base != "." && base != string(filepath.Separator) {
		locationPart = dim + base
		if in.Workspace.GitWorktree != "" {
			locationPart += " (" + in.Workspace.GitWorktree + ")"
		}
		locationPart += reset
	}

	line1 := join(modelPart, emailPart, ctxPart, fivePart, weekPart)
	line2 := join(quotaParts, runsPart, locationPart)
	if line2 != "" {
		fmt.Fprintf(stdout, "%s\n%s", line1, line2)
	} else {
		fmt.Fprint(stdout, line1)
	}
	return 0
}

// renderRuns asks the registry in-process — the shell version spawned
// runs.sh on every render, and that subprocess was most of the render's cost.
//
// The rounds shown are this session's. The registry is machine-wide, and it
// should be: an orphaned round has to be findable from wherever you are. But a
// status line is a report on YOUR window, so another window's rounds appearing
// here read as your own work and are worse than showing nothing.
func renderRuns(sessionID string) string {
	scope := []string{"line"}
	if os.Getenv("OUTSOURCE_STATUSLINE_SCOPE") != "all" {
		owner := sessionID
		if owner == "" {
			owner = os.Getenv("CLAUDE_CODE_SESSION_ID")
		}
		ownerPid := os.Getenv("CLAUDE_PID")
		if owner == "" && ownerPid == "" {
			// No identity at all: an empty filter means "no filter"
			// downstream, so asking anyway would print the whole machine —
			// precisely what scoping is here to prevent. Claim nothing
			// instead; `runs` unfiltered still has it.
			return ""
		}
		scope = append(scope, "--owner", owner, "--owner-claude-pid", ownerPid)
	}
	var buf bytes.Buffer
	if runs.Main(scope, &buf, io.Discard) != 0 {
		return ""
	}
	line := strings.TrimRight(buf.String(), "\n")
	if line == "" {
		return ""
	}
	return cyan + line + reset
}

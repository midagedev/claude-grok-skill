// Package statusline renders the Claude Code status line: the two budgets that
// stop this session, the delegation budgets that stop the next round, and the
// rounds running right now.
//
// Every budget is one token: NAME used%/until-it-resets. The percentage says
// how much is gone, the second half says how long until it comes back, and
// neither is actionable without the other — a bar renders the first half in
// thirty columns and the second half not at all, so there is no bar here.
// Colour carries the alarm instead.
//
// Everything degrades to silence. No z.ai key, never signed in to grok, no
// delegated run on record: the segment disappears rather than printing a zero
// that reads like bad news.
package statusline

import (
	"encoding/json"
	"fmt"
	"math"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// Why the quota numbers are cached: a status line runs on every render and must
// return in milliseconds, while the provider quota APIs take one to two
// seconds. So the foreground never calls them. It reads a small key=value
// cache, and when that cache is older than the TTL it detaches one background
// refresh, guarded by a lock directory so a burst of renders produces one fetch
// and not thirty.
//
// Until the first refresh lands the segment shows "…", which is honest: it
// means "not measured yet", not "zero". A number that has gone stale because
// refreshes keep failing is prefixed "~" rather than quietly kept.
type cache struct {
	// fetchedAt is when we last *tried*; measuredAt is when the numbers below
	// were actually true. Staleness is the gap between them.
	fetchedAt  int64
	measuredAt int64
	label      string
	percentage string
	resetEpoch string
	plan       string
	err        bool
}

func cacheDir() string {
	if d := os.Getenv("OUTSOURCE_STATUSLINE_CACHE"); d != "" {
		return d
	}
	base := os.Getenv("XDG_CACHE_HOME")
	if base == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			home = os.Getenv("HOME")
		}
		base = filepath.Join(home, ".cache")
	}
	return filepath.Join(base, "outsource", "statusline")
}

func ttl() int64 {
	if v := os.Getenv("OUTSOURCE_STATUSLINE_TTL"); v != "" {
		if n, err := strconv.ParseInt(v, 10, 64); err == nil && n > 0 {
			return n
		}
	}
	return 180
}

func readCache(provider string) (cache, bool) {
	b, err := os.ReadFile(filepath.Join(cacheDir(), provider+".kv"))
	if err != nil {
		return cache{}, false
	}
	c := cache{}
	for _, line := range strings.Split(string(b), "\n") {
		k, v, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}
		switch k {
		case "fetchedAt":
			c.fetchedAt, _ = strconv.ParseInt(v, 10, 64)
		case "measuredAt":
			c.measuredAt, _ = strconv.ParseInt(v, 10, 64)
		case "label":
			c.label = v
		case "percentage":
			c.percentage = v
		case "resetEpoch":
			c.resetEpoch = v
		case "plan":
			c.plan = v
		case "error":
			c.err = v == "1"
		}
	}
	return c, true
}

// quotaJSON is the shape bin/quota.sh --json emits. Only the fields this
// renderer needs are named; the rest of that contract belongs to quota.sh.
type quotaJSON struct {
	Level        any `json:"level"`
	Subscription struct {
		ProductName string `json:"productName"`
	} `json:"subscription"`
	Windows []struct {
		Label         string   `json:"label"`
		Percentage    *float64 `json:"percentage"`
		NextResetTime *int64   `json:"nextResetTime"`
	} `json:"windows"`
}

// Refresh fetches one provider's quota and digests it into the flat cache the
// foreground reads, so the hot path parses no JSON from the provider at all.
//
// A failed fetch must not erase the last good numbers. Silence in this status
// line means "this backend is not set up here"; a backend that was working and
// stopped — an expired sign-in, a network blip — is a different thing entirely,
// and vanishing would report it as the first. The previous measurement is
// carried forward and marked stale instead.
func Refresh(provider, quotaSh string) error {
	dir := cacheDir()
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	defer os.Remove(filepath.Join(dir, provider+".lock"))

	now := time.Now().Unix()
	out, runErr := exec.Command(quotaSh, "--provider", provider, "--json").Output()

	var b strings.Builder
	fmt.Fprintf(&b, "fetchedAt=%d\n", now)

	var q quotaJSON
	if runErr != nil || json.Unmarshal(out, &q) != nil {
		b.WriteString("error=1\n")
		if prev, ok := readCache(provider); ok {
			// Carry the last good measurement forward, untouched.
			if prev.measuredAt != 0 {
				fmt.Fprintf(&b, "measuredAt=%d\n", prev.measuredAt)
			}
			writeIf(&b, "label", prev.label)
			writeIf(&b, "percentage", prev.percentage)
			writeIf(&b, "resetEpoch", prev.resetEpoch)
			writeIf(&b, "plan", prev.plan)
		}
		return writeCache(dir, provider, b.String())
	}

	fmt.Fprintf(&b, "measuredAt=%d\n", now)

	// The weekly window is the one a plan is actually rationed by, so prefer
	// it; grok's unified-billing accounts expose only a monthly budget, and an
	// account with neither still has a shortest window worth showing.
	var w *struct {
		Label         string   `json:"label"`
		Percentage    *float64 `json:"percentage"`
		NextResetTime *int64   `json:"nextResetTime"`
	}
	for i := range q.Windows {
		if strings.HasSuffix(q.Windows[i].Label, "w") {
			w = &q.Windows[i]
			break
		}
	}
	if w == nil {
		for i := range q.Windows {
			if q.Windows[i].Label == "1mo" {
				w = &q.Windows[i]
				break
			}
		}
	}
	if w == nil && len(q.Windows) > 0 {
		w = &q.Windows[0]
	}
	if w == nil {
		b.WriteString("error=1\n")
		return writeCache(dir, provider, b.String())
	}

	label := w.Label
	if label == "" {
		label = "?"
	}
	fmt.Fprintf(&b, "label=%s\n", label)
	if w.Percentage != nil {
		fmt.Fprintf(&b, "percentage=%d\n", int64(math.Round(*w.Percentage)))
	} else {
		b.WriteString("percentage=\n")
	}
	if w.NextResetTime != nil && *w.NextResetTime != 0 {
		fmt.Fprintf(&b, "resetEpoch=%d\n", *w.NextResetTime/1000)
	} else {
		b.WriteString("resetEpoch=\n")
	}
	plan := q.Subscription.ProductName
	if plan == "" {
		if s, ok := q.Level.(string); ok {
			plan = s
		}
	}
	fmt.Fprintf(&b, "plan=%s\n", strings.ReplaceAll(plan, "\n", " "))
	return writeCache(dir, provider, b.String())
}

func writeIf(b *strings.Builder, k, v string) {
	if v != "" {
		fmt.Fprintf(b, "%s=%s\n", k, v)
	}
}

func writeCache(dir, provider, body string) error {
	tmp := filepath.Join(dir, fmt.Sprintf("%s.kv.tmp%d", provider, os.Getpid()))
	if err := os.WriteFile(tmp, []byte(body), 0o644); err != nil {
		return err
	}
	if err := os.Rename(tmp, filepath.Join(dir, provider+".kv")); err != nil {
		os.Remove(tmp)
		return err
	}
	return nil
}

// maybeRefresh detaches at most one fetch per provider. The lock is a
// directory because mkdir is atomic everywhere; one left behind by a killed
// refresher would freeze the number forever, so one older than a minute is
// treated as abandoned.
func maybeRefresh(provider string) {
	dir := cacheDir()
	now := time.Now().Unix()
	if c, ok := readCache(provider); ok && now-c.fetchedAt < ttl() {
		return
	}
	lock := filepath.Join(dir, provider+".lock")
	if fi, err := os.Stat(lock); err == nil {
		if now-fi.ModTime().Unix() <= 60 {
			return
		}
		os.Remove(lock)
	}
	if os.Mkdir(lock, 0o755) != nil {
		return
	}
	self, err := os.Executable()
	if err != nil {
		os.Remove(lock)
		return
	}
	// stdin is closed explicitly and the child is detached: it must outlive
	// this render, and an inherited stdin is what would make it block instead
	// of fetching. (In the shell version that exact mistake held the lock
	// forever and pinned the number at "…".)
	devnull, err := os.Open(os.DevNull)
	if err != nil {
		os.Remove(lock)
		return
	}
	defer devnull.Close()
	cmd := exec.Command(self, "statusline", "--refresh", provider)
	cmd.Stdin = devnull
	cmd.Stdout, cmd.Stderr = nil, nil
	cmd.SysProcAttr = detachAttr()
	if cmd.Start() != nil {
		os.Remove(lock)
		return
	}
	go func() { _ = cmd.Wait() }() // reap without blocking the render
}

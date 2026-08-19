// Package human formats the quantities this tool shows a person: durations,
// and percentages that must never lie by rounding.
//
// It exists as its own package because the shell version had two copies of
// duration formatting that had already drifted — runs.sh printed `1h04m`
// while statusline.sh printed `3h20m` from a separate awk program with a
// different day threshold. One owner, one set of thresholds.
package human

import "fmt"

// Secs renders a duration the way a lead reads it at a glance:
// 45s · 12m · 1h04m · 2d3h. The unit pair shifts with magnitude because past
// a day the minutes stop mattering and the days start to; that is what keeps
// a week-long window readable in five columns.
//
// Negative input clamps to zero: a clock that went backwards (NTP step, a
// record written on another machine) must not render as "-3s", which reads
// as a bug in the round rather than in the clock.
func Secs(s int64) string {
	if s < 0 {
		s = 0
	}
	switch {
	case s < 60:
		return fmt.Sprintf("%ds", s)
	case s < 3600:
		return fmt.Sprintf("%dm", s/60)
	case s < 86400:
		return fmt.Sprintf("%dh%02dm", s/3600, s%3600/60)
	default:
		return fmt.Sprintf("%dd%dh", s/86400, s%86400/3600)
	}
}

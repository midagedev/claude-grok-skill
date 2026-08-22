package report

import "testing"

// TestEndsWithMarker pins the 2026-08-22 field false-positive (gadak GDK-616
// round): the delegate's FINAL message was a promise — "…the report's last
// line will be `DONE-GDK616`" — and Contains() over the report scored it
// found while the round's gates were still running. The verdict is the
// spec's own contract: the last non-empty line IS the marker.
func TestEndsWithMarker(t *testing.T) {
	cases := []struct {
		name   string
		rep    string
		marker string
		want   bool
	}{
		{"exact last line", "work done.\n\nDONE-X", "DONE-X", true},
		{"backticked last line", "done.\n`DONE-X`", "DONE-X", true},
		{"bold last line", "done.\n**DONE-X**", "DONE-X", true},
		{"trailing blank lines", "done.\nDONE-X\n\n\n", "DONE-X", true},
		// The incident: marker quoted mid-sentence in the last line.
		{"promissory sentence", "대기 중 — 이후 마지막 줄 `DONE-X`)를 작성하는 것입니다.", "DONE-X", false},
		{"marker mid-report only", "DONE-X\nbut then more text", "DONE-X", false},
		{"punctuation glued", "done.\nDONE-X.", "DONE-X", false},
		{"empty report", "", "DONE-X", false},
		{"empty marker", "DONE-X", "", false},
	}
	for _, c := range cases {
		if got := EndsWithMarker(c.rep, c.marker); got != c.want {
			t.Errorf("%s: EndsWithMarker(%q, %q) = %v, want %v", c.name, c.rep, c.marker, got, c.want)
		}
	}
}

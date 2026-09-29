package cli

// limit_clamp_test.go pins the ONE comparison that lets a client know a server
// narrowed its window: what was asked for against what the server says it
// applied. The arms below are chosen so a cap that MOVES cannot silently pass:
// the same table is run at a 200 ceiling and at a 400 ceiling, and a helper
// carrying a literal would fail one of them.

import (
	"strconv"
	"strings"
	"testing"
)

// TestServerClampedByDetectsNarrowingAtTheBoundary is the EXCESS-and-BOUNDARY
// arm together, at the live ceiling measured 2026-09-15 against
// api.barkpark.cloud (GET /v1/barkparks/:id/metrics answered points=200 for
// ?points=200, ?points=201 and ?points=500).
//
// 201 is the arm that matters: a test that only probes 500 cannot tell a cap at
// 200 from a cap at 400 and would pass unchanged against a server that had
// moved it.
func TestServerClampedByDetectsNarrowingAtTheBoundary(t *testing.T) {
	cases := []struct {
		name               string
		requested, applied int
		want               int
	}{
		{"exactly the cap is NOT a clamp", 200, 200, 0},
		{"one over the cap IS a clamp", 201, 200, 201},
		{"far over the cap IS a clamp", 500, 200, 500},
		{"under the cap is untouched", 30, 30, 0},
	}
	for _, c := range cases {
		if got := serverClampedBy(c.requested, c.applied); got != c.want {
			t.Errorf("%s: serverClampedBy(%d,%d)=%d want %d", c.name, c.requested, c.applied, got, c.want)
		}
	}
}

// TestServerClampedBySurvivesACapThatMoved is the DRIFT control, and it is the
// reason no literal may appear in limit_clamp.go: the identical shape is
// replayed against a 400 ceiling. A helper that hardcoded 200 would call 400
// applied-for-500 correct AND call 200 applied-for-201 wrong; this table pins
// the relationship instead of the number.
func TestServerClampedBySurvivesACapThatMoved(t *testing.T) {
	const movedCap = 400
	if got := serverClampedBy(movedCap, movedCap); got != 0 {
		t.Errorf("exactly the moved cap must stay silent, got %d", got)
	}
	if got := serverClampedBy(movedCap+1, movedCap); got != movedCap+1 {
		t.Errorf("one over the moved cap must report %d, got %d", movedCap+1, got)
	}
	// And the OLD ceiling, at the moved server, is now an honest full window.
	if got := serverClampedBy(200, 200); got != 0 {
		t.Errorf("200/200 at a 400-cap server must stay silent, got %d", got)
	}
}

// TestServerClampedByStaysSilentWithoutBothNumbers: a caller who typed no flag
// chose no number to be misled about, and a control plane that echoes no window
// has told us nothing — an absent echo is not evidence of a clamp.
func TestServerClampedByStaysSilentWithoutBothNumbers(t *testing.T) {
	for _, c := range [][3]int{
		{0, 200, 0},  // no --points typed
		{500, 0, 0},  // server echoed no window
		{-1, 200, 0}, // nonsense request
		{100, 200, 0},
	} {
		if got := serverClampedBy(c[0], c[1]); got != c[2] {
			t.Errorf("serverClampedBy(%d,%d)=%d want %d", c[0], c[1], got, c[2])
		}
	}
}

// TestClampNoticeNamesBothSides: the message must carry the asked-for number
// AND the arrived number, or a reader still cannot tell a total from a ceiling.
func TestClampNoticeNamesBothSides(t *testing.T) {
	got := clampNotice("points", 500, 200)
	for _, want := range []string{"500", "200", "points", "narrowed"} {
		if !strings.Contains(got, want) {
			t.Fatalf("clampNotice missing %q: %s", want, got)
		}
	}
}

// metricsEnvelopeWithPoints builds a live envelope whose `points` echo is n —
// the control-plane field documented in BarkparkCloud.Metrics as "the requested
// (clamped) window size".
func metricsEnvelopeWithPoints(t *testing.T, n int) string {
	t.Helper()
	out := strings.Replace(metricsLiveEnvelope, `"points":4,`,
		`"points":`+strconv.Itoa(n)+`,`, 1)
	// POSITIVE CONTROL on the fixture itself: a replacement that silently did
	// nothing would leave points=4 and make every arm below measure the wrong
	// envelope. An absence is never caught by inspection.
	if out == metricsLiveEnvelope {
		t.Fatalf(`fixture rewrite did not fire — no "points":4, in metricsLiveEnvelope`)
	}
	if !strings.Contains(out, `"points":`+strconv.Itoa(n)+`,`) {
		t.Fatalf("fixture does not carry points=%d: %s", n, out)
	}
	return out
}

// TestCloudInstanceTopReportsAClampedWindow is the END-TO-END arm: the command
// asks for 500 points, the fake control plane echoes 200, and the CLI says so
// naming both numbers. THIS is the test that fails if the guard is deleted.
func TestCloudInstanceTopReportsAClampedWindow(t *testing.T) {
	newMetricsServer(t, 200, metricsEnvelopeWithPoints(t, 200))
	stdout, stderr, code := runTop(t, "table", testInstanceID, "--points", "500")
	if code != exitOK {
		t.Fatalf("exit=%d stderr=%s", code, stderr)
	}
	if want := clampNotice("points", 500, 200); !strings.Contains(stdout, want) {
		t.Fatalf("human output missing %q — a clamped window went unreported:\n%s", want, stdout)
	}
}

// TestCloudInstanceTopBoundaryIsNotReportedAsAClamp is the NOISE arm c2 demands:
// a response of exactly the requested size is NOT a clamp and must not be
// announced as one. A signal that fires spuriously is tuned out within a week.
func TestCloudInstanceTopBoundaryIsNotReportedAsAClamp(t *testing.T) {
	newMetricsServer(t, 200, metricsEnvelopeWithPoints(t, 200))
	stdout, stderr, code := runTop(t, "table", testInstanceID, "--points", "200")
	if code != exitOK {
		t.Fatalf("exit=%d stderr=%s", code, stderr)
	}
	if strings.Contains(stdout, "narrowed") || strings.Contains(stderr, "narrowed") {
		t.Fatalf("200 asked / 200 applied was reported as a clamp:\nstdout:\n%s\nstderr:\n%s", stdout, stderr)
	}
}

// TestCloudInstanceTopClampNoticeKeepsJSONVerbatim: in machine mode the notice
// rides stderr so stdout stays the exact control-plane document.
func TestCloudInstanceTopClampNoticeKeepsJSONVerbatim(t *testing.T) {
	body := metricsEnvelopeWithPoints(t, 200)
	newMetricsServer(t, 200, body)
	stdout, stderr, code := runTop(t, "json", testInstanceID, "--points", "500")
	if code != exitOK {
		t.Fatalf("exit=%d stderr=%s", code, stderr)
	}
	if got := strings.TrimRight(stdout, "\n"); got != body {
		t.Fatalf("json stdout not verbatim:\n got: %s\nwant: %s", got, body)
	}
	if !strings.Contains(stderr, "narrowed") {
		t.Fatalf("machine mode lost the truncation advisory; stderr:\n%s", stderr)
	}
}

// TestCloudInstanceTopNoClampNoticeWhenNoPointsAsked: the default window (no
// --points) has no requested number to disagree with, so nothing is printed —
// the pre-change human output stays byte-identical.
func TestCloudInstanceTopNoClampNoticeWhenNoPointsAsked(t *testing.T) {
	newMetricsServer(t, 200, metricsEnvelopeWithPoints(t, 200))
	stdout, _, code := runTop(t, "table", testInstanceID)
	if code != exitOK {
		t.Fatalf("exit=%d", code)
	}
	if strings.Contains(stdout, "narrowed") {
		t.Fatalf("an unasked window reported itself as narrowed:\n%s", stdout)
	}
}

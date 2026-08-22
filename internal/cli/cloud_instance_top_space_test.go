package cli

// cloud_instance_top_space_test.go covers the HOST-SPACE section of
// `bp cloud instance top` — the render of the space report the agent posts on
// its own 15-minute cadence to /v1/agent/space.
//
// The section exists because "what is eating this box's disk" was an SSH
// question whose answer was already in the database. Its hardest requirement is
// not the happy path: today most boxes send NO space report, and the render has
// to say WHICH kind of nothing that is, because the two have opposite remedies.

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/cloudclient"
)

// TestSpaceLinesTellsCannotReportFromHasNotReported is the criterion this
// section lives or dies on. Both cases arrive as `space: null` and are
// indistinguishable in the space payload itself; only the core count separates
// them, and it separates them because `cpu_cores` and the space probe entered
// the agent in the SAME commit (see TestSpaceInferenceBracketStillHolds).
func sptr(s string) *string { return &s }

func TestSpaceLinesTellsCannotReportFromHasNotReported(t *testing.T) {
	// CANNOT report: no space row AND no readable core count.
	cannot, blocks := spaceLines(cloudclient.MetricsResult{})
	if len(cannot) != 1 || blocks != nil {
		t.Fatalf("cannot-report = %d lines / %+v blocks, want 1 line and no chart", len(cannot), blocks)
	}
	if !strings.Contains(cannot[0], "predates the space probe") {
		t.Fatalf("cannot-report must name the agent build as the cause, got %q", cannot[0])
	}
	if !strings.Contains(cannot[0], "upgrading the agent") {
		t.Fatalf("cannot-report must point at the remedy that works, got %q", cannot[0])
	}

	// HAS NOT reported: no space row, but the core count reads — so the binary
	// contains the probe and simply has not posted yet.
	hasnt, blocks := spaceLines(cloudclient.MetricsResult{
		Latest: cloudclient.MetricsLatest{Cores: fp(4)},
	})
	if len(hasnt) != 1 || blocks != nil {
		t.Fatalf("not-yet = %d lines / %+v blocks", len(hasnt), blocks)
	}
	if !strings.Contains(hasnt[0], "no report yet") || !strings.Contains(hasnt[0], "CAN report") {
		t.Fatalf("not-yet must say the agent is capable, got %q", hasnt[0])
	}

	// THE WHOLE POINT: the two absences must not read alike. A render that
	// emitted one sentence for both would pass every other assertion here.
	if cannot[0] == hasnt[0] {
		t.Fatal("the two absent states render identically — the section cannot tell an operator what to do")
	}
	if strings.Contains(hasnt[0], "predates") {
		t.Fatalf("a capable agent must never be accused of being too old: %q", hasnt[0])
	}
}

// TestSpaceLinesRendersAFullReport proves the measured path, including that a
// bar's length is a share of the sites total.
func TestSpaceLinesRendersAFullReport(t *testing.T) {
	lines, blocks := spaceLines(cloudclient.MetricsResult{
		Space: &cloudclient.MetricsSpace{
			Root:         cloudclient.MetricsSpaceRoot{UsedBytes: fp(12884901888), TotalBytes: fp(42949672960)},
			JournalBytes: fp(536870912),
			DBSize:       fp(3525639191),
			ReportedAt:   sptr("2026-08-22T10:00:00Z"),
			Sites: cloudclient.MetricsSpaceSites{
				Dir:   sptr("/opt/barkpark/sites"),
				Bytes: fp(8589934592),
				Count: fp(3),
				Top: []cloudclient.RelationSize{
					{Name: "search-capstone", Bytes: 5368709120},
					{Name: "hundesteder", Bytes: 2147483648},
				},
			},
		},
	})

	joined := strings.Join(lines, "\n")
	for _, want := range []string{
		"reported 2026-08-22T10:00:00Z",
		"root 12.0 GB of 40.0 GB used (30.0%)",
		"journal: 512.0 MB",
		"database: 3.3 GB",
		"/opt/barkpark/sites",
		"8.0 GB",
		"3 sites",
	} {
		if !strings.Contains(joined, want) {
			t.Fatalf("full report missing %q in:\n%s", want, joined)
		}
	}
	if len(blocks) != 1 || blocks[0].Type != "bar-chart" {
		t.Fatalf("want one bar-chart, got %+v", blocks)
	}
	bars, _ := blocks[0].Attrs["bars"].([]any)
	if len(bars) != 2 {
		t.Fatalf("bars=%d want 2", len(bars))
	}
	if label := bars[0].(map[string]any)["label"]; label != "search-capstone 5.0 GB" {
		t.Fatalf("bar label=%v want the named consumer and its size", label)
	}
	if max := blocks[0].Attrs["max"]; max != 8589934592.0 {
		t.Fatalf("bar max=%v want the sites total so a bar length IS the share", max)
	}
}

// TestSpaceSitesCountSaysWhichOfItsThreeStates is the -1 guard. A failed walk
// rendering as "0 sites" would be a measured claim built on a failed probe.
func TestSpaceSitesCountSaysWhichOfItsThreeStates(t *testing.T) {
	line := func(sites cloudclient.MetricsSpaceSites) string {
		lines, _ := spaceLines(cloudclient.MetricsResult{
			Space: &cloudclient.MetricsSpace{Sites: sites},
		})
		return strings.Join(lines, "\n")
	}

	failed := line(cloudclient.MetricsSpaceSites{Bytes: fp(1024), Count: fp(-1)})
	if !strings.Contains(failed, "the walk failed") {
		t.Fatalf("a -1 count must say the walk failed, got %q", failed)
	}
	if strings.Contains(failed, "0 sites") || strings.Contains(failed, "-1 sites") {
		t.Fatalf("a -1 count must never render as a number of sites, got %q", failed)
	}

	absent := line(cloudclient.MetricsSpaceSites{Bytes: fp(1024)})
	if !strings.Contains(absent, "site count not reported") {
		t.Fatalf("an absent count must say so, got %q", absent)
	}
	if strings.Contains(absent, "the walk failed") {
		t.Fatalf("an absent count is not a failed walk, got %q", absent)
	}

	real0 := line(cloudclient.MetricsSpaceSites{Bytes: fp(1024), Count: fp(0)})
	if !strings.Contains(real0, "0 sites") {
		t.Fatalf("a measured zero IS a real answer and must render, got %q", real0)
	}
}

// TestSpaceTopListNilIsNotEmpty keeps the unmeasured/measured-empty split that
// storageLines already holds one level down.
func TestSpaceTopListNilIsNotEmpty(t *testing.T) {
	nilTop, blocks := spaceLines(cloudclient.MetricsResult{
		Space: &cloudclient.MetricsSpace{Sites: cloudclient.MetricsSpaceSites{Bytes: fp(2048)}},
	})
	if !strings.Contains(strings.Join(nilTop, "\n"), "biggest consumers not reported") || blocks != nil {
		t.Fatalf("nil top must say unmeasured and draw nothing, got %q / %+v", nilTop, blocks)
	}

	emptyTop, blocks := spaceLines(cloudclient.MetricsResult{
		Space: &cloudclient.MetricsSpace{Sites: cloudclient.MetricsSpaceSites{
			Bytes: fp(2048), Top: []cloudclient.RelationSize{},
		}},
	})
	if !strings.Contains(strings.Join(emptyTop, "\n"), "no sites reported") || blocks != nil {
		t.Fatalf("measured-empty top must say so, got %q / %+v", emptyTop, blocks)
	}
}

// TestSpaceRootRefusesAShareItCannotCompute — a used figure with no capacity
// prints as the bare number. Inventing the denominator is how a 30%-full box
// and a 97%-full box come to read alike.
func TestSpaceRootRefusesAShareItCannotCompute(t *testing.T) {
	lines, _ := spaceLines(cloudclient.MetricsResult{
		Space: &cloudclient.MetricsSpace{
			Root: cloudclient.MetricsSpaceRoot{UsedBytes: fp(1073741824)},
		},
	})
	head := lines[0]
	if !strings.Contains(head, "capacity not reported") {
		t.Fatalf("missing capacity must be named, got %q", head)
	}
	if strings.Contains(head, "%") {
		t.Fatalf("no share may be printed without a denominator, got %q", head)
	}

	none, _ := spaceLines(cloudclient.MetricsResult{Space: &cloudclient.MetricsSpace{}})
	if !strings.Contains(none[0], "root filesystem not reported") {
		t.Fatalf("an unread root must say so rather than render 0, got %q", none[0])
	}
	if strings.Contains(none[0], "0 B") {
		t.Fatalf("an unread root must never render as zero bytes, got %q", none[0])
	}
}

// TestSpaceInferenceBracketStillHolds is the tripwire under the whole
// cannot/has-not distinction. That inference is only sound while `cpu_cores`
// and the space probe live in the SAME agent binary generation — they entered
// together in fc6a74ca23 (#9824). If someone ever ships one without the other,
// the render would start telling operators to upgrade an agent that is fine (or
// to wait for a report that can never come), and nothing else here would fail.
func TestSpaceInferenceBracketStillHolds(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("..", "agent", "report.go"))
	if err != nil {
		t.Fatalf("read internal/agent/report.go: %v", err)
	}
	src := string(raw)
	for _, marker := range []string{"cpu_cores", "root_used_bytes"} {
		if !strings.Contains(src, marker) {
			t.Fatalf("internal/agent/report.go no longer contains %q — the core-count/space bracket that "+
				"spaceLines infers from is broken, and the two absent states can no longer be told apart", marker)
		}
	}
}

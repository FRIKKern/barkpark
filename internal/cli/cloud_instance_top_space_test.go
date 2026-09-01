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

// --- the consumer roots and the residual --------------------------------------

// jarlSpace is the build-plane box's REAL space payload, read live from
// /v1/barkparks/<id>/metrics on 2026-09-01T20:33:42Z, with the byte figures
// corrected to the `du -kx` re-capture of the same trees minutes later (the
// landed payload had been through `du -h`, which rounds up: it reported
// containerd as exactly 14.0 GiB against a true 13.166).
//
// It is a real fixture for the reason the agent's is: a payload written in the
// shape the renderer is already assumed to handle makes a green mean nothing.
func jarlSpace() *cloudclient.MetricsSpace {
	return &cloudclient.MetricsSpace{
		Root:         cloudclient.MetricsSpaceRoot{UsedBytes: fp(38462406656), TotalBytes: fp(80290492416)},
		JournalBytes: fp(1932735283),
		Sites: cloudclient.MetricsSpaceSites{
			Dir: sptr("/opt/barkpark/sites"), Bytes: fp(-1), Count: fp(-1),
		},
		ConsumerRoots: []cloudclient.MetricsSpaceConsumerRoot{
			{
				Path: "/var/lib/containerd", Status: sptr("read"),
				Bytes: fp(14136475648), Count: fp(11),
				Top: []cloudclient.RelationSize{
					{Name: "io.containerd.snapshotter.v1.overlayfs", Bytes: 12072505344},
					{Name: "io.containerd.content.v1.content", Bytes: 2060689408},
				},
			},
			{
				Path: "/var/lib/barkpark-builder", Status: sptr("read"),
				Bytes: fp(11575521280), Count: fp(2),
				Top:   []cloudclient.RelationSize{{Name: "images", Bytes: 11573633024}},
			},
			{
				Path: "/var/log/journal", Status: sptr("read"),
				Bytes: fp(1971761152), Count: fp(2),
				Top:   []cloudclient.RelationSize{{Name: "e82ca0d33eb64f0f84e134be7b72c656", Bytes: 1963364352}},
			},
		},
		Residual: &cloudclient.MetricsSpaceResidual{
			Status: sptr("computed"), Bytes: fp(10778648576), OfBytes: fp(38462406656),
			MeasuredBytes: fp(27683758080), CountedRoots: fp(3), ExcludedRoots: fp(0),
			PGSource: sptr("none"), Reason: sptr(""),
		},
		ReportedAt: sptr("2026-09-01T20:33:42Z"),
	}
}

// TestSpaceLinesNamesTheConsumersOnThisBox is the reader that did not exist.
//
// The agent has posted consumer_roots since #13000 and `bp` decoded none of it:
// `grep -rn consumer_roots internal/cli internal/cloudclient` returned NOTHING
// on origin/main, so the only surface that could answer "what is eating that
// box's disk" was the browser console — and an operator in a terminal was back
// to ssh, with the answer already in the control plane's database. That is the
// space payload's own founding complaint, one layer up.
func TestSpaceLinesNamesTheConsumersOnThisBox(t *testing.T) {
	lines, _ := spaceLines(cloudclient.MetricsResult{Space: jarlSpace()})
	joined := strings.Join(lines, "\n")

	// The three roots by PATH, with their bytes. An operator's next command
	// takes a path; "containerd" is a daemon, not a place.
	for _, want := range []string{
		"/var/lib/containerd",
		"/var/lib/barkpark-builder",
		"/var/log/journal",
	} {
		if !strings.Contains(joined, want) {
			t.Errorf("render never names %s. This is the whole reader:\n%s", want, joined)
		}
	}

	// The biggest child by name, which is what an operator actually acts on.
	if !strings.Contains(joined, "io.containerd.snapshotter.v1.overlayfs") {
		t.Errorf("render names no child of containerd — an operator acts on the snapshotter "+
			"directory, never on /var/lib/containerd:\n%s", joined)
	}
	// The cap announces itself: 2 of 11 children shown.
	if !strings.Contains(joined, "top 2 of 11") {
		t.Errorf("the child list is capped and does not say so — a cap that eats its own "+
			"denominator can never announce itself:\n%s", joined)
	}
}

// TestSpaceLinesResidualNamesWhatWasNotMeasured is criterion 1 at the render.
func TestSpaceLinesResidualNamesWhatWasNotMeasured(t *testing.T) {
	lines, _ := spaceLines(cloudclient.MetricsResult{Space: jarlSpace()})
	joined := strings.Join(lines, "\n")

	if !strings.Contains(joined, "unaccounted:") {
		t.Fatalf("no unaccounted line. The roots above are a SUBSET of the disk and the render "+
			"must say how large a subset:\n%s", joined)
	}
	// The share AND the denominator that produced it, together.
	if !strings.Contains(joined, "28.0%") {
		t.Errorf("the residual's share is missing or wrong (want 28.0%% of 38462406656):\n%s", joined)
	}
	if !strings.Contains(joined, "of this box's") {
		t.Errorf("the residual renders a percentage without the volume behind it — the denominator "+
			"must travel with the share:\n%s", joined)
	}
	if !strings.Contains(joined, "measured 3 of 3 root(s) on this box") {
		t.Errorf("coverage is not stated per-box:\n%s", joined)
	}
}

// TestSpaceCoverageIsNeverStatedFleetWide is criterion 5, and it is a test
// about words that must NOT appear.
//
// Coverage is ANTI-CORRELATED with trouble: the same two roots cover 81.66% of
// the box at 96% disk and 34.86% of another — a 47-point spread — so any
// fleet-wide average is highest exactly where it is least true. There is no
// such thing as "the fleet's coverage" on this axis, only one box's at a time.
func TestSpaceCoverageIsNeverStatedFleetWide(t *testing.T) {
	for name, sp := range map[string]*cloudclient.MetricsSpace{
		"computed": jarlSpace(),
		"undefined": func() *cloudclient.MetricsSpace {
			s := jarlSpace()
			s.Residual = &cloudclient.MetricsSpaceResidual{
				Status: sptr("undefined"), Bytes: fp(-1), OfBytes: fp(38462406656),
				MeasuredBytes: fp(40000000000), CountedRoots: fp(5), ExcludedRoots: fp(0),
				PGSource: sptr("none"), Reason: sptr("roots-overlap-or-cross-a-mount"),
			}
			return s
		}(),
		"no residual at all": func() *cloudclient.MetricsSpace {
			s := jarlSpace()
			s.Residual = nil
			return s
		}(),
	} {
		t.Run(name, func(t *testing.T) {
			joined := strings.ToLower(strings.Join(mustSpaceLines(t, sp), "\n"))
			for _, banned := range []string{"fleet", "across boxes", "on average", "all boxes", "every box"} {
				if strings.Contains(joined, banned) {
					t.Errorf("the render says %q. Coverage is a per-box fact and averaging it hides "+
						"the boxes in trouble, which are exactly the ones with the worst coverage:\n%s",
						banned, joined)
				}
			}
			// And the positive half: it must anchor on THIS box.
			if !strings.Contains(joined, "this box") {
				t.Errorf("the render never says whose disk this is; a coverage claim with no subject "+
					"reads as a claim about all of them:\n%s", joined)
			}
		})
	}
}

func mustSpaceLines(t *testing.T, sp *cloudclient.MetricsSpace) []string {
	t.Helper()
	lines, _ := spaceLines(cloudclient.MetricsResult{Space: sp})
	return lines
}

// TestSpaceResidualNegativeIsNeverPrinted is criterion 4 at the render, and it
// is the last place a phantom gigabyte could reach a human.
func TestSpaceResidualNegativeIsNeverPrinted(t *testing.T) {
	sp := jarlSpace()
	sp.Residual = &cloudclient.MetricsSpaceResidual{
		Status: sptr("undefined"), Bytes: fp(-1), OfBytes: fp(38462406656),
		MeasuredBytes: fp(40000000000), CountedRoots: fp(5), ExcludedRoots: fp(0),
		PGSource: sptr("none"), Reason: sptr("roots-overlap-or-cross-a-mount"),
	}
	joined := strings.Join(mustSpaceLines(t, sp), "\n")

	if !strings.Contains(joined, "NOT COMPUTABLE") {
		t.Fatalf("an undefined residual must be worded as a refusal:\n%s", joined)
	}
	if !strings.Contains(joined, "overlap or cross a mount") {
		t.Errorf("the refusal does not say WHY, so the operator cannot act on it:\n%s", joined)
	}

	// No negative byte figure, and no "0 B unaccounted" either. The second is
	// the subtler failure: it is the strongest claim this axis can make — we saw
	// everything — reached by arithmetic going wrong.
	for _, banned := range []string{"-1", "-10", "unaccounted: 0 B", "unaccounted: -"} {
		if strings.Contains(joined, banned) {
			t.Errorf("the render contains %q. A negative gigabyte is a new dishonest number inside "+
				"the fix for dishonest numbers, and a clamped zero renders the LEAST-measured box as "+
				"the best-measured one:\n%s", banned, joined)
		}
	}

	// The evidence for the refusal is shown: measured against the denominator,
	// so the overlapping root is one step away.
	if !strings.Contains(joined, "37.3 GB") || !strings.Contains(joined, "35.8 GB") {
		t.Errorf("the refusal does not show its arithmetic; a refusal without the two numbers that "+
			"produced it is a shrug:\n%s", joined)
	}
}

// TestSpaceExcludedRootIsShownMeasuredAndNamed is criterion 2 at the render.
// The overlay is a COMPLETE, CORRECT reading of a tree that is not on the root
// filesystem, so it keeps its bytes and gains a reason.
func TestSpaceExcludedRootIsShownMeasuredAndNamed(t *testing.T) {
	sp := jarlSpace()
	sp.ConsumerRoots = append(sp.ConsumerRoots, cloudclient.MetricsSpaceConsumerRoot{
		Path: "/var/lib/docker/rootfs/overlayfs/63036f65", Status: sptr("read"),
		Bytes: fp(1542586368), Count: fp(1),
		ExcludedReason: sptr("cross-mount"),
	})
	sp.ConsumerRoots[1].ExcludedReason = sptr("under:/var/lib")
	sp.Residual.CountedRoots, sp.Residual.ExcludedRoots = fp(2), fp(2)

	joined := strings.Join(mustSpaceLines(t, sp), "\n")

	// Measured AND excluded — both, on the same line.
	if !strings.Contains(joined, "1.4 GB") {
		t.Errorf("the excluded overlay lost its bytes. Exclusion is about the SUBTRACTION, not the "+
			"measurement, and a correct 1.44 GiB reading must not vanish:\n%s", joined)
	}
	if !strings.Contains(joined, "different filesystem than /") {
		t.Errorf("the cross-mount exclusion is not worded:\n%s", joined)
	}
	if !strings.Contains(joined, "already counted inside /var/lib") {
		t.Errorf("the containment exclusion does not name WHAT covered it, so the operator has to "+
			"work out which pair collided:\n%s", joined)
	}
	if !strings.Contains(joined, "measured 2 of 4 root(s) on this box") {
		t.Errorf("coverage does not account for the excluded roots:\n%s", joined)
	}
}

// TestSpaceConsumerRootAbsentIsNeverRenderedAsZero carries the epic's sixth
// clause into the render: a probe pointed at a root that is not there reporting
// "nothing to see" for "I did not look" is the failure being repaired.
func TestSpaceConsumerRootAbsentIsNeverRenderedAsZero(t *testing.T) {
	sp := jarlSpace()
	sp.ConsumerRoots = []cloudclient.MetricsSpaceConsumerRoot{
		{Path: "/opt/barkpark/sites", Status: sptr("absent"), Bytes: fp(-1), Count: fp(-1)},
		{Path: "/var/lib/snapd", Status: sptr("unmeasured"), Bytes: fp(-1), Count: fp(-1)},
		{Path: "/var/lib/containerd", Status: sptr("degraded"), Bytes: fp(14136475648), Count: fp(11),
			Degraded: []string{"/var/lib/containerd/locked"}, DegradedCount: fp(3)},
	}
	joined := strings.Join(mustSpaceLines(t, sp), "\n")

	if !strings.Contains(joined, "not on this box") {
		t.Errorf("an absent root is not worded as absent:\n%s", joined)
	}
	if strings.Contains(joined, "/opt/barkpark/sites: 0 B") {
		t.Errorf("an absent root rendered as 0 bytes — that is the measured claim \"this tree is "+
			"empty\" about a directory that is not there:\n%s", joined)
	}
	if !strings.Contains(joined, "could not be read") {
		t.Errorf("an unmeasured root is not distinguished from an absent one; they are different "+
			"operator actions (fix the probe vs. point it somewhere real):\n%s", joined)
	}
	// A degraded total is a FLOOR. Rendering it as a size is a 70% under-report
	// wearing a confident face (measured: 212K reported against a true 712K).
	if !strings.Contains(joined, "OR MORE") {
		t.Errorf("a degraded root's floor is rendered as a size:\n%s", joined)
	}
	if !strings.Contains(joined, "3 subtree(s)") {
		t.Errorf("a degraded root does not say how much it could not see:\n%s", joined)
	}
}

// TestSpaceConsumerRootsAbsentListVsEmptyList: an agent that predates the axis
// and an agent told to look nowhere are different facts with different fixes.
func TestSpaceConsumerRootsAbsentListVsEmptyList(t *testing.T) {
	old := jarlSpace()
	old.ConsumerRoots = nil
	if got := strings.Join(mustSpaceLines(t, old), "\n"); !strings.Contains(got, "predates the consumer-root list") {
		t.Errorf("a nil root list must say the AGENT is old (upgrade it), never that the box is clean:\n%s", got)
	}

	none := jarlSpace()
	none.ConsumerRoots = []cloudclient.MetricsSpaceConsumerRoot{}
	if got := strings.Join(mustSpaceLines(t, none), "\n"); !strings.Contains(got, "none configured") {
		t.Errorf("an empty root list must say the box was told to look NOWHERE (configure it):\n%s", got)
	}
}

// TestSpaceResidualUnmeasuredWordsWhichRefusal: the two non-attempts have
// different remedies, so they must not render alike.
func TestSpaceResidualUnmeasuredWordsWhichRefusal(t *testing.T) {
	for reason, want := range map[string]string{
		"root-used-unmeasured":   "no root-filesystem used total",
		"root-device-unverified": "could not verify which filesystem",
	} {
		sp := jarlSpace()
		sp.Residual = &cloudclient.MetricsSpaceResidual{
			Status: sptr("unmeasured"), Bytes: fp(-1), OfBytes: fp(-1), Reason: sptr(reason),
		}
		if got := strings.Join(mustSpaceLines(t, sp), "\n"); !strings.Contains(got, want) {
			t.Errorf("reason %q renders without %q:\n%s", reason, want, got)
		}
	}

	// And the denominator warning is on the arm where it matters: df's capacity
	// percent is a share of a different whole and is not a substitute for it.
	sp := jarlSpace()
	sp.Residual = &cloudclient.MetricsSpaceResidual{
		Status: sptr("unmeasured"), Bytes: fp(-1), OfBytes: fp(-1), Reason: sptr("root-used-unmeasured"),
	}
	if got := strings.Join(mustSpaceLines(t, sp), "\n"); !strings.Contains(got, "share of a different whole") {
		t.Errorf("nothing warns the reader off substituting the capacity percent:\n%s", got)
	}
}

// TestSpaceResidualPGSourceIsStated is criterion 3 at the render: postgres is
// the one consumer measurable twice, so which measurement was used is shown
// rather than assumed.
func TestSpaceResidualPGSourceIsStated(t *testing.T) {
	for source, want := range map[string]string{
		"du-root":       "postgres counted once, via its du root",
		"pg-size-bytes": "postgres counted once, via pg_database_size",
	} {
		sp := jarlSpace()
		sp.Residual.PGSource = sptr(source)
		if got := strings.Join(mustSpaceLines(t, sp), "\n"); !strings.Contains(got, want) {
			t.Errorf("pg_source %q renders without %q:\n%s", source, want, got)
		}
	}

	// "none" says nothing, because there is nothing to disambiguate.
	sp := jarlSpace()
	sp.Residual.PGSource = sptr("none")
	if got := strings.Join(mustSpaceLines(t, sp), "\n"); strings.Contains(got, "postgres counted once") {
		t.Errorf("a box with no postgres claims a postgres decision:\n%s", got)
	}
}

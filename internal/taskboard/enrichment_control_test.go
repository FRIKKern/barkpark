package taskboard

import (
	"fmt"
	"math"
	"testing"
)

// mkRows expands a (class, stratum, total, missing) tuple into rows. Fixtures
// are written as the counts actually measured off the ledger so the test reads
// like the census that produced it.
func mkRows(class, stratum string, total, missing int) []EnrichmentRow {
	out := make([]EnrichmentRow, 0, total)
	for i := 0; i < total; i++ {
		out = append(out, EnrichmentRow{
			ID:      fmt.Sprintf("%s-%s-%d", class, stratum, i),
			Class:   class,
			Stratum: stratum,
			Missing: i < missing,
		})
	}
	return out
}

func cat(groups ...[]EnrichmentRow) []EnrichmentRow {
	var out []EnrichmentRow
	for _, g := range groups {
		out = append(out, g...)
	}
	return out
}

// realCorpus is the REAL SHAPE, not a synthetic one: the 2026-09-17 census of
// close_reason absence over 8,028 terminal task rows, stratified by the worker
// recorded at claim.closed_by.
//
//	stale-disposition class : 182 rows,   12 missing close_reason (6.59%)
//	clean closed            : 1,184 rows,  7 missing            (0.59%)
//	no disposition          : 6,662 rows, 129 missing           (1.94%)
//	partition is exact: 182 + 1184 + 6662 = 8028
//
// All twelve missing-close_reason rows in the stale class were closed on
// 2026-09-02 by four workers, whose own no-disposition rows miss close_reason at
// 33-56%. Those four closed ZERO clean rows, which is why the clean baseline has
// no mass inside any of their strata.
func realCorpus() []EnrichmentRow {
	return cat(
		// The four bulk-closing workers: stale / noDisp, measured counts.
		mkRows("stale", "lead-cli-2-r", 2, 2), mkRows("noDisp", "lead-cli-2-r", 3, 1),
		mkRows("stale", "lead-docs", 2, 1), mkRows("noDisp", "lead-docs", 27, 15),
		mkRows("stale", "lead-grip", 14, 4), mkRows("noDisp", "lead-grip", 10, 5),
		mkRows("stale", "lead-pds", 12, 5), mkRows("noDisp", "lead-pds", 21, 11),
		// Everyone else. 182-30 stale, none missing; the whole clean class;
		// 6662-61 noDisp rows carrying the remaining 129-32 absences.
		mkRows("stale", "other", 152, 0),
		mkRows("clean", "other", 1184, 7),
		mkRows("noDisp", "other", 6601, 97),
	)
}

// The headline finding the row was filed on, and its refutation.
func TestControlEnrichment_RealCorpus_StaleVsClean_IsConfounded(t *testing.T) {
	v := ControlEnrichment(realCorpus(), "stale", "clean", 2)

	if v.Suspect.Total != 182 || v.Suspect.Missing != 12 {
		t.Fatalf("suspect class mis-sliced: got %s, want 12/182", v.Suspect)
	}
	if v.Baseline.Total != 1184 || v.Baseline.Missing != 7 {
		t.Fatalf("baseline class mis-sliced: got %s, want 7/1184", v.Baseline)
	}
	if got := v.MarginalRatio(); math.Abs(got-11.15) > 0.2 {
		t.Fatalf("marginal enrichment = %.2fx, want ~11.2x (the filed number)", got)
	}
	if !v.Discriminates {
		t.Fatalf("close_reason IS populated on 7,880 of 8,028 rows; the control must not call it non-discriminating")
	}
	// The four bulk-closing strata hold no clean rows at all, so only "other"
	// is comparable — and inside it the stale class misses close_reason on
	// ZERO of 152 rows.
	if v.Comparable != 1 {
		t.Fatalf("comparable strata = %d, want 1 (only 'other' carries both classes)", v.Comparable)
	}
	if v.Survives {
		t.Fatalf("enrichment must NOT survive the closing-worker control; reason was %q", v.Reason)
	}
	if v.PooledSuspect.Missing != 0 {
		t.Fatalf("pooled suspect missing = %d, want 0 (all 12 sit in strata with no clean rows)", v.PooledSuspect.Missing)
	}
}

// The same corpus restricted to the four workers who actually closed the twelve:
// there the stale class misses close_reason LESS often than their other rows, so
// the effect does not merely vanish, it reverses.
func TestControlEnrichment_RealCorpus_WithinClosingWorkers_Reverses(t *testing.T) {
	rows := cat(
		mkRows("stale", "lead-cli-2-r", 2, 2), mkRows("noDisp", "lead-cli-2-r", 3, 1),
		mkRows("stale", "lead-docs", 2, 1), mkRows("noDisp", "lead-docs", 27, 15),
		mkRows("stale", "lead-grip", 14, 4), mkRows("noDisp", "lead-grip", 10, 5),
		mkRows("stale", "lead-pds", 12, 5), mkRows("noDisp", "lead-pds", 21, 11),
	)
	v := ControlEnrichment(rows, "stale", "noDisp", 2)
	if v.Comparable != 4 {
		t.Fatalf("comparable strata = %d, want 4", v.Comparable)
	}
	if v.PooledSuspect.Total != 30 || v.PooledSuspect.Missing != 12 {
		t.Fatalf("pooled suspect = %s, want 12/30", v.PooledSuspect)
	}
	if v.PooledBase.Total != 61 || v.PooledBase.Missing != 32 {
		t.Fatalf("pooled baseline = %s, want 32/61", v.PooledBase)
	}
	if v.Survives {
		t.Fatalf("within the closing workers the stale class misses LESS (40%% vs 52%%); must not survive: %q", v.Reason)
	}
}

// The positive arm. Without it the suite would pass on a function hard-wired to
// refuse, which is the uniform-verdict failure this control exists to catch.
func TestControlEnrichment_SurvivesWhenEffectIsInEveryStratum(t *testing.T) {
	rows := cat(
		mkRows("stale", "w1", 50, 20), mkRows("clean", "w1", 50, 5),
		mkRows("stale", "w2", 40, 16), mkRows("clean", "w2", 60, 6),
		mkRows("stale", "w3", 30, 12), mkRows("clean", "w3", 30, 3),
	)
	v := ControlEnrichment(rows, "stale", "clean", 2)
	if !v.Survives {
		t.Fatalf("a within-stratum effect present in all 3 strata must survive: %q", v.Reason)
	}
	if v.Comparable != 3 {
		t.Fatalf("comparable strata = %d, want 3", v.Comparable)
	}
	if got := v.PooledRatio(); got < 2 {
		t.Fatalf("pooled ratio = %.2fx, want the ~4x that is in every stratum", got)
	}
}

// The null-everywhere trap: a field absent on every row rates 100% in both
// classes and would report a clean 1.0x with no warning at all.
func TestControlEnrichment_RefusesAFieldThatIsNullEverywhere(t *testing.T) {
	rows := cat(
		mkRows("stale", "w1", 20, 20), mkRows("clean", "w1", 80, 80),
	)
	v := ControlEnrichment(rows, "stale", "clean", 2)
	if v.Discriminates || v.Survives {
		t.Fatalf("a field missing on 100/100 rows discriminates nothing: %+v", v)
	}
	if v.Reason == "" {
		t.Fatal("refusal must name which floor fired")
	}
}

// A confound perfectly aligned with the class: every stratum holds one class
// only, so nothing is separable and the marginal ratio must be reported as
// UNCONTROLLED rather than as a finding.
func TestControlEnrichment_RefusesWhenNoStratumHoldsBothClasses(t *testing.T) {
	rows := cat(
		mkRows("stale", "w1", 30, 12), mkRows("clean", "w2", 300, 2),
	)
	v := ControlEnrichment(rows, "stale", "clean", 2)
	if v.Comparable != 0 {
		t.Fatalf("comparable strata = %d, want 0", v.Comparable)
	}
	if v.Survives {
		t.Fatalf("an unseparable comparison must not survive: %q", v.Reason)
	}
	if v.MarginalRatio() < 10 {
		t.Fatalf("the marginal ratio is still reported (%.1fx), it is just not a finding", v.MarginalRatio())
	}
}

// The selftest's own distribution must be SPLIT: a suite in which every arm
// reaches the same verdict measures nothing about the function.
func TestControlEnrichment_SelftestDistributionIsSplit(t *testing.T) {
	arms := map[string]EnrichmentVerdict{
		"real-stale-vs-clean": ControlEnrichment(realCorpus(), "stale", "clean", 2),
		"synthetic-survives": ControlEnrichment(cat(
			mkRows("stale", "w1", 50, 20), mkRows("clean", "w1", 50, 5),
			mkRows("stale", "w2", 40, 16), mkRows("clean", "w2", 60, 6),
		), "stale", "clean", 2),
		"null-everywhere": ControlEnrichment(cat(
			mkRows("stale", "w1", 20, 20), mkRows("clean", "w1", 80, 80),
		), "stale", "clean", 2),
	}
	survived, refused := 0, 0
	for name, v := range arms {
		if v.Survives {
			survived++
		} else {
			refused++
		}
		t.Logf("%s: survives=%v %s", name, v.Survives, v.Reason)
	}
	if survived == 0 || refused == 0 {
		t.Fatalf("uniform verdict across arms (survived=%d refused=%d) — the fixtures encode a shape the function cannot distinguish", survived, refused)
	}
}

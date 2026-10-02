package cli

import (
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/taskboard"
)

// detail builds one terminal-row fixture in the wire vocabulary the adapter
// reads: lifecycle_status, content.disposition, content.close_reason,
// claim.closed_by. Nothing here goes through the control's own types, so the
// test exercises the ledger→control projection and not just the arithmetic.
func detail(id, lifecycle, disposition, closeReason, closedBy string) taskboard.TaskDetail {
	d := taskboard.TaskDetail{Disposition: disposition, CloseReason: closeReason, ClosedBy: closedBy}
	d.DocID = id
	d.Lifecycle = lifecycle
	return d
}

func index(ds ...taskboard.TaskDetail) taskboard.DetailIndex {
	ix := taskboard.DetailIndex{}
	for _, d := range ds {
		ix[d.DocID] = d
	}
	return ix
}

// bulkClosed reproduces the 2026-09-17 ledger shape at small scale: a class
// whose every close_reason absence sits with four bulk-closing workers who
// closed NO clean rows at all.
func bulkClosed() taskboard.DetailIndex {
	var ds []taskboard.TaskDetail
	add := func(n int, prefix, lifecycle, disp, reason, by string) {
		for i := 0; i < n; i++ {
			ds = append(ds, detail(prefix+string(rune('a'+i%26))+string(rune('0'+i/26)), lifecycle, disp, reason, by))
		}
	}
	// The bulk closers: stale rows missing the reason, plus their own
	// no-disposition rows missing it even more often.
	add(4, "s-grip-", "done", "open", "", "lead-grip")
	add(10, "n-grip-", "done", "", "", "lead-grip")
	add(5, "n-gripok-", "done", "", "landed #1", "lead-grip")
	add(5, "s-pds-", "done", "open", "", "lead-pds")
	add(11, "n-pds-", "done", "", "", "lead-pds")
	add(10, "n-pdsok-", "done", "", "landed #2", "lead-pds")
	// Everyone else: the rest of the stale class with reasons recorded, and
	// the whole clean class. No clean row sits in a bulk-closer stratum.
	add(60, "s-other-", "done", "open", "landed #3", "lead-other")
	add(200, "c-other-", "done", "closed", "landed #4", "lead-other")
	add(7, "c-othermiss-", "done", "closed", "", "lead-other")
	return index(ds...)
}

// The refusal direction, on the ledger's own shape: the marginal ratio is real
// and large, and it does not survive the closing-worker control.
func TestTaskEnrichment_BulkCloseConfoundIsRefused(t *testing.T) {
	v := enrichmentVerdictOf(bulkClosed())

	if v.Suspect.Total != 69 || v.Suspect.Missing != 9 {
		t.Fatalf("suspect class mis-projected: got %s, want 9/69", v.Suspect)
	}
	if v.Baseline.Total != 207 || v.Baseline.Missing != 7 {
		t.Fatalf("baseline class mis-projected: got %s, want 7/207", v.Baseline)
	}
	if got := v.MarginalRatio(); got < 3 {
		t.Fatalf("marginal = %.2fx, want the large uncontrolled ratio the finding was filed on", got)
	}
	if !v.Discriminates {
		t.Fatal("close_reason is populated on most rows here; the floor must not fire")
	}
	if v.Comparable != 1 {
		t.Fatalf("comparable strata = %d, want 1 (only lead-other carries both classes)", v.Comparable)
	}
	if v.Survives {
		t.Fatalf("the enrichment must not survive the closing-worker control: %q", v.Reason)
	}
	if v.PooledSuspect.Missing != 0 {
		t.Fatalf("pooled suspect missing = %d, want 0 — every absence sits in a bulk-closer stratum", v.PooledSuspect.Missing)
	}
}

// The pass direction, same projection: an effect present INSIDE every stratum
// survives. Without this arm the suite would be green against an adapter or a
// control hard-wired to refuse.
func TestTaskEnrichment_GenuineFindingSurvives(t *testing.T) {
	var ds []taskboard.TaskDetail
	add := func(n int, prefix, disp, reason, by string) {
		for i := 0; i < n; i++ {
			ds = append(ds, detail(prefix+string(rune('a'+i%26))+string(rune('0'+i/26)), "done", disp, reason, by))
		}
	}
	for _, w := range []string{"w1", "w2", "w3"} {
		add(8, "s-miss-"+w+"-", "open", "", w)   // 8/20 stale missing
		add(12, "s-ok-"+w+"-", "open", "r", w)   //
		add(2, "c-miss-"+w+"-", "closed", "", w) // 2/20 clean missing
		add(18, "c-ok-"+w+"-", "closed", "r", w) //
	}
	v := enrichmentVerdictOf(index(ds...))

	if !v.Survives {
		t.Fatalf("an effect present in all 3 strata must survive: %q", v.Reason)
	}
	if v.Comparable != 3 {
		t.Fatalf("comparable strata = %d, want 3", v.Comparable)
	}
	if got := v.PooledRatio(); got < 2 {
		t.Fatalf("pooled ratio = %.2fx, want the ~4x present in every stratum", got)
	}
}

// Open rows have no close_reason by definition. Admitting them would put
// thousands of definitionally-missing rows in the denominator and trip the
// discrimination floor on a corpus where the field is well populated.
func TestTaskEnrichment_NonTerminalRowsAreDropped(t *testing.T) {
	ix := bulkClosed()
	before := enrichmentVerdictOf(ix)
	for i := 0; i < 500; i++ {
		d := detail("open-"+string(rune('a'+i%26))+string(rune('0'+i/26)), "open", "", "", "")
		ix[d.DocID] = d
	}
	after := enrichmentVerdictOf(ix)

	// The verdict arms alone do NOT catch a dropped terminal filter: open rows
	// carry no disposition, so they land in neither class and leave Suspect and
	// Baseline untouched. The assertion that bites is on the CORPUS — the
	// denominator the discrimination floor is computed over — so this arm reds
	// when the filter is removed and stays quiet when it is not.
	list := make([]taskboard.TaskDetail, 0, len(ix))
	for _, d := range ix {
		list = append(list, d)
	}
	if got, want := len(taskboard.CloseReasonRows(list)), len(ix)-500; got != want {
		t.Fatalf("projected corpus = %d rows, want %d — the 500 open rows are in the denominator", got, want)
	}
	if !after.Discriminates {
		t.Fatal("open rows must not flip the discrimination floor — they are not terminal")
	}
	if before.Suspect != after.Suspect || before.Baseline != after.Baseline || before.Reason != after.Reason {
		t.Fatalf("open rows changed the verdict: %s -> %s / %q -> %q",
			before.Suspect, after.Suspect, before.Reason, after.Reason)
	}
}

// The null-everywhere trap on the live path: a field absent on every terminal
// row rates 100% in both classes and would report a serene 1.0x.
func TestTaskEnrichment_RefusesAFieldAbsentOnEveryTerminalRow(t *testing.T) {
	var ds []taskboard.TaskDetail
	for i := 0; i < 40; i++ {
		disp := "open"
		if i%2 == 0 {
			disp = "closed"
		}
		ds = append(ds, detail("x"+string(rune('a'+i%26))+string(rune('0'+i/26)), "done", disp, "", "w1"))
	}
	v := enrichmentVerdictOf(index(ds...))
	if v.Discriminates || v.Survives {
		t.Fatalf("a field missing on every terminal row discriminates nothing: %+v", v)
	}
	if !strings.Contains(verdictWord(v), "NO MEASUREMENT") {
		t.Fatalf("verdict word = %q, want the NO MEASUREMENT refusal", verdictWord(v))
	}
}

// The three refusals must not collapse into one word: a reader who cannot tell
// "the instrument is broken" from "the finding is confounded" has lost the
// measurement.
func TestTaskEnrichment_VerdictWordsAreDistinct(t *testing.T) {
	seen := map[string]string{}
	for name, v := range map[string]taskboard.EnrichmentVerdict{
		"confounded": enrichmentVerdictOf(bulkClosed()),
		"nomeasure":  taskboard.ControlEnrichment(nil, taskboard.ClassStale, taskboard.ClassClean, 2),
		"uncontrolled": taskboard.ControlEnrichment([]taskboard.EnrichmentRow{
			{ID: "a", Class: taskboard.ClassStale, Stratum: "w1", Missing: true},
			{ID: "b", Class: taskboard.ClassStale, Stratum: "w1", Missing: true},
			{ID: "c", Class: taskboard.ClassClean, Stratum: "w2"},
			{ID: "d", Class: taskboard.ClassClean, Stratum: "w2"},
		}, taskboard.ClassStale, taskboard.ClassClean, 2),
	} {
		w := verdictWord(v)
		if prev, dup := seen[w]; dup {
			t.Fatalf("%s and %s both render %q — the refusals are not distinguishable", prev, name, w)
		}
		seen[w] = name
	}
	if len(seen) != 3 {
		t.Fatalf("got %d distinct verdict words, want 3", len(seen))
	}
}

// The adapter's vocabulary mapping, spelled once so a rename cannot silently
// reclass a third of the corpus.
func TestDispositionClassAndStratum(t *testing.T) {
	for in, want := range map[string]string{
		"":       taskboard.ClassNoDisposition,
		"  ":     taskboard.ClassNoDisposition,
		"closed": taskboard.ClassClean,
		"CLOSED": taskboard.ClassClean,
		"open":   taskboard.ClassStale,
		"parked": taskboard.ClassStale,
		"open — demoted child of truth-grip-epic (charter D117)": taskboard.ClassStale,
	} {
		if got := taskboard.DispositionClass(in); got != want {
			t.Errorf("DispositionClass(%q) = %q, want %q", in, got, want)
		}
	}
	if got := taskboard.ClosingStratum("  "); got != taskboard.UnattributedStratum {
		t.Errorf("a blank closed_by must land in %q, got %q", taskboard.UnattributedStratum, got)
	}
	if !taskboard.IsTerminalLifecycle("cancelled") || taskboard.IsTerminalLifecycle("in_progress") {
		t.Error("terminal predicate mis-classifies cancelled/in_progress")
	}
}

// The enumeration is load-bearing: the row this command serves demands the
// absent-reason rows be listed by id and adjudicated one at a time. A verdict
// with no ids is a number nobody can act on.
func TestTaskEnrichment_EnumeratesTheSuspectAbsences(t *testing.T) {
	ids := missingIDs(bulkClosed())
	if len(ids) != 9 {
		t.Fatalf("enumerated %d ids, want 9 — the same count the verdict reports as Suspect.Missing", len(ids))
	}
	for i := 1; i < len(ids); i++ {
		if ids[i-1] >= ids[i] {
			t.Fatalf("ids are not sorted: %q before %q", ids[i-1], ids[i])
		}
	}
	// It must list the SUSPECT class only. A clean-class row missing its reason
	// is a different (and much rarer) defect; folding it in here would inflate
	// the list the operator adjudicates by the baseline's own absences.
	for _, id := range ids {
		if !strings.HasPrefix(id, "s-") {
			t.Fatalf("id %q is not a stale-class row — the enumeration leaked the baseline", id)
		}
	}
	if got := enrichmentVerdictOf(bulkClosed()).Suspect.Missing; got != len(ids) {
		t.Fatalf("verdict says %d absences, enumeration lists %d — the report contradicts itself", got, len(ids))
	}
}

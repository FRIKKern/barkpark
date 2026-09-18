package taskboard

import (
	"fmt"
	"sort"
	"strings"
)

// Stratified enrichment control for ledger field-absence findings.
//
// A finding of the shape "field F is absent on X% of class A but only Y% of
// class B, an Nx enrichment, therefore class A is defective" is the most common
// false positive this ledger produces. Two failure modes kill it, and neither is
// visible in the ratio itself:
//
//  1. The field is absent (or present) on nearly every row in the corpus. A
//     field that is null everywhere discriminates nothing; the ratio is noise on
//     a handful of rows.
//  2. The classes differ in some third variable that actually drives the
//     absence — who closed the row, which lane filed it, when it was written. A
//     bulk-close session that skipped F on half of everything it touched will
//     manufacture an enrichment in whichever class it happened to touch most.
//
// EnrichmentVerdict refuses to report a marginal ratio on its own: it always
// re-computes the comparison INSIDE each stratum of the named confound and says
// whether the effect survives. A caller that only wants the headline number
// cannot get one without also getting the control.
//

// EnrichmentRow is one terminal ledger row reduced to the three facts the
// control needs. Nothing here is task-specific: Class is the partition under
// suspicion, Stratum is the candidate confound, Missing is the field absence.
type EnrichmentRow struct {
	ID      string
	Class   string
	Stratum string
	Missing bool
}

// Ratio is a missing-count over a denominator. Rate is NaN-free: an empty
// denominator reports 0, and callers are expected to check Total first.
type Ratio struct {
	Total   int
	Missing int
}

// Rate returns the absence rate in [0,1]; an empty stratum rates 0.
func (r Ratio) Rate() float64 {
	if r.Total == 0 {
		return 0
	}
	return float64(r.Missing) / float64(r.Total)
}

func (r Ratio) String() string {
	return fmt.Sprintf("%d/%d (%.2f%%)", r.Missing, r.Total, r.Rate()*100)
}

// StratumRatio pairs the suspect and baseline ratios inside one stratum.
type StratumRatio struct {
	Stratum  string
	Suspect  Ratio
	Baseline Ratio
}

// Comparable reports whether this stratum carries enough of BOTH classes to say
// anything. A stratum holding only one class cannot separate class from
// confound and is excluded from the pooled control rather than counted as
// agreement.
func (s StratumRatio) Comparable(min int) bool {
	return s.Suspect.Total >= min && s.Baseline.Total >= min
}

// EnrichmentVerdict is the whole finding: the marginal ratio a naive report
// would quote, the same comparison pooled within strata, and the survival call.
type EnrichmentVerdict struct {
	Suspect       Ratio
	Baseline      Ratio
	Strata        []StratumRatio
	PooledSuspect Ratio
	PooledBase    Ratio
	Comparable    int
	Discriminates bool
	Survives      bool
	Reason        string
}

// MarginalRatio is the headline enrichment: suspect rate over baseline rate. It
// is 0 when the baseline rate is 0 and the suspect rate is 0 too, and +Inf-free:
// a zero baseline with a non-zero suspect reports 0 and sets Reason instead, so
// no caller prints "Infx".
func (v EnrichmentVerdict) MarginalRatio() float64 {
	if v.Baseline.Rate() == 0 {
		return 0
	}
	return v.Suspect.Rate() / v.Baseline.Rate()
}

// PooledRatio is the same quantity recomputed inside the confound strata.
func (v EnrichmentVerdict) PooledRatio() float64 {
	if v.PooledBase.Rate() == 0 {
		return 0
	}
	return v.PooledSuspect.Rate() / v.PooledBase.Rate()
}

// ControlEnrichment runs the control. suspectClass and baselineClass name two
// values of EnrichmentRow.Class; rows in neither class are ignored for the
// comparison but still count toward the discrimination floor, because a field
// that is null across the WHOLE corpus is a broken instrument no matter how the
// two classes happen to split.
//
// minStratum is the per-class floor a stratum must clear to enter the pooled
// control. A stratum below it is listed in Strata but excluded from the pool.
//
// Survives is true only when the field discriminates AND the pooled
// within-stratum suspect rate is strictly greater than the pooled baseline rate.
// Everything else — no comparable strata, a field that is absent or present
// almost everywhere, a pooled effect that vanishes or reverses — is a refusal
// with a Reason naming which one fired.
// @canonical capability:ledger-enrichment-control aka:false-done-carveout,close_reason-enrichment
func ControlEnrichment(rows []EnrichmentRow, suspectClass, baselineClass string, minStratum int) EnrichmentVerdict {
	if minStratum < 1 {
		minStratum = 1
	}
	v := EnrichmentVerdict{Comparable: 0}

	corpusMissing := 0
	byStratum := map[string]*StratumRatio{}
	for _, r := range rows {
		if r.Missing {
			corpusMissing++
		}
		switch r.Class {
		case suspectClass:
			v.Suspect.Total++
			if r.Missing {
				v.Suspect.Missing++
			}
		case baselineClass:
			v.Baseline.Total++
			if r.Missing {
				v.Baseline.Missing++
			}
		default:
			continue
		}
		s, ok := byStratum[r.Stratum]
		if !ok {
			s = &StratumRatio{Stratum: r.Stratum}
			byStratum[r.Stratum] = s
		}
		target := &s.Baseline
		if r.Class == suspectClass {
			target = &s.Suspect
		}
		target.Total++
		if r.Missing {
			target.Missing++
		}
	}

	keys := make([]string, 0, len(byStratum))
	for k := range byStratum {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		s := *byStratum[k]
		v.Strata = append(v.Strata, s)
		if s.Comparable(minStratum) {
			v.Comparable++
			v.PooledSuspect.Total += s.Suspect.Total
			v.PooledSuspect.Missing += s.Suspect.Missing
			v.PooledBase.Total += s.Baseline.Total
			v.PooledBase.Missing += s.Baseline.Missing
		}
	}

	// Discrimination floor: the field must be absent on at least one row and
	// present on at least one row across the whole corpus handed in. A field
	// null everywhere, or filled everywhere, separates nothing.
	v.Discriminates = len(rows) > 0 && corpusMissing > 0 && corpusMissing < len(rows)

	switch {
	case !v.Discriminates:
		v.Reason = fmt.Sprintf("field does not discriminate: %d of %d corpus rows missing — a field absent (or present) on every row separates nothing", corpusMissing, len(rows))
	case v.Suspect.Total == 0 || v.Baseline.Total == 0:
		v.Reason = fmt.Sprintf("one class is empty: suspect %s, baseline %s — no comparison exists", v.Suspect, v.Baseline)
	case v.Comparable == 0:
		v.Reason = fmt.Sprintf("no stratum carries >=%d rows of BOTH classes, so class and confound are not separable here; the marginal %.1fx is UNCONTROLLED", minStratum, v.MarginalRatio())
	case v.PooledSuspect.Rate() > v.PooledBase.Rate():
		v.Survives = true
		v.Reason = fmt.Sprintf("survives: within %d comparable strata the suspect class still misses more (%s vs %s, %.1fx) — marginal was %.1fx", v.Comparable, v.PooledSuspect, v.PooledBase, v.PooledRatio(), v.MarginalRatio())
	default:
		v.Reason = fmt.Sprintf("CONFOUNDED by stratum: the marginal %.1fx collapses to %.1fx once pooled within %d comparable strata (%s vs %s) — the absence tracks the stratum, not the class", v.MarginalRatio(), v.PooledRatio(), v.Comparable, v.PooledSuspect, v.PooledBase)
	}
	return v
}

// ── the live-ledger adapter ────────────────────────────────────────────────
//
// Everything above is pure arithmetic over EnrichmentRow. The adapter below is
// the ONE place the ledger's own vocabulary is spelled, so the control has
// exactly one live consumer and cannot drift from the shape it is fed.

// Disposition class names. The suspect class is the stale-disposition
// population: a row that reached a terminal lifecycle while its durable
// adjudication still says something other than "closed".
const (
	// ClassStale — terminal lifecycle, disposition authored and NOT "closed".
	ClassStale = "stale"
	// ClassClean — terminal lifecycle, disposition "closed".
	ClassClean = "clean"
	// ClassNoDisposition — terminal lifecycle, never adjudicated at all. It is
	// neither suspect nor baseline for the stale-vs-clean comparison, but it is
	// handed to the control anyway: the discrimination floor is a statement
	// about the WHOLE corpus, and a field null across every terminal row is a
	// broken instrument regardless of how two classes happen to split.
	ClassNoDisposition = "noDisp"
)

// UnattributedStratum is the stratum a row lands in when the ledger records no
// closing worker. It is a REAL stratum, not a discard: those rows are still
// corpus, and lumping them under one name is honest about the fact that they
// cannot separate class from confound. It will rarely be Comparable, which is
// the correct outcome — a stratum that cannot separate should not vote.
const UnattributedStratum = "«unattributed»"

// CloseReasonRows projects terminal task details onto the control's input for
// the close_reason absence finding: class from content.disposition, stratum
// from claim.closed_by, Missing from an empty content.close_reason.
//
// Non-terminal rows are DROPPED rather than classed. An open row has no
// close_reason by definition, so admitting them puts thousands of
// definitionally-missing rows into the CORPUS DENOMINATOR — the population the
// discrimination floor is computed over. On the live ledger that does not by
// itself flip the floor, and it changes neither class rate, which is exactly
// why the drop needs an arm asserting the projected corpus size rather than
// the verdict: the verdict alone cannot see it.
func CloseReasonRows(details []TaskDetail) []EnrichmentRow {
	out := make([]EnrichmentRow, 0, len(details))
	for _, d := range details {
		if !IsTerminalLifecycle(d.Lifecycle) {
			continue
		}
		out = append(out, EnrichmentRow{
			ID:      BareID(d.DocID),
			Class:   DispositionClass(d.Disposition),
			Stratum: ClosingStratum(d.ClosedBy),
			Missing: strings.TrimSpace(d.CloseReason) == "",
		})
	}
	return out
}

// IsTerminalLifecycle reports whether a lifecycle_status is one the server can
// only reach through a close. "closed" is accepted alongside the two stored
// enum values because the board's own Task.Lifecycle comment documents it as a
// value that can arrive as served.
func IsTerminalLifecycle(lifecycle string) bool {
	switch strings.ToLower(strings.TrimSpace(lifecycle)) {
	case "done", "cancelled", "closed":
		return true
	}
	return false
}

// DispositionClass maps content.disposition onto the three class names. An
// unauthored disposition is ClassNoDisposition; "closed" (in any casing — the
// server downcases, but a hand-written row may not have gone through it) is
// ClassClean; everything else authored — "open", "parked", and any prose a
// writer appended to the term — is ClassStale.
func DispositionClass(disposition string) string {
	d := strings.ToLower(strings.TrimSpace(disposition))
	switch {
	case d == "":
		return ClassNoDisposition
	case d == "closed":
		return ClassClean
	default:
		return ClassStale
	}
}

// ClosingStratum names the confound axis for one row.
func ClosingStratum(closedBy string) string {
	if s := strings.TrimSpace(closedBy); s != "" {
		return s
	}
	return UnattributedStratum
}

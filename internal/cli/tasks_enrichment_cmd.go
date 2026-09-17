package cli

// tasks_enrichment_cmd.go — `bp task enrichment`: the live consumer of
// taskboard.ControlEnrichment.
//
// It answers ONE question against the real ledger: is the close_reason absence
// enrichment in the stale-disposition class a property of the class, or of the
// worker who happened to close those rows? A finding of the shape "field F is
// absent Nx more often in class A" is the commonest false positive this ledger
// produces, and neither of its two killers is visible in the ratio itself — a
// field null (or filled) across the whole corpus, or a third variable that
// actually drives the absence.
//
// The command CANNOT print the marginal ratio without also printing the
// controlled one and the survival call: both come out of a single
// ControlEnrichment verdict. That is the whole point of routing the report
// through the control rather than computing a ratio here.
//
// Advisory, like `bp task lint`: it always exits 0 on a successful read. A
// CONFOUNDED verdict is a correct measurement, not a command failure. Only an
// operational failure (fetch, usage) yields a non-OK code.

import (
	"fmt"
	"sort"
	"strings"

	"github.com/FRIKKern/barkpark/internal/apiclient"
	"github.com/FRIKKern/barkpark/internal/manifest"
	"github.com/FRIKKern/barkpark/internal/taskboard"
)

// defaultMinStratum is the per-class floor a stratum must clear to enter the
// pooled control. Two is the smallest number that can disagree with itself; a
// stratum holding one row of a class contributes a 0% or 100% rate and would
// dominate the pool on no evidence.
const defaultMinStratum = 2

// runTaskEnrichment handles `bp task enrichment [-o table|json|yaml]`.
func runTaskEnrichment(out *writer, g globals, ctx manifest.Context, tail []string) int {
	if g.help {
		printTaskEnrichmentHelp(out)
		return exitOK
	}
	if len(tail) > 0 {
		return usageErrf(out, func() { printTaskEnrichmentHelp(out) },
			"takes no positional arguments")
	}

	client := apiclient.New(apiclient.Config{
		BaseURL:     ctx.Server,
		Token:       ctx.Token,
		Workspace:   ctx.Workspace,
		Project:     ctx.Project,
		Dataset:     ctx.Dataset,
		Perspective: "drafts", // tasks live as drafts; the board reads the same view
	})

	_, details, err := taskboard.FetchSnapshotFull(client)
	if err != nil {
		return fetchSnapshotErr(out, "enrichment", err)
	}
	return renderEnrichment(out, enrichmentVerdictOf(details), missingIDs(details))
}

// enrichmentVerdictOf is the pure half: index -> rows -> verdict. Split out so
// the test can drive it from a fixture DetailIndex without a server.
func enrichmentVerdictOf(details taskboard.DetailIndex) taskboard.EnrichmentVerdict {
	list := make([]taskboard.TaskDetail, 0, len(details))
	for _, d := range details {
		list = append(list, d)
	}
	// Deterministic order so the Strata slice and any id listing are stable
	// across runs; the arithmetic itself is order-independent.
	sort.Slice(list, func(i, j int) bool { return list[i].DocID < list[j].DocID })

	rows := taskboard.CloseReasonRows(list)
	return taskboard.ControlEnrichment(rows, taskboard.ClassStale, taskboard.ClassClean, defaultMinStratum)
}

// missingIDs lists the suspect-class rows carrying the absence, id-sorted. A
// verdict is a number; these are the rows a human has to adjudicate one at a
// time, and a report that omits them cannot be acted on.
func missingIDs(details taskboard.DetailIndex) []string {
	var ids []string
	for _, d := range details {
		if !taskboard.IsTerminalLifecycle(d.Lifecycle) {
			continue
		}
		if taskboard.DispositionClass(d.Disposition) != taskboard.ClassStale {
			continue
		}
		if strings.TrimSpace(d.CloseReason) != "" {
			continue
		}
		ids = append(ids, taskboard.BareID(d.DocID))
	}
	sort.Strings(ids)
	return ids
}

func renderEnrichment(out *writer, v taskboard.EnrichmentVerdict, ids []string) int {
	if out.machineOut() {
		payload := map[string]any{
			"ok":                true,
			"advisory":          true,
			"field":             "close_reason",
			"suspect":           map[string]any{"class": taskboard.ClassStale, "total": v.Suspect.Total, "missing": v.Suspect.Missing, "rate": v.Suspect.Rate()},
			"baseline":          map[string]any{"class": taskboard.ClassClean, "total": v.Baseline.Total, "missing": v.Baseline.Missing, "rate": v.Baseline.Rate()},
			"marginal_ratio":    v.MarginalRatio(),
			"pooled_ratio":      v.PooledRatio(),
			"comparable_strata": v.Comparable,
			"discriminates":     v.Discriminates,
			"survives":          v.Survives,
			"reason":            v.Reason,
			// The rows a human has to adjudicate one at a time. A verdict is a
			// number; a report that omits the ids cannot be acted on, and a
			// bulk flip over them is the exact laundering this control exists
			// to stop.
			"missing_ids": ids,
		}
		if out.output == "yaml" {
			out.renderYAML(payload)
		} else {
			out.renderJSON(payload)
		}
		return exitOK
	}

	out.outf("ENRICHMENT CONTROL · field close_reason · stratified by claim.closed_by")
	out.outf("suspect  %-7s %s", taskboard.ClassStale, v.Suspect)
	out.outf("baseline %-7s %s", taskboard.ClassClean, v.Baseline)
	out.outf("marginal %s", ratioLabel(v.MarginalRatio()))
	out.outf("pooled   %s  (%d comparable strata, min %d rows of BOTH classes)",
		ratioLabel(v.PooledRatio()), v.Comparable, defaultMinStratum)
	out.outf("verdict  %s", verdictWord(v))
	out.outf("         %s", v.Reason)
	if len(ids) > 0 {
		out.outf("")
		out.outf("the %d %s rows carrying no close_reason — adjudicate INDIVIDUALLY, never a bulk flip:", len(ids), taskboard.ClassStale)
		for _, id := range ids {
			out.outf("  %s", id)
		}
	}
	return exitOK
}

func ratioLabel(r float64) string {
	if r == 0 {
		return "n/a"
	}
	return fmt.Sprintf("%.1fx", r)
}

// verdictWord never says "clean" or "no finding": the two refusals mean
// different things and a reader who conflates them has lost the measurement.
func verdictWord(v taskboard.EnrichmentVerdict) string {
	switch {
	case v.Survives:
		return "SURVIVES — the enrichment is a property of the class"
	case !v.Discriminates:
		return "NO MEASUREMENT — the field does not discriminate"
	case v.Comparable == 0:
		return "UNCONTROLLED — no stratum separates class from confound"
	default:
		return "CONFOUNDED — the absence tracks the closing worker, not the class"
	}
}

func printTaskEnrichmentHelp(out *writer) {
	out.outf("Usage: bp task enrichment [-o table|json|yaml]")
	out.outf("")
	out.outf("Controlled read of the close_reason absence enrichment in the")
	out.outf("stale-disposition class, stratified by the closing worker.")
	out.outf("Advisory: always exits 0 on a successful read.")
}

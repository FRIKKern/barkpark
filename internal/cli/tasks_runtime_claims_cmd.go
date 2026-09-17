package cli

// tasks_runtime_claims_cmd.go — `bp task runtime-claims`: the live consumer of
// taskboard.RuntimeClaimFindings and its stratified control.
//
// It answers ONE question against the real ledger: which SEALED criteria on
// TERMINAL rows assert a property only the running system can answer, while
// carrying only repo-side proof — a merged PR, an ancestry check, a grep, a
// green test?
//
// The verdict word is UNMEASURED, never "false". This command cannot run an
// arbitrary English sentence against production and does not pretend to; what
// it establishes is that nothing on the row establishes the claim. The
// remediation is to run the probe, one row at a time, which is why the ids are
// always printed in full and never summarised away — and why nothing here
// writes to any row.
//
// The control rides along for the same reason `bp task enrichment` carries
// one: the headline "runtime claims go unprobed Nx more often" is the shape of
// finding this ledger most often gets wrong, and neither killer (a field that
// does not discriminate; an absence that tracks the closing worker) is visible
// in the ratio. The report cannot print the marginal number without the
// controlled one beside it.
//
// Advisory: always exits 0 on a successful read. A finding is a measurement,
// not a command failure. Only an operational failure (fetch, usage) yields a
// non-OK code.

import (
	"sort"
	"strings"

	"github.com/FRIKKern/barkpark/internal/apiclient"
	"github.com/FRIKKern/barkpark/internal/manifest"
	"github.com/FRIKKern/barkpark/internal/taskboard"
)

// runTaskRuntimeClaims handles `bp task runtime-claims [-o table|json|yaml]`.
func runTaskRuntimeClaims(out *writer, g globals, ctx manifest.Context, tail []string) int {
	if g.help {
		printTaskRuntimeClaimsHelp(out)
		return exitOK
	}
	if len(tail) > 0 {
		return usageErrf(out, func() { printTaskRuntimeClaimsHelp(out) },
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
		return fetchSnapshotErr(out, "runtime-claims", err)
	}
	findings, verdict := runtimeClaimsOf(details)
	return renderRuntimeClaims(out, findings, verdict)
}

// runtimeClaimsOf is the pure half: index -> findings + control verdict. Split
// out so the test can drive it from a fixture DetailIndex without a server.
func runtimeClaimsOf(details taskboard.DetailIndex) ([]taskboard.RuntimeFinding, taskboard.EnrichmentVerdict) {
	list := make([]taskboard.TaskDetail, 0, len(details))
	for _, d := range details {
		list = append(list, d)
	}
	// Deterministic order so the finding list and the Strata slice are stable
	// across runs; the arithmetic itself is order-independent.
	sort.Slice(list, func(i, j int) bool { return list[i].DocID < list[j].DocID })

	findings := taskboard.RuntimeClaimFindings(list)
	rows := taskboard.RuntimeClaimRows(list)
	v := taskboard.ControlEnrichment(rows, taskboard.ClassRuntimeClaim, taskboard.ClassRepoLocalClaim, defaultMinStratum)
	return findings, v
}

// truncateCriterion keeps a finding line readable without losing the subject.
// The full text is in the row; this is a pointer to it, and the ref beside it
// is what a reader actually chases.
func truncateCriterion(s string) string {
	s = strings.Join(strings.Fields(s), " ")
	const max = 96
	if len(s) <= max {
		return s
	}
	return s[:max-1] + "…"
}

func renderRuntimeClaims(out *writer, findings []taskboard.RuntimeFinding, v taskboard.EnrichmentVerdict) int {
	unmeasured, noEvidence := 0, 0
	for _, f := range findings {
		if f.Verdict == taskboard.VerdictNoEvidence {
			noEvidence++
		} else {
			unmeasured++
		}
	}

	if out.machineOut() {
		items := make([]map[string]any, 0, len(findings))
		for _, f := range findings {
			items = append(items, map[string]any{
				"ref":       f.Ref(),
				"doc_id":    f.DocID,
				"index":     f.Index,
				"verdict":   f.Verdict.String(),
				"criterion": f.Criterion,
				"closed_by": f.ClosedBy,
			})
		}
		payload := map[string]any{
			"ok":       true,
			"advisory": true,
			"finding":  "sealed runtime claims proved only by code presence",
			// The verdict is a statement about the EVIDENCE, never about the
			// property. A consumer that reads this as "these rows are false"
			// has read it wrong, so the word is in the payload.
			"verdict_means":        "UNMEASURED — the row's own proof cannot establish the property it asserts; run the probe to decide",
			"unmeasured":           unmeasured,
			"met_without_evidence": noEvidence,
			"findings":             items,
			"control": map[string]any{
				"stratified_by":     "claim.closed_by",
				"suspect":           map[string]any{"class": taskboard.ClassRuntimeClaim, "total": v.Suspect.Total, "missing": v.Suspect.Missing, "rate": v.Suspect.Rate()},
				"baseline":          map[string]any{"class": taskboard.ClassRepoLocalClaim, "total": v.Baseline.Total, "missing": v.Baseline.Missing, "rate": v.Baseline.Rate()},
				"marginal_ratio":    v.MarginalRatio(),
				"pooled_ratio":      v.PooledRatio(),
				"comparable_strata": v.Comparable,
				"discriminates":     v.Discriminates,
				"survives":          v.Survives,
				"reason":            v.Reason,
			},
		}
		if out.output == "yaml" {
			out.renderYAML(payload)
		} else {
			out.renderJSON(payload)
		}
		return exitOK
	}

	out.outf("RUNTIME-CLAIM AUDIT · sealed criteria on terminal rows")
	out.outf("")
	out.outf("A criterion asserting a property only the RUNNING system can answer,")
	out.outf("stamped met on repo-side proof alone (a merge, an ancestry check, a")
	out.outf("grep, a green test). Code presence does not entail runtime presence.")
	out.outf("")
	out.outf("UNMEASURED-AT-RUNTIME   %d", unmeasured)
	out.outf("MET-WITHOUT-EVIDENCE    %d", noEvidence)
	out.outf("")
	out.outf("These are NOT verdicts of false. The property may hold; what is")
	out.outf("established is that nothing on the row establishes it. Decide each")
	out.outf("one by RUNNING THE PROBE — never by a bulk flip.")
	out.outf("")
	out.outf("CONTROL · stratified by claim.closed_by")
	out.outf("  suspect  %-10s %s", taskboard.ClassRuntimeClaim, v.Suspect)
	out.outf("  baseline %-10s %s", taskboard.ClassRepoLocalClaim, v.Baseline)
	out.outf("  marginal %s", ratioLabel(v.MarginalRatio()))
	out.outf("  pooled   %s  (%d comparable strata, min %d rows of BOTH classes)",
		ratioLabel(v.PooledRatio()), v.Comparable, defaultMinStratum)
	out.outf("  verdict  %s", runtimeControlWord(v))
	out.outf("           %s", v.Reason)

	if len(findings) > 0 {
		out.outf("")
		out.outf("the %d sealed runtime claims nothing on their row measured — adjudicate INDIVIDUALLY:", len(findings))
		for _, f := range findings {
			out.outf("  %-44s %-21s %s", f.Ref(), f.Verdict, truncateCriterion(f.Criterion))
		}
	}
	return exitOK
}

// runtimeControlWord never says "clean": the refusals mean different things and
// a reader who conflates them has lost the measurement. In particular a
// NO MEASUREMENT verdict does NOT retract the finding list above it — the
// findings are per-row facts about evidence; the control speaks only to whether
// the CLASS-LEVEL enrichment is interpretable.
func runtimeControlWord(v taskboard.EnrichmentVerdict) string {
	switch {
	case v.Survives:
		return "SURVIVES — runtime claims really do go unprobed more often"
	case !v.Discriminates:
		return "NO MEASUREMENT — live-probe citation does not discriminate (the per-row findings still stand)"
	case v.Comparable == 0:
		return "UNCONTROLLED — no stratum separates class from closing worker"
	case v.MarginalRatio() <= 1:
		// There was never an effect for the control to kill. Saying CONFOUNDED
		// here would explain a non-effect — a true number with a false story,
		// and a reader would come away believing an enrichment existed and was
		// merely mis-attributed. It did not exist.
		return "NO EFFECT — runtime claims are not proved worse than repo-local ones; there was no enrichment to control"
	default:
		return "CONFOUNDED — the absence tracks the closing worker, not the class"
	}
}

func printTaskRuntimeClaimsHelp(out *writer) {
	out.outf("Usage: bp task runtime-claims [-o table|json|yaml]")
	out.outf("")
	out.outf("Sealed criteria on TERMINAL rows that assert a property only the")
	out.outf("running system can answer, carrying only repo-side proof.")
	out.outf("The verdict is UNMEASURED, never false: run the probe to decide.")
	out.outf("Advisory: always exits 0 on a successful read. Writes nothing.")
}

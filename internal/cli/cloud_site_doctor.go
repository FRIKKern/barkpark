package cli

// cloud_site_doctor.go is `bp cloud site doctor <site>` — the CLI half of
// ssw8-site-doctor.
//
// WHY THE VERB EXISTS. A spawned site occupies many substrates and exactly ONE
// of them had a real readback before this: the control-plane row. When a spawn
// half-completes there was no way to see what exists without SSH. A live census
// found four distinct shapes, and the worst is silent — a site carrying a
// content-publish secret on the CP row and NO webhook on the box, so the control
// plane believes it is wired for auto-deploy and nothing will ever be delivered.
//
// WHAT THIS FILE MAY AND MAY NOT DO. Every judgment here belongs to the server:
// GET /v1/sites/:id/doctor decides the state of each substrate, writes the
// sentence explaining it, and names the exact repair verb (or says outright that
// none exists). This file DECODES and PRINTS. It never re-derives a state, never
// invents a repair for a row the server left empty, and never collapses the
// server's four states into two — the collapse of `unknown` into `absent` is the
// precise defect the route exists to prevent, and a receipt that printed the
// same bytes for both would reintroduce it one layer out. That is what
// renderSiteDoctorReport is enrolled in the success-claim registry to prove:
// change the server's answer and the printed sentence has to change with it.

import (
	"encoding/json"
	"fmt"
	"strings"

	"github.com/FRIKKern/barkpark/internal/cloudclient"
)

// runCloudSiteDoctor is `bp cloud site doctor <site>` — one read-only GET, then
// the receipt. It resolves a name to an id through the same door `status` and
// `open` use, so an operator never has to hold a UUID to diagnose their own site.
func runCloudSiteDoctor(out *writer, g globals, args []string) int {
	const usage = "bp cloud site doctor <site>"
	a, err := parseHzArgs(args, nil, nil, usage)
	if err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	if len(a.pos) != 1 {
		return useError(out, "usage", fmt.Sprintf("want exactly one <site> (usage: %s)", usage), exitUsage)
	}
	ref := a.pos[0]

	cfg, ok := siteCloudConfig(out, "run a site's doctor")
	if !ok {
		return exitAuth
	}
	id, rerr := resolveOpenSiteID(cfg, ref)
	if rerr != nil {
		return openResolveFail(out, rerr)
	}
	report, derr := cfg.CloudClient().SiteDoctor(cloudCtx(), id)
	if derr != nil {
		return cloudFail(out, "site doctor", derr)
	}

	if out.machineOut() {
		emitSiteDoctorRaw(out, report)
		return siteDoctorExit(report)
	}
	renderSiteDoctorReport(out, ref, report)
	return siteDoctorExit(report)
}

// emitSiteDoctorRaw writes the envelope for a machine consumer: json is the
// exact control-plane bytes — verbatim, key order and all, so the CLI never
// becomes a second, drifting definition of the contract (the emitDomainStatusRaw
// idiom); yaml is a faithful re-encode.
func emitSiteDoctorRaw(out *writer, report cloudclient.SiteDoctorReport) {
	switch out.output {
	case "json":
		fmt.Fprintln(out.stdout, strings.TrimRight(string(report.Raw), "\n"))
	case "yaml":
		var v any
		if json.Unmarshal(report.Raw, &v) == nil {
			out.renderYAML(v)
		}
	}
}

// siteDoctorExit maps a COMPLETED run onto the exit code, and the mapping is the
// server's own `ok` law: absent sinks it, UNKNOWN NEVER DOES. An unknown is an
// abstention — the doctor could not perform that read — and exiting non-zero on
// one would make `bp cloud site doctor blog && deploy` fail whenever the box was
// briefly slow, which is how a gate gets removed. Belt and braces on the count as
// well as the flag: a report that says ok:true while carrying an absent row is a
// server bug, and a gate must not exit 0 over it.
func siteDoctorExit(report cloudclient.SiteDoctorReport) int {
	if !report.OK || report.AbsentCount > 0 {
		return exitGeneric
	}
	for _, s := range report.Substrates {
		if strings.EqualFold(s.State, cloudclient.SiteDoctorAbsent) {
			return exitGeneric
		}
	}
	return exitOK
}

// siteDoctorStateMark is the glyph column. It is TOTAL over the wire: a state
// this CLI has never heard of gets a neutral marker and its own word printed
// beside it, never a guess at which of the four it resembles.
func siteDoctorStateMark(state string) string {
	switch strings.ToLower(strings.TrimSpace(state)) {
	case cloudclient.SiteDoctorPresent:
		return "✓"
	case cloudclient.SiteDoctorAbsent:
		return "✗"
	case cloudclient.SiteDoctorUnknown:
		return "?"
	case cloudclient.SiteDoctorNotApplicable:
		return "–"
	default:
		return "·"
	}
}

// siteDoctorVerdictLine is the one-sentence bottom line, and it is the sentence
// the registry pair varies on. It names THREE numbers, never one: what is
// broken, what was not measured, and — through the caller's unreadable list —
// which substrates the doctor abstained on. A green verdict that hid its
// unknowns would be exactly the confident-from-a-failed-read receipt this whole
// slice exists to prevent, so the unmeasured count rides in the same sentence as
// the verdict rather than under a flag.
func siteDoctorVerdictLine(report cloudclient.SiteDoctorReport) string {
	verdict := "NOT HEALTHY"
	if report.OK {
		verdict = "healthy"
	}
	return fmt.Sprintf("verdict: %s — %d absent, %d unmeasured", verdict, report.AbsentCount, report.UnknownCount)
}

// renderSiteDoctorReport prints the human receipt: a header naming the row that
// was examined, one block per substrate (state, key, the server's sentence, and
// its repair verb when the server named one), then the verdict.
//
// ENROLLED IN successClaimRegistry. The property that gate asserts is the one
// that matters here: hand this function a report whose content_webhook is
// `unknown` and one whose content_webhook is `absent`, and the printed bytes
// must differ — because the operator's next action differs completely (arm the
// hook vs. do NOT write against a substrate nobody read).
func renderSiteDoctorReport(out *writer, ref string, report cloudclient.SiteDoctorReport) {
	name := strings.TrimSpace(report.Site.Slug)
	if name == "" {
		name = ref
	}
	header := fmt.Sprintf("site doctor — %s", sanitizeCell(name))
	if k := strings.TrimSpace(report.Site.Kind); k != "" {
		header += fmt.Sprintf(" (kind %s)", sanitizeCell(k))
	}
	if inst := strings.TrimSpace(report.Site.Instance); inst != "" {
		header += fmt.Sprintf(" on %s", sanitizeCell(inst))
	} else {
		// NOT a cosmetic blank. A site whose instance carries no slug is an
		// orphan or a half-finished launch, which is one of the four census
		// shapes this verb was built for — say it in the header rather than
		// leaving the column empty for the reader to interpret.
		header += " — no instance resolved"
	}
	out.outf("%s", header)
	if at := strings.TrimSpace(report.CheckedAt); at != "" {
		out.outf("  checked %s", sanitizeCell(at))
	}

	if len(report.Substrates) == 0 {
		// A report with no rows is not a clean bill of health. Say what it is:
		// the server answered and described nothing.
		out.outf("")
		out.outf("the control plane returned NO substrate rows — nothing was measured, so this is not a clean bill of health")
		out.outf("%s", siteDoctorVerdictLine(report))
		return
	}

	out.outf("")
	for _, s := range report.Substrates {
		out.outf("  %s %-14s %s — %s",
			siteDoctorStateMark(s.State),
			sanitizeCell(strings.ToLower(strings.TrimSpace(s.State))),
			sanitizeCell(s.Key),
			sanitizeCell(s.Detail))
		if r := strings.TrimSpace(s.Repair); r != "" {
			out.outf("      repair: %s", sanitizeCell(r))
			continue
		}
		// The honest empty case. Only a row that is NOT fine can lack a repair
		// and still be interesting: `present` and `not_applicable` need none, so
		// silence there is correct. An absent/unknown row with no repair means
		// the SERVER named none, and the receipt must not let the reader assume
		// one was printed elsewhere.
		switch strings.ToLower(strings.TrimSpace(s.State)) {
		case cloudclient.SiteDoctorAbsent, cloudclient.SiteDoctorUnknown:
			out.outf("      repair: the control plane named none for this row")
		}
	}

	out.outf("")
	if len(report.Unreadable) > 0 {
		cleaned := make([]string, 0, len(report.Unreadable))
		for _, k := range report.Unreadable {
			cleaned = append(cleaned, sanitizeCell(k))
		}
		out.outf("unmeasured (the doctor could not perform these reads, so they are NOT claims of absence): %s",
			strings.Join(cleaned, ", "))
	}
	out.outf("%s", siteDoctorVerdictLine(report))
}

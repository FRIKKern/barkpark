package cli

// cloud_verify_cmd.go is `bp cloud verify <instance>` — the CLI twin of the
// console's on-demand verify (epic charter D53/decision 36). It asks the
// control plane to re-run the golden-path probe suite (the SAME birth
// certificate the provisioner required before ever declaring the box ready)
// via POST /v1/barkparks/:id/verify, authenticated with the CLOUD session
// token — the instance's admin token is resolved and used entirely
// server-side and never reaches this terminal.
//
// Honest states, deliberately:
//   - an UNREACHABLE box is a completed, FAILED verification (every probe
//     reachable:false) rendered as a probe table + non-zero exit — never a
//     transport error, because "the box never answered" is exactly the answer
//     the operator asked for;
//   - a refused run (409 not_live, 404, 500 decrypt_failed) maps to one human
//     sentence through the unified `bp:` error seam (useError), with -o json
//     parity via the {ok:false,error:{code,message}} envelope;
//   - `-o json` emits the verify envelope BYTES verbatim (D4 — the envelope IS
//     the contract), and the exit code still follows the verdict, so
//     `bp cloud verify prod && deploy` is a real gate.
//
// The probe vocabulary (names + labels) is the shared fixture
// cloud/priv/static/__fixtures__/verify_probes.json, asserted from the Go
// provisioner gate, the Elixir executor, AND this file's test — one
// vocabulary, three speakers, zero drift.

import (
	"encoding/json"
	"errors"
	"fmt"
	"strconv"
	"strings"

	"github.com/FRIKKern/barkpark/internal/cloudclient"
	"github.com/mattn/go-runewidth"
)

// verifyProbeOrder is the gate order (api → login → studio) as the committed
// fixture pins it; verifyProbeLabels carries each probe's human table label.
// TestVerifyProbeVocabularyMatchesFixture holds BOTH to verify_probes.json, so
// a probe rename reds this runtime alongside the Elixir and provisioner gates.
var verifyProbeOrder = []string{"verify.api", "verify.login", "verify.studio"}

var verifyProbeLabels = map[string]string{
	"verify.api":    "API answers",
	"verify.login":  "Login responds",
	"verify.studio": "Studio renders",
}

// runCloudVerify is `bp cloud verify <instance>`: resolve the instance (name
// or id, the same forms `bp cloud status`/`bp cloud open` accept), re-run the
// suite, and render the verdict + probe table. Requires `bp login`.
func runCloudVerify(out *writer, g globals, args []string) int {
	// -h/--help anywhere in the tail prints help (the cloud-webhook convention;
	// no positional can legitimately start with "-").
	for _, a := range args {
		if a == "-h" || a == "--help" {
			printCloudVerifyHelp(out)
			return exitOK
		}
	}
	if g.help || (len(args) > 0 && args[0] == "help") {
		printCloudVerifyHelp(out)
		return exitOK
	}

	const usage = "bp cloud verify <instance>"
	a, err := parseHzArgs(args, nil, nil, usage)
	if err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	if len(a.pos) != 1 {
		return useError(out, "usage", fmt.Sprintf("want 1 argument (usage: %s)", usage), exitUsage)
	}
	ref := a.pos[0]

	cfg, cerr := LoadConfig()
	if cerr != nil {
		return useError(out, "failed", "read config: "+cerr.Error(), exitGeneric)
	}
	if !cfg.HasCloudToken() {
		return useError(out, "auth", "not logged in — run `bp login` to verify an instance, or set BARKPARK_CLOUD_TOKEN for a CI job", exitAuth)
	}

	id, rerr := resolveOpenBarkparkID(cfg, ref)
	if rerr != nil {
		return openResolveFail(out, rerr)
	}

	res, verr := cfg.CloudClient().VerifyInstance(cloudCtx(), id)
	if verr != nil {
		return verifyFail(out, ref, verr)
	}

	if out.output == "json" || out.output == "yaml" {
		emitVerifyRaw(out, res)
		return verifyExit(res)
	}
	renderVerifyResult(out, ref, res)
	return verifyExit(res)
}

// verifyFail maps a refused verify run onto the unified `bp:` error seam:
// each contract code becomes one plain, actionable sentence (and the
// {ok:false,error:{code,message}} envelope under -o json/yaml), exit-coded per
// the CLI's canonical ladder. Anything outside the contract set (an expired
// session, a gateway page) routes through cloudFail so auth handling stays
// identical to every other cloud verb.
func verifyFail(out *writer, ref string, err error) int {
	var ve *cloudclient.VerifyError
	if errors.As(err, &ve) {
		switch ve.Code {
		case "not_live":
			return useError(out, "not_live",
				fmt.Sprintf("instance %q is not live — it is still provisioning or being removed; there is nothing to verify yet (watch `bp cloud status`)", ref),
				exitConflict)
		case "not_found":
			return useError(out, "not_found",
				fmt.Sprintf("no such instance %q (or it is not in your team)", ref),
				exitNotFound)
		case "no_admin_token":
			return useError(out, "no_admin_token",
				fmt.Sprintf("instance %q has no stored admin token — it is captured at provision time, so a pre-existing instance may need a re-provision", ref),
				exitNotFound)
		case "decrypt_failed":
			return useError(out, "decrypt_failed",
				"could not decrypt the instance admin token — the stored credential looks corrupt",
				exitGeneric)
		}
	}
	return cloudFail(out, "verify instance", err)
}

// verifyExit maps a COMPLETED run onto the exit code: 0 only when the verdict
// is ok AND every probe passed (belt and braces — the server derives one from
// the other, but a check command must never exit 0 on a red row). Verify is a
// gate; `bp cloud verify prod && …` must mean "the golden path works".
func verifyExit(res cloudclient.VerifyResult) int {
	if !res.OK {
		return exitGeneric
	}
	for _, p := range res.Probes {
		if !p.OK {
			return exitGeneric
		}
	}
	return exitOK
}

// emitVerifyRaw writes the envelope for a machine consumer: json is the exact
// control-plane bytes — verbatim, key order and all, so the CLI never becomes
// a second, drifting definition of the contract (the emitWebhookRaw idiom);
// yaml is a faithful re-encode (yaml consumers do not depend on key order).
func emitVerifyRaw(out *writer, res cloudclient.VerifyResult) {
	switch out.output {
	case "json":
		fmt.Fprintln(out.stdout, strings.TrimRight(string(res.Raw), "\n"))
	case "yaml":
		var v any
		if json.Unmarshal(res.Raw, &v) == nil {
			out.renderYAML(v)
		}
	}
}

// renderVerifyResult prints the human view: one verdict line on top, an
// honest unreachable note when the box never answered, then the probe table.
func renderVerifyResult(out *writer, ref string, res cloudclient.VerifyResult) {
	total := len(res.Probes)
	failed := 0
	for _, p := range res.Probes {
		if !p.OK {
			failed++
		}
	}

	switch {
	case res.OK && failed == 0:
		out.outf("Golden path verified — %d of %d probes passed (%s)", total, total, ref)
	case failed == 0:
		// Defensive: the server derives ok FROM the probes, so a not-ok verdict
		// over all-green rows is a contract break — say so rather than print the
		// nonsense "0 of N probes failed" while exiting non-zero.
		out.outf("verification not ok (%s) — yet every probe passed; run with -o json to inspect the envelope", ref)
	default:
		out.outf("%d of %d probes failed (%s)", failed, total, ref)
	}
	if !res.Reachable {
		out.outf("the instance never answered — a failed verification, not a CLI error; check the box is running")
	}
	if strings.TrimSpace(res.VerifiedAt) != "" {
		out.outf("verified at %s", sanitizeCell(res.VerifiedAt))
	}

	if total == 0 {
		// Defensive: the route always sends three probes; an empty list would be
		// a contract break worth seeing, not an invisible blank table.
		out.outf("(the control plane returned no probes — run with -o json to inspect the envelope)")
		return
	}
	out.outf("")
	renderVerifyProbes(out, res.Probes)
}

// renderVerifyProbes prints the aligned probe table: PROBE (human label) ·
// STATUS (painted through the shared statusRole seam — ok→green, failed→red,
// the D12 one-vocabulary guarantee) · HTTP · LATENCY · DETAIL (the probe's own
// evidence line). Widths are measured on BARE strings and painting wraps the
// padded cell, so piped/--no-color output is byte-identical to an uncolored
// build (the renderStatusRows idiom).
func renderVerifyProbes(out *writer, probes []cloudclient.VerifyProbe) {
	headers := []string{"PROBE", "STATUS", "HTTP", "LATENCY", "DETAIL"}
	cells := make([][]string, 0, len(probes))
	for _, p := range probes {
		cells = append(cells, []string{
			verifyProbeLabel(p.Name),
			verifyProbeToken(p),
			verifyHTTPCell(p.Status),
			fmt.Sprintf("%d ms", p.LatencyMS),
			statusDash(p.Evidence),
		})
	}
	widths := make([]int, len(headers))
	for i, h := range headers {
		widths[i] = runewidth.StringWidth(h)
	}
	for _, row := range cells {
		for i, c := range row {
			if n := runewidth.StringWidth(c); n > widths[i] {
				widths[i] = n
			}
		}
	}
	out.outf("%s", joinCols(headers, widths))
	for _, row := range cells {
		out.outf("%s", joinColsPainted(out, row, widths))
	}
}

// verifyProbeLabel resolves a probe name to its human label. An unknown
// (future) probe name passes through — honest, never dropped — but scrubbed of
// control bytes like every other server-authored cell (the statusDash rule).
func verifyProbeLabel(name string) string {
	if l, ok := verifyProbeLabels[name]; ok {
		return l
	}
	return sanitizeCell(name)
}

// verifyProbeToken maps a probe outcome onto a statusRole token so the STATUS
// cell colours identically to a dashboard dot: pass → "ok" (green), any fail —
// including unreachable — → "failed" (red).
func verifyProbeToken(p cloudclient.VerifyProbe) string {
	if p.OK {
		return "ok"
	}
	return "failed"
}

// verifyHTTPCell renders the probe's HTTP status, or an em dash for the
// honest null an unreachable probe carries (never a fake 0).
func verifyHTTPCell(status *int) string {
	if status == nil {
		return "—"
	}
	return strconv.Itoa(*status)
}

// printCloudVerifyHelp writes `bp cloud verify` usage.
func printCloudVerifyHelp(out *writer) {
	const help = `bp cloud verify — re-run the golden-path verification against an instance.

USAGE
  bp cloud verify <instance> [-o json|yaml]

WHAT IT DOES
  asks the control plane to re-run the birth-certificate probe suite (the same
  gate that decided "ready") against the LIVE box, using the stored admin
  token server-side — the token never reaches your terminal:

    verify.api      API answers      GET /v1/capabilities is 200
    verify.login    Login responds   bad creds cleanly rejected (never a 5xx)
    verify.studio   Studio renders   /studio resolves through its redirect

  <instance> is a fleet name or id (the forms bp cloud status shows); needs
  'bp login'. An unreachable box is a FAILED VERIFICATION — the table still
  renders (every probe unreachable) and the exit is non-zero; it is never
  reported as a CLI transport error.

OUTPUT + EXIT
  a one-line verdict, then one row per probe: status (green ok / red failed),
  HTTP status, latency, and the probe's own evidence.
  -o json    the verify envelope verbatim: {ok, reachable, verified_at, probes}
  exit 0 only when every probe passed — scriptable as a deploy gate.`
	out.outf("%s", help)
}

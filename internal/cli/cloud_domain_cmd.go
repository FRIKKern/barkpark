package cli

// cloud_domain_cmd.go is `bp cloud domain status <instance>` — the CLI twin of
// the console's per-domain checklist (azure-hetzner hosting charter, S13). It
// asks the control plane for the domain-status envelope (GET
// /v1/barkparks/:id/domain-status), authenticated with the CLOUD session token,
// and renders a Vercel-grade per-host stage checklist: DNS found → points here
// → TLS issued → serving.
//
// The CLI NEVER probes: DNS resolvers and the box's TLS endpoint are the
// control plane's to touch, exactly as `bp cloud verify` delegates the probe
// suite server-side. This file only RENDERS the CP's truth — including the
// per-rung remediation string VERBATIM under any non-ok rung (the copy is
// server-owned; the CLI never invents its own fix text).
//
// Honest states, deliberately:
//   - a domain mid-issuance is a completed run with `pending` rungs (yellow-ish
//     "in progress"), NOT a CLI error — the checklist is exactly what the
//     operator asked to see;
//   - `-o json` emits the envelope BYTES verbatim (the envelope IS the
//     contract), and the exit code follows the verdict (0 only when every host
//     is serving), so `bp cloud domain status prod && …` is a real gate;
//   - an auth-expired / gateway failure routes through cloudFail so auth
//     handling is identical to every other cloud verb.

import (
	"encoding/json"
	"fmt"
	"strings"

	"github.com/FRIKKern/barkpark/internal/cloudclient"
	"github.com/mattn/go-runewidth"
)

// domainStageGlyph paints a checklist bullet per rung status: ok → a check,
// failed → a cross, anything else (pending / unknown) → a hollow dot. The glyph
// is ASCII-only so piped/non-UTF terminals stay legible; color comes from the
// status token cell, never the glyph.
func domainStageGlyph(status string) string {
	switch strings.ToLower(strings.TrimSpace(status)) {
	case "ok":
		return "[x]"
	case "failed":
		return "[!]"
	default:
		return "[ ]"
	}
}

// runCloudDomain routes `bp cloud domain <verb> …`. Today the only verb is
// `status`; the namespace exists so future domain verbs (attach/detach) have a
// home without another top-level `bp cloud` command.
func runCloudDomain(out *writer, g globals, args []string) int {
	for _, a := range args {
		if a == "-h" || a == "--help" {
			printCloudDomainHelp(out)
			return exitOK
		}
	}
	if len(args) == 0 || args[0] == "help" {
		if g.help || (len(args) > 0 && args[0] == "help") {
			printCloudDomainHelp(out)
			return exitOK
		}
		return useError(out, "usage", "missing domain command (run `bp cloud domain -h` for usage)", exitUsage)
	}
	switch args[0] {
	case "status":
		return runCloudDomainStatus(out, g, args[1:])
	default:
		return useError(out, "usage", fmt.Sprintf("unknown domain command %q (run `bp cloud domain -h` for usage)", args[0]), exitUsage)
	}
}

// runCloudDomainStatus is `bp cloud domain status <instance>`: resolve the
// instance (name or id, the same forms `bp cloud verify` accepts), fetch the
// per-host checklist, and render it. Requires `bp login`.
func runCloudDomainStatus(out *writer, g globals, args []string) int {
	for _, a := range args {
		if a == "-h" || a == "--help" {
			printCloudDomainHelp(out)
			return exitOK
		}
	}
	if g.help {
		printCloudDomainHelp(out)
		return exitOK
	}

	const usage = "bp cloud domain status <instance>"
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
		return useError(out, "auth", "not logged in — run `bp login` to check a domain, or set BARKPARK_CLOUD_TOKEN for a CI job", exitAuth)
	}

	id, rerr := resolveOpenBarkparkID(cfg, ref)
	if rerr != nil {
		return openResolveFail(out, rerr)
	}

	res, derr := cfg.CloudClient().DomainStatus(cloudCtx(), id)
	if derr != nil {
		return cloudFail(out, "domain status", derr)
	}

	if out.output == "json" || out.output == "yaml" {
		emitDomainStatusRaw(out, res)
		return domainStatusExit(res)
	}
	renderDomainStatus(out, ref, res)
	return domainStatusExit(res)
}

// domainStatusExit maps a COMPLETED run onto the exit code: 0 only when the
// verdict is ok AND every rung of every host is ok (belt and braces — the
// server derives one from the other, but a gate must never exit 0 over a
// pending/failed rung). `bp cloud domain status prod && deploy` must mean "every
// domain is live".
func domainStatusExit(res cloudclient.DomainStatusResult) int {
	if !res.OK {
		return exitGeneric
	}
	for _, d := range res.Domains {
		if !strings.EqualFold(d.Overall, "ok") {
			return exitGeneric
		}
		for _, s := range d.Stages {
			if !strings.EqualFold(s.Status, "ok") {
				return exitGeneric
			}
		}
	}
	return exitOK
}

// emitDomainStatusRaw writes the envelope for a machine consumer: json is the
// exact control-plane bytes — verbatim, key order and all, so the CLI never
// becomes a second, drifting definition of the contract (the emitVerifyRaw
// idiom); yaml is a faithful re-encode (yaml consumers do not depend on key
// order).
func emitDomainStatusRaw(out *writer, res cloudclient.DomainStatusResult) {
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

// renderDomainStatus prints the human view: a header line (which box, when
// checked), then one checklist block per attached host.
func renderDomainStatus(out *writer, ref string, res cloudclient.DomainStatusResult) {
	if at := strings.TrimSpace(res.CheckedAt); at != "" {
		out.outf("Domain status for %s — checked %s", ref, sanitizeCell(at))
	} else {
		out.outf("Domain status for %s", ref)
	}
	if len(res.Domains) == 0 {
		out.outf("")
		out.outf("No domains are attached yet — attach one from the Cloud console (Instance → Attach a domain).")
		return
	}
	for _, d := range res.Domains {
		out.outf("")
		renderDomainCheck(out, d)
	}
}

// renderDomainCheck prints one host's checklist: a header (host · kind ·
// overall, the overall painted through the shared statusRole seam) then one
// aligned rung per stage — glyph · STATUS (painted) · LABEL · EVIDENCE — with
// the server's remediation string on its own indented line under any non-ok
// rung. Stage labels come from the SERVER (rendered verbatim, only scrubbed of
// control bytes), never a client-side table.
func renderDomainCheck(out *writer, d cloudclient.DomainCheck) {
	header := sanitizeCell(d.Host)
	if k := domainKindLabel(d.Kind); k != "" {
		header += "  ·  " + k
	}
	overall := domainOverallLabel(d.Overall)
	out.outf("%s  ·  %s", header, out.paintCell(overall, statusForOverall(d.Overall)))

	// Widths measured on BARE strings so painting never shears alignment (the
	// renderVerifyProbes idiom). The status token cell is the painted one.
	labelW := runewidth.StringWidth("STATUS")
	for _, s := range d.Stages {
		if n := runewidth.StringWidth(sanitizeCell(s.Label)); n > labelW {
			labelW = n
		}
	}
	for _, s := range d.Stages {
		token := domainStageToken(s.Status)
		label := runewidth.FillRight(sanitizeCell(s.Label), labelW)
		line := "  " + domainStageGlyph(s.Status) + " " +
			out.paintCell(runewidth.FillRight(token, 8), token) + "  " +
			out.paintCell(label, "") + "  " + statusDash(s.Evidence)
		out.outf("%s", strings.TrimRight(line, " "))
		// Remediation is shown ONLY under a non-ok rung, verbatim (server-owned).
		if !strings.EqualFold(s.Status, "ok") {
			if rem := strings.TrimSpace(s.Remediation); rem != "" {
				out.outf("      → %s", sanitizeCell(rem))
			}
		}
	}
}

// domainStageToken maps a rung's status onto a statusRole token so its cell
// colours identically to a dashboard dot: ok → green, pending → cyan (info),
// failed → red. An unknown/empty status passes through scrubbed (never a guess).
func domainStageToken(status string) string {
	switch strings.ToLower(strings.TrimSpace(status)) {
	case "ok":
		return "ok"
	case "pending":
		return "pending"
	case "failed":
		return "failed"
	default:
		return statusDash(status)
	}
}

// statusForOverall maps the rolled-up overall verdict onto the value whose
// statusRole paints the header cell (ok|pending|failed → green|yellow|red).
func statusForOverall(overall string) string {
	switch strings.ToLower(strings.TrimSpace(overall)) {
	case "ok", "pending", "failed":
		return strings.ToLower(strings.TrimSpace(overall))
	default:
		return ""
	}
}

// domainOverallLabel humanises the rolled-up verdict for the header. An unknown
// value passes through scrubbed rather than being dropped.
func domainOverallLabel(overall string) string {
	switch strings.ToLower(strings.TrimSpace(overall)) {
	case "ok":
		return "live"
	case "pending":
		return "in progress"
	case "failed":
		return "failed"
	default:
		return statusDash(overall)
	}
}

// domainKindLabel humanises the host kind chip; an empty/unknown kind yields "".
func domainKindLabel(kind string) string {
	switch strings.ToLower(strings.TrimSpace(kind)) {
	case "platform":
		return "platform domain"
	case "custom":
		return "custom domain"
	case "":
		return ""
	default:
		return sanitizeCell(kind)
	}
}

// printCloudDomainHelp writes `bp cloud domain` usage.
func printCloudDomainHelp(out *writer) {
	const help = `bp cloud domain — the per-domain DNS/TLS checklist for an instance.

USAGE
  bp cloud domain status <instance> [-o json|yaml]

WHAT IT DOES
  asks the control plane to check every domain attached to the box and reports
  a per-host checklist — the control plane owns every probe (your terminal never
  touches a DNS resolver or the box):

    DNS found       the host resolves to an A record
    Points here     that record points at THIS instance
    TLS issued      a certificate has been issued and installed
    Serving         the box answers HTTPS on the host

  <instance> is a fleet name or id (the forms bp cloud status shows); needs
  'bp login'. A domain still being set up shows pending rungs with the server's
  own next-step guidance under each — it is a normal result, never a CLI error.

  A failed Serving rung (DNS + TLS green, but the box isn't answering) means the
  domain is wired but the app behind it is down — recoverable: bring the instance
  back (an app restart heals it) and re-run this command. The exit stays non-zero
  until it serves, so a go-live gate never passes a box that isn't live.

OUTPUT + EXIT
  a header per host, then one row per rung: status (green ok / cyan pending /
  red failed), the rung label, and the server's evidence; a non-ok rung carries
  the server's remediation line beneath it.
  -o json    the domain-status envelope verbatim: {ok, checked_at, instance, domains}
  exit 0 only when every domain is serving — scriptable as a go-live gate.`
	out.outf("%s", help)
}

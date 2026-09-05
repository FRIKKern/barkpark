package cli

// doctor_cmd.go is `bp doctor` — the cloud-13 health command. It runs the 7-check
// health gate (setup.RunHealthGate) against the active (or --name'd / --url'd)
// Barkpark and prints a per-check report with a ✓/✗ marker and detail, then an
// overall verdict. It exits non-zero when ANY check fails — the CLI analogue of
// api/scripts/prod-postcheck.sh, but covering the full readiness battery (the
// websocket-not-403 footgun, TLS, Postgres-via-API) rather than a single curl.
//
// Target resolution mirrors `bp agent`: an explicit --name wins, else the active
// server; --url overrides the base outright (and --token the bearer) so the
// command is usable against a server not yet in config. The stub probes
// (agent/backup, cloud-9/10) report an honest "unknown/skipped" — the gate marks
// them not-ready, and doctor surfaces that plainly rather than pretending green.

import (
	"strings"

	"github.com/FRIKKern/barkpark/internal/cli/setup"
)

// doctorGateOpts builds the HealthGate options doctor runs for a resolved base
// URL + token. It is a package var so the golden test can inject RootCAs (to
// trust an httptest TLS cert) and point the stub probes at its fake server
// without a live deployment — the command itself never knows it was swapped. The
// default leaves the stub-probe URLs empty (agent/backup are cloud-9/10), so the
// gate honestly marks them not-ready until those endpoints ship.
//
// When a Cloud session token is present in config, doctor adds an opt-in
// cloud-sites probe pointing at the saved CloudURL — surfacing the P6 sites
// count (and any with no live deployment) in the same battery. The probe is
// skipped silently when no token is in scope, so self-hosted Barkparks
// without a Cloud control plane never see it.
var doctorGateOpts = func(base, token string) setup.HealthGate {
	g := setup.HealthGate{}
	if cfg, err := LoadConfig(); err == nil && cfg.HasCloudToken() {
		url := strings.TrimRight(strings.TrimSpace(cfg.CloudURL), "/")
		if url == "" {
			url = "https://api.barkpark.cloud"
		}
		g.CloudSitesURL = url + "/v1/sites"
		// Through the RESOLVER, not cfg.CloudToken: HasCloudToken above answers
		// true for a BARKPARK_CLOUD_TOKEN in the environment (how CI
		// authenticates — there is no `bp login` there), while cfg.CloudToken is
		// the persisted tier only and is EMPTY in that case. Reading the field
		// directly therefore armed this probe with an empty Bearer and reported a
		// 401 as a failed check — a false red produced by the very credential
		// that works for every other Cloud command.
		g.CloudSitesToken, _ = cfg.ResolveCloudToken()
	}
	return g
}

// runDoctor is the `bp doctor [--name <handle>] [--url <url>] [--token <tok>]`
// built-in. It resolves the target, runs the health gate, prints the report, and
// returns exit 0 (all checks pass) or exitGeneric (any check failed / the gate
// could not run).
func runDoctor(out *writer, args []string) int {
	for _, a := range args {
		if a == "-h" || a == "--help" {
			printDoctorHelp(out)
			return exitOK
		}
	}

	name, urlOverride, tokenOverride, perr := parseDoctorArgs(args)
	if perr != nil {
		return useError(out, "usage", perr.Error(), exitUsage)
	}

	base, token, target, ok := resolveDoctorTarget(out, name, urlOverride, tokenOverride)
	if !ok {
		return exitUsage
	}

	report, gateErr := setup.RunHealthGate(base, token, doctorGateOpts(base, token))

	// WHICH Cloud credential this doctor run used — the origin label only, never
	// the value. A CI job whose deploy 401s can now read the tier off the same
	// receipt that reports the cloud-sites probe, instead of guessing whether
	// BARKPARK_CLOUD_TOKEN or a stale config.json session was in play. Empty
	// (no token in either tier) prints and serialises NOTHING, so every
	// no-cloud-token receipt stays byte-identical to what it was before.
	cloudSource := doctorCloudTokenSource()

	switch out.output {
	case "json":
		out.renderJSON(doctorJSON(target, base, report, cloudSource))
		if report.OK {
			return exitOK
		}
		return exitGeneric
	case "yaml":
		out.renderYAML(toGeneric(doctorJSON(target, base, report, cloudSource)))
		if report.OK {
			return exitOK
		}
		return exitGeneric
	}

	renderDoctorReport(out, target, base, report, cloudSource)
	// The gate returns a non-nil error iff not every check passed; doctor's exit
	// follows report.OK so it is non-zero whenever any check failed.
	_ = gateErr
	if report.OK {
		return exitOK
	}
	return exitGeneric
}

// resolveDoctorTarget resolves the base URL + token + a human target label for
// the gate. Precedence: an explicit --url wins outright (with --token for the
// bearer); else an explicit --name resolves a known server; else the active
// server. Returns ok=false (after emitting the right error) when nothing
// resolves.
func resolveDoctorTarget(out *writer, name, urlOverride, tokenOverride string) (base, token, target string, ok bool) {
	if strings.TrimSpace(urlOverride) != "" {
		return strings.TrimRight(strings.TrimSpace(urlOverride), "/"), strings.TrimSpace(tokenOverride), urlOverride, true
	}

	cfg, err := LoadConfig()
	if err != nil {
		useError(out, "failed", "read config: "+err.Error(), exitGeneric)
		return "", "", "", false
	}

	var entry ServerEntry
	switch {
	case name != "":
		e, found := cfg.FindServer(name)
		if !found {
			doctorNoTarget(out, "no known Barkpark matches "+quote(name), cfg)
			return "", "", "", false
		}
		entry = e
	default:
		e, found := activeEntry(cfg)
		if !found {
			doctorNoTarget(out, "no active Barkpark — pass --url <url>, --name <handle>, or run `bp use <name>`", cfg)
			return "", "", "", false
		}
		entry = e
	}

	tok := entry.Token
	if strings.TrimSpace(tokenOverride) != "" {
		tok = strings.TrimSpace(tokenOverride)
	}
	return strings.TrimRight(entry.Server, "/"), tok, cfg.DisplayName(entry), true
}

// renderDoctorReport prints the human report: a header naming the target, one
// line per check with a ✓/✗/– marker and detail, then the overall verdict.
//
// The dash is a check that DID NOT RUN, and it is rendered as its own marker
// rather than folded into ✓ because an operator reading a green doctor needs to
// know which conditions it declined to look at. "all N checks passed" is only
// printed when N probes actually ran.
func renderDoctorReport(out *writer, target, base string, report setup.HealthReport, cloudSource string) {
	out.outf("bp doctor — %s (%s)", target, base)
	if cloudSource != "" {
		out.outf("  cloud token source: %s", cloudSource)
	}
	for _, c := range report.Checks {
		mark := "✗"
		switch c.Effective() {
		case setup.CheckPass:
			mark = "✓"
		case setup.CheckSkip:
			mark = "–"
		}
		out.outf("  %s %-22s %s", mark, c.Name, c.Detail)
	}
	skipped := report.Skipped()
	if report.OK {
		if len(skipped) == 0 {
			out.outf("=> READY — all %d checks passed", len(report.Checks))
		} else {
			out.outf("=> READY — %d passed, %d NOT CHECKED: %s",
				len(report.Passed()), len(skipped), strings.Join(skipped, ", "))
		}
	} else {
		out.outf("=> NOT READY — %d/%d failed: %s",
			len(report.Failures()), len(report.Checks), strings.Join(report.Failures(), ", "))
	}
	if !report.OK && len(skipped) > 0 {
		out.outf("   (%d NOT CHECKED: %s)", len(skipped), strings.Join(skipped, ", "))
	}
}

// doctorJSON projects the report onto a stable JSON envelope for `-o json`.
//
// `pass` keeps its historical two-state meaning for existing scripts; `status`
// and the top-level `skipped` list are the additive channel that distinguishes
// a probe that FAILED from one that never ran.
func doctorJSON(target, base string, report setup.HealthReport, cloudSource string) map[string]any {
	checks := make([]map[string]any, 0, len(report.Checks))
	for _, c := range report.Checks {
		checks = append(checks, map[string]any{
			"name":   c.Name,
			"pass":   c.Pass,
			"status": string(c.Effective()),
			"detail": c.Detail,
		})
	}
	m := map[string]any{
		"ok":       report.OK,
		"target":   target,
		"base_url": base,
		"checks":   checks,
		"failures": report.Failures(),
		"skipped":  report.Skipped(),
	}
	// Additive and CONDITIONAL: the key appears only when a Cloud credential is
	// actually in scope, so a self-hosted doctor envelope is unchanged.
	if cloudSource != "" {
		m["cloud"] = map[string]any{"token_source": cloudSource}
	}
	return m
}

// doctorCloudTokenSource names the tier the active Cloud credential came from
// (env:BARKPARK_CLOUD_TOKEN | config:cloud_token), or "" when there is none.
// It goes through the RESOLVER, so a CI job that exports the env var — and has
// no config.json at all — reads its own tier back instead of an empty receipt.
func doctorCloudTokenSource() string {
	cfg, err := LoadConfig()
	if err != nil {
		return ""
	}
	return cfg.CloudTokenSource()
}

// doctorNoTarget emits the clean miss path when no target resolves — a JSON/YAML
// error envelope or a one-line stderr message with the known names as a hint.
// Exit is handled by the caller (returns ok=false → exitUsage).
func doctorNoTarget(out *writer, msg string, cfg *Config) {
	names := knownNames(cfg)
	m := map[string]any{
		"ok": false,
		"error": map[string]any{
			"code":    "not_found",
			"message": msg,
			"known":   names,
		},
	}
	switch out.output {
	case "json":
		out.renderJSON(m)
		return
	case "yaml":
		out.renderYAML(toGeneric(m))
		return
	}
	out.userErr("%s", msg)
	if len(names) > 0 {
		out.errf("known Barkparks: %s", joinComma(names))
	}
}

// parseDoctorArgs splits `bp doctor` flags: --name/--url/--token, each accepting
// both `--flag value` and `--flag=value`. Any positional or unknown flag is a
// usage error.
func parseDoctorArgs(args []string) (name, url, token string, err error) {
	for i := 0; i < len(args); i++ {
		a := args[i]
		switch {
		case a == "--name":
			name, i, err = nextFlagValue(args, i)
		case strings.HasPrefix(a, "--name="):
			name = a[len("--name="):]
		case a == "--url":
			url, i, err = nextFlagValue(args, i)
		case strings.HasPrefix(a, "--url="):
			url = a[len("--url="):]
		case a == "--token":
			token, i, err = nextFlagValue(args, i)
		case strings.HasPrefix(a, "--token="):
			token = a[len("--token="):]
		default:
			return "", "", "", errDoctorUsage(a)
		}
		if err != nil {
			return "", "", "", err
		}
	}
	return name, url, token, nil
}

// errDoctorUsage is the unexpected-argument error for `bp doctor`.
func errDoctorUsage(a string) error {
	return &usageErr{"unexpected argument " + quote(a) + " (usage: bp doctor [--name <handle>] [--url <url>] [--token <tok>])"}
}

// usageErr is a tiny error type so parseDoctorArgs stays dependency-free of fmt.
type usageErr struct{ msg string }

func (e *usageErr) Error() string { return e.msg }

// quote wraps s in double quotes for error messages (avoids importing fmt here).
func quote(s string) string { return `"` + s + `"` }

func printDoctorHelp(out *writer) {
	const help = `bp doctor — run the post-deploy health gate against a Barkpark.

USAGE
  bp doctor [--name <handle>] [--url <url>] [--token <token>]

WHAT IT DOES
  runs the 7-check readiness battery against the target server and reports each
  check (✓/✗ + detail) plus an overall verdict. Exits non-zero if any check
  fails. The checks: API up (/v1/capabilities), Studio renders, the LiveView
  websocket is NOT 403'd (the check_origin/PHX_HOST footgun), TLS verifies,
  Postgres answers through the API, and stub probes for agent/backup (cloud-9/10,
  reported as not-yet-ready until those endpoints ship).

  The conceptual analogue of api/scripts/prod-postcheck.sh, but covering the full
  readiness battery rather than a single curl.

TARGET
  --url <url>      probe this base URL directly (overrides config)
  --name <handle>  probe a known Barkpark by name (else the active server)
  --token <token>  bearer token for the token-gated probes (else the saved one)

FLAGS
  -o json          emit one machine-readable JSON object on stdout
  -o yaml          emit one machine-readable YAML document on stdout

SEE ALSO
  bp doctor --onboarding   client-readiness receipt for THIS machine (bp on PATH,
                           CLI freshness, target instance + team, auth tier, the
                           8-tool MCP catalog, and a read-only tool-call proof)`
	out.outf("%s", help)
}

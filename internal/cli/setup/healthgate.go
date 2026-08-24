package setup

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"net/url"
	"strings"
	"time"
)

// HealthGate runs a fixed battery of 7 post-deploy checks against a live
// Barkpark server and reports, per check, whether the box is genuinely "ready".
// It is the deploy-time hardening of verifyServer: where verifyServer only
// pokes /v1/capabilities + /studio, the gate additionally proves the LiveView
// websocket is not 403'd by check_origin/PHX_HOST drift (the canonical
// Studio-click-dead footgun), that TLS verifies, that Postgres answers through
// the API, and — via stub probes wired for cloud-9/10 — that an agent is
// connected and a backup is scheduled.
//
// Checks 1-4 (capabilities, studio, websocket, TLS) hit BaseURL. Checks 5-7
// take injected probe URLs (PostgresProbeURL/AgentStatusURL/BackupStatusURL) so
// they are exercisable against httptest servers WITHOUT a live deployment, and
// so the not-yet-built agent/backup endpoints can be pointed at the real routes
// once cloud-9/10 land. Every check is honest about what it asserts — a stub
// probe says "stub" in its name.
type HealthGate struct {
	// BaseURL is the public origin of the deployed server (e.g.
	// https://barkpark.example.com). Checks 1-4 hit it directly.
	BaseURL string
	// Token authenticates the probes that need it (the Postgres query read is
	// token-gated; capabilities/studio/websocket are anonymous).
	Token string

	// PostgresProbeURL is an ABSOLUTE URL that returns 200 iff the API can read
	// from Postgres (a scoped /v1/data/query read by default — see
	// RunHealthGate). Empty disables the check with an explicit "skipped" detail.
	PostgresProbeURL string
	// RequireDatabaseStatusOperational makes the Postgres probe decode the
	// public status envelope and require its database component to be
	// operational. It is opt-in so explicit legacy probe URLs retain their
	// historical HTTP-200/body-independent contract.
	RequireDatabaseStatusOperational bool
	// AgentStatusURL is an ABSOLUTE URL to the agent-status endpoint. This
	// endpoint does NOT exist yet — cloud-9/10 build it. Until then the caller
	// points this at the real route (failing closed) or a fake in tests. Empty
	// marks the check skipped.
	AgentStatusURL string
	// BackupStatusURL is an ABSOLUTE URL to the backup-schedule endpoint, same
	// stub story as AgentStatusURL.
	BackupStatusURL string

	// CloudSitesURL is an OPTIONAL absolute URL to the Cloud control plane's
	// GET /v1/sites endpoint (cloud-12c / P6). When set, the gate adds a
	// "cloud-sites" check that authenticates with CloudSitesToken, decodes the
	// {"sites":[...]} envelope, and reports a count plus the slugs of any
	// sites that have no current_deployment_id (which the docs treat as the
	// "no live deployment" signal — the deployment-status walk is N+1 and
	// stays out of the gate). Leaving this empty skips the check entirely —
	// unlike the agent/backup stubs, a missing Cloud-sites URL doesn't fail
	// the gate, because most deployments don't sign up for hosted-sites.
	CloudSitesURL   string
	CloudSitesToken string

	// Timeout bounds each individual HTTP probe. Zero means healthGateTimeout.
	Timeout time.Duration
	// RootCAs, when non-nil, replaces the system trust store for the TLS +
	// websocket + https probes. Tests set this to httptest.Server.Certificate()'s
	// pool so the self-signed test cert verifies; production leaves it nil.
	RootCAs *x509.CertPool

	// PinnedIP, when non-empty, makes every probe whose URL host equals
	// BaseURL's hostname DIAL PinnedIP:<port> instead of resolving the name
	// through the local resolver. The URL's hostname stays in place for the
	// Host header, TLS SNI, and cert verification (the rewrite happens inside
	// DialContext, below the layer net/http derives all three from), so the
	// gate still proves the box answers AS its public identity — it just stops
	// trusting the resolver. Why: the support chain's gate runs on the CP box,
	// and barkpark.cloud's SOA minimum is 3600s — after a failed chain deletes
	// the A record, NXDOMAIN is negative-cached for up to an hour, so a retry
	// on the same name fails the entire gate deadline even though box, record,
	// and cert are fine (live-reproduced twice, 2026-07-26); a repointed name's
	// stale positive cache (zone TTL 300) fails the same way. Probe URLs on
	// OTHER hosts (injected agent/backup/cloud-sites probes) dial normally.
	PinnedIP string

	// StubsOptional flips the unconfigured-stub behavior from fail-closed to
	// skip-OK. By default an empty AgentStatusURL/BackupStatusURL is not-ready
	// (forces wiring before go-live). The Cloud warm-pool sets this true for v1:
	// the agent + backup endpoints are cloud-9/10 and not deployed on instances
	// yet, so requiring them would block EVERY go-live. Once those features ship
	// and the caller wires real URLs, the probes run regardless of this flag
	// (a non-empty URL is always probed), so this only governs the unwired case.
	StubsOptional bool
}

// healthGateTimeout is the per-probe HTTP timeout when HealthGate.Timeout is 0.
const healthGateTimeout = 8 * time.Second

// CheckStatus is the outcome of one check, and it has THREE values on purpose.
// "I could not check this" is not "this is broken", and it is not "this is
// fine" either — a probe that did not run has no evidence to vote with, so it
// abstains. Collapsing that third state into either of the other two produces a
// lying instrument: fold it into CheckFail and the gate cries wolf until nobody
// reads it; fold it into CheckPass and the report claims it verified a
// condition it never looked at. BOTH mistakes have shipped on this gate — the
// second one is what StubsOptional does today — which is why the state is now
// spelled out rather than implied by a bool.
type CheckStatus string

const (
	// CheckPass — the probe ran and the condition held.
	CheckPass CheckStatus = "pass"
	// CheckFail — the probe ran and the condition did NOT hold. This is the
	// only status that makes a gate report not-ready.
	CheckFail CheckStatus = "fail"
	// CheckSkip — the probe did not run, so this check has no opinion. It is
	// counted and rendered separately and it never votes: a skip cannot make a
	// gate red, and it is never added to a "N checks passed" total.
	CheckSkip CheckStatus = "skip"
)

// CheckResult is the outcome of one named check.
//
// Pass is retained as the WIRE-COMPATIBLE two-state projection for readers that
// predate Status (the Cloud control plane's Telemetry.summarize_checks reads
// `pass`). Its value under every status is exactly what this gate emitted
// before Status existed, so no existing consumer's roll-up moves on the day
// this ships; Status is the honest channel a reader opts into. Never derive a
// verdict from Pass inside this package — read Status through Effective.
type CheckResult struct {
	Name string `json:"name"`
	Pass bool   `json:"pass"`
	// Status is the three-valued outcome, omitted from the wire when empty so a
	// zero-value CheckResult built by an older caller round-trips unchanged and
	// is read through Effective's two-state fallback.
	Status CheckStatus `json:"status,omitempty"`
	Detail string      `json:"detail"`
}

// passCheck, failCheck and skipCheck are the ONLY ways this package builds a
// CheckResult. They exist so Status can never be silently left unset: the
// previous positional-literal shape let a new probe forget the field and
// inherit whatever the zero value happened to mean.
func passCheck(name, detail string) CheckResult {
	return CheckResult{Name: name, Pass: true, Status: CheckPass, Detail: detail}
}

func failCheck(name, detail string) CheckResult {
	return CheckResult{Name: name, Pass: false, Status: CheckFail, Detail: detail}
}

// skipCheck records an abstention. Pass is true ONLY to preserve the exact
// bytes older readers already receive for this case — an optional unwired stub
// has reported `pass:true` since StubsOptional landed. It is not a claim that
// anything was verified, and every reader inside this package routes through
// Effective, which reports CheckSkip.
func skipCheck(name, detail string) CheckResult {
	return CheckResult{Name: name, Pass: true, Status: CheckSkip, Detail: detail}
}

// Effective returns the check's status, defaulting an unset Status to the old
// two-state reading of Pass. A CheckResult built outside this package (a test
// literal, a caller compiled against the previous struct) therefore keeps its
// original meaning instead of silently becoming a skip — an abstention has to
// be asserted, never inferred from a missing field.
func (c CheckResult) Effective() CheckStatus {
	if c.Status != "" {
		return c.Status
	}
	if c.Pass {
		return CheckPass
	}
	return CheckFail
}

// HealthReport is the structured result of a full gate run: every check's
// outcome plus an OK roll-up that is true iff no check FAILED. Skipped checks
// do not move OK — they were never evidence in either direction.
type HealthReport struct {
	BaseURL string        `json:"base_url"`
	OK      bool          `json:"ok"`
	Checks  []CheckResult `json:"checks"`
}

// Failures returns the names of the checks that ran and did not hold, in order.
// A skipped check is NOT a failure and never appears here.
func (r HealthReport) Failures() []string {
	var f []string
	for _, c := range r.Checks {
		if c.Effective() == CheckFail {
			f = append(f, c.Name)
		}
	}
	return f
}

// Skipped returns the names of the checks that did not run, in order. It is the
// counterpart to Failures and exists so an operator reading a GREEN gate can
// still see what it declined to look at — a readiness claim is only as good as
// the list of things actually probed.
func (r HealthReport) Skipped() []string {
	var s []string
	for _, c := range r.Checks {
		if c.Effective() == CheckSkip {
			s = append(s, c.Name)
		}
	}
	return s
}

// Passed returns the names of the checks that ran and held, in order.
func (r HealthReport) Passed() []string {
	var p []string
	for _, c := range r.Checks {
		if c.Effective() == CheckPass {
			p = append(p, c.Name)
		}
	}
	return p
}

// String renders the report as a human-scannable block: one line per check with
// a PASS/FAIL/SKIP marker and the detail, then a final roll-up line. It is used
// implicitly via fmt's Stringer interface by test %s/%v format verbs
// (healthgate_test.go) — a live caller, so it stays.
//
// The roll-up never says "all N checks passed" when any check was skipped: N
// would include probes that never ran, and that exact sentence is what turned
// an unwired stub into a verified condition.
func (r HealthReport) String() string {
	var b strings.Builder
	fmt.Fprintf(&b, "health gate — %s\n", r.BaseURL)
	for _, c := range r.Checks {
		mark := "FAIL"
		switch c.Effective() {
		case CheckPass:
			mark = "PASS"
		case CheckSkip:
			mark = "SKIP"
		}
		fmt.Fprintf(&b, "  [%s] %s — %s\n", mark, c.Name, c.Detail)
	}
	skipped := r.Skipped()
	if r.OK {
		if len(skipped) == 0 {
			fmt.Fprintf(&b, "  => READY (all %d checks passed)\n", len(r.Checks))
		} else {
			fmt.Fprintf(&b, "  => READY (%d passed, %d NOT CHECKED: %s)\n",
				len(r.Passed()), len(skipped), strings.Join(skipped, ", "))
		}
	} else {
		fmt.Fprintf(&b, "  => NOT READY (%d/%d failed: %s)\n",
			len(r.Failures()), len(r.Checks), strings.Join(r.Failures(), ", "))
		if len(skipped) > 0 {
			fmt.Fprintf(&b, "  => %d NOT CHECKED: %s\n", len(skipped), strings.Join(skipped, ", "))
		}
	}
	return b.String()
}

// RunHealthGate runs the 7-check gate against base and returns the report. The
// returned error is non-nil iff NOT every check passed — so a caller can both
// inspect the structured report AND treat the gate as a hard pass/fail with a
// single `if err != nil`. opts may leave the stub-probe URLs ("") — an unwired
// stub is a FAIL by default (wiring it is required before go-live), and with
// StubsOptional it is a SKIP: it does not fail the gate, and it is not counted
// as a passing check either. Read HealthReport.Skipped to see what a green gate
// declined to probe.
func RunHealthGate(base, token string, opts HealthGate) (HealthReport, error) {
	g := opts
	g.BaseURL = strings.TrimRight(base, "/")
	g.Token = token
	if g.Timeout <= 0 {
		g.Timeout = healthGateTimeout
	}

	// Default the Postgres probe to a scoped query read when the caller did not
	// supply one — that is the honest "the DB answered" signal the API exposes.
	if g.PostgresProbeURL == "" && g.BaseURL != "" {
		g.PostgresProbeURL = g.BaseURL + "/w/default/p/default/v1/data/query/production/post?limit=0"
	}

	checks := []CheckResult{
		g.checkCapabilities(),
		g.checkStudio(),
		g.checkWebsocket(),
		g.checkTLS(),
		g.checkPostgres(),
		g.checkAgentConnected(),
		g.checkBackupScheduled(),
	}
	// Cloud-sites is opt-in (the gate only adds it when a CloudSitesURL is
	// configured) so a self-hosted Barkpark with no Cloud control plane in
	// scope doesn't get a spurious failure. Doctor wires the URL from
	// Config.CloudURL + CloudToken when the user is logged in.
	if g.CloudSitesURL != "" {
		checks = append(checks, g.checkCloudSites())
	}
	report := HealthReport{
		BaseURL: g.BaseURL,
		Checks:  checks,
	}
	// A gate is red only when a check RAN and did not hold. A skipped check
	// carries no evidence, so it cannot make the gate red — and it is equally
	// barred from the "passed" total that String and the doctor render.
	report.OK = true
	for _, c := range report.Checks {
		if c.Effective() == CheckFail {
			report.OK = false
		}
	}
	if !report.OK {
		return report, fmt.Errorf("health gate failed: %s not ready", strings.Join(report.Failures(), ", "))
	}
	return report, nil
}

// httpClient builds an HTTP client for the gate's probes. It never follows
// redirects (the websocket + studio checks read the FIRST status verbatim),
// pins RootCAs when the caller injected a test trust store, and — with
// PinnedIP set — rewrites the DIAL for BaseURL's hostname (every check, the
// websocket preflight included, goes through this one client, so the pin
// covers the whole battery).
func (g HealthGate) httpClient() *http.Client {
	tr := &http.Transport{}
	if g.RootCAs != nil {
		tr.TLSClientConfig = &tls.Config{RootCAs: g.RootCAs}
	}
	if g.PinnedIP != "" {
		// Rewrite ONLY the dialed address, only for BaseURL's host: net/http
		// derives the Host header, TLS SNI, and the cert-verification name from
		// the request URL, all above this hook, so swapping the address here
		// keeps every identity check intact while skipping the resolver — the
		// whole point of the pin (never touch tls.Config.ServerName for this).
		// Off-base hosts (injected agent/backup/cloud-sites probe URLs) fall
		// through to a normal resolved dial.
		pinnedHost := ""
		if u, err := url.Parse(g.BaseURL); err == nil {
			pinnedHost = u.Hostname()
		}
		dialer := &net.Dialer{}
		tr.DialContext = func(ctx context.Context, network, addr string) (net.Conn, error) {
			if host, port, err := net.SplitHostPort(addr); err == nil && pinnedHost != "" && strings.EqualFold(host, pinnedHost) {
				addr = net.JoinHostPort(g.PinnedIP, port)
			}
			return dialer.DialContext(ctx, network, addr)
		}
	}
	return &http.Client{
		Timeout:   g.Timeout,
		Transport: tr,
		CheckRedirect: func(*http.Request, []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}
}

// checkCapabilities (1): GET /v1/capabilities must return 200 — the API is up.
func (g HealthGate) checkCapabilities() CheckResult {
	const name = "capabilities"
	resp, err := g.httpClient().Get(g.BaseURL + "/v1/capabilities")
	if err != nil {
		return failCheck(name, fmt.Sprintf("GET /v1/capabilities: %v", err))
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return failCheck(name, fmt.Sprintf("GET /v1/capabilities returned %d, want 200", resp.StatusCode))
	}
	return passCheck(name, "GET /v1/capabilities returned 200 (API up)")
}

// CheckStudio is the exported wrapper over checkStudio so the Go provisioner's
// golden-path VERIFY gate (C2/D45) can reuse the EXACT scoped-redirect hop logic
// — the ≤3-hop walk that catches a Studio whose session pipeline 500s one hop
// past the bare 302 — without duplicating it. It returns the same CheckResult
// checkStudio produces; a final status <500 (renders, or an auth redirect that
// still proves the session pipeline is alive) passes.
func (g HealthGate) CheckStudio() CheckResult { return g.checkStudio() }

// checkStudio (2): GET /studio, FOLLOWING the scoped-path redirect chain (≤3
// hops). A bare 302 proves nothing: the unscoped route redirects BEFORE the
// session pipeline runs, so a Studio whose cookie store crashes on every
// request (e.g. a short SECRET_KEY_BASE) still 302s here and 500s one hop
// later — which is exactly how a go-live gate once greenlit a Studio-dead box.
// The scoped hop exercises Plug.Session; any final status <500 passes (200
// renders; an auth redirect still proves the session pipeline is alive).
func (g HealthGate) checkStudio() CheckResult {
	const name = "studio"
	url := g.BaseURL + "/studio"
	for hop := 0; hop <= 3; hop++ {
		resp, err := g.httpClient().Get(url)
		if err != nil {
			return failCheck(name, fmt.Sprintf("GET %s: %v", url, err))
		}
		resp.Body.Close()
		if resp.StatusCode >= 300 && resp.StatusCode < 400 {
			loc := resp.Header.Get("Location")
			if loc == "" {
				return failCheck(name, fmt.Sprintf("GET %s returned %d with no Location", url, resp.StatusCode))
			}
			if strings.HasPrefix(loc, "/") {
				loc = g.BaseURL + loc
			}
			url = loc
			continue
		}
		if resp.StatusCode >= 500 {
			return failCheck(name, fmt.Sprintf("GET %s returned %d (Studio's session pipeline is broken)", url, resp.StatusCode))
		}
		return passCheck(name, fmt.Sprintf("GET %s returned %d (Studio renders through the scoped path)", url, resp.StatusCode))
	}
	return failCheck(name, "GET /studio: redirect chain exceeded 3 hops without rendering")
}

// checkWebsocket (3): the LiveView footgun. Send the EXACT websocket-upgrade
// preflight from Makefile:173 to /live/websocket. A 403 here is the
// check_origin/PHX_HOST drift that leaves Studio silently click-dead. A genuine
// upgrade attempt answers 101 (switching) or 400/426 (upgrade-required / bad
// preflight against a server that DID accept the origin) — any non-403 is a
// pass; the gate's job is specifically to catch the 403.
func (g HealthGate) checkWebsocket() CheckResult {
	const name = "websocket-not-403"
	req, err := http.NewRequest("GET", g.BaseURL+"/live/websocket", nil)
	if err != nil {
		return failCheck(name, fmt.Sprintf("build request: %v", err))
	}
	// Exactly the headers the Makefile websocket probe sends.
	origin := g.BaseURL
	if u, perr := url.Parse(g.BaseURL); perr == nil && u.Host != "" {
		origin = u.Scheme + "://" + u.Host
	}
	req.Header.Set("Origin", origin)
	req.Header.Set("Upgrade", "websocket")
	req.Header.Set("Connection", "Upgrade")
	req.Header.Set("Sec-WebSocket-Key", "test")
	req.Header.Set("Sec-WebSocket-Version", "13")

	resp, err := g.httpClient().Do(req)
	if err != nil {
		return failCheck(name, fmt.Sprintf("GET /live/websocket: %v", err))
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusForbidden {
		return failCheck(name, "GET /live/websocket returned 403 — check_origin/PHX_HOST drift; Studio is click-dead (see docs/ops/studio-nav-bug-2026-04-19.md)")
	}
	return passCheck(name, fmt.Sprintf("GET /live/websocket returned %d (not 403 — origin accepted)", resp.StatusCode))
}

// checkTLS (4): for an https BaseURL, the cert chain must verify against the
// trust store (system, or the injected RootCAs in tests). A plain-http BaseURL
// has no cert to check — that is reported as a pass with an explicit "http,
// no TLS to verify" detail so the gate is honest rather than silently green.
func (g HealthGate) checkTLS() CheckResult {
	const name = "tls"
	u, err := url.Parse(g.BaseURL)
	if err != nil {
		return failCheck(name, fmt.Sprintf("parse base URL: %v", err))
	}
	if u.Scheme != "https" {
		return passCheck(name, "base URL is http — no TLS to verify")
	}
	// A real GET with default (verifying) TLS: a cert error surfaces as a
	// transport error here. We do NOT set InsecureSkipVerify — that is the whole
	// point of the check.
	resp, err := g.httpClient().Get(g.BaseURL + "/v1/capabilities")
	if err != nil {
		if strings.Contains(err.Error(), "x509") || strings.Contains(err.Error(), "certificate") || strings.Contains(err.Error(), "tls") {
			return failCheck(name, fmt.Sprintf("TLS verification failed: %v", err))
		}
		return failCheck(name, fmt.Sprintf("TLS probe could not connect: %v", err))
	}
	defer resp.Body.Close()
	return passCheck(name, fmt.Sprintf("TLS cert for %s verified", u.Host))
}

// checkPostgres (5): proves the DB answers by reading through the API. The
// default probe is a scoped /v1/data/query read (limit=0) — a 200 means the
// controller reached Postgres and got a result set back; a 5xx means the DB
// path is broken. This is an honest "DB reachable via API" check, NOT a direct
// pg connection.
func (g HealthGate) checkPostgres() CheckResult {
	const name = "postgres-via-api"
	if g.PostgresProbeURL == "" {
		return failCheck(name, "no Postgres probe URL configured and no BaseURL to derive one from (treated as not-ready)")
	}
	req, err := http.NewRequest("GET", g.PostgresProbeURL, nil)
	if err != nil {
		return failCheck(name, fmt.Sprintf("build request: %v", err))
	}
	if g.Token != "" {
		req.Header.Set("Authorization", "Bearer "+g.Token)
	}
	resp, err := g.httpClient().Do(req)
	if err != nil {
		return failCheck(name, fmt.Sprintf("query probe: %v", err))
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return failCheck(name, fmt.Sprintf("query probe returned %d, want 200 (DB read failed)", resp.StatusCode))
	}
	if g.RequireDatabaseStatusOperational {
		var status struct {
			Components []struct {
				Name   string `json:"name"`
				Status string `json:"status"`
			} `json:"components"`
		}
		if err := json.NewDecoder(resp.Body).Decode(&status); err != nil {
			return failCheck(name, fmt.Sprintf("status probe returned malformed JSON: %v", err))
		}
		for _, component := range status.Components {
			if component.Name == "database" {
				if component.Status == "operational" {
					return passCheck(name, "public status database component is operational")
				}
				return failCheck(name, fmt.Sprintf("public status database component is %q, want operational", component.Status))
			}
		}
		return failCheck(name, "public status response has no database component")
	}
	return passCheck(name, "scoped query read returned 200 (Postgres reachable via API)")
}

// checkAgentConnected (6): STUB PROBE. The agent-status endpoint does not exist
// yet (cloud-9/10 build it). This check GETs the configured AgentStatusURL and
// passes on 200; it is wired for the real route the moment that endpoint ships,
// and points at a fake in tests. Honest name: the check itself is real, the
// endpoint behind it is a stub.
func (g HealthGate) checkAgentConnected() CheckResult {
	return g.stubProbe("agent-connected-stub", g.AgentStatusURL, "agent-status endpoint (cloud-9/10)")
}

// checkBackupScheduled (7): STUB PROBE, same shape as checkAgentConnected.
func (g HealthGate) checkBackupScheduled() CheckResult {
	return g.stubProbe("backup-scheduled-stub", g.BackupStatusURL, "backup-schedule endpoint (cloud-9/10)")
}

// checkCloudSites (opt-in 8th check): GET the Cloud control plane's /v1/sites
// with the Cloud bearer token. A 200 + a decodable {"sites":[...]} envelope
// passes; the detail names the count and the slugs of any sites with no
// `current_deployment_id` (the docs' "no live deployment" signal). A 401 / 5xx
// is a hard fail. The check is added by RunHealthGate ONLY when
// CloudSitesURL is set, so a self-hosted Barkpark without a Cloud control
// plane never sees this check at all.
func (g HealthGate) checkCloudSites() CheckResult {
	const name = "cloud-sites"
	req, err := http.NewRequest("GET", g.CloudSitesURL, nil)
	if err != nil {
		return failCheck(name, fmt.Sprintf("build request: %v", err))
	}
	if g.CloudSitesToken != "" {
		req.Header.Set("Authorization", "Bearer "+g.CloudSitesToken)
	}
	resp, err := g.httpClient().Do(req)
	if err != nil {
		return failCheck(name, fmt.Sprintf("GET /v1/sites: %v", err))
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusUnauthorized {
		return failCheck(name, "GET /v1/sites returned 401 — saved Cloud token rejected; run `bp login` to refresh")
	}
	if resp.StatusCode != http.StatusOK {
		return failCheck(name, fmt.Sprintf("GET /v1/sites returned %d, want 200", resp.StatusCode))
	}
	// Decode just the slug + current_deployment_id off each row — enough to
	// count sites and flag the ones with no live deployment.
	var env struct {
		Sites []struct {
			Slug                string `json:"slug"`
			CurrentDeploymentID string `json:"current_deployment_id"`
		} `json:"sites"`
	}
	dec := json.NewDecoder(resp.Body)
	if err := dec.Decode(&env); err != nil {
		return failCheck(name, fmt.Sprintf("decode /v1/sites response: %v", err))
	}
	count := len(env.Sites)
	var noLive []string
	for _, s := range env.Sites {
		if s.CurrentDeploymentID == "" {
			noLive = append(noLive, s.Slug)
		}
	}
	if len(noLive) > 0 {
		return passCheck(name,
			fmt.Sprintf("%d site(s) registered; %d with no live deployment yet: %s",
				count, len(noLive), strings.Join(noLive, ", ")))
	}
	return passCheck(name, fmt.Sprintf("%d site(s) registered; all have a live deployment", count))
}

// stubProbe is the shared body for checks 6-7: GET probeURL with the token and
// pass on 200.
//
// An empty probeURL means the probe DID NOT RUN, and the two ways of saying so
// are deliberately different states, not different wordings:
//
//   - StubsOptional — the caller has declared this condition out of scope for
//     now (agent + backup endpoints are cloud-9/10 and not deployed yet), so the
//     check ABSTAINS: CheckSkip. It does not fail the gate, and — the part that
//     was wrong before — it is not counted as a passing check either. Reporting
//     "all 7 checks passed" when two of them were never probed is a claim to
//     have verified an agent connection and a backup schedule that nothing
//     looked at.
//   - otherwise — wiring this probe is REQUIRED before go-live and it is
//     missing. That is a real, actionable failure of the operator's contract,
//     not an abstention, so it stays CheckFail.
func (g HealthGate) stubProbe(name, probeURL, what string) CheckResult {
	if probeURL == "" {
		if g.StubsOptional {
			return skipCheck(name, fmt.Sprintf("NOT CHECKED — no probe URL for %s (optional in v1; agent/backup are cloud-9/10). This check did not run and is not evidence of readiness.", what))
		}
		return failCheck(name, fmt.Sprintf("no probe URL for %s and wiring it is required (treated as not-ready)", what))
	}
	req, err := http.NewRequest("GET", probeURL, nil)
	if err != nil {
		return failCheck(name, fmt.Sprintf("build request: %v", err))
	}
	if g.Token != "" {
		req.Header.Set("Authorization", "Bearer "+g.Token)
	}
	resp, err := g.httpClient().Do(req)
	if err != nil {
		return failCheck(name, fmt.Sprintf("%s probe: %v", what, err))
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return failCheck(name, fmt.Sprintf("%s returned %d, want 200", what, resp.StatusCode))
	}
	return passCheck(name, fmt.Sprintf("%s returned 200", what))
}

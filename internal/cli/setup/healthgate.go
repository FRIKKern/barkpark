package setup

import (
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"fmt"
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

// CheckResult is the outcome of one named check.
type CheckResult struct {
	Name   string `json:"name"`
	Pass   bool   `json:"pass"`
	Detail string `json:"detail"`
}

// HealthReport is the structured result of a full gate run: every check's
// outcome plus an OK roll-up that is true iff EVERY check passed.
type HealthReport struct {
	BaseURL string        `json:"base_url"`
	OK      bool          `json:"ok"`
	Checks  []CheckResult `json:"checks"`
}

// Failures returns the names of the checks that did not pass, in order.
func (r HealthReport) Failures() []string {
	var f []string
	for _, c := range r.Checks {
		if !c.Pass {
			f = append(f, c.Name)
		}
	}
	return f
}

// String renders the report as a human-scannable block: one line per check
// with a PASS/FAIL marker and the detail, then a final roll-up line.
func (r HealthReport) String() string {
	var b strings.Builder
	fmt.Fprintf(&b, "health gate — %s\n", r.BaseURL)
	for _, c := range r.Checks {
		mark := "PASS"
		if !c.Pass {
			mark = "FAIL"
		}
		fmt.Fprintf(&b, "  [%s] %s — %s\n", mark, c.Name, c.Detail)
	}
	if r.OK {
		fmt.Fprintf(&b, "  => READY (all %d checks passed)\n", len(r.Checks))
	} else {
		fmt.Fprintf(&b, "  => NOT READY (%d/%d failed: %s)\n",
			len(r.Failures()), len(r.Checks), strings.Join(r.Failures(), ", "))
	}
	return b.String()
}

// RunHealthGate runs the 7-check gate against base and returns the report. The
// returned error is non-nil iff NOT every check passed — so a caller can both
// inspect the structured report AND treat the gate as a hard pass/fail with a
// single `if err != nil`. opts may leave the stub-probe URLs ("") to skip
// checks 5-7; a skipped check counts as a FAIL (a gate that cannot prove
// readiness is not ready).
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
	report.OK = true
	for _, c := range report.Checks {
		if !c.Pass {
			report.OK = false
		}
	}
	if !report.OK {
		return report, fmt.Errorf("health gate failed: %s not ready", strings.Join(report.Failures(), ", "))
	}
	return report, nil
}

// httpClient builds an HTTP client for the gate's probes. It never follows
// redirects (the websocket + studio checks read the FIRST status verbatim) and
// pins RootCAs when the caller injected a test trust store.
func (g HealthGate) httpClient() *http.Client {
	tr := &http.Transport{}
	if g.RootCAs != nil {
		tr.TLSClientConfig = &tls.Config{RootCAs: g.RootCAs}
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
		return CheckResult{name, false, fmt.Sprintf("GET /v1/capabilities: %v", err)}
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return CheckResult{name, false, fmt.Sprintf("GET /v1/capabilities returned %d, want 200", resp.StatusCode)}
	}
	return CheckResult{name, true, "GET /v1/capabilities returned 200 (API up)"}
}

// checkStudio (2): GET /studio must return 200 or 302 — Studio renders (a 302
// is the scoped-path redirect). Anything else (incl. 5xx) fails.
func (g HealthGate) checkStudio() CheckResult {
	const name = "studio"
	resp, err := g.httpClient().Get(g.BaseURL + "/studio")
	if err != nil {
		return CheckResult{name, false, fmt.Sprintf("GET /studio: %v", err)}
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusOK || resp.StatusCode == http.StatusFound {
		return CheckResult{name, true, fmt.Sprintf("GET /studio returned %d (Studio renders)", resp.StatusCode)}
	}
	return CheckResult{name, false, fmt.Sprintf("GET /studio returned %d, want 200 or 302", resp.StatusCode)}
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
		return CheckResult{name, false, fmt.Sprintf("build request: %v", err)}
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
		return CheckResult{name, false, fmt.Sprintf("GET /live/websocket: %v", err)}
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusForbidden {
		return CheckResult{name, false, "GET /live/websocket returned 403 — check_origin/PHX_HOST drift; Studio is click-dead (see docs/ops/studio-nav-bug-2026-04-19.md)"}
	}
	return CheckResult{name, true, fmt.Sprintf("GET /live/websocket returned %d (not 403 — origin accepted)", resp.StatusCode)}
}

// checkTLS (4): for an https BaseURL, the cert chain must verify against the
// trust store (system, or the injected RootCAs in tests). A plain-http BaseURL
// has no cert to check — that is reported as a pass with an explicit "http,
// no TLS to verify" detail so the gate is honest rather than silently green.
func (g HealthGate) checkTLS() CheckResult {
	const name = "tls"
	u, err := url.Parse(g.BaseURL)
	if err != nil {
		return CheckResult{name, false, fmt.Sprintf("parse base URL: %v", err)}
	}
	if u.Scheme != "https" {
		return CheckResult{name, true, "base URL is http — no TLS to verify"}
	}
	// A real GET with default (verifying) TLS: a cert error surfaces as a
	// transport error here. We do NOT set InsecureSkipVerify — that is the whole
	// point of the check.
	resp, err := g.httpClient().Get(g.BaseURL + "/v1/capabilities")
	if err != nil {
		if strings.Contains(err.Error(), "x509") || strings.Contains(err.Error(), "certificate") || strings.Contains(err.Error(), "tls") {
			return CheckResult{name, false, fmt.Sprintf("TLS verification failed: %v", err)}
		}
		return CheckResult{name, false, fmt.Sprintf("TLS probe could not connect: %v", err)}
	}
	defer resp.Body.Close()
	return CheckResult{name, true, fmt.Sprintf("TLS cert for %s verified", u.Host)}
}

// checkPostgres (5): proves the DB answers by reading through the API. The
// default probe is a scoped /v1/data/query read (limit=0) — a 200 means the
// controller reached Postgres and got a result set back; a 5xx means the DB
// path is broken. This is an honest "DB reachable via API" check, NOT a direct
// pg connection.
func (g HealthGate) checkPostgres() CheckResult {
	const name = "postgres-via-api"
	if g.PostgresProbeURL == "" {
		return CheckResult{name, false, "skipped — no Postgres probe URL configured (treated as not-ready)"}
	}
	req, err := http.NewRequest("GET", g.PostgresProbeURL, nil)
	if err != nil {
		return CheckResult{name, false, fmt.Sprintf("build request: %v", err)}
	}
	if g.Token != "" {
		req.Header.Set("Authorization", "Bearer "+g.Token)
	}
	resp, err := g.httpClient().Do(req)
	if err != nil {
		return CheckResult{name, false, fmt.Sprintf("query probe: %v", err)}
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return CheckResult{name, false, fmt.Sprintf("query probe returned %d, want 200 (DB read failed)", resp.StatusCode)}
	}
	return CheckResult{name, true, "scoped query read returned 200 (Postgres reachable via API)"}
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
		return CheckResult{name, false, fmt.Sprintf("build request: %v", err)}
	}
	if g.CloudSitesToken != "" {
		req.Header.Set("Authorization", "Bearer "+g.CloudSitesToken)
	}
	resp, err := g.httpClient().Do(req)
	if err != nil {
		return CheckResult{name, false, fmt.Sprintf("GET /v1/sites: %v", err)}
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusUnauthorized {
		return CheckResult{name, false, "GET /v1/sites returned 401 — saved Cloud token rejected; run `bp login` to refresh"}
	}
	if resp.StatusCode != http.StatusOK {
		return CheckResult{name, false, fmt.Sprintf("GET /v1/sites returned %d, want 200", resp.StatusCode)}
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
		return CheckResult{name, false, fmt.Sprintf("decode /v1/sites response: %v", err)}
	}
	count := len(env.Sites)
	var noLive []string
	for _, s := range env.Sites {
		if s.CurrentDeploymentID == "" {
			noLive = append(noLive, s.Slug)
		}
	}
	if len(noLive) > 0 {
		return CheckResult{name, true,
			fmt.Sprintf("%d site(s) registered; %d with no live deployment yet: %s",
				count, len(noLive), strings.Join(noLive, ", "))}
	}
	return CheckResult{name, true, fmt.Sprintf("%d site(s) registered; all have a live deployment", count)}
}

// stubProbe is the shared body for checks 6-7: GET probeURL with the token and
// pass on 200. An empty probeURL marks the check skipped (and thus not-ready),
// since a gate that cannot prove the condition is not ready.
func (g HealthGate) stubProbe(name, probeURL, what string) CheckResult {
	if probeURL == "" {
		if g.StubsOptional {
			return CheckResult{name, true, fmt.Sprintf("skipped — no probe URL for %s (optional in v1; agent/backup are cloud-9/10)", what)}
		}
		return CheckResult{name, false, fmt.Sprintf("skipped — no probe URL for %s (treated as not-ready)", what)}
	}
	req, err := http.NewRequest("GET", probeURL, nil)
	if err != nil {
		return CheckResult{name, false, fmt.Sprintf("build request: %v", err)}
	}
	if g.Token != "" {
		req.Header.Set("Authorization", "Bearer "+g.Token)
	}
	resp, err := g.httpClient().Do(req)
	if err != nil {
		return CheckResult{name, false, fmt.Sprintf("%s probe: %v", what, err)}
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return CheckResult{name, false, fmt.Sprintf("%s returned %d, want 200", what, resp.StatusCode)}
	}
	return CheckResult{name, true, fmt.Sprintf("%s returned 200", what)}
}

package provisioner

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/FRIKKern/barkpark/internal/cli/setup"
)

// C2 / D45 — the golden-path VERIFY gate.
//
// A box that passes the health gate is "healthy", but healthy is not the same as
// "the owner can actually create a server, open Studio, and log in". The #957
// class of failure — a 32-byte SECRET_KEY_BASE — leaves a box that answers
// /v1/capabilities and even 302s /studio, yet dies with a 500 the moment the
// session/cookie stack is exercised (login, the scoped Studio hop). The health
// gate's Studio check already walks the scoped redirect to catch part of this;
// VERIFY closes the loop by additionally proving the AUTH stack answers.
//
// The gate runs AFTER content bootstrap and BEFORE the provisioner declares the
// box ready, over HTTPS against the live instance origin. Three probes, in order:
//
//	verify.api    GET  /v1/capabilities        → 200                 (the API is up)
//	verify.login  POST /v1/auth/login (sentinel wrong creds) → <500  (auth answers)
//	verify.studio GET  /studio (≤3 scoped hops) → final <500         (Studio renders)
//
// verify.login sends DELIBERATELY-WRONG sentinel credentials: a clean 401/422
// proves the whole request→session→auth pipeline ran and rejected them; ANY 5xx
// is the dead-on-arrival class and FAILS the gate. The minted admin token is
// held (for a future authenticated probe) but is NEVER sent by these anonymous /
// sentinel probes, and NEVER appears in any narrated evidence string.

const (
	// verifyProbeTimeout bounds each individual probe's HTTP request(s).
	verifyProbeTimeout = 10 * time.Second
	// verifyTotalBudget bounds the whole three-probe gate.
	verifyTotalBudget = 45 * time.Second
	// verifyMaxBodyBytes caps how much of a failing response body rides into the
	// failure evidence (≤200 bytes, per D45).
	verifyMaxBodyBytes = 200
)

// verifyLoginSentinel is the deliberately-invalid credential payload the login
// probe POSTs. It must never authenticate anything — its ONLY job is to make the
// auth/session stack answer (401/422 = alive; 5xx = #957 dead-on-arrival). It is
// NOT the minted admin token and carries no real secret.
const verifyLoginSentinel = `{"email":"barkpark-verify-probe@invalid.example","password":"deliberately-invalid-verify-sentinel"}`

// verifyConfig is one VERIFY gate invocation against a freshly provisioned box.
type verifyConfig struct {
	// baseURL is the instance origin (https://<label>.<zone> in prod; an httptest
	// fake instance in tests).
	baseURL string
	// token is the minted per-instance admin bearer. Held so an authenticated
	// probe could use it, but NEVER sent by the current anonymous/sentinel probes
	// and NEVER logged or narrated.
	token string
	// probeTimeout / totalBudget default to verifyProbeTimeout / verifyTotalBudget
	// when zero (production); tests set tiny values for fast fail paths.
	probeTimeout time.Duration
	totalBudget  time.Duration
}

// probeOutcome is one probe's verdict plus the evidence + elapsed time narrated
// for it. evidence is a short human string — for a green probe a one-line
// success, for a red probe "<status> — <body ≤200 bytes>" or the transport
// error. It NEVER carries a secret.
type probeOutcome struct {
	name     string
	pass     bool
	evidence string
	elapsed  time.Duration
}

// runVerifyGate probes the golden path against a freshly provisioned instance and
// narrates each probe through report. Probes run in order; the FIRST red probe is
// reported as verify/failed and returned as an error so ProvisionWith fails the
// job (the box is torn down and the worker never POSTs /succeed). All green →
// verify/done and a nil error.
//
// The verdict is derived ONLY from the probe HTTP outcomes. report() tees to the
// StepReporter + live console and SWALLOWS their errors, so a dropped step/console
// report can never flip the gate — a red gate fails and a green gate passes
// regardless of telemetry delivery.
func runVerifyGate(ctx context.Context, cfg verifyConfig, report func(step, status, detail string)) error {
	if cfg.probeTimeout <= 0 {
		cfg.probeTimeout = verifyProbeTimeout
	}
	if cfg.totalBudget <= 0 {
		cfg.totalBudget = verifyTotalBudget
	}
	ctx, cancel := context.WithTimeout(ctx, cfg.totalBudget)
	defer cancel()

	// One client for the api + login probes: per-request timeout, and it does NOT
	// follow redirects (login's status is read verbatim). verify.studio reuses the
	// health gate's own hop-walking client via setup.HealthGate.CheckStudio.
	client := &http.Client{
		Timeout: cfg.probeTimeout,
		CheckRedirect: func(*http.Request, []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}

	report("verify", "started", "")
	for _, probe := range []func(context.Context, verifyConfig, *http.Client) probeOutcome{
		verifyAPI, verifyLogin, verifyStudio,
	} {
		out := probe(ctx, cfg, client)
		if !out.pass {
			report("verify", "failed", fmt.Sprintf("%s: %s", out.name, out.evidence))
			return fmt.Errorf("golden-path %s: %s", out.name, out.evidence)
		}
		report("verify", "progress", fmt.Sprintf("%s: %s (%dms)", out.name, out.evidence, out.elapsed.Milliseconds()))
	}
	report("verify", "done", "")
	return nil
}

// verifyAPI (1): GET /v1/capabilities must return 200 — the API is up. Mirrors
// setup.HealthGate.checkCapabilities.
func verifyAPI(ctx context.Context, cfg verifyConfig, client *http.Client) probeOutcome {
	const name = "verify.api"
	start := time.Now()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, cfg.baseURL+"/v1/capabilities", nil)
	if err != nil {
		return probeOutcome{name, false, "build request: " + err.Error(), time.Since(start)}
	}
	resp, err := client.Do(req)
	if err != nil {
		return probeOutcome{name, false, fmt.Sprintf("transport error: %v", err), time.Since(start)}
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return probeOutcome{name, false, fmt.Sprintf("%d — %s", resp.StatusCode, verifyBodySnippet(resp.Body)), time.Since(start)}
	}
	return probeOutcome{name, true, "GET /v1/capabilities → 200 (API up)", time.Since(start)}
}

// verifyLogin (2): POST /v1/auth/login with sentinel wrong creds. PASS iff the
// status is <500 — a 401/422 proves the request→session→auth pipeline ran and
// cleanly rejected the creds. Any 5xx is the #957 32-byte-SECRET_KEY_BASE
// dead-on-arrival class (the session/cookie stack crashes before auth) → FAIL.
func verifyLogin(ctx context.Context, cfg verifyConfig, client *http.Client) probeOutcome {
	const name = "verify.login"
	start := time.Now()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, cfg.baseURL+"/v1/auth/login", strings.NewReader(verifyLoginSentinel))
	if err != nil {
		return probeOutcome{name, false, "build request: " + err.Error(), time.Since(start)}
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := client.Do(req)
	if err != nil {
		return probeOutcome{name, false, fmt.Sprintf("transport error: %v", err), time.Since(start)}
	}
	defer resp.Body.Close()
	if resp.StatusCode >= http.StatusInternalServerError {
		return probeOutcome{name, false, fmt.Sprintf("%d — %s", resp.StatusCode, verifyBodySnippet(resp.Body)), time.Since(start)}
	}
	return probeOutcome{name, true, fmt.Sprintf("POST /v1/auth/login → %d (auth stack answered; bad creds rejected)", resp.StatusCode), time.Since(start)}
}

// verifyStudio (3): GET /studio following the scoped-redirect chain (≤3 hops),
// final status <500 passes. It REUSES setup.HealthGate.CheckStudio so the exact
// hop-walking logic (and the reason it exists — a Studio that 302s then 500s one
// hop later) is shared, not duplicated. The context bounds the gate as a whole;
// the per-hop timeout is the health gate's own client timeout.
func verifyStudio(_ context.Context, cfg verifyConfig, _ *http.Client) probeOutcome {
	const name = "verify.studio"
	start := time.Now()
	hg := setup.HealthGate{
		BaseURL: cfg.baseURL,
		Token:   cfg.token, // held; CheckStudio is anonymous and does not send it
		Timeout: cfg.probeTimeout,
	}
	res := hg.CheckStudio()
	return probeOutcome{name, res.Pass, res.Detail, time.Since(start)}
}

// verifyBodySnippet reads at most verifyMaxBodyBytes of a failing response body
// for the failure evidence, trimmed. Bounded so a chatty error page can never
// bloat the narrated detail.
func verifyBodySnippet(r io.Reader) string {
	data, _ := io.ReadAll(io.LimitReader(r, verifyMaxBodyBytes))
	return strings.TrimSpace(string(data))
}

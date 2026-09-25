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
// box ready, over HTTPS against the live instance origin. Four probes, in order:
//
//	verify.api       GET  /v1/capabilities        → 200                 (the API is up)
//	verify.login     POST /v1/auth/login (sentinel wrong creds) → <500  (auth answers)
//	verify.studio    GET  /studio (≤3 scoped hops) → final <500         (Studio renders)
//	verify.siteplane the site-hosting plane, WHEN REQUIRED               (sites can build)
//
// verify.siteplane is the one probe that is not an HTTP request: nothing the
// instance origin serves can see docker / nixpacks / the builder units. It reads
// a SITE-PLANE FACT handed to the gate by its caller (verifyConfig.sitePlane*)
// and is CONDITIONAL: a caller that does not require a plane gets a SKIPPED
// probe (it passes, and its evidence says it was skipped — never a fake
// "installed"). See verifySitePlane for who requires it and why.
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

	// sitePlaneRequired says whether THIS box must carry the site-hosting plane
	// for the gate to pass. False (the zero value) makes verify.siteplane a
	// SKIPPED probe — the restore path's setting, because a restored box is a
	// CMS resurrection whose plane nobody installed in this run, and a box that
	// legitimately has no plane must still restore green.
	sitePlaneRequired bool
	// sitePlaneComplete is the site-plane FACT the probe reads, three-state
	// under internal/agent/site_plane.go's law: nil UNMEASURED, false a measured
	// verdict that the plane is missing, true present. At birth it is the go-live
	// chain's own record of step 7c (cloud.LiveServer.SitePlaneInstalled).
	// Ignored when sitePlaneRequired is false.
	sitePlaneComplete *bool
	// sitePlaneMissing / sitePlaneUnmeasured / sitePlaneLogTail explain a false
	// sitePlaneComplete (cloud.LiveServer's diagnosis of the failed step 7c):
	// the components measured absent / not readable after the failed install,
	// and the last lines of the installer's own output. They ride into the
	// failure evidence so an upstream apt / nixpacks outage reads as one.
	sitePlaneMissing    []string
	sitePlaneUnmeasured []string
	sitePlaneLogTail    string
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
	for _, probe := range verifyProbes {
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

// verifyProbes is the gate's dispatch order — the ONE list runVerifyGate walks
// and TestProvisionerProbeVocabularyMatchesFixture holds to verify_probes.json.
// verify.siteplane rides LAST: it is the only probe that is not an HTTP read,
// and a box whose CMS is dead should be reported as that, not as a plane fault.
var verifyProbes = []func(context.Context, verifyConfig, *http.Client) probeOutcome{
	verifyAPI, verifyLogin, verifyStudio, verifySitePlane,
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

// verifySitePlane (4): the site-hosting plane, CONDITIONALLY.
//
// Not required (sitePlaneRequired false) → PASS with evidence that says
// "skipped". That is the restore path and any caller with no expectation: a box
// that legitimately has no plane must not fail a gate over it.
//
// Required → PASS iff the fact is a measured true. A measured false FAILS (the
// box would go live with every site pointed at it sitting `queued`), and so does
// a nil: a required fact nobody measured is not a pass — a green with no
// subject is exactly the vacuous verdict the three-state law exists to refuse.
//
// ProvisionWith requires it iff the go-live chain actually ATTEMPTED step 7c
// (LiveServer.SitePlaneInstalled != nil — the control plane sent the agent
// token + control URL the plane installer rides on). An old control plane that
// never asked leaves it nil, and the probe is skipped: byte-for-byte the
// pre-probe verdict for those boxes.
func verifySitePlane(_ context.Context, cfg verifyConfig, _ *http.Client) probeOutcome {
	const name = "verify.siteplane"
	if !cfg.sitePlaneRequired {
		return probeOutcome{name, true, "skipped — no site plane required for this box", 0}
	}
	switch {
	case cfg.sitePlaneComplete == nil:
		return probeOutcome{name, false, "site plane required but UNMEASURED — nothing recorded whether it was installed", 0}
	case !*cfg.sitePlaneComplete:
		return probeOutcome{name, false, sitePlaneFailureEvidence(cfg), 0}
	default:
		return probeOutcome{name, true, "site plane installed (site-runtime installer exited 0)", 0}
	}
}

// sitePlaneFailureEvidence names what is missing and quotes the installer's
// last lines. Every clause is present only when it has content, but the
// "components" clause always says SOMETHING: when nothing was measured it says
// so, rather than implying a clean box.
func sitePlaneFailureEvidence(cfg verifyConfig) string {
	var b strings.Builder
	b.WriteString("site plane NOT installed — the site-runtime installer (go-live step 7c) failed; sites on this box would stay queued")
	if len(cfg.sitePlaneMissing) > 0 {
		b.WriteString("; missing: " + strings.Join(cfg.sitePlaneMissing, ", "))
	}
	if len(cfg.sitePlaneUnmeasured) > 0 {
		b.WriteString("; unmeasured: " + strings.Join(cfg.sitePlaneUnmeasured, ", "))
	}
	if len(cfg.sitePlaneMissing) == 0 && len(cfg.sitePlaneUnmeasured) == 0 {
		b.WriteString("; components: none recorded")
	}
	if cfg.sitePlaneLogTail != "" {
		b.WriteString("; step 7c log tail: " + cfg.sitePlaneLogTail)
	}
	return b.String()
}

// verifyBodySnippet reads at most verifyMaxBodyBytes of a failing response body
// for the failure evidence, trimmed. Bounded so a chatty error page can never
// bloat the narrated detail.
func verifyBodySnippet(r io.Reader) string {
	data, _ := io.ReadAll(io.LimitReader(r, verifyMaxBodyBytes))
	return strings.TrimSpace(string(data))
}

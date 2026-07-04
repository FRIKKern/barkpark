package provisioner

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"

	"github.com/FRIKKern/barkpark/internal/cli/cloud"
)

// WarmServer is one warm-pool box as the control-plane claim store hands it back:
// its Hetzner name (warm-<rand>) and public IP. The JSON matches the Elixir
// /v1/internal/warm-servers/* endpoints.
type WarmServer struct {
	Name string `json:"name"`
	IP   string `json:"ip"`
	// ClaimToken (claim-fence bp-c55) is the per-claim token the control plane
	// stamps and returns on a warm claim / claim-retire; the worker echoes it on the
	// DELETE so a stale delete of a re-registered box (same name, new claim) is
	// fenced to a no-op. Empty when a pre-Stage-1 control plane omitted the key, and
	// omitempty keeps it off the Register body (register doesn't carry a token).
	ClaimToken string `json:"claim_token,omitempty"`
}

// WarmPoolClient is the control-plane seam for the warm-server claim store
// (dwb-10). ALL claim atomicity lives server-side — a claim is a Postgres
// `FOR UPDATE SKIP LOCKED` row flip in the cloud app, so two concurrent claimers
// can never both win the same box (Hetzner labels are not CAS, which is exactly
// what leaked the old fixed-name pool). This seam just relays HTTP; tests inject a
// fake whose claim is a mutex (genuinely atomic at the seam boundary).
type WarmPoolClient interface {
	// Claim pops the oldest ready warm box for an ASSIGN. ok=false means the pool
	// is empty (the go-live falls through to one-shot). A transport error is
	// returned (the caller logs + one-shots, never blocking the go-live).
	Claim(ctx context.Context) (ws WarmServer, ok bool, err error)
	// ClaimForRetire pops the oldest ready box for RETIREMENT (the reconciler
	// shrinking an oversized pool). SKIP LOCKED, so it can never grab a box an
	// assign already claimed. ok=false means nothing ready to retire.
	ClaimForRetire(ctx context.Context) (ws WarmServer, ok bool, err error)
	// Register records a freshly-created warm box into the pool. Idempotent on name.
	Register(ctx context.Context, ws WarmServer) error
	// Delete drops a box's claim-store row once its box is consumed (assigned live,
	// torn down on a failed assign, or retired). Idempotent. claim-fence (bp-c55):
	// claimToken is the token from the Claim/ClaimForRetire that popped this box;
	// echoed so the server only deletes while it still matches (a stale delete of a
	// re-registered box is a no-op). Empty → delete-by-name (Stage 1 compat).
	Delete(ctx context.Context, name, claimToken string) error
	// CountReady reports how many ready (unclaimed) boxes the pool holds — the
	// reconciler's grow/shrink input.
	CountReady(ctx context.Context) (int, error)
}

const (
	warmClaimPath       = "/v1/internal/warm-servers/claim"
	warmClaimRetirePath = "/v1/internal/warm-servers/claim-retire"
	warmRegisterPath    = "/v1/internal/warm-servers"
	warmCountPath       = "/v1/internal/warm-servers/count"
	warmDeletePathFmt   = "/v1/internal/warm-servers/%s"
)

// warmRefillTimeout bounds a single async pool refill (create + freshen + register
// one box). Raised 6 → 20 min for dwb-17: a fresh warm box is now FRESHENED to
// origin/main before it enters the pool (fail-closed), and a real deploy-rebuild is
// many minutes — the old 6m budget would abort a legitimate rebuild mid-flight. It
// runs in the background where nobody waits, so a generous bound is free.
const warmRefillTimeout = 20 * time.Minute

// sshReadyWaiter is the optional readiness-probe capability a per-host runner
// advertises (the production cloud.SSHStepRunner implements WaitReady; the test
// fakes don't). Declared locally so the warm-create freshen path can wait for a
// freshly-created box's sshd before it SSHes in, mirroring cloud.configureHost.
type sshReadyWaiter interface {
	WaitReady(ctx context.Context, timeout time.Duration) error
}

// freshenWarmBox brings a freshly-CREATED warm box's baked checkout to origin/main
// BEFORE it is registered into the pool (dwb-17, call site (a)). It is FAIL-CLOSED:
// it returns an error on any freshen failure so the caller tears the box down — a
// stale box must NEVER enter the pool (unlike the in-chain go-live path, which
// degrades to a working baked box; here nobody is waiting, so we can afford to
// insist on current). It builds the per-host runner (the injected RunnerFor in
// tests, else the real SSH runner), waits for sshd, then runs the freshen sequence
// with NO narration (a background refill has no user watching) and no rebuild
// sub-budget (the whole call is already bounded by the caller's ctx /
// warmRefillTimeout).
func freshenWarmBox(ctx context.Context, seams Seams, host cloud.Server) error {
	var runner cloud.StepRunner
	if seams.RunnerFor != nil {
		runner = seams.RunnerFor(host.IP)
	} else {
		runner = cloud.NewSSHStepRunner(host.IP)
	}

	// A freshly-created box isn't SSH-ready the instant create returns (OS still
	// booting). Wait for sshd before the freshen SSHes in; test fakes without the
	// capability skip it.
	if rw, ok := runner.(sshReadyWaiter); ok {
		if err := rw.WaitReady(ctx, warmFreshenSSHReadyTimeout); err != nil {
			return fmt.Errorf("ssh not ready on %s: %w", host.IP, err)
		}
	}

	if _, err := cloud.EnsureFresh(ctx, runner, cloud.FreshenOpts{}); err != nil {
		return err
	}
	return nil
}

// warmFreshenSSHReadyTimeout bounds the sshd wait before the warm-create freshen —
// a snapshot boot is ~30-60s; 3 min is generous (parity with cloud.sshReadyTimeout).
const warmFreshenSSHReadyTimeout = 3 * time.Minute

// HTTPWarmPoolClient is the production WarmPoolClient: it talks to the control
// plane's /v1/internal/warm-servers/* endpoints with the shared WORKER_TOKEN,
// mirroring the Worker's own transport. Injected in main(); tests point it at an
// httptest.Server.
type HTTPWarmPoolClient struct {
	// ControlURL is the control-plane origin (trailing slash trimmed).
	ControlURL string
	// Token is the shared WORKER_TOKEN, sent as `Authorization: Bearer <token>`.
	Token string
	// HTTPClient is the injected client. nil → http.DefaultClient.
	HTTPClient *http.Client
}

func (c *HTTPWarmPoolClient) httpClient() *http.Client {
	if c.HTTPClient != nil {
		return c.HTTPClient
	}
	return http.DefaultClient
}

func (c *HTTPWarmPoolClient) url(path string) string {
	return strings.TrimRight(c.ControlURL, "/") + path
}

func (c *HTTPWarmPoolClient) authorize(req *http.Request) {
	if c.Token != "" {
		req.Header.Set("Authorization", "Bearer "+c.Token)
	}
}

// claimOne POSTs a claim endpoint and decodes {name, ip} on 200; a 204 is the
// empty signal (ok=false, no error); any other status is an error.
func (c *HTTPWarmPoolClient) claimOne(ctx context.Context, path string) (WarmServer, bool, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.url(path), nil)
	if err != nil {
		return WarmServer{}, false, err
	}
	c.authorize(req)

	resp, err := c.httpClient().Do(req)
	if err != nil {
		return WarmServer{}, false, err
	}
	defer resp.Body.Close()
	data, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))

	switch {
	case resp.StatusCode == http.StatusNoContent:
		return WarmServer{}, false, nil
	case resp.StatusCode < 200 || resp.StatusCode >= 300:
		return WarmServer{}, false, fmt.Errorf("POST %s: status %d: %s", path, resp.StatusCode, truncate(string(data), 200))
	}

	var ws WarmServer
	if len(bytes.TrimSpace(data)) > 0 {
		if err := json.Unmarshal(data, &ws); err != nil {
			return WarmServer{}, false, fmt.Errorf("decode %s response: %w", path, err)
		}
	}
	if strings.TrimSpace(ws.Name) == "" {
		return WarmServer{}, false, fmt.Errorf("%s response missing name: %s", path, truncate(string(data), 200))
	}
	return ws, true, nil
}

// Claim pops a ready box for an assign.
func (c *HTTPWarmPoolClient) Claim(ctx context.Context) (WarmServer, bool, error) {
	return c.claimOne(ctx, warmClaimPath)
}

// ClaimForRetire pops a ready box for retirement.
func (c *HTTPWarmPoolClient) ClaimForRetire(ctx context.Context) (WarmServer, bool, error) {
	return c.claimOne(ctx, warmClaimRetirePath)
}

// Register records a warm box into the pool (POST {name, ip}); enforces a 2xx.
func (c *HTTPWarmPoolClient) Register(ctx context.Context, ws WarmServer) error {
	buf, _ := json.Marshal(ws)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.url(warmRegisterPath), bytes.NewReader(buf))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	c.authorize(req)
	return c.do2xx(req, "register warm server "+ws.Name)
}

// Delete drops a box's claim-store row (DELETE); enforces a 2xx (idempotent).
// claim-fence (bp-c55): when claimToken is non-empty it rides as `?claim_token=`
// (the server reads a body key OR the query param) so a stale delete of a
// re-registered box is fenced to a no-op; empty → today's delete-by-name.
func (c *HTTPWarmPoolClient) Delete(ctx context.Context, name, claimToken string) error {
	target := c.url(fmt.Sprintf(warmDeletePathFmt, name))
	if claimToken != "" {
		target += "?claim_token=" + url.QueryEscape(claimToken)
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodDelete, target, nil)
	if err != nil {
		return err
	}
	c.authorize(req)
	return c.do2xx(req, "delete warm server "+name)
}

// CountReady reads the ready count (GET → {ready: N}).
func (c *HTTPWarmPoolClient) CountReady(ctx context.Context) (int, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, c.url(warmCountPath), nil)
	if err != nil {
		return 0, err
	}
	c.authorize(req)

	resp, err := c.httpClient().Do(req)
	if err != nil {
		return 0, err
	}
	defer resp.Body.Close()
	data, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return 0, fmt.Errorf("GET %s: status %d: %s", warmCountPath, resp.StatusCode, truncate(string(data), 200))
	}
	var out struct {
		Ready int `json:"ready"`
	}
	if err := json.Unmarshal(data, &out); err != nil {
		return 0, fmt.Errorf("decode %s response: %w", warmCountPath, err)
	}
	return out.Ready, nil
}

func (c *HTTPWarmPoolClient) do2xx(req *http.Request, what string) error {
	resp, err := c.httpClient().Do(req)
	if err != nil {
		return fmt.Errorf("%s: %w", what, err)
	}
	defer resp.Body.Close()
	data, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("%s: status %d: %s", what, resp.StatusCode, truncate(string(data), 200))
	}
	return nil
}

var _ WarmPoolClient = (*HTTPWarmPoolClient)(nil)

// warmBaseSpec is the uniform spec every warm-pool box is created from: the
// provider defaults (region/type via BARKPARK_SERVER_TYPE/LOCATION, image via the
// required BARKPARK_SERVER_IMAGE baked snapshot). The pool is uniform — the
// per-job region/server_type only apply to a one-shot custom create — so refill
// and reconcile both use this. Name is left empty; CreateWarmServer fills warm-<rand>.
func warmBaseSpec() cloud.ServerSpec {
	spec := cloud.DefaultSpec(cloud.ProviderHetzner)
	spec.Name = ""
	return spec
}

// tryWarmAssign claims a warm box and assigns it into a live instance — the
// ≤15s path. Returns (live, true) on success; (_, false) when the pool is empty,
// the claim errored, or the assign failed (in which case the box was already torn
// down + its row dropped) — the caller then falls through to one-shot SILENTLY, so
// the go-live never dead-ends and the 90s p95 holds even on a cold/lagging pool.
//
// A successful claim ALWAYS fires the async refill (never blocking the assign) so
// the pool stays warm between reconciler passes; a refill failure is logged and
// the next claim/reconcile re-tops the pool.
func tryWarmAssign(ctx context.Context, seams Seams, wp *cloud.WarmPool, spec cloud.GoLiveSpec) (cloud.LiveServer, bool) {
	ws, ok, err := seams.WarmClient.Claim(ctx)
	if err != nil {
		fmt.Fprintf(os.Stderr, "barkpark-provisioner: WARNING: warm claim failed, falling back to one-shot: %v\n", err)
		return cloud.LiveServer{}, false
	}
	if !ok {
		return cloud.LiveServer{}, false // empty pool — silent one-shot
	}

	// The claim consumed a ready box: refill the pool asynchronously (must NOT
	// block the assign the customer is waiting on).
	launchWarmRefill(seams)

	host := cloud.Server{Name: ws.Name, IP: ws.IP}
	live, aerr := wp.AssignWarm(ctx, host, spec)

	// The claimed row is consumed either way (assigned live, or box torn down on a
	// failed assign): drop it so the ready count reflects reality. Fresh bounded
	// context so it completes even if the job ctx was cancelled; best-effort (a
	// stale row is reaped server-side).
	dctx, cancel := context.WithTimeout(context.Background(), warmRefillTimeout)
	if derr := seams.WarmClient.Delete(dctx, ws.Name, ws.ClaimToken); derr != nil {
		fmt.Fprintf(os.Stderr, "barkpark-provisioner: WARNING: warm row delete %s: %v\n", ws.Name, derr)
	}
	cancel()

	if aerr != nil {
		fmt.Fprintf(os.Stderr, "barkpark-provisioner: WARNING: warm assign %s failed, falling back to one-shot: %v\n", ws.Name, aerr)
		return cloud.LiveServer{}, false
	}
	return live, true
}

// launchWarmRefill fires the async pool refill after a claim. It uses the injected
// Seams.WarmRefill when set (tests observe the async behaviour without racing on a
// real create); otherwise the default create-one-warm-box-and-register action. It
// runs in its own goroutine on a background context so it NEVER blocks the assign.
func launchWarmRefill(seams Seams) {
	refill := seams.WarmRefill
	if refill == nil {
		refill = func(ctx context.Context) { defaultWarmRefill(ctx, seams) }
	}
	go refill(context.Background())
}

// defaultWarmRefill creates one replacement warm box and registers it into the
// pool. On a create failure it logs and returns (the next claim/reconcile retries);
// on a register failure it tears the just-created box down so an untracked billed
// box is never leaked.
func defaultWarmRefill(ctx context.Context, seams Seams) {
	rctx, cancel := context.WithTimeout(ctx, warmRefillTimeout)
	defer cancel()

	host, err := cloud.CreateWarmServer(rctx, seams.Provider, warmBaseSpec())
	if err != nil {
		fmt.Fprintf(os.Stderr, "barkpark-provisioner: WARNING: warm refill create failed: %v\n", err)
		return
	}
	// dwb-17: freshen the box to origin/main BEFORE it enters the pool. FAIL-CLOSED
	// — a box that can't be brought current is torn down, never registered, so the
	// pool only ever holds boxes running today's code.
	if ferr := freshenWarmBox(rctx, seams, host); ferr != nil {
		fmt.Fprintf(os.Stderr, "barkpark-provisioner: WARNING: warm refill freshen %s failed (tearing box down — a stale box must not enter the pool): %v\n", host.Name, ferr)
		if derr := seams.Provider.Delete(rctx, host.Name); derr != nil {
			fmt.Fprintf(os.Stderr, "barkpark-provisioner: WARNING: warm refill stale-box %s delete failed: %v\n", host.Name, derr)
		}
		return
	}
	if err := seams.WarmClient.Register(rctx, WarmServer{Name: host.Name, IP: host.IP}); err != nil {
		fmt.Fprintf(os.Stderr, "barkpark-provisioner: WARNING: warm refill register %s failed (tearing box down): %v\n", host.Name, err)
		if derr := seams.Provider.Delete(rctx, host.Name); derr != nil {
			fmt.Fprintf(os.Stderr, "barkpark-provisioner: WARNING: warm refill orphan %s delete failed: %v\n", host.Name, derr)
		}
	}
}

// ReconcileFunc enforces the target warm-pool size on a schedule. Injected like
// ProvisionFunc/SweepFunc so the worker stays transport-only and tests drive it
// against the fakes.
type ReconcileFunc func(ctx context.Context) error

// ReconcileWarmPoolWith holds the warm pool at EXACTLY `size` (billing safety —
// warm boxes cost money):
//
//   - ready < size → create (size-ready) warm boxes and register each.
//   - ready > size → pop (ready-size) EXCESS ready rows via claim-for-retire (SKIP
//     LOCKED, so it can NEVER grab a box an assign already claimed) and delete the
//     Hetzner box + its row.
//
// It NEVER touches a claimed box (an in-flight assign): claim-for-retire only ever
// selects `ready` rows. A create failure (likely a sold-out type) stops the grow
// loop — the next pass retries; a per-box delete failure leaves that row `retiring`
// for the reaper / next pass and continues. Returns (created, deleted, err).
func ReconcileWarmPoolWith(ctx context.Context, seams Seams, size int) (created, deleted int, err error) {
	if seams.WarmClient == nil {
		return 0, 0, fmt.Errorf("provisioner: a WarmClient must be set to reconcile the warm pool")
	}
	if seams.Provider == nil {
		return 0, 0, fmt.Errorf("provisioner: a CloudProvider must be set to reconcile the warm pool")
	}
	if size < 0 {
		size = 0
	}

	ready, cerr := seams.WarmClient.CountReady(ctx)
	if cerr != nil {
		return 0, 0, fmt.Errorf("reconcile warm pool: count: %w", cerr)
	}

	var errs []string
	switch {
	case ready < size:
		for i := 0; i < size-ready; i++ {
			host, herr := cloud.CreateWarmServer(ctx, seams.Provider, warmBaseSpec())
			if herr != nil {
				errs = append(errs, fmt.Sprintf("create: %v", herr))
				break // likely sold out — stop; the next pass retries
			}
			// dwb-17: freshen to origin/main before the box enters the pool.
			// FAIL-CLOSED — tear a box that can't be brought current down rather than
			// register a stale box; stop the grow loop (the next pass retries).
			if ferr := freshenWarmBox(ctx, seams, host); ferr != nil {
				if derr := seams.Provider.Delete(ctx, host.Name); derr != nil {
					errs = append(errs, fmt.Sprintf("freshen %s (stale-box delete also failed: %v): %v", host.Name, derr, ferr))
				} else {
					errs = append(errs, fmt.Sprintf("freshen %s (box torn down — stale box kept out of pool): %v", host.Name, ferr))
				}
				break
			}
			if rerr := seams.WarmClient.Register(ctx, WarmServer{Name: host.Name, IP: host.IP}); rerr != nil {
				if derr := seams.Provider.Delete(ctx, host.Name); derr != nil {
					errs = append(errs, fmt.Sprintf("register %s (orphan delete also failed: %v): %v", host.Name, derr, rerr))
				} else {
					errs = append(errs, fmt.Sprintf("register %s (box torn down): %v", host.Name, rerr))
				}
				break
			}
			created++
		}
	case ready > size:
		for i := 0; i < ready-size; i++ {
			ws, ok, rerr := seams.WarmClient.ClaimForRetire(ctx)
			if rerr != nil {
				errs = append(errs, fmt.Sprintf("claim-retire: %v", rerr))
				break
			}
			if !ok {
				break // nothing ready to retire (raced away) — done
			}
			if derr := seams.Provider.Delete(ctx, ws.Name); derr != nil {
				// Box not gone — leave its row `retiring` for the reaper / next pass.
				errs = append(errs, fmt.Sprintf("delete %s: %v", ws.Name, derr))
				continue
			}
			if derr := seams.WarmClient.Delete(ctx, ws.Name, ws.ClaimToken); derr != nil {
				errs = append(errs, fmt.Sprintf("row delete %s: %v", ws.Name, derr))
			}
			deleted++
		}
	}

	if len(errs) > 0 {
		return created, deleted, fmt.Errorf("reconcile warm pool: %s", strings.Join(errs, "; "))
	}
	return created, deleted, nil
}

// DefaultReconcile returns a ReconcileFunc bound to seams + size — the value the
// Worker runs on startup and every ReconcileEvery cycles to hold the pool at size.
func DefaultReconcile(seams Seams, size int) ReconcileFunc {
	return func(ctx context.Context) error {
		_, _, err := ReconcileWarmPoolWith(ctx, seams, size)
		return err
	}
}

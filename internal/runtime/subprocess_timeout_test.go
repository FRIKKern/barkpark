package runtime

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/FRIKKern/barkpark/internal/caddyfile"
)

// hangingRunner is a CommandRunner that NEVER RETURNS for the subprocess names
// in hang — not even when the context it is handed is cancelled. That is the
// point: a wedged docker daemon does not politely notice a deadline, and a
// runner that returned ctx.Err() on cancellation would let a broken
// implementation pass by accident. Every other name succeeds immediately, so a
// test can hang exactly one step of a real deploy.
type hangingRunner struct {
	hang map[string]bool

	mu    sync.Mutex
	calls []string

	release chan struct{} // closed by cleanup so the parked goroutines exit
}

func newHangingRunner(names ...string) *hangingRunner {
	h := &hangingRunner{hang: map[string]bool{}, release: make(chan struct{})}
	for _, n := range names {
		h.hang[n] = true
	}
	return h
}

func (h *hangingRunner) Run(ctx context.Context, w io.Writer, name string, args ...string) error {
	h.mu.Lock()
	h.calls = append(h.calls, name)
	h.mu.Unlock()
	if h.hang[name] {
		<-h.release // deliberately ignores ctx
		return errors.New("released")
	}
	return nil
}

func (h *hangingRunner) cleanup() { close(h.release) }

// TestReloadCaddy_HungSubprocess_SurfacesNamedTimeout is the direct proof.
//
// RED WITHOUT: against the unmodified reloadCaddy —
//
//	func (e *Executor) reloadCaddy(ctx context.Context) error {
//	    return e.runner().Run(ctx, devNull{}, "caddy", "reload", "--config", e.CaddyfilePath)
//	}
//
// this test does not fail with a wrong error, it HANGS: the ambient
// context.Background() has no deadline, the runner never returns, and the
// whole `go test` binary dies on the 30s panic timeout set by -timeout. That
// hang IS the production defect — the executor stuck mid blue/green cutover.
//
// GREEN WITH: reloadCaddy goes through runOp, which bounds the call at
// Timeouts.CaddyReload and returns *OpTimeoutError naming "caddy reload".
func TestReloadCaddy_HungSubprocess_SurfacesNamedTimeout(t *testing.T) {
	runner := newHangingRunner("caddy")
	t.Cleanup(runner.cleanup)

	e := &Executor{
		CaddyfilePath: "/etc/caddy/Caddyfile",
		Runner:        runner,
		FS:            newMapFS(),
		Timeouts:      OpTimeouts{CaddyReload: 50 * time.Millisecond},
	}

	start := time.Now()
	err := e.reloadCaddy(context.Background())
	elapsed := time.Since(start)

	if err == nil {
		t.Fatalf("reloadCaddy returned nil against a runner that never returns")
	}
	if elapsed > 5*time.Second {
		t.Fatalf("reloadCaddy blocked %s — the budget did not bound the executor", elapsed)
	}

	var opErr *OpTimeoutError
	if !errors.As(err, &opErr) {
		t.Fatalf("error %T (%v) is not an *OpTimeoutError — a bare deadline error names no operation", err, err)
	}
	if opErr.Op != OpCaddyReload {
		t.Errorf("timed-out operation = %q, want %q", opErr.Op, OpCaddyReload)
	}
	if !strings.Contains(err.Error(), "caddy reload timed out after 50ms") {
		t.Errorf("error text %q does not name the operation and its budget", err.Error())
	}
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Errorf("error does not unwrap to context.DeadlineExceeded: %v", err)
	}
}

// TestRunOp_AmbientCancel_IsNotReportedAsAnOperationTimeout is the control for
// the discrimination runOp claims to make. A shutdown of the agent loop must
// not be recorded as "docker run timed out" in a deployment's failure_reason.
func TestRunOp_AmbientCancel_IsNotReportedAsAnOperationTimeout(t *testing.T) {
	runner := newHangingRunner("docker")
	t.Cleanup(runner.cleanup)

	e := &Executor{Runner: runner}

	ctx, cancel := context.WithCancel(context.Background())
	go func() {
		time.Sleep(20 * time.Millisecond)
		cancel()
	}()

	err := e.runOp(ctx, OpDockerRun, time.Minute, devNull{}, "docker", "run")
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("ambient cancel produced %v, want context.Canceled", err)
	}
	var opErr *OpTimeoutError
	if errors.As(err, &opErr) {
		t.Fatalf("ambient cancel was mislabelled as %q timing out", opErr.Op)
	}
}

// TestRunOnce_HungDrain_WarnsAndKeepsTheDeployLive is AC3: the drain is
// best-effort, so a drain that blows its budget records a VISIBLE warning
// naming the timeout and the deploy still transitions to live.
//
// RED WITHOUT: on unmodified drainContainer the "sh" subprocess never returns,
// RunOnce never comes back, and the test binary dies on the -timeout panic
// with the goroutine parked in drainContainer.
func TestRunOnce_HungDrain_WarnsAndKeepsTheDeployLive(t *testing.T) {
	cp := newCP(t)
	cp.pending = []claimReply{{
		deployment: Deployment{
			ID:       "d-green9999",
			SiteID:   "s-existing",
			Status:   "pushing",
			ImageTag: "site-shop-green",
			Site:     InlineSite{Slug: "shop", Domains: []string{"shop.example.com"}},
		},
		epoch: 7,
	}}

	healthSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))
	defer healthSrv.Close()
	greenPort := mustPort(t, healthSrv.URL)

	srv := httptest.NewServer(cp.handler())
	defer srv.Close()

	// Only the drain's shell hangs. docker load / run / rm and caddy reload
	// all answer, so the cutover reaches the drain step for real.
	runner := newHangingRunner("sh")
	t.Cleanup(runner.cleanup)

	var mu sync.Mutex
	var logs []string

	e := &Executor{
		ControlURL:    srv.URL,
		AgentToken:    "test-token",
		WorkerID:      "agent-1",
		CacheDir:      "/var/lib/barkpark-builder/images",
		CaddyfilePath: "/etc/caddy/Caddyfile",
		AskGateURL:    "https://cloud.barkpark.cloud/v1/tls/ask",
		HTTPClient:    srv.Client(),
		Runner:        runner,
		FS:            newMapFS(),
		Ports:         &fixedPorts{next: greenPort},
		HealthTimeout: 2 * time.Second,
		Timeouts:      OpTimeouts{Drain: 50 * time.Millisecond},
		Logger: func(format string, args ...any) {
			mu.Lock()
			defer mu.Unlock()
			logs = append(logs, fmt.Sprintf(format, args...))
		},
	}

	bluePort := greenPort + 100
	state := State{
		LiveSites: []caddyfile.Site{
			{Slug: "shop", Domains: []string{"shop.example.com"}, Port: bluePort},
		},
	}

	start := time.Now()
	had, err := e.RunOnce(context.Background(), state)
	elapsed := time.Since(start)

	if err != nil {
		t.Fatalf("RunOnce err: %v", err)
	}
	if !had {
		t.Fatalf("expected had=true")
	}
	if elapsed > 5*time.Second {
		t.Fatalf("RunOnce blocked %s on the hung drain", elapsed)
	}

	// AC3, half one: the deploy is NOT failed by the timed-out drain.
	if len(cp.transitions) != 1 {
		t.Fatalf("expected exactly 1 transition, got %d: %+v", len(cp.transitions), cp.transitions)
	}
	if got := cp.transitions[0]["status"]; got != "live" {
		t.Errorf("transition status = %v, want live despite the drain timing out", got)
	}

	// AC3, half two: the timeout is VISIBLE, and it names the operation.
	mu.Lock()
	defer mu.Unlock()
	joined := strings.Join(logs, "\n")
	if !strings.Contains(joined, "drain timed out after 50ms") {
		t.Errorf("Logger never saw a named drain timeout: logs=%v", logs)
	}
	if !strings.Contains(joined, "site-shop-blue") {
		t.Errorf("the warning does not identify which container was left behind: logs=%v", logs)
	}
}

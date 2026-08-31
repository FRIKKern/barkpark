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

// drainRunner is a CommandRunner that can fail a specific subprocess name
// (e.g. "sh", the one drainContainer shells out through) while also writing
// canned combined stdout+stderr into the io.Writer it's handed — so a test
// can assert that output actually reached wherever the caller pointed it,
// rather than assuming a devNull sink swallowed it.
type drainRunner struct {
	mu     sync.Mutex
	calls  []call
	failOn map[string]error
	output map[string]string
}

func (r *drainRunner) Run(ctx context.Context, w io.Writer, name string, args ...string) error {
	r.mu.Lock()
	r.calls = append(r.calls, call{name: name, args: append([]string(nil), args...)})
	r.mu.Unlock()
	if out, ok := r.output[name]; ok && out != "" {
		_, _ = io.WriteString(w, out)
	}
	if err, ok := r.failOn[name]; ok {
		return err
	}
	return nil
}

// TestRunOnce_DrainFailure_ReachesLoggerNotDevNull reproduces a cutover where
// the OLD (blue) container's drain fails after the new (green) container is
// already live. runtime.go:309-313 historically discarded this into devNull
// (runtime.go:814-816) while its own comment claimed it "logs via the runner
// output" — so the leaked blue container left zero trace for an operator.
//
// MUTATION PROOF: reverting drainContainer to `e.runner().Run(ctx,
// devNull{}, "sh", "-c", ...)` (dropping the bytes.Buffer capture + logf
// call) reds this test:
//
//	--- FAIL: TestRunOnce_DrainFailure_ReachesLoggerNotDevNull (0.01s)
//	    drain_visibility_test.go:98: Logger never saw the drain error: logs=[]
//
// because devNull{}'s Write discards every byte and nothing ever calls
// Logger — the failure and its output vanish exactly as the defect described.
func TestRunOnce_DrainFailure_ReachesLoggerNotDevNull(t *testing.T) {
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

	fs := newMapFS()
	runner := &drainRunner{
		failOn: map[string]error{"sh": errors.New("exit status 1: no such container")},
		output: map[string]string{"sh": "Error: No such container: site-shop-blue\n"},
	}

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
		FS:            fs,
		Ports:         &fixedPorts{next: greenPort},
		HealthTimeout: 2 * time.Second,
		Logger: func(format string, args ...any) {
			mu.Lock()
			defer mu.Unlock()
			logs = append(logs, fmt.Sprintf(format, args...))
		},
	}

	// Existing blue site on a different port so a drain is actually attempted.
	bluePort := greenPort + 100
	state := State{
		LiveSites: []caddyfile.Site{
			{Slug: "shop", Domains: []string{"shop.example.com"}, Port: bluePort},
		},
	}

	had, err := e.RunOnce(context.Background(), state)
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if !had {
		t.Fatalf("expected had=true")
	}

	// The drain stays best-effort: its failure must NOT fail the deploy —
	// the transition to live still must happen (the new container is
	// already serving).
	if len(cp.transitions) != 1 {
		t.Fatalf("expected 1 transition (live), got %d: %+v", len(cp.transitions), cp.transitions)
	}
	if cp.transitions[0]["status"] != "live" {
		t.Errorf("transition status = %v, want live despite the drain failure", cp.transitions[0]["status"])
	}

	// The drain's error AND its captured output must have reached Logger —
	// the sink being asserted on, not the (intentionally ignored) return
	// value of drainContainer at the call site.
	mu.Lock()
	defer mu.Unlock()
	joined := strings.Join(logs, "\n")
	if !strings.Contains(joined, "no such container") {
		t.Errorf("Logger never saw the drain's error: logs=%v", logs)
	}
	if !strings.Contains(joined, "No such container: site-shop-blue") {
		t.Errorf("Logger never saw the drain's captured output: logs=%v", logs)
	}
}

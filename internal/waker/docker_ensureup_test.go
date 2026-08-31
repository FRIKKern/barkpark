package waker

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

// TestDockerContainer_EnsureUp_Running_Unhealthy_Errors pins the contracted
// behavior at waker.go:48-52 — EnsureUp must "bring the backing container
// into a running, HEALTH-CHECKED state." A container docker reports as
// Running but whose HTTP port never answers (process alive, server wedged)
// must make EnsureUp return an error, not nil, so the waker never hands
// traffic to it.
//
// MUTATION PROOF: reverting the fix restores the stateRunning branch's early
// `return nil` in internal/waker/docker.go's EnsureUp switch. With that
// revert this test reds:
//
//	--- FAIL: TestDockerContainer_EnsureUp_Running_Unhealthy_Errors (0.00s)
//	    docker_ensureup_test.go:45: EnsureUp returned nil for a Running-but-unhealthy container; want a non-nil error
//
// because the early return skips d.healthCheck(ctx) entirely and the
// synthetic upstream below (which always answers 503) is never even dialed.
func TestDockerContainer_EnsureUp_Running_Unhealthy_Errors(t *testing.T) {
	r := &scriptedRunner{respond: map[string]runResponse{
		"inspect": {stdout: "true\n"},
	}}

	// Synthetic upstream that is reachable but never healthy (always 5xx) —
	// simulates a wedged container: the process is up (docker agrees) but
	// the HTTP server inside it never serves a real response.
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusServiceUnavailable)
	}))
	defer srv.Close()
	port := mustPort(t, srv.URL)

	d := &DockerContainer{
		Name:          "site-shop",
		Image:         "site-shop-img",
		InternalPort:  port,
		HealthTimeout: 500 * time.Millisecond, // keep the test fast
		Runner:        r,
	}

	err := d.EnsureUp(context.Background())
	if err == nil {
		t.Fatalf("EnsureUp returned nil for a Running-but-unhealthy container; want a non-nil error")
	}

	if len(r.callsFor("start")) != 0 {
		t.Errorf("docker start should not be called for an already-running container: %+v", r.calls)
	}
	if len(r.callsFor("run")) != 0 {
		t.Errorf("docker run should not be called for an already-running container: %+v", r.calls)
	}
}

// TestDockerContainer_EnsureUp_Running_Healthy_SingleInspect is the
// companion happy-path: stateRunning + a HEALTHY endpoint still returns nil,
// and the fix must not cost extra `docker inspect` calls — exactly one,
// same as before the fix.
func TestDockerContainer_EnsureUp_Running_Healthy_SingleInspect(t *testing.T) {
	r := &scriptedRunner{respond: map[string]runResponse{
		"inspect": {stdout: "true\n"},
	}}

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()
	port := mustPort(t, srv.URL)

	d := &DockerContainer{
		Name:          "site-shop",
		Image:         "site-shop-img",
		InternalPort:  port,
		HealthTimeout: 2 * time.Second,
		Runner:        r,
	}

	if err := d.EnsureUp(context.Background()); err != nil {
		t.Fatalf("EnsureUp: %v", err)
	}

	if got := len(r.callsFor("inspect")); got != 1 {
		t.Errorf("expected exactly 1 docker inspect call, got %d: %+v", got, r.calls)
	}
	if len(r.callsFor("start")) != 0 {
		t.Errorf("docker start should not be called: %+v", r.calls)
	}
	if len(r.callsFor("run")) != 0 {
		t.Errorf("docker run should not be called: %+v", r.calls)
	}
}

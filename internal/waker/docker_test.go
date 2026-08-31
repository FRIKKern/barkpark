package waker

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
)

// scriptedRunner is a CommandRunner whose behavior depends on the first arg
// (e.g. "inspect", "start", "run") — so a single DockerContainer test can
// drive the missing → run → healthy or stopped → start → healthy paths.
type scriptedRunner struct {
	mu        sync.Mutex
	calls     []runCall
	respond   map[string]runResponse // keyed on the docker subcommand (args[0])
	defaultOK bool
}

type runCall struct {
	name string
	args []string
}

type runResponse struct {
	stdout string
	err    error
}

func (s *scriptedRunner) Run(ctx context.Context, w io.Writer, name string, args ...string) error {
	s.mu.Lock()
	s.calls = append(s.calls, runCall{name, append([]string(nil), args...)})
	resp, hit := runResponse{}, false
	if name == "docker" && len(args) > 0 {
		resp, hit = s.respond[args[0]]
	}
	s.mu.Unlock()
	if !hit && !s.defaultOK {
		return fmt.Errorf("scripted: no response for %s %v", name, args)
	}
	if resp.stdout != "" {
		_, _ = io.WriteString(w, resp.stdout)
	}
	return resp.err
}

func (s *scriptedRunner) callsFor(sub string) []runCall {
	s.mu.Lock()
	defer s.mu.Unlock()
	var out []runCall
	for _, c := range s.calls {
		if c.name == "docker" && len(c.args) > 0 && c.args[0] == sub {
			out = append(out, c)
		}
	}
	return out
}

func TestDockerContainer_EnsureUp_AlreadyRunning_NoOp(t *testing.T) {
	r := &scriptedRunner{respond: map[string]runResponse{
		"inspect": {stdout: "true\n"},
	}}
	// EnsureUp now converges stateRunning on healthCheck too (see
	// TestDockerContainer_EnsureUp_Running_Unhealthy_Errors in
	// docker_ensureup_test.go for the defect this guards against) — stand up
	// a healthy synthetic upstream so this "no docker start/run" assertion
	// isn't entangled with health-check plumbing.
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
	if len(r.callsFor("start")) != 0 {
		t.Errorf("docker start should not be called: %+v", r.calls)
	}
	if len(r.callsFor("run")) != 0 {
		t.Errorf("docker run should not be called: %+v", r.calls)
	}
	if len(r.callsFor("inspect")) != 1 {
		t.Errorf("expected exactly 1 docker inspect, got %d: %+v", len(r.callsFor("inspect")), r.calls)
	}
}

func TestDockerContainer_EnsureUp_Stopped_CallsStart(t *testing.T) {
	r := &scriptedRunner{respond: map[string]runResponse{
		"inspect": {stdout: "false\n"},
		"start":   {},
	}}
	// Stand up a synthetic upstream for the health check on a known port.
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
	if len(r.callsFor("start")) != 1 {
		t.Errorf("docker start called %d times, want 1", len(r.callsFor("start")))
	}
	if len(r.callsFor("run")) != 0 {
		t.Errorf("docker run should not be called when container exists")
	}
}

func TestDockerContainer_EnsureUp_Missing_CallsRun(t *testing.T) {
	// Inspect fails (treated as "missing") → DockerContainer should fall
	// through to `docker run -d` with the configured ports + image.
	r := &scriptedRunner{respond: map[string]runResponse{
		"inspect": {err: errors.New("No such object: site-shop")},
		"run":     {},
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
		Memory:        "256m",
		CPUs:          "0.5",
		HealthTimeout: 2 * time.Second,
		Runner:        r,
	}
	if err := d.EnsureUp(context.Background()); err != nil {
		t.Fatalf("EnsureUp: %v", err)
	}
	runs := r.callsFor("run")
	if len(runs) != 1 {
		t.Fatalf("docker run called %d times, want 1", len(runs))
	}
	argStr := strings.Join(runs[0].args, " ")
	if !strings.Contains(argStr, "--name site-shop") {
		t.Errorf("docker run missing --name: %s", argStr)
	}
	if !strings.Contains(argStr, "site-shop-img") {
		t.Errorf("docker run missing image: %s", argStr)
	}
	if !strings.Contains(argStr, "--memory=256m") {
		t.Errorf("docker run missing memory cap: %s", argStr)
	}
}

func TestDockerContainer_Stop_CallsDockerStop(t *testing.T) {
	r := &scriptedRunner{respond: map[string]runResponse{"stop": {}}}
	d := &DockerContainer{Name: "site-shop", Runner: r}
	if err := d.Stop(context.Background()); err != nil {
		t.Fatalf("Stop: %v", err)
	}
	stops := r.callsFor("stop")
	if len(stops) != 1 {
		t.Fatalf("docker stop called %d times, want 1", len(stops))
	}
	if !contains(stops[0].args, "site-shop") {
		t.Errorf("stop should target container name: %+v", stops[0].args)
	}
}

func mustPort(t *testing.T, urlStr string) int {
	t.Helper()
	i := strings.LastIndex(urlStr, ":")
	if i < 0 {
		t.Fatalf("no port in %q", urlStr)
	}
	var p int
	for _, c := range urlStr[i+1:] {
		if c < '0' || c > '9' {
			break
		}
		p = p*10 + int(c-'0')
	}
	if p == 0 {
		t.Fatalf("no port parsed from %q", urlStr)
	}
	return p
}

func contains(haystack []string, needle string) bool {
	for _, h := range haystack {
		if h == needle {
			return true
		}
	}
	return false
}

package runtime

// Tests for live-state reconstruction from the on-box Caddyfile — the fix for
// the two production failures the empty-state MVP stub caused on the jarl box:
//
//  1. Caddyfile clobber: rewriting from empty state dropped every vhost the
//     executor did not just create (the instance's own API/Studio vhost
//     jarl.barkpark.cloud and the attach-domain vhost barkpark.jarl.no both
//     went TLS-dead until cp-ops caddy-repair, PR #8198).
//  2. Port collision: with LiveSites always empty the allocator returned the
//     same port (7001) on the second deploy while the first container still
//     bound it — `docker run` failed with exit 125 (deployment 2f92055a).

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/FRIKKern/barkpark/internal/caddyfile"
)

// boxCaddyfile is the provisioner-written shape the executor finds on a real
// box before its first deploy: global ask-gate block, the instance API/Studio
// vhost, and an attach-domain vhost — all foreign (no runtime marker), both
// vhosts proxying the box's own Barkpark on 127.0.0.1:4000.
const boxCaddyfile = `{
  on_demand_tls {
    ask https://cloud.barkpark.cloud/v1/tls/ask
  }
}

# Instance API + Studio vhost (provisioner-owned).
jarl.barkpark.cloud {
	reverse_proxy 127.0.0.1:4000
}

# Managed by barkpark-provisioner (attach-domain) — custom host barkpark.jarl.no.
# On-demand TLS is gated by the control plane's /v1/tls/ask. Do not edit by hand.
barkpark.jarl.no {
	tls {
		on_demand
	}
	reverse_proxy 127.0.0.1:4000
}
`

func TestStateFromDisk_ReconstructsManagedSitesAndForeignPorts(t *testing.T) {
	fs := newMapFS()
	fs.files["/etc/caddy/Caddyfile"] = []byte(boxCaddyfile +
		"\n# Managed by barkpark-runtime — site shop (port 7001). Do not edit by hand.\n" +
		"shop.example.com {\n  tls {\n    on_demand\n  }\n  reverse_proxy 127.0.0.1:7001\n}\n")
	e := &Executor{CaddyfilePath: "/etc/caddy/Caddyfile", FS: fs}

	state, err := e.StateFromDisk(context.Background())
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if len(state.LiveSites) != 1 {
		t.Fatalf("LiveSites = %+v, want exactly the managed shop block", state.LiveSites)
	}
	s := state.LiveSites[0]
	if s.Slug != "shop" || s.Port != 7001 || len(s.Domains) != 1 || s.Domains[0] != "shop.example.com" {
		t.Errorf("recovered site wrong: %+v", s)
	}
	// The instance vhost + attach-domain vhost both proxy 127.0.0.1:4000 —
	// that port is reserved, never a container's.
	if !state.ReservedPorts[4000] {
		t.Errorf("foreign port 4000 not reserved: %v", state.ReservedPorts)
	}
	if state.ReservedPorts[7001] {
		t.Errorf("managed port 7001 must ride LiveSites, not ReservedPorts: %v", state.ReservedPorts)
	}
}

func TestStateFromDisk_MissingFileIsEmptyState(t *testing.T) {
	e := &Executor{CaddyfilePath: "/etc/caddy/Caddyfile", FS: newMapFS()}
	state, err := e.StateFromDisk(context.Background())
	if err != nil {
		t.Fatalf("missing file must not error: %v", err)
	}
	if len(state.LiveSites) != 0 || len(state.ReservedPorts) != 0 {
		t.Errorf("expected empty state, got %+v", state)
	}
}

// errReadFS fails every read with a non-NotExist error (e.g. permissions).
type errReadFS struct{}

func (errReadFS) WriteFile(path string, data []byte, perm uint32) error { return nil }
func (errReadFS) ReadFile(path string) ([]byte, error)                  { return nil, errors.New("permission denied") }

func TestStateFromDisk_ReadErrorSurfaces(t *testing.T) {
	// An unreadable file must surface, never degrade to guessed-empty state —
	// empty state IS the bug this fix removes.
	e := &Executor{CaddyfilePath: "/etc/caddy/Caddyfile", FS: errReadFS{}}
	if _, err := e.StateFromDisk(context.Background()); err == nil {
		t.Fatal("expected a read error, got nil")
	}
}

func TestWriteCaddyfile_UnreadableExistingFileFailsDeploy(t *testing.T) {
	// Same fail-closed posture on the write side: if the existing file can't
	// be read, rewriting from scratch would clobber every vhost we couldn't
	// see — the deploy must fail instead.
	e := &Executor{CaddyfilePath: "/etc/caddy/Caddyfile", FS: errReadFS{}}
	err := e.writeCaddyfile([]caddyfile.Site{{Slug: "shop", Domains: []string{"shop.com"}, Port: 7001}})
	if err == nil || !strings.Contains(err.Error(), "read existing") {
		t.Fatalf("expected read-existing failure, got %v", err)
	}
}

func TestDefaultPortAllocator_NeverReturnsReservedPort(t *testing.T) {
	// Table: whatever mix of live and foreign-reserved ports is in use, the
	// allocator's pick is never one of them.
	cases := []struct {
		name  string
		inUse map[int]bool
		want  int
	}{
		{"foreign port inside the range", map[int]bool{7001: true}, 7002},
		{"live + foreign mix", map[int]bool{7001: true, 7002: true, 7004: true}, 7003},
		{"foreign port below the range is a no-op", map[int]bool{4000: true}, 7001},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got, err := DefaultPortAllocator{}.Allocate(c.inUse)
			if err != nil {
				t.Fatalf("err: %v", err)
			}
			if got != c.want {
				t.Errorf("Allocate(%v) = %d, want %d", c.inUse, got, c.want)
			}
			if c.inUse[got] {
				t.Errorf("allocator returned an in-use port %d", got)
			}
		})
	}
}

// recordingPorts wraps an allocator and records every inUse set it was shown.
type recordingPorts struct {
	inner PortAllocator
	seen  []map[int]bool
}

func (r *recordingPorts) Allocate(inUse map[int]bool) (int, error) {
	cp := map[int]bool{}
	for k, v := range inUse {
		cp[k] = v
	}
	r.seen = append(r.seen, cp)
	return r.inner.Allocate(inUse)
}

func TestRunOnce_AllocatorSeesForeignAndLivePorts(t *testing.T) {
	// The executor must hand the allocator EVERY port already spoken for:
	// ports of live managed sites AND ports reserved by foreign Caddyfile
	// blocks (the instance API vhost's 4000 — never allocate that).
	cp := newCP(t)
	cp.pending = []claimReply{{
		deployment: Deployment{
			ID:       "d-ports1234abcd",
			SiteID:   "s-ports",
			Status:   "pushing",
			ImageTag: "site-shop-d-ports123",
			Site:     InlineSite{Slug: "shop", Domains: []string{"shop.example.com"}},
		},
		epoch: 1,
	}}

	containerSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))
	defer containerSrv.Close()

	srv := httptest.NewServer(cp.handler())
	defer srv.Close()

	ports := &recordingPorts{inner: &fixedPorts{next: mustPort(t, containerSrv.URL)}}
	e := &Executor{
		ControlURL:    srv.URL,
		AgentToken:    "test-token",
		WorkerID:      "agent-1",
		CacheDir:      "/var/lib/barkpark-builder/images",
		CaddyfilePath: "/etc/caddy/Caddyfile",
		HTTPClient:    srv.Client(),
		Runner:        &fakeRunner{},
		FS:            newMapFS(),
		Ports:         ports,
		HealthTimeout: 2 * time.Second,
	}

	state := State{
		LiveSites:     []caddyfile.Site{{Slug: "other", Domains: []string{"other.example.com"}, Port: 4100}},
		ReservedPorts: map[int]bool{4000: true},
	}
	if _, err := e.RunOnce(context.Background(), state); err != nil {
		t.Fatalf("err: %v", err)
	}
	if len(ports.seen) != 1 {
		t.Fatalf("allocator called %d times, want 1", len(ports.seen))
	}
	inUse := ports.seen[0]
	if !inUse[4000] {
		t.Errorf("foreign-reserved port 4000 not marked in use: %v", inUse)
	}
	if !inUse[4100] {
		t.Errorf("live site port 4100 not marked in use: %v", inUse)
	}
}

func TestRunOnce_RemovesStaleSameNameContainerBeforeRun(t *testing.T) {
	// Belt and braces for the exit-125 path: a Created-but-never-started
	// container from a failed cycle squats the exact site-<slug>-<short> name
	// (production had site-jarl-website-2f92055a in Created blocking the
	// retry). The executor must `docker rm -f <name>` BEFORE `docker run`.
	runner := envDeploy(t, func(cp *scriptedCP) {})

	rmIdx, runIdx := -1, -1
	for i, c := range runner.calls {
		if c.name != "docker" || len(c.args) == 0 {
			continue
		}
		switch c.args[0] {
		case "rm":
			if rmIdx < 0 && len(c.args) >= 3 && c.args[1] == "-f" && strings.HasPrefix(c.args[2], "site-shop-") {
				rmIdx = i
			}
		case "run":
			runIdx = i
		}
	}
	if rmIdx < 0 {
		t.Fatalf("no docker rm -f site-shop-... before run; calls: %+v", runner.calls)
	}
	if runIdx < 0 {
		t.Fatalf("no docker run; calls: %+v", runner.calls)
	}
	if rmIdx > runIdx {
		t.Errorf("stale-name removal (call %d) must precede docker run (call %d)", rmIdx, runIdx)
	}
	// Same name on both: the rm targets exactly the container about to run.
	name := runner.calls[rmIdx].args[2]
	if !strings.Contains(strings.Join(runner.calls[runIdx].args, " "), "--name "+name) {
		t.Errorf("rm'd name %q differs from run's --name: %v", name, runner.calls[runIdx].args)
	}
}

// candidatePorts hands out the first candidate not in use — lets the test pin
// which real listener ports the allocator may pick while still exercising the
// executor's inUse bookkeeping.
type candidatePorts struct{ candidates []int }

func (c *candidatePorts) Allocate(inUse map[int]bool) (int, error) {
	for _, p := range c.candidates {
		if !inUse[p] {
			return p, nil
		}
	}
	return 0, errors.New("no free candidate port")
}

// TestRunOnce_SecondDeploy_StateFromDisk_PreservesForeignAndAvoidsPortCollision
// replays the jarl-box incident end-to-end through the production wiring: a
// provisioner-written Caddyfile (instance vhost + attach-domain vhost, both on
// 127.0.0.1:4000), then TWO successive deploys of the same site with state
// reconstructed from disk between cycles via StateFromDisk — exactly what
// cmd/barkpark-runtime now does. The old empty-state stub failed this twice
// over: the rewrite deleted both foreign vhosts, and the second deploy
// re-allocated the first deploy's port while its container still bound it.
func TestRunOnce_SecondDeploy_StateFromDisk_PreservesForeignAndAvoidsPortCollision(t *testing.T) {
	cp := newCP(t)
	cp.pending = []claimReply{
		{
			deployment: Deployment{
				ID:       "d-first111aaaa",
				SiteID:   "s-jarlsite",
				Status:   "pushing",
				ImageTag: "site-jarl-website-d-first111",
				Site:     InlineSite{Slug: "jarl-website", Domains: []string{"jarl-website.barkpark.cloud"}},
			},
			epoch: 1,
		},
		{
			deployment: Deployment{
				ID:       "d-second22bbbb",
				SiteID:   "s-jarlsite",
				Status:   "pushing",
				ImageTag: "site-jarl-website-d-second22",
				Site:     InlineSite{Slug: "jarl-website", Domains: []string{"jarl-website.barkpark.cloud"}},
			},
			epoch: 2,
		},
	}

	// Two real listeners standing in for the two containers — the health check
	// only passes on a port something actually answers.
	blueSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))
	defer blueSrv.Close()
	greenSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))
	defer greenSrv.Close()
	bluePort := mustPort(t, blueSrv.URL)
	greenPort := mustPort(t, greenSrv.URL)

	srv := httptest.NewServer(cp.handler())
	defer srv.Close()

	fs := newMapFS()
	fs.files["/etc/caddy/Caddyfile"] = []byte(boxCaddyfile)
	runner := &fakeRunner{}

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
		// 4000 first: were foreign ports not reserved, the allocator would hand
		// the instance API's port to the container and the test would fail on
		// the health check (nothing of ours listens there).
		Ports:         &candidatePorts{candidates: []int{4000, bluePort, greenPort}},
		HealthTimeout: 2 * time.Second,
	}
	ctx := context.Background()

	// --- Deploy 1: fresh state from the provisioner-written file. -----------
	state, err := e.StateFromDisk(ctx)
	if err != nil {
		t.Fatalf("state 1: %v", err)
	}
	if had, err := e.RunOnce(ctx, state); err != nil || !had {
		t.Fatalf("deploy 1: had=%v err=%v", had, err)
	}

	caddy1 := string(fs.files["/etc/caddy/Caddyfile"])
	if !strings.HasPrefix(caddy1, boxCaddyfile) {
		t.Fatalf("deploy 1 did not preserve the foreign vhosts byte-identical:\n%s", caddy1)
	}
	if !strings.Contains(caddy1, "reverse_proxy 127.0.0.1:"+itoa(bluePort)) {
		t.Fatalf("deploy 1 should serve on the blue port %d:\n%s", bluePort, caddy1)
	}

	// --- Deploy 2: state reconstructed from the file deploy 1 wrote. --------
	state, err = e.StateFromDisk(ctx)
	if err != nil {
		t.Fatalf("state 2: %v", err)
	}
	if got := len(state.LiveSites); got != 1 || state.LiveSites[0].Port != bluePort {
		t.Fatalf("state 2 must see the live blue site on %d, got %+v", bluePort, state.LiveSites)
	}
	if had, err := e.RunOnce(ctx, state); err != nil || !had {
		t.Fatalf("deploy 2: had=%v err=%v", had, err)
	}

	// The second deploy allocated a DIFFERENT port than the still-bound blue.
	caddy2 := string(fs.files["/etc/caddy/Caddyfile"])
	if !strings.Contains(caddy2, "reverse_proxy 127.0.0.1:"+itoa(greenPort)) {
		t.Errorf("deploy 2 should swap to the green port %d:\n%s", greenPort, caddy2)
	}
	if strings.Contains(caddy2, "127.0.0.1:"+itoa(bluePort)) {
		t.Errorf("deploy 2 left the blue port %d in the Caddyfile:\n%s", bluePort, caddy2)
	}
	// Foreign vhosts still byte-identical after both rewrites.
	if !strings.HasPrefix(caddy2, boxCaddyfile) {
		t.Errorf("deploy 2 did not preserve the foreign vhosts byte-identical:\n%s", caddy2)
	}
	// Exactly one managed block for the slug — replaced in place, not duplicated.
	if n := strings.Count(caddy2, "jarl-website.barkpark.cloud {"); n != 1 {
		t.Errorf("expected exactly one managed host key, got %d:\n%s", n, caddy2)
	}

	// The blue container was drained once the green went live.
	drained := false
	for _, c := range runner.calls {
		if c.name == "sh" && strings.Contains(strings.Join(c.args, " "), "publish="+itoa(bluePort)) {
			drained = true
		}
	}
	if !drained {
		t.Errorf("expected the blue container (port %d) to be drained; calls: %+v", bluePort, runner.calls)
	}

	// Both deployments reported live.
	if len(cp.transitions) != 2 {
		t.Fatalf("expected 2 transitions, got %+v", cp.transitions)
	}
	for i, tr := range cp.transitions {
		if tr["status"] != "live" {
			t.Errorf("transition %d = %v, want live (reason: %v)", i, tr["status"], tr["failure_reason"])
		}
	}
	if p1, p2 := cp.transitions[0]["site_port"].(float64), cp.transitions[1]["site_port"].(float64); p1 == p2 {
		t.Errorf("both deploys reported the same site_port %v — the port-collision bug", p1)
	}
}

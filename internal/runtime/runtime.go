// Package runtime is the on-box deployment executor for Barkpark Cloud (P3 /
// Move A finish). It is the runtime half of the cloud-website-hosting story:
// the off-box Builder (P2) ships an image tarball to a shared filesystem cache
// and sets the Deployment to `pushing`; this Executor claims the deployment,
// loads the image into Docker, blue/green runs a new container on a fresh
// loopback port, health-checks it, renders the per-box Caddyfile to point at
// the new port, reloads Caddy, drains the previous container, and transitions
// the Deployment to `live` while atomically pointing the Site at the new
// deployment + port.
//
// Everything the Executor talks to is injected — HTTPClient (tests point it
// at httptest.Server), Runner (subprocess, tests use a fake), FS (file ops,
// tests use an in-process map), and PortAllocator (deterministic in tests).
// One full deploy cycle runs hermetic in the unit test suite; the live e2e
// proof runs the same code path against real Docker + Caddy.
package runtime

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os/exec"
	"strings"
	"time"

	"github.com/FRIKKern/barkpark/internal/caddyfile"
)

// DefaultInterval is the claim-poll cadence when Executor.Interval is zero.
const DefaultInterval = 5 * time.Second

// DefaultHealthTimeout is how long the executor will wait for /` to answer
// after `docker run` before declaring the new container unhealthy.
const DefaultHealthTimeout = 30 * time.Second

const (
	pendingPath        = "/v1/agent/pending"
	claimPath          = "/v1/agent/deployments/claim"
	transitionPathFmt  = "/v1/agent/deployments/%s/transition"
	defaultPortMin     = 7001
	defaultPortMax     = 7999
	containerInnerPort = 3000
)

// Executor runs the on-box deployment loop. AgentToken is the bearer minted
// per-Barkpark (Registry.mint_agent_token); it carries the box identity that
// the control plane uses to scope /v1/agent/pending and /claim. CacheDir is
// the shared filesystem location where the Builder's docker-saved image tar
// is reachable (e.g. an NFS mount, or just a local dir when the builder runs
// on the same host for a single-box install). CaddyfilePath is the file the
// executor rewrites + reloads (default /etc/caddy/Caddyfile).
type Executor struct {
	ControlURL    string
	AgentToken    string
	WorkerID      string
	CacheDir      string
	CaddyfilePath string

	AskGateURL     string // global on_demand_tls ask URL — pass-through to caddyfile
	StudioUpstream string // host:port for the studio fallback block

	Interval      time.Duration
	HealthTimeout time.Duration
	HTTPClient    *http.Client
	Runner        CommandRunner
	FS            FS
	Ports         PortAllocator
}

// Deployment mirrors the fields the executor reads from the control plane. The
// executor only consumes a small slice of the full Deployment row. Site is
// inlined by the agent claim/pending response so the executor has slug +
// domains for first-time deploys without a second round trip.
type Deployment struct {
	ID       string     `json:"id"`
	SiteID   string     `json:"site_id"`
	Status   string     `json:"status"`
	ImageTag string     `json:"image_tag"`
	Site     InlineSite `json:"site"`
}

// InlineSite is the slug + domains slice the control plane bundles with each
// agent claim — exactly what the executor needs to render its Caddyfile.
// ScaleMode is "always_on" (default) or "zero" — when "zero" the executor
// spawns a per-site barkpark-waker (P7 stream C) on the allocated port
// instead of running the container directly; the waker handles cold-start +
// idle-reap. Caddy sees the same loopback port either way, so the on-box
// reverse-proxy block is unchanged.
type InlineSite struct {
	Slug      string   `json:"slug"`
	Domains   []string `json:"domains"`
	ScaleMode string   `json:"scale_mode,omitempty"`
}

// CommandRunner runs a subprocess, streaming combined stdout+stderr to w.
type CommandRunner interface {
	Run(ctx context.Context, w io.Writer, name string, args ...string) error
}

// ExecRunner is the default real-shell-out CommandRunner.
type ExecRunner struct{}

// Run executes name+args, streaming output to w.
func (ExecRunner) Run(ctx context.Context, w io.Writer, name string, args ...string) error {
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Stdout = w
	cmd.Stderr = w
	return cmd.Run()
}

// FS is the small filesystem surface the executor needs. Tests inject a map
// implementation; production uses OSFS.
type FS interface {
	WriteFile(path string, data []byte, perm uint32) error
	ReadFile(path string) ([]byte, error)
}

// PortAllocator picks the next free loopback port for a new container, given
// the set of ports currently in use by live blue containers (so a green swap
// never lands on the blue's port). Tests inject a deterministic stub.
type PortAllocator interface {
	Allocate(inUse map[int]bool) (int, error)
}

// DefaultPortAllocator picks the lowest free port in [defaultPortMin,
// defaultPortMax] not present in inUse.
type DefaultPortAllocator struct{}

// Allocate returns the lowest free port in the range.
func (DefaultPortAllocator) Allocate(inUse map[int]bool) (int, error) {
	for p := defaultPortMin; p <= defaultPortMax; p++ {
		if !inUse[p] {
			return p, nil
		}
	}
	return 0, fmt.Errorf("no free ports in [%d, %d]", defaultPortMin, defaultPortMax)
}

// State carries the across-cycle facts the executor needs: which ports are
// already serving live sites (so the next blue/green green never collides),
// and the slug+port+domains of each live site (so the rendered Caddyfile
// reflects all sites, not just the one being deployed). Tests build State by
// hand; the production path fetches it from /v1/agent/sites (TBD) or just
// from the disk Caddyfile parse (P3 followup).
//
// For the MVP, the executor accepts State explicitly — the loop's caller
// (cmd/barkpark-runtime) constructs it from disk + control plane.
type State struct {
	LiveSites []caddyfile.Site
}

// RunOnce runs a single pending-claim → execute → transition cycle. Returns:
//   - (true, nil)  — a deployment was claimed and walked to live (or failed
//     transition with reason). Caller should re-poll immediately.
//   - (false, nil) — nothing to do. Caller should sleep.
//   - (false, err) — transport / protocol error reaching the control plane.
func (e *Executor) RunOnce(ctx context.Context, state State) (bool, error) {
	d, claimed, err := e.claim(ctx)
	if err != nil {
		return false, fmt.Errorf("claim: %w", err)
	}
	if !claimed {
		return false, nil
	}

	site, slug, domains, port, livePort, err := e.executeDeploy(ctx, d, state)
	if err != nil {
		_ = e.transition(ctx, d.ID, map[string]any{
			"worker_id":      e.WorkerID,
			"observed_epoch": d.Epoch,
			"status":         "failed",
			"failure_reason": err.Error(),
		})
		return true, nil
	}

	// We have a healthy new container on `port`. Render Caddyfile with the
	// updated site list (replace this site's existing entry), reload Caddy,
	// then drain the old (blue) container if any.
	updated := mergeSite(state.LiveSites, caddyfile.Site{
		Slug:    slug,
		Domains: domains,
		Port:    port,
	})

	if err := e.writeCaddyfile(updated); err != nil {
		// The green container is up but unreachable (no Caddyfile entry). Tear
		// it down so a flapping Caddy doesn't leak 512m orphans across reboots.
		_ = e.runner().Run(ctx, devNull{}, "docker", "rm", "-f", fmt.Sprintf("site-%s-%s", slug, short(d.ID)))
		_ = e.transition(ctx, d.ID, map[string]any{
			"worker_id":      e.WorkerID,
			"observed_epoch": d.Epoch,
			"status":         "failed",
			"failure_reason": fmt.Errorf("write caddyfile: %w", err).Error(),
		})
		return true, nil
	}

	if err := e.reloadCaddy(ctx); err != nil {
		// Same as above — the new container is pinned to a loopback port that
		// Caddy never picked up. Reap it before failing the transition.
		_ = e.runner().Run(ctx, devNull{}, "docker", "rm", "-f", fmt.Sprintf("site-%s-%s", slug, short(d.ID)))
		_ = e.transition(ctx, d.ID, map[string]any{
			"worker_id":      e.WorkerID,
			"observed_epoch": d.Epoch,
			"status":         "failed",
			"failure_reason": fmt.Errorf("caddy reload: %w", err).Error(),
		})
		return true, nil
	}

	if livePort > 0 && livePort != port {
		// Best-effort drain — failure here doesn't fail the deploy (the new
		// container is already serving). Just log via the runner output.
		_ = e.drainContainer(ctx, fmt.Sprintf("site-%s-blue", slug), livePort)
	}

	// Atomic transition to live + Site pointer update.
	now := time.Now().UTC().Format(time.RFC3339)
	if err := e.transition(ctx, d.ID, map[string]any{
		"worker_id":      e.WorkerID,
		"observed_epoch": d.Epoch,
		"status":         "live",
		"became_live_at": now,
		"make_current":   true,
		"site_port":      port,
	}); err != nil {
		return true, fmt.Errorf("transition live: %w", err)
	}

	_ = site // future: emit local audit log keyed on site
	return true, nil
}

// claim POSTs /v1/agent/deployments/claim. Returns (dep+epoch, true, nil) on
// 200, (nil, false, nil) on 404 no_pending, (nil, false, err) on any other.
func (e *Executor) claim(ctx context.Context) (*claimed, bool, error) {
	body, _ := json.Marshal(map[string]string{"worker_id": e.WorkerID})

	req, err := http.NewRequestWithContext(
		ctx,
		http.MethodPost,
		strings.TrimRight(e.ControlURL, "/")+claimPath,
		bytes.NewReader(body),
	)
	if err != nil {
		return nil, false, err
	}
	e.attachAuth(req)
	req.Header.Set("Content-Type", "application/json")

	resp, err := e.http().Do(req)
	if err != nil {
		return nil, false, err
	}
	defer resp.Body.Close()

	switch resp.StatusCode {
	case http.StatusOK:
		var out struct {
			Deployment    Deployment `json:"deployment"`
			ObservedEpoch int        `json:"observed_epoch"`
		}
		if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
			return nil, false, fmt.Errorf("decode claim: %w", err)
		}
		return &claimed{Deployment: out.Deployment, Epoch: out.ObservedEpoch}, true, nil

	case http.StatusNotFound:
		return nil, false, nil

	default:
		return nil, false, statusError(resp)
	}
}

func (e *Executor) transition(ctx context.Context, id string, body map[string]any) error {
	buf, _ := json.Marshal(body)
	url := strings.TrimRight(e.ControlURL, "/") + fmt.Sprintf(transitionPathFmt, id)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(buf))
	if err != nil {
		return err
	}
	e.attachAuth(req)
	req.Header.Set("Content-Type", "application/json")
	resp, err := e.http().Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusOK {
		_, _ = io.Copy(io.Discard, resp.Body)
		return nil
	}
	return statusError(resp)
}

// executeDeploy walks a claimed deployment from pushing → running container:
// docker load → docker run on a fresh port → health-check. Returns:
//
//	(siteJSON, slug, domains, newPort, oldPortIfAny, err)
//
// On error, no Caddyfile work has been done — caller transitions to `failed`.
func (e *Executor) executeDeploy(
	ctx context.Context,
	d *claimed,
	state State,
) (string, string, []string, int, int, error) {
	slug, domains, livePort := e.resolveSite(d, state)
	site := d.SiteID

	// 1. Load the image from the builder's cache.
	imageTar := fmt.Sprintf("%s/%s.tar", strings.TrimRight(e.CacheDir, "/"), d.ImageTag)
	if err := e.runner().Run(ctx, devNull{},
		"sh", "-c", fmt.Sprintf("docker load -i %q", imageTar)); err != nil {
		return "", "", nil, 0, 0, fmt.Errorf("docker load %s: %w", imageTar, err)
	}

	// 2. Pick the new (green) port — avoiding any live ports.
	inUse := map[int]bool{}
	for _, s := range state.LiveSites {
		if s.Port > 0 {
			inUse[s.Port] = true
		}
	}
	if livePort > 0 {
		inUse[livePort] = true
	}
	port, err := e.portAllocator().Allocate(inUse)
	if err != nil {
		return "", "", nil, 0, 0, fmt.Errorf("port allocate: %w", err)
	}

	// 3. Run the new container.
	containerName := fmt.Sprintf("site-%s-%s", slug, short(d.ID))
	args := []string{
		"run", "-d",
		"--name", containerName,
		"--restart", "unless-stopped",
		"--memory=512m", "--cpus=1",
		"-e", fmt.Sprintf("HOSTNAME=0.0.0.0"),
		"-e", fmt.Sprintf("PORT=%d", containerInnerPort),
		"-p", fmt.Sprintf("127.0.0.1:%d:%d", port, containerInnerPort),
		d.ImageTag,
	}
	if err := e.runner().Run(ctx, devNull{}, "docker", args...); err != nil {
		return "", "", nil, 0, 0, fmt.Errorf("docker run: %w", err)
	}

	// 4. Health-check the container until /` answers (any non-5xx).
	if err := e.healthCheck(ctx, port); err != nil {
		// Tear down the failed container before bailing.
		_ = e.runner().Run(ctx, devNull{}, "docker", "rm", "-f", containerName)
		return "", "", nil, 0, 0, fmt.Errorf("health-check: %w", err)
	}

	return site, slug, domains, port, livePort, nil
}

// resolveSite returns (slug, domains, livePort) for the deployment. The
// agent claim/pending response inlines the site shape (slug + domains), so the
// MVP doesn't need a second round trip. livePort comes from state.LiveSites
// (the cmd wrapper supplies it on subsequent boots by parsing the existing
// Caddyfile or by querying the control plane).
//
// livePort = 0 means "first deploy for this site, no blue yet" — the executor
// allocates the green port without trying to avoid a blue.
func (e *Executor) resolveSite(d *claimed, state State) (string, []string, int) {
	slug := d.Site.Slug
	domains := d.Site.Domains
	if slug == "" {
		slug = "site-" + short(d.SiteID)
	}

	livePort := 0
	for _, s := range state.LiveSites {
		if s.Slug == slug {
			livePort = s.Port
			break
		}
	}
	return slug, domains, livePort
}

// healthCheck polls http://127.0.0.1:<port>/ until a < 500 response or the
// timeout elapses. Any non-5xx is "healthy" — the home route might 404 for an
// SSG with no `/` page, but a 404 means the server is up.
func (e *Executor) healthCheck(ctx context.Context, port int) error {
	deadline := time.Now().Add(e.healthTimeout())
	url := fmt.Sprintf("http://127.0.0.1:%d/", port)
	client := &http.Client{Timeout: 3 * time.Second}

	for {
		if time.Now().After(deadline) {
			return fmt.Errorf("did not become healthy in %s", e.healthTimeout())
		}
		req, _ := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
		resp, err := client.Do(req)
		if err == nil {
			_ = resp.Body.Close()
			if resp.StatusCode < 500 {
				return nil
			}
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(500 * time.Millisecond):
		}
	}
}

func (e *Executor) writeCaddyfile(sites []caddyfile.Site) error {
	text := caddyfile.Render(caddyfile.Box{
		AskGateURL:     e.AskGateURL,
		StudioUpstream: e.StudioUpstream,
		Sites:          sites,
	})
	return e.fs().WriteFile(e.CaddyfilePath, []byte(text), 0o644)
}

func (e *Executor) reloadCaddy(ctx context.Context) error {
	return e.runner().Run(ctx, devNull{}, "caddy", "reload", "--config", e.CaddyfilePath)
}

func (e *Executor) drainContainer(ctx context.Context, name string, port int) error {
	// Best-effort. A graceful 5s SIGTERM, then kill.
	return e.runner().Run(ctx, devNull{}, "sh", "-c",
		fmt.Sprintf("docker ps -q --filter publish=%d | xargs -r docker stop -t 5", port))
}

// Run loops RunOnce on Interval. State is rebuilt before each iteration via
// the caller-supplied build function — the caller owns how state is gathered
// (read disk Caddyfile, ask control plane, etc.).
func (e *Executor) Run(ctx context.Context, buildState func(context.Context) (State, error)) error {
	interval := e.Interval
	if interval <= 0 {
		interval = DefaultInterval
	}
	for {
		if err := ctx.Err(); err != nil {
			return err
		}
		state, err := buildState(ctx)
		if err != nil {
			select {
			case <-ctx.Done():
				return ctx.Err()
			case <-time.After(interval):
				continue
			}
		}
		had, err := e.RunOnce(ctx, state)
		if err != nil {
			select {
			case <-ctx.Done():
				return ctx.Err()
			case <-time.After(interval):
				continue
			}
		}
		if had {
			continue
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(interval):
		}
	}
}

func (e *Executor) http() *http.Client {
	if e.HTTPClient != nil {
		return e.HTTPClient
	}
	return http.DefaultClient
}

func (e *Executor) runner() CommandRunner {
	if e.Runner != nil {
		return e.Runner
	}
	return ExecRunner{}
}

func (e *Executor) fs() FS {
	if e.FS != nil {
		return e.FS
	}
	return OSFS{}
}

func (e *Executor) portAllocator() PortAllocator {
	if e.Ports != nil {
		return e.Ports
	}
	return DefaultPortAllocator{}
}

func (e *Executor) healthTimeout() time.Duration {
	if e.HealthTimeout > 0 {
		return e.HealthTimeout
	}
	return DefaultHealthTimeout
}

func (e *Executor) attachAuth(req *http.Request) {
	if e.AgentToken != "" {
		req.Header.Set("Authorization", "Bearer "+e.AgentToken)
	}
}

type claimed struct {
	Deployment
	Epoch int
}

func statusError(resp *http.Response) error {
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 64*1024))
	return fmt.Errorf("%s %s: %d %s — %s",
		resp.Request.Method, resp.Request.URL.Path,
		resp.StatusCode, http.StatusText(resp.StatusCode),
		strings.TrimSpace(string(body)))
}

// mergeSite replaces or appends s by slug in sites — pure function, returns a
// new slice (input untouched, safe to call with shared state).
func mergeSite(sites []caddyfile.Site, s caddyfile.Site) []caddyfile.Site {
	out := make([]caddyfile.Site, 0, len(sites)+1)
	replaced := false
	for _, existing := range sites {
		if existing.Slug == s.Slug {
			out = append(out, s)
			replaced = true
		} else {
			out = append(out, existing)
		}
	}
	if !replaced {
		out = append(out, s)
	}
	return out
}

func short(id string) string {
	if len(id) >= 8 {
		return id[:8]
	}
	return id
}

type devNull struct{}

func (devNull) Write(p []byte) (int, error) { return len(p), nil }

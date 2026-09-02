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
	"errors"
	"fmt"
	"io"
	"io/fs"
	"net/http"
	"os/exec"
	"regexp"
	"sort"
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
	siteEnvPathFmt     = "/v1/agent/sites/%s/env"
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

	// RetainImages bounds how many container generations — and therefore how
	// many loaded Docker images — this box keeps PER SITE after a PROVEN
	// cutover. Zero (unset) takes DefaultRetainImages; RetainImagesUnlimited
	// (-1) restores the historical never-delete behaviour that filled the jarl
	// box to 100%. See image_retention.go.
	RetainImages int

	// BuildCacheKeep is the storage floor the co-located build plane's
	// BuildKit cache is swept down to after a proven cutover (e.g. "5GB").
	// Zero (unset) takes DefaultBuildCacheKeep; "off" disables that arm.
	BuildCacheKeep string

	// Logger is called for non-fatal warnings the executor wants visible
	// without failing the deploy — e.g. a best-effort drain that didn't
	// succeed. nil -> silent.
	Logger func(format string, args ...any)
}

// Deployment mirrors the fields the executor reads from the control plane. The
// executor only consumes a small slice of the full Deployment row. Site is
// inlined by the agent claim/pending response so the executor has slug +
// domains for first-time deploys without a second round trip.
//
// gh-6: Environment is "production" (default) or "preview". A preview deployment
// answers on its OWN host (Site.PreviewHost) under a distinct Caddy slug key
// (Site.PreviewSlug) and is activated WITHOUT the production-slot pointer update
// (make_current) — so a branch preview never repoints the live site.
type Deployment struct {
	ID          string     `json:"id"`
	SiteID      string     `json:"site_id"`
	Status      string     `json:"status"`
	ImageTag    string     `json:"image_tag"`
	Environment string     `json:"environment"`
	Branch      string     `json:"branch"`
	Site        InlineSite `json:"site"`
}

// isPreview reports whether this deployment targets the preview environment.
func (d Deployment) isPreview() bool { return d.Environment == "preview" }

// InlineSite is the slug + domains slice the control plane bundles with each
// agent claim — exactly what the executor needs to render its Caddyfile.
// ScaleMode carries the control plane's "always_on" (default) or "zero"
// instruction. NOTHING ON THIS SIDE ACTS ON IT: the executor always runs the
// container directly, so a site created with scale_mode="zero" is served
// always-on. The field is decoded (not dropped) only so the over-claim stays
// traceable from the box back to the CP that accepts the value — see the
// site-spawner charter D84, which records `scale_mode: "zero"` as ACCEPTED and
// VALIDATED by the control plane with no implementation behind it.
//
// The P7 stream-C Docker waker that once backed this field (cmd/barkpark-waker,
// internal/waker) was deleted as dead code: it had no systemd unit, no build
// target and no caller, and this comment was the only thing that described it
// as wired. Node scale-to-zero is a DEFERRED charter item, and it would be
// built on the node-slot path, not on this Docker executor — so the deleted
// Docker waker is not the implementation a future scale_mode="zero" wants.
//
// gh-6: PreviewSlug + PreviewHost are set (non-empty) only for a preview
// deployment — the distinct Caddy slug key + the single host it answers on.
type InlineSite struct {
	Slug        string   `json:"slug"`
	Domains     []string `json:"domains"`
	ScaleMode   string   `json:"scale_mode,omitempty"`
	PreviewSlug string   `json:"preview_slug,omitempty"`
	PreviewHost string   `json:"preview_host,omitempty"`

	// ServingMode is the control plane's per-site instruction for how the box
	// terminates TLS: ServingModeDirect (default) issues a cert on demand;
	// ServingModeCFProxied renders `tls internal` so a Cloudflare-proxied origin
	// never runs on-demand ACME (whose challenge cannot complete through the
	// proxy → error 526). The empty string is the zero value and means direct,
	// so a claim from a control plane that does not yet send serving_mode keeps
	// rendering today's on-demand block byte-for-byte. The CP→box channel that
	// populates this is a separate concern (cf-agent-sites-tls-channel backlog);
	// the field is threaded here so the derivation is ready the moment it lands.
	ServingMode string `json:"serving_mode,omitempty"`
}

// Serving modes carried on InlineSite.ServingMode — the control plane's per-site
// TLS-termination instruction. Direct sites resolve straight to the box and
// issue their own cert on demand; CF-proxied sites sit behind Cloudflare's
// orange cloud and must present a self-signed cert instead of running ACME.
const (
	// ServingModeDirect — the domain resolves straight to the box (grey cloud /
	// no proxy). On-demand ACME is correct. This is the zero-value default.
	ServingModeDirect = "direct"
	// ServingModeCFProxied — the domain is proxied through Cloudflare (orange
	// cloud). On-demand ACME cannot complete through the proxy, so the box must
	// render `tls internal` (self-signed) to avoid Cloudflare error 526.
	ServingModeCFProxied = "cf_proxied"
)

// tlsModeForServing maps a site's serving_mode to the caddyfile TLS mode the
// renderer needs: cf_proxied → internal (self-signed, no ACME — 526-safe behind
// the Cloudflare proxy); everything else (direct, empty, or any unknown value)
// → on_demand, the direct-to-box default. On-demand is the fail-safe default so
// an unrecognized mode never silently produces a `tls internal` origin.
func tlsModeForServing(mode string) string {
	if mode == ServingModeCFProxied {
		return caddyfile.TLSModeInternal
	}
	return caddyfile.TLSModeOnDemand
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
// and the slug+port+domains of each live site (so the rewritten Caddyfile
// reflects all sites, not just the one being deployed). Tests build State by
// hand; the production path (cmd/barkpark-runtime) reconstructs it fresh
// before every cycle via StateFromDisk — parsing the on-box Caddyfile, the
// source of truth for what Caddy is actually serving.
type State struct {
	// LiveSites are the runtime-managed sites recovered from the Caddyfile's
	// marker-carrying blocks (slug, domains, upstream port, kind, TLS mode).
	LiveSites []caddyfile.Site

	// ReservedPorts are loopback upstream ports claimed by Caddyfile vhosts
	// the runtime does NOT manage — e.g. the instance API/Studio vhost
	// proxying 127.0.0.1:4000, or an attach-domain vhost the provisioner
	// appended. The port allocator must never hand one of these to a new
	// container.
	ReservedPorts map[int]bool
}

// StateFromDisk reconstructs State by parsing the Caddyfile at CaddyfilePath:
// every marker-carrying managed block comes back as a live Site, and every
// loopback port claimed by a foreign block is reserved. A missing file is an
// empty box, not an error; any other read failure surfaces so a cycle never
// proceeds on guessed-empty state (which is exactly the MVP bug this
// replaces: empty state made the rewrite delete every foreign vhost and the
// allocator re-issue a port a live container still bound).
//
// The signature matches Run's buildState, so the cmd wrapper passes the
// method directly — state is re-parsed before EVERY cycle, never cached, so a
// long-running executor cannot go stale against a file that the provisioner,
// attach-domain, or an operator edits underneath it.
func (e *Executor) StateFromDisk(context.Context) (State, error) {
	buf, err := e.fs().ReadFile(e.CaddyfilePath)
	if err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			return State{}, nil
		}
		return State{}, fmt.Errorf("read caddyfile %s: %w", e.CaddyfilePath, err)
	}
	p := caddyfile.Parse(buf)
	return State{LiveSites: p.Sites, ReservedPorts: p.ForeignPorts}, nil
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
	// Derive the TLS mode from the site's serving_mode so a Cloudflare-proxied
	// site renders `tls internal` (526-safe) and a direct site keeps on-demand.
	// serving_mode is zero-valued until the CP→box channel populates it
	// (cf-agent-sites-tls-channel backlog), so today every site resolves to
	// on_demand and the rendered block is byte-identical to before.
	updated := mergeSite(state.LiveSites, caddyfile.Site{
		Slug:    slug,
		Domains: domains,
		Port:    port,
		TLSMode: tlsModeForServing(d.Site.ServingMode),
	})

	if err := e.writeCaddyfile(updated); err != nil {
		// The green container is up but unreachable (no Caddyfile entry). Tear
		// it down so a flapping Caddy doesn't leak 512m orphans across reboots.
		_ = e.runner().Run(ctx, devNull{}, "docker", "rm", "-f", containerName(slug, d.ID))
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
		_ = e.runner().Run(ctx, devNull{}, "docker", "rm", "-f", containerName(slug, d.ID))
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
		// container is already serving). drainContainer captures its output
		// and surfaces any failure through Logger so it's visible instead of
		// silently vanishing.
		_ = e.drainContainer(ctx, fmt.Sprintf("site-%s-blue", slug), livePort)
	}

	// Atomic transition to live. For a PRODUCTION deploy we also repoint the
	// Site at this deployment + port (make_current). For a PREVIEW we do NOT —
	// the preview serves on its own host/port and must leave the production slot
	// (current_deployment_id / port) exactly as it was (gh-6).
	now := time.Now().UTC().Format(time.RFC3339)
	body := map[string]any{
		"worker_id":      e.WorkerID,
		"observed_epoch": d.Epoch,
		"status":         "live",
		"became_live_at": now,
	}
	if !d.isPreview() {
		body["make_current"] = true
		body["site_port"] = port
	}
	if err := e.transition(ctx, d.ID, body); err != nil {
		return true, fmt.Errorf("transition live: %w", err)
	}

	// THE CUTOVER IS NOW A FACT — Caddy is proxying the new port and the
	// control plane has accepted `live`. Only here may the executor delete
	// anything: every failure path above returns before this line, so a deploy
	// that did NOT cut over leaves the previous container (stopped, instant
	// `docker start` rollback) and its image untouched.
	//
	// Before this call nothing in this repo had EVER removed a site container
	// or a loaded site image: RunOnce only `docker stop`s the blue, and a
	// stopped container pins its image against `docker image prune`. Ten
	// deploys on the jarl box left 18 images / 20.76 GB on a 38 GB disk and
	// took the CMS down (jpf-box-prune-op).
	e.sweepSiteImages(ctx, slug, containerName(slug, d.ID), otherSlugs(state.LiveSites, slug))

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

// safeImageTag is the fail-closed allowlist for d.ImageTag before it is used to
// build the docker-load tar path AND the docker-run image ref. The producer
// mints tags as `site-<hex8>-<hex8>` (builder.go), so a strict charset is
// lossless for every legitimate tag while refusing the whole path-escape /
// arbitrary-tar-load class defense-in-depth on top of the #12308 shell-RCE fix.
//
// CRITICAL — the two rules must not drift: this charset rejects '/', and it is
// the '/' rejection (not a '..' rule) that neutralizes a bare `..`. A tag of
// exactly ".." passes the charset (dot and hyphen are allowed) but is inert:
// `<CacheDir>/...tar` is a single filename under CacheDir, not a parent-dir
// traversal. Traversal needs a separator — `../x` or `a/../..` — and every one
// of those carries a '/', which this pattern refuses. Do NOT relax '/' on the
// theory that '..' is separately handled; there is no separate '..' handling,
// and there must not be, because '/' rejection IS the containment.
var safeImageTag = regexp.MustCompile(`^[A-Za-z0-9._-]+$`)

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
	// 0. Fail closed on a hostile image tag BEFORE it reaches either docker sink.
	// This one guard at function entry dominates BOTH uses of d.ImageTag below:
	// the docker-load tar path (step 1) and the docker-run image ref (step 4).
	// d.ImageTag is decoded RAW from the control-plane claim JSON; a tag bearing
	// '/' or '..' would let `docker load -i <CacheDir>/<tag>.tar` read an
	// attacker-chosen tar OUTSIDE CacheDir. See safeImageTag for why '/' rejection
	// (not a '..' rule) is what provides containment — the two must not drift.
	if !safeImageTag.MatchString(d.ImageTag) {
		return "", "", nil, 0, 0, fmt.Errorf("refusing unsafe image tag %q: must match %s", d.ImageTag, safeImageTag.String())
	}

	slug, domains, livePort := e.resolveSite(d, state)
	site := d.SiteID

	// 1. Load the image from the builder's cache. Fixed argv straight through
	// execve (ExecRunner.Run is exec.CommandContext — NO shell): imageTar embeds
	// d.ImageTag, decoded raw from the control-plane claim JSON, so a malicious
	// tag like `$(...)`/backticks must land as one literal filename argument, not
	// a command the shell expands. A prior `sh -c "docker load -i %q"` was a real
	// RCE — Go's %q does NOT neutralize `$(...)`/backticks inside a shell.
	imageTar := fmt.Sprintf("%s/%s.tar", strings.TrimRight(e.CacheDir, "/"), d.ImageTag)
	if err := e.runner().Run(ctx, devNull{},
		"docker", "load", "-i", imageTar); err != nil {
		return "", "", nil, 0, 0, fmt.Errorf("docker load %s: %w", imageTar, err)
	}

	// 2. Pick the new (green) port — avoiding every port already spoken for:
	// live managed sites, AND ports claimed by foreign Caddyfile vhosts the
	// runtime doesn't manage (the instance API vhost proxies 127.0.0.1:4000 —
	// handing that to a container would break the box's own control surface).
	inUse := map[int]bool{}
	for p, used := range state.ReservedPorts {
		if used {
			inUse[p] = true
		}
	}
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

	// 3. Fetch the site's env (site-env-injection): the DECRYPTED blob the user
	// set via `bp sites env set`, injected as `-e KEY=VAL` pairs so the RUNNING
	// container (not just the build) sees it. A missing blob — or a control
	// plane predating the route (404 either way) — runs env-less; any other
	// error fails the deploy rather than silently starting a container without
	// the env its site was configured with.
	//
	// Leak posture: `-e` pairs over an --env-file. The values land in the
	// container's config either way (`docker inspect`, root-only), the runner
	// exec's docker DIRECTLY (no shell, output to devNull — nothing reaches the
	// journal or any log writer), and an on-disk env-file would add a real
	// leak: a crash between write and cleanup strands the secrets in a file
	// forever. The argv is visible in /proc only for the docker CLI's lifetime
	// on a single-tenant root-owned box.
	env, err := e.fetchSiteEnv(ctx, d.SiteID)
	if err != nil {
		return "", "", nil, 0, 0, fmt.Errorf("site env: %w", err)
	}

	// 4. Run the new container. Site env rides FIRST and the platform pairs
	// (HOSTNAME/PORT) LAST — with docker the last `-e` wins, so a site env that
	// names PORT can never repoint the container off the port Caddy proxies to.
	container := containerName(slug, d.ID)

	// Belt and braces: a previous failed cycle can leave a Created-but-never-
	// started container squatting this exact name (seen in production —
	// deployment 2f92055a left site-jarl-website-2f92055a in Created, and the
	// retry's `docker run` failed with "name already in use", exit 125).
	// Best-effort removal; an absent name just errors quietly.
	_ = e.runner().Run(ctx, devNull{}, "docker", "rm", "-f", container)

	args := []string{
		"run", "-d",
		"--name", container,
		"--restart", "unless-stopped",
		"--memory=512m", "--cpus=1",
	}
	for _, k := range sortedKeys(env) {
		args = append(args, "-e", k+"="+env[k])
	}
	args = append(args,
		"-e", fmt.Sprintf("HOSTNAME=0.0.0.0"),
		"-e", fmt.Sprintf("PORT=%d", containerInnerPort),
		"-p", fmt.Sprintf("127.0.0.1:%d:%d", port, containerInnerPort),
		d.ImageTag,
	)
	if err := e.runner().Run(ctx, devNull{}, "docker", args...); err != nil {
		return "", "", nil, 0, 0, fmt.Errorf("docker run: %w", err)
	}

	// 5. Health-check the container until /` answers (any non-5xx).
	if err := e.healthCheck(ctx, port); err != nil {
		// Tear down the failed container before bailing.
		_ = e.runner().Run(ctx, devNull{}, "docker", "rm", "-f", container)
		return "", "", nil, 0, 0, fmt.Errorf("health-check: %w", err)
	}

	return site, slug, domains, port, livePort, nil
}

// fetchSiteEnv GETs the site's decrypted env from the agent surface of the
// control plane (box-scoped by the agent token). Returns:
//   - (map, nil) on 200 — the KEY=VAL pairs to inject (`{}` when no blob set).
//   - (nil, nil) on 404 — tolerated: a control plane predating the route (or a
//     site racing a delete) must not brick every deploy; it runs env-less.
//   - (nil, err) on anything else — the caller fails the deploy rather than
//     silently running without the env the site was configured with.
func (e *Executor) fetchSiteEnv(ctx context.Context, siteID string) (map[string]string, error) {
	url := strings.TrimRight(e.ControlURL, "/") + fmt.Sprintf(siteEnvPathFmt, siteID)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	e.attachAuth(req)

	resp, err := e.http().Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	switch resp.StatusCode {
	case http.StatusOK:
		var out struct {
			Env map[string]string `json:"env"`
		}
		if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
			return nil, fmt.Errorf("decode site env: %w", err)
		}
		return out.Env, nil

	case http.StatusNotFound:
		return nil, nil

	default:
		return nil, statusError(resp)
	}
}

// sortedKeys returns env's keys sorted — a deterministic `-e` order, so two
// deploys of the same site produce identical docker invocations.
func sortedKeys(env map[string]string) []string {
	keys := make([]string, 0, len(env))
	for k := range env {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}

// resolveSite returns (slug, domains, livePort) for the deployment. The
// agent claim/pending response inlines the site shape (slug + domains), so the
// MVP doesn't need a second round trip. livePort comes from state.LiveSites
// (the cmd wrapper supplies it on subsequent boots by parsing the existing
// Caddyfile or by querying the control plane).
//
// livePort = 0 means "first deploy for this site, no blue yet" — the executor
// allocates the green port without trying to avoid a blue.
//
// gh-6: for a PREVIEW deployment the slug key is the preview slug and the
// single domain is the preview host — so the preview renders as its own Caddy
// block on its own port, keyed distinctly from the production site (no slug
// collision, and blue/green replace works per-branch across pushes).
func (e *Executor) resolveSite(d *claimed, state State) (string, []string, int) {
	slug := d.Site.Slug
	domains := d.Site.Domains

	if d.isPreview() && d.Site.PreviewSlug != "" && d.Site.PreviewHost != "" {
		slug = d.Site.PreviewSlug
		domains = []string{d.Site.PreviewHost}
	}

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

// writeCaddyfile rewrites the on-box Caddyfile so it serves sites while
// preserving, byte-identical, every vhost the runtime does not manage (no
// "# Managed by barkpark-runtime" marker): the instance API/Studio vhost, the
// provisioner's attach-domain blocks, anything an operator added by hand. The
// previous MVP re-rendered the whole file from (always-empty) state, which
// deleted every foreign vhost on the box — on the jarl box that took down
// jarl.barkpark.cloud and barkpark.jarl.no until an operator repaired them.
func (e *Executor) writeCaddyfile(sites []caddyfile.Site) error {
	prev, err := e.fs().ReadFile(e.CaddyfilePath)
	if err != nil {
		if !errors.Is(err, fs.ErrNotExist) {
			// An unreadable existing file must fail the deploy — rewriting
			// from scratch here would clobber every vhost we couldn't read.
			return fmt.Errorf("read existing: %w", err)
		}
		prev = nil
	}
	text := caddyfile.Rewrite(prev, caddyfile.Box{
		AskGateURL:     e.AskGateURL,
		StudioUpstream: e.StudioUpstream,
		Sites:          sites,
	})
	return e.fs().WriteFile(e.CaddyfilePath, text, 0o644)
}

func (e *Executor) reloadCaddy(ctx context.Context) error {
	return e.runner().Run(ctx, devNull{}, "caddy", "reload", "--config", e.CaddyfilePath)
}

func (e *Executor) drainContainer(ctx context.Context, name string, port int) error {
	// Best-effort. A graceful 5s SIGTERM, then kill. Output is captured (not
	// discarded into devNull) so a drain failure after cutover-to-live is
	// visible via Logger instead of leaving the old container running with
	// zero trace.
	var buf bytes.Buffer
	err := e.runner().Run(ctx, &buf, "sh", "-c",
		fmt.Sprintf("docker ps -q --filter publish=%d | xargs -r docker stop -t 5", port))
	if err != nil {
		e.logf("drain %s (port %d) failed: %v; output: %s", name, port, err, strings.TrimSpace(buf.String()))
	}
	return err
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

// http returns the injected client, or a Timeout-bearing fallback (30s) so a
// hung control-plane connection can't freeze the claim/transition loop with
// no crash and no log — http.DefaultClient has Timeout 0 (no deadline).
func (e *Executor) http() *http.Client {
	if e.HTTPClient != nil {
		return e.HTTPClient
	}
	return &http.Client{Timeout: 30 * time.Second}
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

// logf calls Logger when set; nil Logger makes this a silent no-op.
func (e *Executor) logf(format string, args ...any) {
	if e.Logger != nil {
		e.Logger(format, args...)
	}
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
// new slice (input untouched, safe to call with shared state). It operates on
// whole caddyfile.Site values, so every field — including a static site's
// Kind/Root (charter D9) — rides through untouched: a KindStatic entry already
// in state.LiveSites survives a reverse_proxy deploy of a different slug, and
// the container path here keeps constructing Kind-empty (reverse_proxy) sites.
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

// Package builder is the off-box build plane (Barkpark Cloud P2 / Move A): a
// dedicated process that claims queued Deployments from the control plane,
// runs nixpacks against the deployment's artifact, docker-saves the image to a
// shared cache, and transitions the Deployment to "pushing" (or "failed"). It
// runs on a host SEPARATE from the customer's serving box so a Next.js build
// never starves the Postgres/Caddy answering live traffic.
//
// Everything the builder talks to is injected — HTTPClient (tests point it at
// an httptest.Server), Runner (tests use a fake that never shells out), and
// Filesystem (tests use an in-process map) — so the build loop runs hermetic
// with no live control plane and no real Docker.
package builder

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

// DefaultInterval is the claim-poll cadence when Builder.Interval is zero.
// Five seconds is snappy enough that a fresh deploy starts building almost
// immediately, slow enough that an idle builder isn't hammering the API.
const DefaultInterval = 5 * time.Second

const (
	claimPath      = "/v1/builder/claim"
	transitionPath = "/v1/builder/deployments/%s/transition"
)

// Builder is the long-running build worker. WorkerID identifies this instance
// in the control plane's claim ledger (use the hostname + a stable suffix).
// CacheDir is where image tarballs land after `docker save` — the box agent
// (P3) pulls from this directory or its mirror. LogDir holds per-deployment
// build logs; the path becomes the deployment's `build_log_url` as `file://`.
type Builder struct {
	ControlURL string
	Token      string
	WorkerID   string
	Platform   string // e.g. "linux/arm64" — nixpacks --platform
	CacheDir   string
	LogDir     string

	Interval   time.Duration
	HTTPClient *http.Client
	Runner     CommandRunner
}

// Deployment mirrors the JSON shape the control plane returns from /claim and
// /transition — fields the builder needs to drive a build. Add more here only
// when the build loop actually reads them.
type Deployment struct {
	ID            string `json:"id"`
	SiteID        string `json:"site_id"`
	Status        string `json:"status"`
	GitRef        string `json:"git_ref"`
	ArtifactURL   string `json:"artifact_url"`
	ImageTag      string `json:"image_tag"`
	BuildLogURL   string `json:"build_log_url"`
	FailureReason string `json:"failure_reason"`
}

// CommandRunner runs a subprocess and writes its combined stdout+stderr to w.
// ExecRunner is the real shell-out; tests inject a fake that produces canned
// behavior without touching the host.
type CommandRunner interface {
	Run(ctx context.Context, w io.Writer, name string, args ...string) error
}

// ExecRunner is the default CommandRunner — real `os/exec` invocations.
type ExecRunner struct{}

// Run executes name+args, streaming combined stdout/stderr to w. Returns the
// exec error (or a wrapped exit-status error).
func (ExecRunner) Run(ctx context.Context, w io.Writer, name string, args ...string) error {
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Stdout = w
	cmd.Stderr = w
	return cmd.Run()
}

// RunOnce performs a single claim → build → transition cycle. Returns:
//   - (true, nil)  — a deployment was claimed and walked through its terminal
//     state (pushing on success, failed on build error captured in DB).
//   - (false, nil) — the queue was empty.
//   - (false, err) — a transport/protocol error reaching the control plane.
//
// The boolean lets a caller decide whether to back off (false → sleep, true →
// re-poll immediately).
func (b *Builder) RunOnce(ctx context.Context) (bool, error) {
	d, claimed, err := b.claim(ctx)
	if err != nil {
		return false, fmt.Errorf("claim: %w", err)
	}
	if !claimed {
		return false, nil
	}

	imageTag, buildLogPath, buildErr := b.build(ctx, d)

	logURL := ""
	if buildLogPath != "" {
		logURL = "file://" + buildLogPath
	}

	if buildErr != nil {
		// The build failed, but the row is ours and we MUST report — otherwise
		// the lease eventually expires and another worker re-runs an
		// already-broken build.
		_ = b.transition(ctx, d.ID, map[string]any{
			"worker_id":      b.WorkerID,
			"observed_epoch": b.claimEpoch(d),
			"status":         "failed",
			"failure_reason": buildErr.Error(),
			"build_log_url":  logURL,
		})
		return true, nil
	}

	// Note the explicit `claim_worker: nil` + `claim_epoch: 0`: handing the row
	// off to the agent. The builder is done; the row needs to look "unclaimed"
	// so the agent's claim query (which fences on is_nil(claim_worker)) can
	// pick it up. The CAS still holds — the CAS checks the BEFORE state, and
	// we set the AFTER values.
	if err := b.transition(ctx, d.ID, map[string]any{
		"worker_id":      b.WorkerID,
		"observed_epoch": b.claimEpoch(d),
		"status":         "pushing",
		"image_tag":      imageTag,
		"build_log_url":  logURL,
		"claim_worker":   nil,
		"claim_epoch":    0,
	}); err != nil {
		return true, fmt.Errorf("transition pushing: %w", err)
	}

	return true, nil
}

// Run loops RunOnce on Interval until ctx is cancelled. On a "queue had work"
// cycle, the next poll fires immediately (let the queue drain). On a "queue
// was empty" cycle, sleep one Interval before re-polling.
func (b *Builder) Run(ctx context.Context) error {
	interval := b.Interval
	if interval <= 0 {
		interval = DefaultInterval
	}

	for {
		if err := ctx.Err(); err != nil {
			return err
		}

		had, err := b.RunOnce(ctx)
		if err != nil {
			// One bad cycle (transport error, e.g. control plane bounced) does
			// not kill the worker; sleep + retry.
			select {
			case <-ctx.Done():
				return ctx.Err()
			case <-time.After(interval):
			}
			continue
		}

		if had {
			// Drain — re-poll immediately.
			continue
		}

		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(interval):
		}
	}
}

// claim POSTs /v1/builder/claim. Returns (deployment, true, nil) on a 200,
// (zero, false, nil) on a 404 no_queued (queue empty — not an error), or
// (zero, false, err) on any other response.
func (b *Builder) claim(ctx context.Context) (*claimedDeployment, bool, error) {
	body, _ := json.Marshal(map[string]string{"worker_id": b.WorkerID})

	req, err := http.NewRequestWithContext(
		ctx,
		http.MethodPost,
		strings.TrimRight(b.ControlURL, "/")+claimPath,
		bytes.NewReader(body),
	)
	if err != nil {
		return nil, false, err
	}
	b.attachAuth(req)
	req.Header.Set("Content-Type", "application/json")

	resp, err := b.http().Do(req)
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
		return &claimedDeployment{Deployment: out.Deployment, Epoch: out.ObservedEpoch}, true, nil

	case http.StatusNotFound:
		// The queue was empty — not an error.
		return nil, false, nil

	default:
		return nil, false, statusError(resp)
	}
}

// transition POSTs the fenced transition. Body is whatever the caller supplies
// — the schema (worker_id + observed_epoch + status + optional image_tag /
// build_log_url / failure_reason) lives in the control plane.
func (b *Builder) transition(ctx context.Context, deploymentID string, body map[string]any) error {
	buf, _ := json.Marshal(body)
	url := strings.TrimRight(b.ControlURL, "/") + fmt.Sprintf(transitionPath, deploymentID)

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(buf))
	if err != nil {
		return err
	}
	b.attachAuth(req)
	req.Header.Set("Content-Type", "application/json")

	resp, err := b.http().Do(req)
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

// build is the actual nixpacks invocation. Returns (image_tag, log_path, err).
// On err, log_path is still set (so the failed-row carries the build log) if a
// log file got created.
//
// The build runs at nice +10 to keep a build CPU-bomb from starving other
// processes on the same builder host; cgroup capping for finer control is the
// systemd unit's job (CPUQuota=...).
func (b *Builder) build(ctx context.Context, d *claimedDeployment) (imageTag string, logPath string, err error) {
	source, err := b.resolveArtifact(d.ArtifactURL)
	if err != nil {
		return "", "", fmt.Errorf("artifact: %w", err)
	}

	// site-<site_id_short>-<deployment_id_short> is unique per build and
	// human-readable in `docker images`.
	imageTag = fmt.Sprintf("site-%s-%s", short(d.SiteID), short(d.ID))

	logPath = filepath.Join(b.LogDir, d.ID+".log")
	logFile, err := openLog(logPath)
	if err != nil {
		return "", "", fmt.Errorf("open log %s: %w", logPath, err)
	}
	defer logFile.Close()

	fmt.Fprintf(logFile, "barkpark-builder build start ts=%s deployment=%s site=%s git_ref=%s artifact=%s\n",
		time.Now().UTC().Format(time.RFC3339), d.ID, d.SiteID, d.GitRef, d.ArtifactURL)

	runner := b.runner()

	// nixpacks build <source> --platform <plat> --name <tag>
	args := []string{"build", source, "--name", imageTag}
	if b.Platform != "" {
		args = append(args, "--platform", b.Platform)
	}

	if err := runner.Run(ctx, logFile, "nice", append([]string{"-n", "10", "nixpacks"}, args...)...); err != nil {
		return "", logPath, fmt.Errorf("nixpacks build: %w", err)
	}

	// docker save to the shared cache. The image-tarball name is the deterministic
	// imageTag; the box agent (P3) pulls this filename to load on the serving box.
	if b.CacheDir != "" {
		out := filepath.Join(b.CacheDir, imageTag+".tar")
		// docker's native -o writes the tarball itself (and cleans up its own
		// incomplete output on failure), unlike a shell `>` redirect that
		// truncates the destination before docker even runs — leaving a partial
		// .tar in the shared cache for the box agent to load.
		if err := runner.Run(ctx, logFile, "docker", "save", imageTag, "-o", out); err != nil {
			return "", logPath, fmt.Errorf("docker save: %w", err)
		}
		fmt.Fprintf(logFile, "barkpark-builder image saved to %s\n", out)
	}

	fmt.Fprintf(logFile, "barkpark-builder build end ts=%s status=ok\n",
		time.Now().UTC().Format(time.RFC3339))

	return imageTag, logPath, nil
}

// resolveArtifact maps an artifact_url to a local directory the builder can
// pass to nixpacks. Only "file://" is implemented for now — P6's `bp deploy`
// SCPs the tarball into the builder's filesystem and creates the deployment
// with a file:// path. https:// blob-storage support is a future addition.
func (b *Builder) resolveArtifact(url string) (string, error) {
	switch {
	case strings.HasPrefix(url, "file://"):
		// file:///abs/path → /abs/path. The builder trusts the path: this is
		// a fleet-internal URL only the trusted upload path produces.
		return strings.TrimPrefix(url, "file://"), nil
	case url == "":
		return "", fmt.Errorf("artifact_url is empty (P6 bp deploy must populate it)")
	default:
		return "", fmt.Errorf("unsupported artifact scheme: %q (only file:// is implemented)", url)
	}
}

func (b *Builder) http() *http.Client {
	if b.HTTPClient != nil {
		return b.HTTPClient
	}
	return http.DefaultClient
}

func (b *Builder) runner() CommandRunner {
	if b.Runner != nil {
		return b.Runner
	}
	return ExecRunner{}
}

func (b *Builder) attachAuth(req *http.Request) {
	if b.Token != "" {
		req.Header.Set("Authorization", "Bearer "+b.Token)
	}
}

// claimedDeployment is the in-process pairing of the claimed Deployment with
// its observed_epoch — both flow forward into the transition CAS.
type claimedDeployment struct {
	Deployment
	Epoch int
}

func (b *Builder) claimEpoch(d *claimedDeployment) int { return d.Epoch }

func statusError(resp *http.Response) error {
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 64*1024))
	return fmt.Errorf("%s %s: %s", resp.Request.Method, resp.Request.URL.Path,
		strings.TrimSpace(fmt.Sprintf("%d %s — %s", resp.StatusCode, http.StatusText(resp.StatusCode), body)))
}

func short(id string) string {
	if len(id) >= 8 {
		return id[:8]
	}
	return id
}

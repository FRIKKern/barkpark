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
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
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
	siteEnvPathFmt = "/v1/builder/sites/%s/env"
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

// BuildSource is the claim envelope's `source` sibling (sites-github-auto-build):
// where the deployment's code comes from when no artifact tarball was uploaded.
// Kind selects the lane — "git" is the only kind today. URL is an anonymously
// fetchable remote; Ref is handed to git VERBATIM — the control plane mints the
// full 40-char commit sha (ref names also work at the wire level, but
// abbreviated shas are refused by the server with `couldn't find remote ref`,
// so never abbreviate).
//
// Token is an optional short-lived GitHub App INSTALLATION token
// (dwb-webhook-deploy-artifact-gap) minted by the control plane at claim time
// for a PRIVATE connected repo. It is deliberately its own field rather than
// credentials spliced into URL: a credential inside a remote URL gets written
// into the clone workdir's config by `git remote add`, is echoed back in git's
// own error text, and would ride every console line that narrates the URL.
// Empty means "clone anonymously", which is all a public repo needs.
type BuildSource struct {
	Kind  string `json:"kind"`
	URL   string `json:"url"`
	Ref   string `json:"ref"`
	Token string `json:"token,omitempty"`
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

	// gh-5: narrate the real build phases to the live build console. Best-effort
	// telemetry — every console call swallows its own error, so it can never fail
	// the build.
	con := b.newBuildConsole(ctx, d.ID)
	con.logf("claim: deployment %s (site %s) claimed by %s — ref %s",
		short(d.ID), short(d.SiteID), b.WorkerID, refOrNone(d.GitRef))
	// dwb-19: the live sub-caption under the deploy's status pill — plain language,
	// distinct from the raw console. Overwritten (latest-wins) at each boundary.
	con.caption("Starting your build (%s)…", refOrNone(d.GitRef))

	imageTag, buildLogPath, buildErr := b.build(ctx, d, con)

	logURL := ""
	if buildLogPath != "" {
		logURL = "file://" + buildLogPath
	}

	if buildErr != nil {
		// The build failed, but the row is ours and we MUST report — otherwise
		// the lease eventually expires and another worker re-runs an
		// already-broken build.
		// The TERMINAL line punches through the console latch (one attempt,
		// with a truncation marker when the latch fired) — a latched build
		// used to end with no failed: line and no explanation, indistinguishable
		// from a build that was merely quiet.
		con.logfTerminal("failed: %s", buildErr.Error())
		_ = b.transition(ctx, d.ID, map[string]any{
			"worker_id":      b.WorkerID,
			"observed_epoch": b.claimEpoch(d),
			"status":         "failed",
			"failure_reason": buildErr.Error(),
			"build_log_url":  logURL,
		})
		return true, nil
	}

	con.caption("Handing off to release…")
	con.logfTerminal("activate: build complete — handing off to release (pushing), image %s", imageTag)

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
			Deployment    Deployment   `json:"deployment"`
			ObservedEpoch int          `json:"observed_epoch"`
			Source        *BuildSource `json:"source"`
		}
		if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
			return nil, false, fmt.Errorf("decode claim: %w", err)
		}
		return &claimedDeployment{Deployment: out.Deployment, Epoch: out.ObservedEpoch, Source: out.Source}, true, nil

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
func (b *Builder) build(ctx context.Context, d *claimedDeployment, con *buildConsole) (imageTag string, logPath string, err error) {
	con.caption("Fetching your source…")
	source, err := b.resolveSource(ctx, d, con)
	if err != nil {
		return "", "", err
	}
	con.logf("source: ready at %s", source)

	// site-<site_id_short>-<deployment_id_short> is unique per build and
	// human-readable in `docker images`.
	imageTag = fmt.Sprintf("site-%s-%s", short(d.SiteID), short(d.ID))

	logPath = filepath.Join(b.LogDir, d.ID+".log")
	logFile, err := openLog(logPath)
	if err != nil {
		return "", "", fmt.Errorf("open log %s: %w", logPath, err)
	}
	defer logFile.Close()

	// Tee the build-log file to the live console: the durable log stays the
	// source of truth, while each COMPLETE output line is mirrored (redacted,
	// best-effort) to the deployment console so the dashboard streams the real
	// nixpacks / docker output line-by-line.
	tee := &consoleTee{w: logFile, c: con}
	defer tee.flush()

	fmt.Fprintf(logFile, "barkpark-builder build start ts=%s deployment=%s site=%s git_ref=%s artifact=%s\n",
		time.Now().UTC().Format(time.RFC3339), d.ID, d.SiteID, d.GitRef, d.ArtifactURL)

	runner := b.runner()

	// Site env (site-env-injection): fetch the DECRYPTED env the user set via
	// `bp sites env set` and hand each pair to nixpacks as `--env KEY=VAL`, so
	// build-time prerendering (a Next.js SSG page reading BARKPARK_READ_TOKEN)
	// sees the same values the running container will. A missing blob (or a
	// control plane predating the route — 404 either way) builds env-less; a
	// transport/500 error FAILS the build instead of silently shipping a site
	// without the env it was configured with. Only KEY NAMES are narrated /
	// logged — the values never touch the build log or the live console.
	env, err := b.fetchSiteEnv(ctx, d.SiteID)
	if err != nil {
		return "", logPath, fmt.Errorf("site env: %w", err)
	}
	envKeys := sortedKeys(env)

	// nixpacks build <source> --platform <plat> --name <tag> [--env KEY=VAL ...]
	args := []string{"build", source, "--name", imageTag}
	if b.Platform != "" {
		args = append(args, "--platform", b.Platform)
	}
	for _, k := range envKeys {
		args = append(args, "--env", k+"="+env[k])
	}
	if len(envKeys) > 0 {
		con.logf("env: injecting %d site env var(s): %s", len(envKeys), strings.Join(envKeys, ", "))
		fmt.Fprintf(logFile, "barkpark-builder site env keys=%s (values withheld)\n", strings.Join(envKeys, ","))
	}

	con.caption("Building your site…")
	con.logf("build: nixpacks build %s (platform %s)", imageTag, platformOrDefault(b.Platform))
	if err := runner.Run(ctx, tee, "nice", append([]string{"-n", "10", "nixpacks"}, args...)...); err != nil {
		tee.flush()
		return "", logPath, fmt.Errorf("nixpacks build: %w", err)
	}
	tee.flush()

	// docker save to the shared cache. The image-tarball name is the deterministic
	// imageTag; the box agent (P3) pulls this filename to load on the serving box.
	if b.CacheDir != "" {
		out := filepath.Join(b.CacheDir, imageTag+".tar")
		con.caption("Saving the build image…")
		con.logf("artifact: docker save %s", imageTag)
		// docker's native -o writes the tarball itself (and cleans up its own
		// incomplete output on failure), unlike a shell `>` redirect that
		// truncates the destination before docker even runs — leaving a partial
		// .tar in the shared cache for the box agent to load.
		if err := runner.Run(ctx, tee, "docker", "save", imageTag, "-o", out); err != nil {
			tee.flush()
			return "", logPath, fmt.Errorf("docker save: %w", err)
		}
		tee.flush()
		fmt.Fprintf(logFile, "barkpark-builder image saved to %s\n", out)
		con.logf("artifact: image saved to %s", out)
	}

	fmt.Fprintf(logFile, "barkpark-builder build end ts=%s status=ok\n",
		time.Now().UTC().Format(time.RFC3339))

	return imageTag, logPath, nil
}

// refOrNone renders a git ref for narration, falling back to "(none)" so a
// console line never reads "ref " with a dangling blank.
func refOrNone(ref string) string {
	if strings.TrimSpace(ref) == "" {
		return "(none)"
	}
	return ref
}

// platformOrDefault renders the nixpacks platform for narration, falling back to
// "default" when the builder didn't pin one.
func platformOrDefault(p string) string {
	if strings.TrimSpace(p) == "" {
		return "default"
	}
	return p
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

// resolveSource walks the source ladder for a claimed deployment and returns
// the local directory to hand nixpacks:
//  1. artifact_url non-empty → resolveArtifact, exactly as before the ladder;
//  2. else a `source` of kind "git" → sha-first shallow clone (cloneGitSource);
//  3. else → the honest empty-artifact error (nothing minted a source at all).
func (b *Builder) resolveSource(ctx context.Context, d *claimedDeployment, con *buildConsole) (string, error) {
	switch {
	case d.ArtifactURL != "":
		con.logf("source: resolving artifact %s", d.ArtifactURL)
		dir, err := b.resolveArtifact(d.ArtifactURL)
		if err != nil {
			return "", fmt.Errorf("artifact: %w", err)
		}
		return dir, nil

	case d.Source != nil && d.Source.Kind == "git":
		// Register the clone credential as a console secret BEFORE the first
		// line that could carry it, so any git output echoing the token is
		// scrubbed from the live console. The URL itself never holds it.
		con.addSecret(d.Source.Token)
		con.logf("source: cloning %s @ %s (%s shallow fetch)",
			d.Source.URL, refOrNone(d.Source.Ref), authModeOf(d.Source))
		dir, err := b.cloneGitSource(ctx, d.Source)
		if err != nil {
			return "", fmt.Errorf("git source: %w", err)
		}
		return dir, nil

	default:
		_, err := b.resolveArtifact("")
		return "", fmt.Errorf("artifact: %w", err)
	}
}

// cloneGitSource materializes src.Ref from src.URL into a fresh temp workdir:
//
//	git init; git remote add origin <url>;
//	git -c credential.helper= fetch --depth 1 origin <ref>; git checkout FETCH_HEAD
//
// The sequence is proven against live GitHub (see
// tooling/grip/ledger/clone-sha-mechanics-2026-07-31.md) and has NO fallback —
// a depth-1 BRANCH fetch does not carry non-tip shas (`reference is not a
// tree`), so fetch-by-ref-then-checkout-sha is not a lane. The ref is passed
// verbatim; the checkout dir feeds nixpacks unchanged.
func (b *Builder) cloneGitSource(ctx context.Context, src *BuildSource) (string, error) {
	if src.URL == "" || src.Ref == "" {
		return "", fmt.Errorf("source envelope incomplete (url=%q ref=%q) — the control plane must mint both", src.URL, src.Ref)
	}
	// A ref is an ARGUMENT to git, and git's option parser claims a leading '-'
	// wherever it appears in argv. `git_ref` is caller-supplied on the manual
	// deploy route (POST /v1/sites/:id/deploy {"git_ref": …}) and carries no
	// format constraint in the changeset.
	//
	// The realized harm over the https transport is NOT command execution
	// (`--upload-pack` is inert for http) — it is a SILENT WRONG BUILD:
	// measured, `fetch --depth 1 origin --upload-pack=…` consumed the ref as an
	// option, fell through to the DEFAULT refspec, and the builder checked out
	// the branch TIP and reported success. That is precisely the moving branch
	// head this lane exists to avoid, arrived at through argv instead of
	// through a branch name.
	//
	// Two independent guards, because they fail differently: this refusal is
	// terminal and says why, while the `--` separator below (measured: turns the
	// same input into `fatal: invalid refspec`) holds even if this check is ever
	// loosened to admit some leading-dash ref.
	if strings.HasPrefix(src.Ref, "-") {
		return "", fmt.Errorf("terminal: refusing ref %q — a ref may not start with '-' (git parses it as an option and silently builds the branch tip instead)", src.Ref)
	}

	authEnv, err := gitAuthEnv(src)
	if err != nil {
		return "", err
	}

	dir, err := os.MkdirTemp("", "bp-builder-git-")
	if err != nil {
		return "", fmt.Errorf("workdir: %w", err)
	}

	steps := [][]string{
		{"init", "--quiet"},
		{"remote", "add", "origin", src.URL},
		// credential.helper is cleared per-command so an OS keychain can't
		// answer for a private repo either — combined with GIT_TERMINAL_PROMPT=0
		// (on every git env, see gitCommand) the fetch FAILS FAST instead of
		// hanging the builder on a username prompt it can never answer. The
		// installation token, when present, rides the ENVIRONMENT (gitAuthEnv)
		// — never argv, which every other process on the host can read.
		{"-c", "credential.helper=", "fetch", "--depth", "1", "origin", "--", src.Ref},
		{"checkout", "--quiet", "FETCH_HEAD"},
	}
	for _, args := range steps {
		var out bytes.Buffer
		cmd := gitCommand(ctx, dir, args...)
		cmd.Env = append(cmd.Env, authEnv...)
		cmd.Stdout = &out
		cmd.Stderr = &out
		if err := cmd.Run(); err != nil {
			return "", classifyGitFailure(src, args, out.String(), err)
		}
	}
	return dir, nil
}

// gitAuthEnv renders src.Token as git configuration ON THE ENVIRONMENT:
//
//	GIT_CONFIG_COUNT=1
//	GIT_CONFIG_KEY_0=http.<scheme>://<host>/.extraHeader
//	GIT_CONFIG_VALUE_0=Authorization: Basic base64("x-access-token:<token>")
//
// Three properties are load-bearing:
//
//   - ENVIRONMENT, not argv: `git -c key=value` puts the credential in the
//     process command line, which every other user on the shared builder host
//     can read out of `ps`. /proc/<pid>/environ is owner-only.
//   - SCOPED to the source's own origin, not bare `http.extraHeader`: a bare
//     key attaches the Authorization header to ANY host git contacts, so a
//     redirect would hand the installation token to a third party.
//   - NOT in the URL: nothing writes it into the workdir's config, and the URL
//     stays safe to narrate to the live console.
//
// Returns nil (no error) when the envelope has no token — a public repo.
func gitAuthEnv(src *BuildSource) ([]string, error) {
	if src.Token == "" {
		return nil, nil
	}

	u, err := url.Parse(src.URL)
	if err != nil || u.Host == "" {
		return nil, fmt.Errorf("terminal: cannot authenticate an unparseable clone url %q", src.URL)
	}

	// Never put a bearer credential on the wire in cleartext. The loopback
	// carve-out exists only so the auth lane can be proven against a real
	// `git http-backend` fixture in-process; those bytes never leave the host.
	switch {
	case u.Scheme == "https":
	case u.Scheme == "http" && isLoopbackHost(u.Host):
	default:
		return nil, fmt.Errorf(
			"terminal: refusing to send the clone credential over %s to %s — only https carries it",
			u.Scheme, u.Host)
	}

	origin := u.Scheme + "://" + u.Host + "/"
	header := "Authorization: Basic " +
		base64.StdEncoding.EncodeToString([]byte(gitAuthUser+":"+src.Token))

	return []string{
		"GIT_CONFIG_COUNT=1",
		"GIT_CONFIG_KEY_0=http." + origin + ".extraHeader",
		"GIT_CONFIG_VALUE_0=" + header,
	}, nil
}

// gitAuthUser is the username GitHub requires alongside an App installation
// token in HTTP Basic auth. The token is the password.
const gitAuthUser = "x-access-token"

// isLoopbackHost reports whether host (an authority, possibly with a port) is
// a loopback address. Used only to allow the hermetic http test fixture.
func isLoopbackHost(host string) bool {
	h := host
	if parsed, _, err := net.SplitHostPort(host); err == nil {
		h = parsed
	}
	if h == "localhost" {
		return true
	}
	ip := net.ParseIP(strings.Trim(h, "[]"))
	return ip != nil && ip.IsLoopback()
}

// authModeOf renders how the clone will authenticate, for narration. Never
// renders the token itself.
func authModeOf(src *BuildSource) string {
	if src != nil && src.Token != "" {
		return "authenticated sha-first"
	}
	return "anonymous sha-first"
}

// gitCommand builds one clone-lane git invocation: cwd pinned to the workdir,
// GIT_TERMINAL_PROMPT=0 on the environment. Without the prompt kill, a fetch
// against a private (or deleted — GitHub answers both identically) repo blocks
// forever reading a username from stdin, wedging the whole builder loop.
func gitCommand(ctx context.Context, dir string, args ...string) *exec.Cmd {
	cmd := exec.CommandContext(ctx, "git", args...)
	cmd.Dir = dir
	cmd.Env = append(os.Environ(), "GIT_TERMINAL_PROMPT=0")
	return cmd
}

// classifyGitFailure maps a failed clone-lane git step to an honest build
// error. Two stderr shapes (both proven against live GitHub) are TERMINAL —
// no retry can ever succeed, so the reason says so and the deployment fails
// once instead of becoming a retry-forever zombie:
//
//   - `not our ref` — the requested commit is no longer reachable on the
//     remote (force-push or branch delete between deployment mint and claim);
//   - `could not read Username` — the repo is not anonymously accessible
//     (private or nonexistent; authenticated GitHub App access is a later,
//     additive provider).
//
// Anything else is a normal build failure carrying the git output tail.
func classifyGitFailure(src *BuildSource, args []string, output string, err error) error {
	authRefused := strings.Contains(output, "could not read Username") ||
		strings.Contains(output, "Authentication failed")

	switch {
	case strings.Contains(output, "not our ref"):
		return fmt.Errorf("terminal: commit %s is no longer reachable on %s (force-push or branch delete since the deployment was created) — a retry cannot succeed; push again to deploy", src.Ref, src.URL)

	// dwb-webhook-deploy-artifact-gap: the two auth refusals are DIFFERENT
	// operator instructions, and conflating them sends the wrong person to fix
	// the wrong thing. No token → the App is not wired or the team has not
	// connected it. Token present and still refused → the installation exists
	// but does not grant this repo.
	case authRefused && src.Token == "":
		return fmt.Errorf("terminal: repository %s is not anonymously accessible (private or nonexistent) and no GitHub App installation token was issued for it — a retry cannot succeed; connect GitHub for this team (and grant the App access to the repo) to deploy a private repository", src.URL)
	case authRefused:
		return fmt.Errorf("terminal: the GitHub App installation token was refused for %s — a retry cannot succeed; grant the Barkpark GitHub App access to this repository (or reinstall it) and push again", src.URL)

	default:
		return fmt.Errorf("git %s: %w — %s", strings.Join(args, " "), err, tailOf(output))
	}
}

// tailOf trims git output for embedding in an error: whitespace-trimmed, last
// 512 bytes at most (git puts the fatal: line last).
func tailOf(s string) string {
	s = strings.TrimSpace(s)
	const max = 512
	if len(s) > max {
		s = "…" + s[len(s)-max:]
	}
	return s
}

// fetchSiteEnv GETs the site's decrypted env from the control plane. Returns:
//   - (map, nil) on 200 — the KEY=VAL pairs to inject (`{}` when no blob set).
//   - (nil, nil) on 404 — tolerated: a control plane predating the route (or a
//     site row racing a delete) must not brick every build; it proceeds env-less.
//   - (nil, err) on anything else — the caller fails the build rather than
//     silently building without the env the site was configured with.
func (b *Builder) fetchSiteEnv(ctx context.Context, siteID string) (map[string]string, error) {
	url := strings.TrimRight(b.ControlURL, "/") + fmt.Sprintf(siteEnvPathFmt, siteID)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	b.attachAuth(req)

	resp, err := b.http().Do(req)
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

// sortedKeys returns env's keys sorted — a deterministic flag order, so two
// builds of the same site produce identical nixpacks invocations.
func sortedKeys(env map[string]string) []string {
	keys := make([]string, 0, len(env))
	for k := range env {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}

// http returns the injected client, or a Timeout-bearing fallback (30s) so a
// hung control-plane connection can't freeze the claim/transition loop with
// no crash and no log — http.DefaultClient has Timeout 0 (no deadline).
func (b *Builder) http() *http.Client {
	if b.HTTPClient != nil {
		return b.HTTPClient
	}
	return &http.Client{Timeout: 30 * time.Second}
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
// its observed_epoch — both flow forward into the transition CAS — plus the
// claim envelope's optional `source` sibling (nil when the deployment carries
// an uploaded artifact instead).
type claimedDeployment struct {
	Deployment
	Epoch  int
	Source *BuildSource
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

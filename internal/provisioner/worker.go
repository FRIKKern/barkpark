// Package provisioner is the Go warm-pool worker that bridges the Elixir control
// plane to the cloud-6 WarmPool.Provision chain. It closes the ONE integration
// gap: /v1/launch + /v1/go-live pay and create a `provisioning` Barkpark row but
// do NOT provision — this worker does, by draining a provision_jobs queue.
//
// The flow is poll-based (no Oban, no websocket — YAGNI):
//
//	loop {
//	  POST /v1/internal/provision-jobs/claim   (Bearer WORKER_TOKEN)
//	  204 → nothing pending; sleep --interval, continue
//	  200 → a job: run WarmPool.Provision for {name,slug,region,server_type}
//	         on success → POST /v1/internal/provision-jobs/:id/succeed {ip}
//	         on error   → POST /v1/internal/provision-jobs/:id/fail    {error}
//	}
//
// Worker auth is a single shared secret WORKER_TOKEN, presented as
// `Authorization: Bearer <WORKER_TOKEN>` — a SEPARATE principal from the user
// session token and the agent token. The internal endpoints are NEVER
// user/agent-reachable (the Elixir require_worker pipeline 401s anything else).
//
// Everything external is INJECTED — HTTPClient (so tests point it at an
// httptest.Server) and Provision (so tests use the cloud-package FAKES) — so the
// whole RunOnce cycle runs with no live control plane and no real cloud spend.
package provisioner

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

// DefaultInterval is the claim-poll cadence when Worker.Interval is zero.
const DefaultInterval = 5 * time.Second

// DefaultProvisionTimeout bounds a single job's Provision when Worker.ProvisionTimeout
// is zero. A real provision SSHes into a fresh box, installs Caddy, migrates, and
// waits on the health gate — minutes, not seconds — but it MUST be bounded so one
// hung step (a dead SSH connection the keepalive missed, a wedged apt) fails the
// job and releases it via fail() instead of pinning the single-threaded worker
// forever.
const DefaultProvisionTimeout = 8 * time.Minute

// claimPath is the queue-drain endpoint; succeedPath/failPath are rendered
// per-job (they carry the job id). Poll-based by design — no streaming.
const (
	claimPath      = "/v1/internal/provision-jobs/claim"
	succeedPathFmt = "/v1/internal/provision-jobs/%s/succeed"
	failPathFmt    = "/v1/internal/provision-jobs/%s/fail"
)

// JobSpec is one claimed provision job as the control plane hands it back. It is
// the EXACT JSON the Elixir claim endpoint returns on 200 (a 204 means no
// pending job). region/server_type default to the warm-pool defaults (nbg1/
// cax11) on the Elixir side when the row didn't store them, so they arrive
// populated here — the worker does not re-default them.
type JobSpec struct {
	JobID      string `json:"job_id"`
	Name       string `json:"name"`
	Slug       string `json:"slug"`
	Region     string `json:"region"`
	ServerType string `json:"server_type"`
}

// ProvisionFunc runs the warm-pool provisioning for one claimed job and returns
// the live host IP. It is the injected seam: tests pass a fake that returns a
// deterministic IP (or an error) without touching a cloud; main() wires the real
// WarmPool.Provision over the real Hetzner provider/DNS. A non-nil error is the
// fail signal — the worker reports it to the control plane and moves on.
type ProvisionFunc func(ctx context.Context, spec JobSpec) (ip string, err error)

// Worker claims provision jobs from the control plane and runs each through the
// injected Provision. Everything it talks to is injected — HTTPClient (so tests
// use httptest), Provision (so tests use the cloud fakes) — so RunOnce runs with
// no live anything.
type Worker struct {
	// ControlURL is the control-plane origin (e.g. https://cloud.barkpark.dev).
	// Trailing slash is trimmed.
	ControlURL string
	// Token is the shared WORKER_TOKEN. Sent as `Authorization: Bearer <token>`
	// on every internal request — the separate worker principal.
	Token string
	// Interval is the claim-poll cadence for Run. Zero means DefaultInterval.
	Interval time.Duration
	// HTTPClient is the injected client. Zero value uses http.DefaultClient.
	HTTPClient *http.Client
	// Provision runs one job's warm-pool chain. MUST be set (RunOnce errors if
	// nil — there is no safe default that doesn't touch a real cloud).
	Provision ProvisionFunc
	// ProvisionTimeout bounds a single Provision call. Zero means
	// DefaultProvisionTimeout. When it fires, the job's ctx is cancelled — a
	// well-behaved Provision returns a (deadline-exceeded) error, which RunOnce
	// reports to /fail so the job is released for a later retry rather than
	// hanging the worker.
	ProvisionTimeout time.Duration
}

// httpClient returns the injected client or http.DefaultClient.
func (w *Worker) httpClient() *http.Client {
	if w.HTTPClient != nil {
		return w.HTTPClient
	}
	return http.DefaultClient
}

// RunOnce performs exactly one claim→provision→report cycle:
//
//  1. POST /v1/internal/provision-jobs/claim (Bearer WORKER_TOKEN).
//  2. 204 No Content → nothing pending; return (claimed=false), no provision.
//  3. 200 → a job: run Provision for {name,slug,region,server_type}.
//  4. on success → POST .../:id/succeed {ip}; the barkpark flips to up.
//  5. on error   → POST .../:id/fail   {error}; the barkpark stays provisioning.
//
// It returns claimed=true when a job was drained (whether it provisioned or
// failed-and-reported), and an error only for a transport/encoding fault or a
// misconfiguration (nil Provision, non-2xx claim). A provision FAILURE is NOT a
// RunOnce error — it is reported to the control plane and the cycle is a success
// (the job was handled). This mirrors the agent's "command failure rides back in
// the result, doesn't abort the cycle" contract.
func (w *Worker) RunOnce(ctx context.Context) (claimed bool, err error) {
	if w.Provision == nil {
		return false, fmt.Errorf("provisioner: a Provision func must be injected")
	}

	job, ok, err := w.claim(ctx)
	if err != nil {
		return false, fmt.Errorf("claim: %w", err)
	}
	if !ok {
		return false, nil // 204 — nothing pending.
	}

	// Bound the provision so one hung step fails the job instead of pinning the
	// single-threaded worker forever. On timeout the job ctx is cancelled and the
	// provision returns an error that flows to the fail() path below, releasing
	// the job for retry. (The one-shot provision cleans up its half-built box on
	// the cancelled ctx via a fresh teardown context.)
	pto := w.ProvisionTimeout
	if pto <= 0 {
		pto = DefaultProvisionTimeout
	}
	provCtx, cancel := context.WithTimeout(ctx, pto)
	ip, provErr := w.Provision(provCtx, job)
	cancel()
	if provErr != nil {
		// Report the failure; the barkpark stays in provisioning so a later
		// claim can retry it. A reporting transport error surfaces here.
		if rerr := w.fail(ctx, job.JobID, provErr.Error()); rerr != nil {
			return true, fmt.Errorf("report fail for job %s (provision error %v): %w", job.JobID, provErr, rerr)
		}
		return true, nil
	}

	if rerr := w.succeed(ctx, job.JobID, ip); rerr != nil {
		return true, fmt.Errorf("report succeed for job %s: %w", job.JobID, rerr)
	}
	return true, nil
}

// Run loops RunOnce until ctx is done, returning ctx.Err(). It sleeps Interval
// between cycles ONLY when a cycle drained nothing (204) — when a job was
// claimed it loops straight to the next claim so a backlog drains fast. A cycle
// error is non-fatal: the loop reports it via onCycle (nil-safe) and keeps
// going, so a transient control-plane blip doesn't kill the worker.
func (w *Worker) Run(ctx context.Context) error {
	return w.RunWith(ctx, nil)
}

// RunWith is Run with an onCycle hook fired after each cycle (nil-safe),
// carrying that cycle's (claimed, error) so a caller can log/observe without the
// provisioner package importing a logger. Used by main() for stderr logging and
// by tests to count cycles.
func (w *Worker) RunWith(ctx context.Context, onCycle func(claimed bool, err error)) error {
	interval := w.Interval
	if interval <= 0 {
		interval = DefaultInterval
	}

	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		default:
		}

		claimed, err := w.RunOnce(ctx)
		if onCycle != nil {
			onCycle(claimed, err)
		}

		// Only idle-sleep when there was nothing to do; a drained job loops
		// straight back to claim the next one.
		if !claimed {
			select {
			case <-ctx.Done():
				return ctx.Err()
			case <-time.After(interval):
			}
		}
	}
}

// claim POSTs the claim endpoint. A 200 decodes into a JobSpec (ok=true); a 204
// is the empty-queue signal (ok=false, no error). Any other status is an error.
func (w *Worker) claim(ctx context.Context) (JobSpec, bool, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, w.url(claimPath), nil)
	if err != nil {
		return JobSpec{}, false, err
	}
	w.authorize(req)

	resp, err := w.httpClient().Do(req)
	if err != nil {
		return JobSpec{}, false, err
	}
	defer resp.Body.Close()

	data, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))

	switch {
	case resp.StatusCode == http.StatusNoContent:
		return JobSpec{}, false, nil
	case resp.StatusCode < 200 || resp.StatusCode >= 300:
		return JobSpec{}, false, fmt.Errorf("POST %s: status %d: %s", claimPath, resp.StatusCode, truncate(string(data), 200))
	}

	var job JobSpec
	if len(bytes.TrimSpace(data)) > 0 {
		if err := json.Unmarshal(data, &job); err != nil {
			return JobSpec{}, false, fmt.Errorf("decode claim response: %w", err)
		}
	}
	if strings.TrimSpace(job.JobID) == "" {
		return JobSpec{}, false, fmt.Errorf("claim response missing job_id: %s", truncate(string(data), 200))
	}
	return job, true, nil
}

// succeed reports a provisioned host's IP, flipping the barkpark to up.
func (w *Worker) succeed(ctx context.Context, jobID, ip string) error {
	return w.postJSON(ctx, fmt.Sprintf(succeedPathFmt, jobID), map[string]string{"ip": ip})
}

// fail reports a provision failure; the barkpark stays provisioning for retry.
func (w *Worker) fail(ctx context.Context, jobID, errMsg string) error {
	return w.postJSON(ctx, fmt.Sprintf(failPathFmt, jobID), map[string]string{"error": errMsg})
}

// postJSON marshals body and POSTs it to ControlURL+path with the Bearer token,
// enforcing a 2xx response. The body is discarded (the contract returns
// {ok:true}); a non-2xx carries the truncated body for diagnosis.
func (w *Worker) postJSON(ctx context.Context, path string, body any) error {
	buf, err := json.Marshal(body)
	if err != nil {
		return fmt.Errorf("marshal: %w", err)
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, w.url(path), bytes.NewReader(buf))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	w.authorize(req)

	resp, err := w.httpClient().Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	data, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("POST %s: status %d: %s", path, resp.StatusCode, truncate(string(data), 200))
	}
	return nil
}

// authorize attaches the shared WORKER_TOKEN bearer (when set).
func (w *Worker) authorize(req *http.Request) {
	if w.Token != "" {
		req.Header.Set("Authorization", "Bearer "+w.Token)
	}
}

// url joins the trimmed ControlURL with path.
func (w *Worker) url(path string) string {
	return strings.TrimRight(w.ControlURL, "/") + path
}

// truncate caps s at n runes for error messages.
func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "…"
}

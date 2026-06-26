package agent

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

// DefaultInterval is the report+poll cadence when Agent.Interval is zero.
const DefaultInterval = 60 * time.Second

// reportPath / commandsPath / resultsPath are the control-plane endpoints. The
// agent POSTs a report, GETs the approved-command queue, runs the allowlisted
// ones, and POSTs results back. Poll-based by design — no websocket/streaming.
const (
	reportPath   = "/v1/agent/report"
	commandsPath = "/v1/agent/commands"
	resultsPath  = "/v1/agent/results"
)

// Agent reports health/status to the control plane and runs approved commands
// from its poll-based queue. Everything it talks to is injected — HTTPClient
// (so tests point it at an httptest.Server), Runner (so tests use a fake that
// never shells out), and ReportConfig's probes — so the entire cycle runs with
// no live control plane and no real systemctl.
type Agent struct {
	// ControlURL is the control-plane origin (e.g. https://cloud.barkpark.dev).
	// Trailing slash is trimmed.
	ControlURL string
	// Token is the agent bearer token (cloud-9 mint_agent_token plaintext). Sent
	// as `Authorization: Bearer <token>` on every request.
	Token string
	// Interval is the report+poll cadence for Run. Zero means DefaultInterval.
	Interval time.Duration
	// HTTPClient is the injected client. Zero value uses http.DefaultClient.
	HTTPClient *http.Client
	// Runner runs approved commands (and backs the git report probe). Zero value
	// uses ExecRunner (real shell-out) — tests inject a fake.
	Runner CommandRunner
	// ReportProbes wires gatherReport's injected probes (git checkout, disk, PG
	// size, backup, health gate). Its Runner is defaulted to Agent.Runner when
	// left nil so the two stay consistent.
	ReportProbes ReportConfig
}

// httpClient returns the injected client or http.DefaultClient.
func (a *Agent) httpClient() *http.Client {
	if a.HTTPClient != nil {
		return a.HTTPClient
	}
	return http.DefaultClient
}

// runner returns the injected runner or the real ExecRunner.
func (a *Agent) runner() CommandRunner {
	if a.Runner != nil {
		return a.Runner
	}
	return ExecRunner{}
}

// RunOnce performs exactly one report+poll cycle:
//
//  1. gather the report from the wired probes,
//  2. POST it to /v1/agent/report (Bearer agent-token),
//  3. GET /v1/agent/commands,
//  4. run each APPROVED command via the runner (rejecting the rest), and
//  5. POST the results to /v1/agent/results.
//
// It returns the first transport/encoding error; a single command failing does
// NOT abort the cycle (its error rides back in the CommandResult). With no
// commands queued, steps 4-5 are a no-op and RunOnce still succeeds.
func (a *Agent) RunOnce(ctx context.Context) error {
	probes := a.ReportProbes
	if probes.Runner == nil {
		probes.Runner = a.runner()
	}
	report := gatherReport(probes)

	if err := a.postJSON(ctx, reportPath, report, nil); err != nil {
		return fmt.Errorf("post report: %w", err)
	}

	var cmds []Command
	if err := a.getJSON(ctx, commandsPath, &cmds); err != nil {
		return fmt.Errorf("get commands: %w", err)
	}
	if len(cmds) == 0 {
		return nil
	}

	results := make([]CommandResult, 0, len(cmds))
	for _, cmd := range cmds {
		results = append(results, runCommand(a.runner(), cmd))
	}

	if err := a.postJSON(ctx, resultsPath, results, nil); err != nil {
		return fmt.Errorf("post results: %w", err)
	}
	return nil
}

// Run loops RunOnce on Interval until ctx is done, returning ctx.Err(). A cycle
// error is non-fatal — the loop logs nothing here (the caller decides) and keeps
// going, so a transient control-plane blip doesn't kill the agent. The first
// cycle fires immediately, not after one Interval.
func (a *Agent) Run(ctx context.Context) error {
	return a.RunWith(ctx, nil)
}

// RunWith is Run with an onCycle hook fired after each cycle (nil-safe),
// carrying that cycle's error so a caller can log/observe without the agent
// package importing a logger. Used by main() for stderr logging and by tests to
// count cycles.
func (a *Agent) RunWith(ctx context.Context, onCycle func(error)) error {
	interval := a.Interval
	if interval <= 0 {
		interval = DefaultInterval
	}

	// Fire immediately, then on each tick.
	if err := a.RunOnce(ctx); err != nil && onCycle != nil {
		onCycle(err)
	} else if onCycle != nil {
		onCycle(nil)
	}

	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-ticker.C:
			err := a.RunOnce(ctx)
			if onCycle != nil {
				onCycle(err)
			}
		}
	}
}

// postJSON marshals body to JSON and POSTs it to ControlURL+path with the Bearer
// token. When out is non-nil the response body is decoded into it. A non-2xx
// status is an error carrying the (truncated) body for diagnosis.
func (a *Agent) postJSON(ctx context.Context, path string, body, out any) error {
	buf, err := json.Marshal(body)
	if err != nil {
		return fmt.Errorf("marshal: %w", err)
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, a.url(path), bytes.NewReader(buf))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	a.authorize(req)
	return a.do(req, out)
}

// getJSON GETs ControlURL+path with the Bearer token and decodes the response
// into out.
func (a *Agent) getJSON(ctx context.Context, path string, out any) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, a.url(path), nil)
	if err != nil {
		return err
	}
	a.authorize(req)
	return a.do(req, out)
}

// authorize attaches the agent bearer token (when set).
func (a *Agent) authorize(req *http.Request) {
	if a.Token != "" {
		req.Header.Set("Authorization", "Bearer "+a.Token)
	}
}

// url joins the trimmed ControlURL with path.
func (a *Agent) url(path string) string {
	return strings.TrimRight(a.ControlURL, "/") + path
}

// do executes req, enforces a 2xx status, and decodes the body into out when
// non-nil. An empty 2xx body with a non-nil out is tolerated (out unchanged).
func (a *Agent) do(req *http.Request, out any) error {
	resp, err := a.httpClient().Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	data, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("%s %s: status %d: %s", req.Method, req.URL.Path, resp.StatusCode, truncate(string(data), 200))
	}
	if out != nil && len(bytes.TrimSpace(data)) > 0 {
		if err := json.Unmarshal(data, out); err != nil {
			return fmt.Errorf("decode %s response: %w", req.URL.Path, err)
		}
	}
	return nil
}

// truncate caps s at n runes for error messages.
func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "…"
}

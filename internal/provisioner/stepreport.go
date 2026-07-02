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

// stepPathFmt is the internal endpoint the worker POSTs each provision step
// transition to (dwb-14). Rendered per-job (it carries the job id).
const stepPathFmt = "/v1/internal/provision-jobs/%s/step"

// defaultStepReportTimeout bounds a single step-report POST. Kept TIGHT: a step
// report sits on the provision hot path (fired synchronously at a phase
// boundary), so a slow/unreachable control plane must not add real latency to a
// go-live. If the control plane is down the provision is doomed anyway (its
// succeed/fail report won't land either), so a short timeout that gives up fast
// is the honest behaviour — narration is telemetry, never control flow.
const defaultStepReportTimeout = 5 * time.Second

// HTTPStepReporter is the production step reporter (dwb-14): it POSTs a coarse
// step transition to the control plane's internal endpoint with the shared
// WORKER_TOKEN. It is wired onto Seams.StepReporter in main(); ProvisionWith
// swallows its error so a report failure NEVER fails the provision.
type HTTPStepReporter struct {
	// ControlURL is the control-plane origin (trailing slash trimmed).
	ControlURL string
	// Token is the shared WORKER_TOKEN, sent as `Authorization: Bearer <token>`.
	Token string
	// HTTPClient is the injected client. nil → a client with defaultStepReportTimeout.
	HTTPClient *http.Client
}

func (r *HTTPStepReporter) httpClient() *http.Client {
	if r.HTTPClient != nil {
		return r.HTTPClient
	}
	return &http.Client{Timeout: defaultStepReportTimeout}
}

// Report POSTs one step transition for jobID. It matches the
// Seams.StepReporter signature so it can be wired directly. A non-2xx or
// transport error is returned to the caller (which logs + continues); it is
// never retried here — a late/dropped step is a harmless gap in narration, not a
// lost job outcome.
func (r *HTTPStepReporter) Report(ctx context.Context, jobID, step, status, detail string) error {
	body := map[string]any{"step": step, "status": status}
	if detail != "" {
		body["detail"] = detail
	}
	buf, err := json.Marshal(body)
	if err != nil {
		return fmt.Errorf("marshal step: %w", err)
	}
	url := strings.TrimRight(r.ControlURL, "/") + fmt.Sprintf(stepPathFmt, jobID)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(buf))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	if r.Token != "" {
		req.Header.Set("Authorization", "Bearer "+r.Token)
	}

	resp, err := r.httpClient().Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	data, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<16))
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("POST %s: status %d: %s", fmt.Sprintf(stepPathFmt, jobID), resp.StatusCode, truncate(string(data), 200))
	}
	return nil
}

package provisioner

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"regexp"
	"strings"
	"time"
)

// consolePathFmt is the internal endpoint the worker POSTs each console
// narration line to (dwb-16). Rendered per-job (it carries the job id). The
// control plane appends the line (capped, append-only) to the job row and
// broadcasts it so the /new progress screen renders a LIVE console.
const consolePathFmt = "/v1/internal/provision-jobs/%s/console"

// defaultConsoleReportTimeout bounds a single console-line POST. Same rationale
// as the step reporter: a console line sits near the provision hot path and is
// PURE TELEMETRY, so a slow/unreachable control plane must give up fast and
// never add latency to a go-live. If the control plane is down the provision is
// doomed anyway; dropping a console line is a harmless gap in narration.
const defaultConsoleReportTimeout = 5 * time.Second

// ConsoleReporter reports one console narration LINE for jobID to the control
// plane (dwb-16). It is the injected seam ProvisionWith tees the create→live
// chain + bootstrap narration to. PURE TELEMETRY: the consoleEmitter swallows
// its error (logging to stderr), so a console-report failure NEVER fails a
// provision. nil (tests, an old wiring) disables console reporting silently.
type ConsoleReporter func(ctx context.Context, jobID, line string) error

// HTTPConsoleReporter is the production console reporter: it POSTs one console
// line to the control plane's internal endpoint with the shared WORKER_TOKEN. It
// is wired onto Seams.ConsoleReporter in main(); the emitter swallows its error
// so a report failure is a narration gap, never a lost provision.
type HTTPConsoleReporter struct {
	// ControlURL is the control-plane origin (trailing slash trimmed).
	ControlURL string
	// Token is the shared WORKER_TOKEN, sent as `Authorization: Bearer <token>`.
	Token string
	// HTTPClient is the injected client. nil → a client with defaultConsoleReportTimeout.
	HTTPClient *http.Client
}

func (r *HTTPConsoleReporter) httpClient() *http.Client {
	if r.HTTPClient != nil {
		return r.HTTPClient
	}
	return &http.Client{Timeout: defaultConsoleReportTimeout}
}

// Report POSTs one console line for jobID. It matches the ConsoleReporter
// signature so it can be wired directly. A non-2xx or transport error is
// returned to the caller (the emitter logs + continues); it is never retried
// here — a dropped console line is a harmless narration gap, not a lost outcome.
func (r *HTTPConsoleReporter) Report(ctx context.Context, jobID, line string) error {
	buf, err := json.Marshal(map[string]any{"line": line})
	if err != nil {
		return fmt.Errorf("marshal console line: %w", err)
	}
	url := strings.TrimRight(r.ControlURL, "/") + fmt.Sprintf(consolePathFmt, jobID)
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
		return fmt.Errorf("POST %s: status %d: %s", fmt.Sprintf(consolePathFmt, jobID), resp.StatusCode, truncate(string(data), 200))
	}
	return nil
}

// adminTokenRe matches a minted per-instance admin bearer (bp_admin_…). It is
// the PATTERN half of the console redaction — belt-and-suspenders on top of the
// literal admin-token scrub the emitter registers once the chain surfaces the
// real value, so a console line can never carry one even if a narration string
// ever formats it.
var adminTokenRe = regexp.MustCompile(`bp_admin_[A-Za-z0-9_-]+`)

// envSecretConsoleRe redacts secret-SHAPED env assignments the SAME way the SSH
// runner's scrubEnvSecrets does — a defense-in-depth pass so a stray narration
// line that echoes a /opt/barkpark/.env value never lands in the persisted /
// streamed console.
var envSecretConsoleRe = regexp.MustCompile(`(SECRET_KEY_BASE|BARKPARK_CLOAK_KEY|PREVIEW_JWT_SECRET|DATABASE_URL)=\S+`)

// redactConsoleLine scrubs a console line before it leaves the worker: the
// literal secrets the caller registered (the KNOWN minted admin token — the same
// literal-substring redaction the cloud runner applies) PLUS the admin-token +
// env-secret PATTERNS. Console narration REUSES the redaction posture and never
// bypasses it.
func redactConsoleLine(line string, secrets []string) string {
	for _, s := range secrets {
		if s != "" {
			line = strings.ReplaceAll(line, s, "[REDACTED]")
		}
	}
	line = adminTokenRe.ReplaceAllString(line, "[REDACTED]")
	line = envSecretConsoleRe.ReplaceAllStringFunc(line, func(m string) string {
		key := m[:strings.IndexByte(m, '=')]
		return key + "=[REDACTED]"
	})
	return line
}

// consoleEmitter tees the create→live + bootstrap narration to the control plane
// as console lines (dwb-16), bound to ONE job. It is best-effort: a report error
// is logged to stderr and SWALLOWED, so console narration is telemetry and NEVER
// fails a provision. A nil report (tests, an old wiring) makes logf a silent
// no-op. It is single-goroutine by construction (the provision chain narrates
// sequentially), so no locking on `secrets`.
type consoleEmitter struct {
	ctx     context.Context
	jobID   string
	report  ConsoleReporter
	secrets []string
}

// newConsoleEmitter binds an emitter to ctx + jobID + the injected reporter.
func newConsoleEmitter(ctx context.Context, jobID string, report ConsoleReporter) *consoleEmitter {
	return &consoleEmitter{ctx: ctx, jobID: jobID, report: report}
}

// addSecret registers a literal secret (the minted admin token) to scrub from
// every SUBSEQUENT console line — reusing the cloud runner's literal-redaction
// approach for the value the worker actually knows. Empty is ignored. nil-safe.
func (c *consoleEmitter) addSecret(s string) {
	if c != nil && s != "" {
		c.secrets = append(c.secrets, s)
	}
}

// logf formats + redacts one console line and reports it best-effort. A report
// error is logged to stderr and swallowed — console narration must never fail a
// provision. nil-safe (no reporter → no-op).
func (c *consoleEmitter) logf(format string, args ...any) {
	if c == nil || c.report == nil {
		return
	}
	line := redactConsoleLine(fmt.Sprintf(format, args...), c.secrets)
	if err := c.report(c.ctx, c.jobID, line); err != nil {
		fmt.Fprintf(os.Stderr, "barkpark-provisioner: console report for job %s failed (non-fatal): %v\n", c.jobID, err)
	}
}

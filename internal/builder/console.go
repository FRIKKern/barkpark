package builder

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

// consolePathFmt is the builder endpoint each build-console narration line is
// POSTed to (gh-5). Rendered per-deployment (it carries the deployment id). The
// control plane appends the line (capped, append-only) to the deployment row and
// broadcasts a "deployments" event so the site-detail deploy row renders a LIVE
// build console.
const consolePathFmt = "/v1/builder/deployments/%s/console"

// defaultConsoleReportTimeout bounds a single console-line POST so a slow or
// unreachable control plane can never add latency to (or wedge) a build. Console
// narration is PURE TELEMETRY: if the control plane is down the build's
// transition report is doomed anyway, and dropping a console line is a harmless
// narration gap.
const defaultConsoleReportTimeout = 5 * time.Second

// buildConsole tees the build narration (claim → fetch source → build →
// artifact → activate) to the control plane as console lines (gh-5), bound to
// ONE deployment. It is the deploy-side twin of the provisioner's consoleEmitter.
// BEST-EFFORT: a report error is logged to stderr and SWALLOWED, so console
// narration NEVER fails a build. A nil buildConsole (an old wiring) makes every
// method a silent no-op. Single-goroutine by construction (the build narrates
// sequentially), so no locking on `secrets`.
type buildConsole struct {
	b       *Builder
	ctx     context.Context
	depID   string
	secrets []string
}

// newBuildConsole binds a console to ctx + the deployment id + this builder
// (whose ControlURL / Token / HTTPClient the reporter reuses).
func (b *Builder) newBuildConsole(ctx context.Context, deploymentID string) *buildConsole {
	return &buildConsole{b: b, ctx: ctx, depID: deploymentID}
}

// addSecret registers a literal secret to scrub from every SUBSEQUENT console
// line (the same literal-redaction posture the provisioner console uses). Empty
// is ignored. nil-safe.
func (c *buildConsole) addSecret(s string) {
	if c != nil && s != "" {
		c.secrets = append(c.secrets, s)
	}
}

// logf formats + redacts one console line and reports it best-effort. A report
// error is logged to stderr and swallowed — narration must never fail a build.
// nil-safe.
func (c *buildConsole) logf(format string, args ...any) {
	if c == nil {
		return
	}
	line := redactBuildLine(fmt.Sprintf(format, args...), c.secrets)
	if err := c.report(line); err != nil {
		fmt.Fprintf(os.Stderr, "barkpark-builder: console report for deployment %s failed (non-fatal): %v\n", c.depID, err)
	}
}

// report POSTs one console line for the bound deployment. Non-2xx / transport
// errors are returned to logf (which logs + continues); it is never retried — a
// dropped line is a narration gap, not a lost build outcome.
func (c *buildConsole) report(line string) error {
	buf, err := json.Marshal(map[string]any{"line": line})
	if err != nil {
		return fmt.Errorf("marshal console line: %w", err)
	}
	url := strings.TrimRight(c.b.ControlURL, "/") + fmt.Sprintf(consolePathFmt, c.depID)
	req, err := http.NewRequestWithContext(c.ctx, http.MethodPost, url, bytes.NewReader(buf))
	if err != nil {
		return err
	}
	c.b.attachAuth(req)
	req.Header.Set("Content-Type", "application/json")

	resp, err := c.client().Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	data, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<16))
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("POST %s: status %d: %s", fmt.Sprintf(consolePathFmt, c.depID), resp.StatusCode, strings.TrimSpace(string(data)))
	}
	return nil
}

// client reuses the injected HTTPClient (tests point it at their httptest
// server) or, in production (nil), a client with a short timeout so a wedged
// control plane can't stall the build on a best-effort console POST.
func (c *buildConsole) client() *http.Client {
	if c.b.HTTPClient != nil {
		return c.b.HTTPClient
	}
	return &http.Client{Timeout: defaultConsoleReportTimeout}
}

// --- redaction ---------------------------------------------------------------

// builderBearerRe scrubs an `Authorization: Bearer <token>` / bare `Bearer
// <token>` that a verbose build tool might echo.
var builderBearerRe = regexp.MustCompile(`(?i)bearer\s+\S+`)

// builderTokenRe scrubs a Barkpark-shaped bearer (bp_admin_…, bp_read_…, …) —
// belt-and-suspenders on top of the literal-secret scrub.
var builderTokenRe = regexp.MustCompile(`bp_[a-z]+_[A-Za-z0-9_-]+`)

// builderEnvSecretRe redacts the VALUE of a secret-SHAPED uppercase env
// assignment (FOO_SECRET=…, API_TOKEN=…, DATABASE_URL=…, *_PASSWORD=…, *_KEY=…)
// a build step might print — the key is kept, the value scrubbed. Uppercase-only
// so it never mangles ordinary prose. Nixpacks/Docker build env is arbitrary
// per-project, so this is broader than the provisioner's fixed key list.
var builderEnvSecretRe = regexp.MustCompile(`\b([A-Z0-9_]*(?:SECRET|TOKEN|PASSWORD|PASSWD|APIKEY|API_KEY|PRIVATE_KEY|DATABASE_URL|KEY)[A-Z0-9_]*)=(\S+)`)

// redactBuildLine scrubs a console line before it leaves the builder: the
// literal secrets the caller registered, then the Barkpark-token, Bearer, and
// env-secret PATTERNS. Console narration REUSES the redaction posture and never
// bypasses it.
func redactBuildLine(line string, secrets []string) string {
	for _, s := range secrets {
		if s != "" {
			line = strings.ReplaceAll(line, s, "[REDACTED]")
		}
	}
	line = builderBearerRe.ReplaceAllString(line, "Bearer [REDACTED]")
	line = builderTokenRe.ReplaceAllString(line, "[REDACTED]")
	line = builderEnvSecretRe.ReplaceAllString(line, "$1=[REDACTED]")
	return line
}

// --- command-output tee ------------------------------------------------------

// consoleTee wraps the per-deployment log file: bytes pass through to the log
// unchanged, and each COMPLETE line is ALSO mirrored to the build console
// (redacted, best-effort). A partial trailing line is buffered until its newline
// arrives; flush() emits any leftover at the end of a command. This is what
// streams the real nixpacks / docker output line-by-line into the live console.
type consoleTee struct {
	w   io.Writer // the underlying build-log file (source of truth)
	c   *buildConsole
	buf []byte
}

func (t *consoleTee) Write(p []byte) (int, error) {
	// Write through to the log file FIRST — the console is a best-effort mirror,
	// never a gate on the durable log.
	n, err := t.w.Write(p)
	if n > 0 {
		t.buf = append(t.buf, p[:n]...)
		for {
			i := bytes.IndexByte(t.buf, '\n')
			if i < 0 {
				break
			}
			line := string(t.buf[:i])
			t.buf = t.buf[i+1:]
			t.emit(line)
		}
	}
	return n, err
}

// flush emits any buffered partial (newline-less) trailing line — called after a
// command finishes so the last line isn't swallowed.
func (t *consoleTee) flush() {
	if len(t.buf) > 0 {
		line := string(t.buf)
		t.buf = nil
		t.emit(line)
	}
}

func (t *consoleTee) emit(line string) {
	line = strings.TrimRight(line, "\r")
	if strings.TrimSpace(line) == "" {
		return
	}
	t.c.logf("%s", line)
}

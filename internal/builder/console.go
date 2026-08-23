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
	"sync"
	"time"
)

// consolePathFmt is the builder endpoint each build-console narration line is
// POSTed to (gh-5). Rendered per-deployment (it carries the deployment id). The
// control plane appends the line (capped, append-only) to the deployment row and
// broadcasts a "deployments" event so the site-detail deploy row renders a LIVE
// build console.
const consolePathFmt = "/v1/builder/deployments/%s/console"

// detailPathFmt is the builder endpoint the LIVE sub-caption is POSTed to
// (dwb-19). Rendered per-deployment. Unlike the append-only console, the control
// plane SETS the deployment's `detail` (latest-wins) and broadcasts
// "deployments" so the site-detail deploy row renders the caption under the
// status pill. Best-effort telemetry — the build-side twin of a provision step's
// `progress`.
const detailPathFmt = "/v1/builder/deployments/%s/detail"

// defaultConsoleReportTimeout bounds a single console-line POST so a slow or
// unreachable control plane can never add latency to (or wedge) a build. Console
// narration is PURE TELEMETRY: if the control plane is down the build's
// transition report is doomed anyway, and dropping a console line is a harmless
// narration gap.
const defaultConsoleReportTimeout = 5 * time.Second

// maxConsoleFails is how many CONSECUTIVE report failures latch console
// narration off for the rest of the build. Console lines are pure telemetry, so
// once the control plane is clearly down, POSTing each of a build's hundreds of
// lines into a full defaultConsoleReportTimeout of serialized latency is pure
// waste — and enough of it can trip the stale-deployment reaper on a build that
// IS progressing. A single success resets the counter.
const maxConsoleFails = 3

// buildConsole tees the build narration (claim → fetch source → build →
// artifact → activate) to the control plane as console lines (gh-5), bound to
// ONE deployment. It is the deploy-side twin of the provisioner's consoleEmitter.
// BEST-EFFORT: a report error is logged to stderr and SWALLOWED, so console
// narration NEVER fails a build. A nil buildConsole (an old wiring) makes every
// method a silent no-op. `secrets` is registered only from phase code (the build
// narrates sequentially) so it needs no locking; `fails` IS guarded by `mu`
// because the tee mirror narrates from the command-copy goroutine.
type buildConsole struct {
	b       *Builder
	ctx     context.Context
	depID   string
	secrets []string

	mu    sync.Mutex // guards fails (logf runs from phase code AND the tee goroutine)
	fails int        // consecutive report() failures; >= maxConsoleFails latches narration off
	// everLatched records that the latch FIRED at least once this build — even
	// if a later success reset `fails`, lines were dropped in the gap. Until
	// dr-bl-builder-console-narration-latch this fact lived only on the
	// builder's stderr, so a build whose console latched was byte-
	// indistinguishable from a build that was merely quiet — a reader calling
	// a truncated console "the whole build" had no way to know otherwise.
	everLatched bool
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
// After maxConsoleFails consecutive failures the POST is skipped entirely (the
// control plane is down; the line still lives in the durable log), so a wedged
// control plane can't serialize a full timeout per line across a whole build. A
// success resets the latch. nil-safe.
func (c *buildConsole) logf(format string, args ...any) {
	if c == nil {
		return
	}
	line := redactBuildLine(fmt.Sprintf(format, args...), c.secrets)

	c.mu.Lock()
	latched := c.fails >= maxConsoleFails
	c.mu.Unlock()
	if latched {
		return
	}

	if err := c.report(line); err != nil {
		c.mu.Lock()
		c.fails++
		firstLatch := c.fails == maxConsoleFails
		if firstLatch {
			c.everLatched = true
		}
		c.mu.Unlock()
		fmt.Fprintf(os.Stderr, "barkpark-builder: console report for deployment %s failed (non-fatal): %v\n", c.depID, err)
		if firstLatch {
			fmt.Fprintf(os.Stderr, "barkpark-builder: console narration for deployment %s disabled for the rest of the build after %d consecutive failures\n", c.depID, maxConsoleFails)
		}
		return
	}
	c.mu.Lock()
	c.fails = 0
	c.mu.Unlock()
}

// logfTerminal formats + redacts one TERMINAL console line (the failed:/
// activate: outcome) and reports it with ONE attempt that BYPASSES the latch —
// and, when the latch ever fired this build, precedes it with an explicit
// truncation marker so the console says it is not the whole story.
//
// WHY THE BYPASS IS SAFE where per-line bypassing was not: the latch exists
// because POSTing hundreds of mid-build lines into a wedged control plane
// serializes a timeout per line and can trip the stale-deployment reaper. The
// terminal line is ONE line (two with the marker) at the very END of the
// build, after which nothing waits on the console — worst case it costs two
// bounded timeouts and changes nothing. And the wave-33 measurement says the
// control plane is usually BACK by build end (every BOX_UNREACHABLE episode
// self-healed, median 1 row): the latch that saved the middle of the build
// would otherwise eat the one line a reader needs most, which is the FOURTH
// silent discard this file used to perform.
//
// A build whose console latched is therefore READABLE AS TRUNCATED: the marker
// names the drop and points at the durable log, so "no failed:/activate: line
// and no marker" stops being ambiguous between quiet and cut. nil-safe.
func (c *buildConsole) logfTerminal(format string, args ...any) {
	if c == nil {
		return
	}
	c.mu.Lock()
	latched := c.everLatched
	c.mu.Unlock()
	if latched {
		// Best-effort, deliberately unlatched: if the plane is still down this
		// fails like any other line and the durable log remains the record.
		if err := c.report("console TRUNCATED: narration was disabled mid-build after " +
			fmt.Sprint(maxConsoleFails) + " consecutive failed reports — the lines above are NOT the whole build; the durable build log is"); err != nil {
			fmt.Fprintf(os.Stderr, "barkpark-builder: truncation marker for deployment %s failed (non-fatal): %v\n", c.depID, err)
		}
	}
	line := redactBuildLine(fmt.Sprintf(format, args...), c.secrets)
	if err := c.report(line); err != nil {
		fmt.Fprintf(os.Stderr, "barkpark-builder: terminal console report for deployment %s failed (non-fatal): %v\n", c.depID, err)
		return
	}
	c.mu.Lock()
	c.fails = 0
	c.mu.Unlock()
}

// caption formats + redacts one CURATED plain-language sub-caption and SETS it
// as the deployment's live `detail` (latest-wins), best-effort (dwb-19). A
// report error is logged to stderr and swallowed — a caption must never fail a
// build. Captions are short human copy (repo, branch, phase), never raw output.
// nil-safe. Shares the console's failure latch: once the control plane is down,
// captions stop POSTing too.
func (c *buildConsole) caption(format string, args ...any) {
	if c == nil {
		return
	}
	line := redactBuildLine(fmt.Sprintf(format, args...), c.secrets)

	c.mu.Lock()
	latched := c.fails >= maxConsoleFails
	c.mu.Unlock()
	if latched {
		return
	}

	if err := c.reportDetail(line); err != nil {
		c.mu.Lock()
		c.fails++
		if c.fails >= maxConsoleFails {
			c.everLatched = true
		}
		c.mu.Unlock()
		fmt.Fprintf(os.Stderr, "barkpark-builder: caption report for deployment %s failed (non-fatal): %v\n", c.depID, err)
		return
	}
	c.mu.Lock()
	c.fails = 0
	c.mu.Unlock()
}

// reportDetail POSTs one sub-caption for the bound deployment (dwb-19). Non-2xx /
// transport errors are returned to caption (which logs + continues); never
// retried — a dropped caption is a narration gap, not a lost build outcome.
func (c *buildConsole) reportDetail(detail string) error {
	buf, err := json.Marshal(map[string]any{"detail": detail})
	if err != nil {
		return fmt.Errorf("marshal caption: %w", err)
	}
	url := strings.TrimRight(c.b.ControlURL, "/") + fmt.Sprintf(detailPathFmt, c.depID)
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
		return fmt.Errorf("POST %s: status %d: %s", fmt.Sprintf(detailPathFmt, c.depID), resp.StatusCode, strings.TrimSpace(string(data)))
	}
	return nil
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

// maxConsoleLineBytes bounds the partial-line buffer. Docker/nixpacks progress
// bars redraw with '\r' and never emit a '\n', and a hostile repo can print one
// endless newline-less line (`yes | tr -d '\n'`); without a cap t.buf would grow
// unbounded and OOM the shared builder that serves every tenant. The server-side
// display caps (2KB / 300 lines) don't protect the worker's memory.
const maxConsoleLineBytes = 64 << 10

// consoleTee wraps the per-deployment log file: bytes pass through to the log
// unchanged, and each COMPLETE line is ALSO mirrored to the build console
// (redacted, best-effort). A partial trailing line is buffered until its newline
// arrives; flush() emits any leftover at the end of a command. This is what
// streams the real nixpacks / docker output line-by-line into the live console.
// The partial-line buffer is bounded at maxConsoleLineBytes — a newline-less
// flood force-emits its prefix rather than growing t.buf without limit.
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
		// Bound the newline-less remainder: force-emit the long prefix (the server
		// caps console display at 2000 chars, so this is harmless) and reset. Every
		// byte already reached the durable log via the write-through above, so no
		// output is lost — only the in-memory buffer is capped.
		if len(t.buf) > maxConsoleLineBytes {
			t.emit(string(t.buf))
			t.buf = t.buf[:0]
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

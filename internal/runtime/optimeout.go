package runtime

import (
	"context"
	"fmt"
	"io"
	"sync"
	"time"
)

// Per-operation subprocess timeouts.
//
// Every `docker` and `caddy` subprocess the executor shells out to used to run
// on the AMBIENT context — the one handed to RunOnce — which in production is
// the process-lifetime context of the agent loop and therefore has no deadline
// at all. A wedged docker daemon or a hung `caddy reload` hung the executor
// forever, and it hung it DURING the blue/green cutover: the green container is
// already running, the Caddyfile is already rewritten, and the deployment row
// is stuck mid-transition with no failure_reason, because the code that would
// have written one never got control back.
//
// Every subprocess now runs under its own bounded child context, and the error
// a blown budget produces NAMES the operation. "context deadline exceeded" with
// no subject is what makes these incidents take an hour; `caddy reload timed
// out after 30s` does not.

// Operation names carried by OpTimeoutError. These are the strings an operator
// reads out of a failure_reason, so they are the literal command shape, not an
// internal identifier.
const (
	OpDockerLoad    = "docker load"
	OpDockerRun     = "docker run"
	OpDockerRemove  = "docker rm -f"
	OpDockerImageRm = "docker image rm"
	OpDockerQuery   = "docker query"
	OpBuilderPrune  = "docker builder prune"
	OpCaddyReload   = "caddy reload"
	OpDrain         = "drain"
)

// Default per-operation budgets. They differ because the operations differ:
// a read-only `docker ps` that has not answered in 30s is a wedged daemon,
// while `docker load` of a multi-hundred-megabyte image tar off an NFS cache
// legitimately takes minutes. The two cutover-critical ones (caddy reload and
// the drain) are deliberately the tightest of the mutating set — they run
// AFTER the green container is serving, so spending minutes there buys
// nothing and costs the whole deploy loop.
const (
	// DefaultDockerLoadTimeout bounds `docker load -i <tar>`. Sized for a
	// large image tar read off a shared/NFS builder cache.
	DefaultDockerLoadTimeout = 10 * time.Minute

	// DefaultDockerRunTimeout bounds `docker run -d`. Detached, so this is
	// container creation only — not the app's startup, which healthCheck
	// covers under HealthTimeout.
	DefaultDockerRunTimeout = 2 * time.Minute

	// DefaultDockerRemoveTimeout bounds `docker rm -f` / `docker image rm`.
	// `rm -f` on a running container implies a stop, hence a minute rather
	// than a query budget.
	DefaultDockerRemoveTimeout = 1 * time.Minute

	// DefaultDockerQueryTimeout bounds the read-only sweeps (`docker ps`,
	// `docker image inspect`). These are local daemon queries; 30s without an
	// answer already means the daemon is wedged.
	DefaultDockerQueryTimeout = 30 * time.Second

	// DefaultCaddyReloadTimeout bounds `caddy reload`. Cutover-critical: this
	// is the step that repoints live traffic, and a config reload that has not
	// returned in 30s is not going to.
	DefaultCaddyReloadTimeout = 30 * time.Second

	// DefaultDrainTimeout bounds the best-effort blue drain, whose inner
	// `docker stop -t 5` grants each container a 5s SIGTERM grace. A minute
	// covers a handful of containers; past that the drain is abandoned with a
	// warning and the deploy proceeds.
	DefaultDrainTimeout = 1 * time.Minute

	// DefaultBuilderPruneTimeout bounds `docker builder prune`, which walks
	// and deletes a BuildKit cache that can be tens of gigabytes.
	DefaultBuilderPruneTimeout = 10 * time.Minute
)

// OpTimeouts overrides the per-operation subprocess budgets. A zero field
// takes its Default… constant, so the zero OpTimeouts is the production
// configuration and a test can tighten exactly the one budget it exercises.
type OpTimeouts struct {
	DockerLoad   time.Duration
	DockerRun    time.Duration
	DockerRemove time.Duration
	DockerQuery  time.Duration
	CaddyReload  time.Duration
	Drain        time.Duration
	BuilderPrune time.Duration
}

func pick(v, def time.Duration) time.Duration {
	if v > 0 {
		return v
	}
	return def
}

func (t OpTimeouts) dockerLoad() time.Duration { return pick(t.DockerLoad, DefaultDockerLoadTimeout) }
func (t OpTimeouts) dockerRun() time.Duration  { return pick(t.DockerRun, DefaultDockerRunTimeout) }
func (t OpTimeouts) dockerQuery() time.Duration {
	return pick(t.DockerQuery, DefaultDockerQueryTimeout)
}
func (t OpTimeouts) caddyReload() time.Duration {
	return pick(t.CaddyReload, DefaultCaddyReloadTimeout)
}
func (t OpTimeouts) drain() time.Duration { return pick(t.Drain, DefaultDrainTimeout) }
func (t OpTimeouts) builderPrune() time.Duration {
	return pick(t.BuilderPrune, DefaultBuilderPruneTimeout)
}
func (t OpTimeouts) dockerRemove() time.Duration {
	return pick(t.DockerRemove, DefaultDockerRemoveTimeout)
}

// OpTimeoutError is what a blown per-operation budget surfaces as. It names
// WHICH operation ran out of time and what its budget was, and it unwraps to
// context.DeadlineExceeded so errors.Is keeps working for callers that only
// care that a deadline blew.
type OpTimeoutError struct {
	Op      string
	Budget  time.Duration
	Command string
}

func (e *OpTimeoutError) Error() string {
	return fmt.Sprintf("%s timed out after %s (subprocess %q was abandoned)", e.Op, e.Budget, e.Command)
}

func (e *OpTimeoutError) Unwrap() error { return context.DeadlineExceeded }

// guardedWriter fences the abandoned subprocess's output away from the
// caller's buffer. runOp hands the runner a guardedWriter; on the timeout path
// it abandons the writer BEFORE returning, so a runner goroutine still alive
// after the budget blew cannot race the caller's read of its own bytes.Buffer.
type guardedWriter struct {
	mu        sync.Mutex
	w         io.Writer
	abandoned bool
}

func (g *guardedWriter) Write(p []byte) (int, error) {
	g.mu.Lock()
	defer g.mu.Unlock()
	if g.abandoned {
		return len(p), nil
	}
	return g.w.Write(p)
}

func (g *guardedWriter) abandon() {
	g.mu.Lock()
	g.abandoned = true
	g.mu.Unlock()
}

// runOp runs one subprocess under its OWN bounded context.
//
// The child context is what a well-behaved runner (ExecRunner, i.e.
// exec.CommandContext) uses to kill the process. But runOp does not DEPEND on
// the runner honouring it: the run happens on a goroutine and runOp returns
// the moment the budget blows, whether or not the runner ever comes back. That
// is the difference between "the subprocess is bounded" and "the executor is
// bounded", and only the second one keeps a blue/green cutover moving when the
// docker daemon is wedged.
//
// An ambient cancellation (the agent loop shutting down) is NOT reported as an
// operation timeout — it returns the ambient context's own error, so a
// shutdown never gets recorded as a false "docker run timed out".
func (e *Executor) runOp(ctx context.Context, op string, budget time.Duration, w io.Writer, name string, args ...string) error {
	opCtx, cancel := context.WithTimeout(ctx, budget)
	defer cancel()

	guard := &guardedWriter{w: w}
	done := make(chan error, 1)
	go func() { done <- e.runner().Run(opCtx, guard, name, args...) }()

	select {
	case err := <-done:
		return err
	case <-opCtx.Done():
		guard.abandon()
		if ctx.Err() != nil {
			// The AMBIENT context died (shutdown), not our budget.
			return ctx.Err()
		}
		return &OpTimeoutError{Op: op, Budget: budget, Command: name}
	}
}

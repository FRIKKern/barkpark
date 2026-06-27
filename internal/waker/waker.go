// Package waker is Barkpark Cloud's scale-to-zero front door (P7 stream C).
//
// A Waker is a tiny per-site HTTP server that:
//
//  1. Listens on the loopback port Caddy reverse_proxies to (ExternalPort).
//  2. On each request, ensures the site's container is up — starting it if
//     it's been reaped — then transparently proxies the request to it on
//     InternalPort.
//  3. After IdleTimeout of zero traffic, stops the container so a fleet of
//     thousands of low-traffic sites costs ~waker-process memory instead of
//     container memory.
//
// The waker is the only process that sees both "browser request arriving"
// and "container is/isn't running" — Caddy is oblivious (it just sees a
// well-behaved upstream that sometimes takes a second longer on a cold
// hit), the control plane is oblivious (it deployed the site and walked
// away). The trade-off is one tiny Go binary per site, which is the point:
// the waker is meant to be ~5 MB resident, not the multi-hundred-megabyte
// Node/Next runtime it fronts.
//
// All shell-out is behind ContainerManager so the unit tests run hermetic
// without Docker. Time is behind Now() so the idle reaper can be driven
// instantly by tests instead of waiting 5 minutes of wall clock.
package waker

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httputil"
	"net/url"
	"sync"
	"time"
)

// DefaultIdleTimeout is the zero-traffic window before a Waker stops its
// backing container. Tuned for "low-traffic blog / docs site that gets a hit
// every minute or two stays warm; a site that sees nothing for 5 minutes
// goes to sleep." Configurable per Waker.
const DefaultIdleTimeout = 5 * time.Minute

// DefaultIdleCheckInterval is how often Run()'s reaper loop wakes up to
// evaluate IdleTimeout. Coarse on purpose — the reaper is cheap, but every
// extra wake-up costs a goroutine + tiny CPU slice across hundreds of waker
// processes on a single box.
const DefaultIdleCheckInterval = 30 * time.Second

// ContainerManager is the docker-shaped surface the Waker needs. EnsureUp
// must be idempotent (no-op when already running) and synchronous (return
// only after the container is up AND health-checked, so the proxy hop that
// follows actually lands somewhere alive). Stop is best-effort — failure is
// logged, not fatal, because the next EnsureUp will reconcile.
//
// Tests inject a fake ContainerManager that tracks call counts; production
// uses DockerContainer which shells to `docker` via runtime.CommandRunner.
type ContainerManager interface {
	EnsureUp(ctx context.Context) error
	Stop(ctx context.Context) error
}

// Waker fronts one site. Construct via New(), then call ServeHTTP from your
// http.Server (typically via Run()).
type Waker struct {
	// SiteSlug is the site identifier used only for log lines.
	SiteSlug string

	// InternalPort is where the backing container is bound on the loopback
	// interface when running (set by the runtime executor when it allocates
	// the container's host-side port — e.g. 127.0.0.1:7142:3000 means
	// InternalPort=7142). The waker reverse-proxies to this port.
	InternalPort int

	// ExternalPort is where this Waker's HTTP server listens — the port
	// Caddy's reverse_proxy block points at. Run() binds this; ServeHTTP can
	// be exercised without binding.
	ExternalPort int

	// Container is the backing docker lifecycle. Required.
	Container ContainerManager

	// IdleTimeout overrides DefaultIdleTimeout when set.
	IdleTimeout time.Duration

	// IdleCheckInterval overrides DefaultIdleCheckInterval when set.
	IdleCheckInterval time.Duration

	// Now is the clock the idle reaper uses. Tests inject a fake; production
	// leaves it nil → time.Now is used.
	Now func() time.Time

	// Logger is called for cold-wake / sleep / error events. nil → silent.
	Logger func(format string, args ...any)

	// proxy is the reverse-proxy handler, constructed lazily on first request
	// so a Waker built bare (no ExternalPort set) can still be ServeHTTP'd in
	// tests against an arbitrary upstream.
	proxyOnce sync.Once
	proxy     http.Handler

	// upMu serializes EnsureUp / Stop / state reads. Held during the
	// (potentially slow) cold-wake so concurrent requests pile up here rather
	// than each starting their own container — that's the "single wake-up"
	// guarantee.
	upMu sync.Mutex
	isUp bool

	// actMu protects lastActivity, which the idle reaper reads.
	actMu        sync.Mutex
	lastActivity time.Time
}

// ServeHTTP implements http.Handler. For each request: ensure the container
// is up (cold path: start it + wait for health), record the activity tick,
// then proxy to InternalPort.
func (w *Waker) ServeHTTP(rw http.ResponseWriter, req *http.Request) {
	if err := w.ensureUp(req.Context()); err != nil {
		w.logf("waker(%s): cold-wake failed: %v", w.SiteSlug, err)
		http.Error(rw, "site is starting; please retry", http.StatusBadGateway)
		return
	}
	w.touch()
	w.handler().ServeHTTP(rw, req)
}

// ensureUp brings the container up if it isn't already. Idempotent under
// concurrent callers: the upMu mutex serializes them so only the first
// request through a cold gate pays the docker-start + health-check cost;
// subsequent concurrent callers see isUp=true and return immediately.
func (w *Waker) ensureUp(ctx context.Context) error {
	w.upMu.Lock()
	defer w.upMu.Unlock()
	if w.isUp {
		return nil
	}
	if err := w.Container.EnsureUp(ctx); err != nil {
		return fmt.Errorf("ensure up: %w", err)
	}
	w.isUp = true
	w.logf("waker(%s): woke", w.SiteSlug)
	return nil
}

// touch records a request just landed. Idle reaper reads this to decide
// whether to sleep the container.
func (w *Waker) touch() {
	w.actMu.Lock()
	w.lastActivity = w.now()
	w.actMu.Unlock()
}

// CheckIdle is the unit step of the reaper loop — exposed so tests can drive
// it deterministically without waiting wall-clock time. Stops the container
// when time-since-last-activity exceeds IdleTimeout. Safe to call repeatedly;
// no-op when already sleeping or still warm.
func (w *Waker) CheckIdle(ctx context.Context) {
	w.actMu.Lock()
	last := w.lastActivity
	w.actMu.Unlock()

	// last==zero means: no request has landed yet. Don't reap a never-warmed
	// site — the first request hasn't even arrived. Once the first request
	// lands, last is set and the idle clock starts.
	if last.IsZero() {
		return
	}
	if w.now().Sub(last) < w.idleTimeout() {
		return
	}

	w.upMu.Lock()
	defer w.upMu.Unlock()
	if !w.isUp {
		return
	}
	if err := w.Container.Stop(ctx); err != nil {
		w.logf("waker(%s): idle-stop failed: %v", w.SiteSlug, err)
		return
	}
	w.isUp = false
	w.logf("waker(%s): slept (idle %s)", w.SiteSlug, w.idleTimeout())
}

// Run binds an http.Server on ExternalPort, starts the idle reaper, and
// blocks until ctx is cancelled. Returns the listener / server error if
// any. Used by cmd/barkpark-waker.
func (w *Waker) Run(ctx context.Context) error {
	if w.ExternalPort <= 0 {
		return fmt.Errorf("ExternalPort must be > 0")
	}

	srv := &http.Server{
		Addr:              fmt.Sprintf("127.0.0.1:%d", w.ExternalPort),
		Handler:           w,
		ReadHeaderTimeout: 5 * time.Second,
	}

	reaperDone := make(chan struct{})
	go func() {
		defer close(reaperDone)
		w.reaperLoop(ctx)
	}()

	errCh := make(chan error, 1)
	go func() {
		errCh <- srv.ListenAndServe()
	}()

	select {
	case <-ctx.Done():
		// Graceful: stop the http server, wait for the reaper, then stop the
		// container so we leave nothing running behind us.
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = srv.Shutdown(shutdownCtx)
		<-reaperDone
		_ = w.shutdownContainer(shutdownCtx)
		return ctx.Err()
	case err := <-errCh:
		return err
	}
}

// reaperLoop fires CheckIdle on IdleCheckInterval cadence until ctx done.
func (w *Waker) reaperLoop(ctx context.Context) {
	t := time.NewTicker(w.idleCheckInterval())
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			w.CheckIdle(ctx)
		}
	}
}

// shutdownContainer stops the backing container on Waker shutdown — leaving
// it warm across a waker restart is a leak (the next waker has no way to
// know it's already up except by inspecting Docker, and concurrent wakers
// for the same site are a contract violation anyway).
func (w *Waker) shutdownContainer(ctx context.Context) error {
	w.upMu.Lock()
	defer w.upMu.Unlock()
	if !w.isUp {
		return nil
	}
	if err := w.Container.Stop(ctx); err != nil {
		return err
	}
	w.isUp = false
	return nil
}

func (w *Waker) handler() http.Handler {
	w.proxyOnce.Do(func() {
		target, err := url.Parse(fmt.Sprintf("http://127.0.0.1:%d", w.InternalPort))
		if err != nil {
			// InternalPort is set at construction; a failure here is a
			// programmer error, not a runtime one. Fall back to a 500 handler
			// so we don't panic mid-request.
			w.proxy = http.HandlerFunc(func(rw http.ResponseWriter, _ *http.Request) {
				http.Error(rw, "waker misconfigured", http.StatusInternalServerError)
			})
			return
		}
		w.proxy = httputil.NewSingleHostReverseProxy(target)
	})
	return w.proxy
}

// SetProxy lets tests inject a stub handler in place of the real
// httputil.NewSingleHostReverseProxy — handy when the test wants to verify
// the proxy is invoked without standing up a real upstream server. Not used
// in production code paths.
func (w *Waker) SetProxy(h http.Handler) {
	w.proxyOnce.Do(func() {})
	w.proxy = h
}

func (w *Waker) idleTimeout() time.Duration {
	if w.IdleTimeout > 0 {
		return w.IdleTimeout
	}
	return DefaultIdleTimeout
}

func (w *Waker) idleCheckInterval() time.Duration {
	if w.IdleCheckInterval > 0 {
		return w.IdleCheckInterval
	}
	return DefaultIdleCheckInterval
}

func (w *Waker) now() time.Time {
	if w.Now != nil {
		return w.Now()
	}
	return time.Now()
}

func (w *Waker) logf(format string, args ...any) {
	if w.Logger != nil {
		w.Logger(format, args...)
	}
}

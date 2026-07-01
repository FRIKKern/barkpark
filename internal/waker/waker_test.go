package waker

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// fakeContainer is an in-memory ContainerManager that records call counts
// and lets the test simulate a slow cold-wake (CoolDelay) so the
// concurrent-wake guarantee is actually under contention.
type fakeContainer struct {
	mu         sync.Mutex
	ensureN    int
	stopN      int
	running    bool
	CoolDelay  time.Duration // sleep inside EnsureUp to simulate startup
	EnsureErr  error
	StopErr    error
	OnEnsureUp func() // optional hook fired at the start of EnsureUp
}

func (f *fakeContainer) EnsureUp(ctx context.Context) error {
	f.mu.Lock()
	already := f.running
	f.ensureN++
	hook := f.OnEnsureUp
	delay := f.CoolDelay
	f.mu.Unlock()

	if hook != nil {
		hook()
	}
	if f.EnsureErr != nil {
		return f.EnsureErr
	}
	if !already && delay > 0 {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(delay):
		}
	}

	f.mu.Lock()
	f.running = true
	f.mu.Unlock()
	return nil
}

func (f *fakeContainer) Stop(ctx context.Context) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.stopN++
	if f.StopErr != nil {
		return f.StopErr
	}
	f.running = false
	return nil
}

func (f *fakeContainer) snapshot() (ensureN, stopN int, running bool) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.ensureN, f.stopN, f.running
}

// stubProxy is an http.Handler the tests inject in place of the real
// reverse-proxy so we don't have to bring up an upstream listener for every
// test. It records the number of proxied requests.
type stubProxy struct{ n int64 }

func (s *stubProxy) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	atomic.AddInt64(&s.n, 1)
	w.WriteHeader(http.StatusOK)
	_, _ = io.WriteString(w, "ok")
}

func (s *stubProxy) count() int64 { return atomic.LoadInt64(&s.n) }

// --- the three required scenarios -------------------------------------------

func TestWaker_ColdWake_StartsContainerThenProxies(t *testing.T) {
	c := &fakeContainer{}
	w := &Waker{
		SiteSlug:  "shop",
		Container: c,
	}
	proxy := &stubProxy{}
	w.SetProxy(proxy)

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/", nil)
	w.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200; body=%s", rec.Code, rec.Body.String())
	}
	if proxy.count() != 1 {
		t.Errorf("proxy not invoked: %d", proxy.count())
	}
	ensureN, stopN, running := c.snapshot()
	if ensureN != 1 {
		t.Errorf("EnsureUp called %d times, want 1", ensureN)
	}
	if stopN != 0 {
		t.Errorf("Stop called %d times before idle, want 0", stopN)
	}
	if !running {
		t.Errorf("container should be running after cold wake")
	}
}

func TestWaker_AlreadyUp_NoRedundantStart(t *testing.T) {
	c := &fakeContainer{}
	w := &Waker{SiteSlug: "shop", Container: c}
	w.SetProxy(&stubProxy{})

	// Two sequential requests — the second must NOT call EnsureUp again
	// (Waker tracks isUp internally so it doesn't spam docker inspect).
	for i := 0; i < 2; i++ {
		rec := httptest.NewRecorder()
		req := httptest.NewRequest(http.MethodGet, "/", nil)
		w.ServeHTTP(rec, req)
		if rec.Code != http.StatusOK {
			t.Fatalf("req %d: status %d", i, rec.Code)
		}
	}
	if ensureN, _, _ := c.snapshot(); ensureN != 1 {
		t.Errorf("EnsureUp called %d times, want 1 (warm path)", ensureN)
	}
}

func TestWaker_IdleSleep_StopsContainerAndRewakes(t *testing.T) {
	c := &fakeContainer{}
	now := time.Date(2026, 6, 27, 12, 0, 0, 0, time.UTC)
	mu := &sync.Mutex{}
	w := &Waker{
		SiteSlug:    "shop",
		Container:   c,
		IdleTimeout: 5 * time.Minute,
		Now: func() time.Time {
			mu.Lock()
			defer mu.Unlock()
			return now
		},
	}
	w.SetProxy(&stubProxy{})

	// First hit warms the container, sets lastActivity to t0.
	rec := httptest.NewRecorder()
	w.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/", nil))
	if ensureN, _, running := c.snapshot(); ensureN != 1 || !running {
		t.Fatalf("after warm: ensureN=%d running=%v", ensureN, running)
	}

	// 3 minutes pass — still warm.
	mu.Lock()
	now = now.Add(3 * time.Minute)
	mu.Unlock()
	w.CheckIdle(context.Background())
	if _, stopN, running := c.snapshot(); stopN != 0 || !running {
		t.Fatalf("3min: stopN=%d running=%v, want stopN=0 running=true", stopN, running)
	}

	// 6 minutes past first hit — exceeds 5min idle, reaper sleeps it.
	mu.Lock()
	now = now.Add(3 * time.Minute) // total 6min
	mu.Unlock()
	w.CheckIdle(context.Background())
	if _, stopN, running := c.snapshot(); stopN != 1 || running {
		t.Fatalf("after idle: stopN=%d running=%v, want stopN=1 running=false", stopN, running)
	}

	// CheckIdle is idempotent — a second tick over an already-stopped waker
	// doesn't spam Stop.
	w.CheckIdle(context.Background())
	if _, stopN, _ := c.snapshot(); stopN != 1 {
		t.Errorf("second CheckIdle should be no-op; stopN=%d", stopN)
	}

	// Next request re-wakes — EnsureUp is called again.
	rec = httptest.NewRecorder()
	w.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("re-wake status = %d", rec.Code)
	}
	if ensureN, _, running := c.snapshot(); ensureN != 2 || !running {
		t.Errorf("re-wake: ensureN=%d running=%v, want ensureN=2 running=true", ensureN, running)
	}
}

func TestWaker_ConcurrentWake_OnlyOneStart(t *testing.T) {
	// Make the cold wake slow enough that 5 concurrent requests pile up on
	// the upMu mutex. Without serialization, all 5 would EnsureUp; with the
	// Waker's lock, exactly 1 does the work, the other 4 wait then proxy.
	c := &fakeContainer{CoolDelay: 50 * time.Millisecond}
	w := &Waker{SiteSlug: "shop", Container: c}
	proxy := &stubProxy{}
	w.SetProxy(proxy)

	const N = 5
	start := make(chan struct{})
	var wg sync.WaitGroup
	codes := make([]int, N)
	for i := 0; i < N; i++ {
		wg.Add(1)
		i := i
		go func() {
			defer wg.Done()
			<-start
			rec := httptest.NewRecorder()
			req := httptest.NewRequest(http.MethodGet, "/", nil)
			w.ServeHTTP(rec, req)
			codes[i] = rec.Code
		}()
	}
	close(start)
	wg.Wait()

	for i, code := range codes {
		if code != http.StatusOK {
			t.Errorf("req %d: status %d", i, code)
		}
	}
	if proxy.count() != int64(N) {
		t.Errorf("proxy served %d, want %d", proxy.count(), N)
	}
	if ensureN, _, _ := c.snapshot(); ensureN != 1 {
		t.Errorf("EnsureUp called %d times under %d concurrent wake; want 1 (single-flight)", ensureN, N)
	}
}

func TestWaker_CheckIdle_TouchDuringWake_DoesNotStop(t *testing.T) {
	// Regression for the cold-hit race: a request that touches lastActivity
	// after the reaper's pre-lock idle read but before the reaper acquires
	// upMu must NOT be reaped. ServeHTTP now touches BEFORE ensureUp, so such
	// a request stamps a fresh tick while its wake holds upMu; CheckIdle's
	// post-lock re-read under upMu must observe that tick and skip Stop.
	//
	// We drive the ordering deterministically without goroutines: the site is
	// idle at t0 and the clock is 10m past that, so the reaper's PRE-lock read
	// (last==t0) passes the idle test. We inject the "request touched during
	// the wake" event via the Now hook, which CheckIdle calls AFTER its
	// pre-lock read — stamping lastActivity to the current time. Without the
	// post-lock re-read the reaper would Stop (stopN=1); with it, the re-read
	// sees the fresh tick and bails (stopN=0).
	c := &fakeContainer{running: true}
	t0 := time.Date(2026, 6, 27, 12, 0, 0, 0, time.UTC)
	cur := t0.Add(10 * time.Minute) // well past the 5m idle window
	w := &Waker{
		SiteSlug:    "shop",
		Container:   c,
		IdleTimeout: 5 * time.Minute,
	}
	w.SetProxy(&stubProxy{})
	w.isUp = true

	// Site last saw traffic at t0 — pre-lock read will observe this old tick.
	w.actMu.Lock()
	w.lastActivity = t0
	w.actMu.Unlock()

	var touched bool
	w.Now = func() time.Time {
		// Simulate the concurrent request landing exactly once, after the
		// pre-lock read has already captured t0.
		if !touched {
			touched = true
			w.actMu.Lock()
			w.lastActivity = cur
			w.actMu.Unlock()
		}
		return cur
	}

	w.CheckIdle(context.Background())

	if _, stopN, running := c.snapshot(); stopN != 0 || !running {
		t.Fatalf("touch-during-wake: stopN=%d running=%v, want stopN=0 running=true", stopN, running)
	}
}

// --- supporting coverage ------------------------------------------------------

func TestWaker_CheckIdle_NoRequestsYet_DoesNotReap(t *testing.T) {
	// A waker that's never been hit shouldn't be reaped — its container
	// isn't even up. Otherwise the very first reaper tick on a freshly
	// spawned waker would attempt a stop on a never-started container.
	c := &fakeContainer{}
	now := time.Now()
	w := &Waker{
		Container:   c,
		IdleTimeout: time.Minute,
		Now:         func() time.Time { return now.Add(time.Hour) },
	}
	w.CheckIdle(context.Background())
	if _, stopN, _ := c.snapshot(); stopN != 0 {
		t.Errorf("Stop called %d times on never-warmed waker, want 0", stopN)
	}
}

func TestWaker_EnsureUpFails_Returns502(t *testing.T) {
	c := &fakeContainer{EnsureErr: errBoom}
	w := &Waker{Container: c}
	w.SetProxy(&stubProxy{})

	rec := httptest.NewRecorder()
	w.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/", nil))
	if rec.Code != http.StatusBadGateway {
		t.Errorf("status = %d, want 502", rec.Code)
	}
}

func TestWaker_Run_RequiresExternalPort(t *testing.T) {
	w := &Waker{Container: &fakeContainer{}}
	err := w.Run(context.Background())
	if err == nil {
		t.Fatal("want error for zero ExternalPort, got nil")
	}
}

// --- helpers ---

type boomErr struct{}

func (boomErr) Error() string { return "boom" }

var errBoom = boomErr{}

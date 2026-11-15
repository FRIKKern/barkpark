package chathost

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// heldClock is a clock that moves only when the test sets it. It counts its
// reads, so a test waits for the runner to have looked at it, not for time to
// pass: a loaded machine slows the runner down but cannot move this clock.
type heldClock struct {
	mu      sync.Mutex
	at      time.Time
	reads   int
	waiters []heldClockWaiter
}

type heldClockWaiter struct {
	reads int
	done  chan struct{}
}

func (c *heldClock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.reads++
	kept := c.waiters[:0]
	for _, w := range c.waiters {
		if c.reads >= w.reads {
			close(w.done)
		} else {
			kept = append(kept, w)
		}
	}
	c.waiters = kept
	return c.at
}

func (c *heldClock) Set(at time.Time) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.at = at
}

// afterReads closes once the clock has been read n more times.
func (c *heldClock) afterReads(n int) <-chan struct{} {
	c.mu.Lock()
	defer c.mu.Unlock()
	w := heldClockWaiter{reads: c.reads + n, done: make(chan struct{})}
	c.waiters = append(c.waiters, w)
	return w.done
}

var backoffStart = time.Date(2026, time.January, 1, 0, 0, 0, 0, time.UTC)

// The retry wait after a call's nth failure in a row is PollInterval << n:
// twice PollInterval after the first. It stops growing at maxRetryWait (30 s)
// and stays there. A success ends the outage, so the next failure waits twice
// PollInterval again. The clock is held, so each wait is pinned to the
// nanosecond: one nanosecond short the call is not made, at the wait it is.
func TestRunnerRetryWaitDoublesCapsAndResetsAfterASuccess(t *testing.T) {
	const s = time.Second
	clock := &heldClock{at: backoffStart}
	r := &Runner{PollInterval: s, Log: &syncBuffer{}, now: clock.Now}
	o := &outage{name: "poll"}
	calls, failing := 0, true
	call := func() error {
		calls++
		if failing {
			return errors.New("connection refused")
		}
		return nil
	}
	// try sets the clock to at and reports whether attempt made the call.
	try := func(at time.Time) bool {
		t.Helper()
		clock.Set(at)
		before := calls
		if err := r.attempt(context.Background(), o, call); err != nil {
			t.Fatalf("attempt ended Run on a transient failure: %v", err)
		}
		return calls > before
	}

	at := backoffStart
	if !try(at) {
		t.Fatal("the first attempt was not made")
	}
	// The waits after failures 1 to 20.
	want := []time.Duration{2 * s, 4 * s, 8 * s, 16 * s}
	for len(want) < 20 {
		want = append(want, maxRetryWait)
	}
	for i, wait := range want {
		if try(at.Add(wait - time.Nanosecond)) {
			t.Fatalf("after %d failures the call was retried %v later; want a wait of %v", i+1, wait-time.Nanosecond, wait)
		}
		at = at.Add(wait)
		if !try(at) {
			t.Fatalf("after %d failures the call was not retried %v later; want a wait of %v", i+1, wait, wait)
		}
	}

	// 21 failures so far; the call answers on the next retry.
	at = at.Add(maxRetryWait)
	failing = false
	if !try(at) {
		t.Fatalf("after 21 failures the call was not retried %v later", maxRetryWait)
	}
	// After the success nothing waits, and a new outage starts from the
	// first wait, not from where the last one stopped.
	failing = true
	if !try(at) {
		t.Fatal("the call after a success waited")
	}
	if try(at.Add(2*s - time.Nanosecond)) {
		t.Fatal("the first failure after a success was retried before twice PollInterval")
	}
	if !try(at.Add(2 * s)) {
		t.Fatalf("the first failure after a success was not retried after twice PollInterval; the outage was not reset")
	}
}

// awaitBackoff waits for done. Its deadline only catches a hang: no step a
// test waits for here depends on how fast the machine runs.
func awaitBackoff(t *testing.T, ctx context.Context, result <-chan error, done <-chan struct{}, what string) {
	t.Helper()
	select {
	case <-done:
	case err := <-result:
		t.Fatalf("Run ended while waiting for %s: %v", what, err)
	case <-ctx.Done():
		t.Fatalf("%s never happened", what)
	}
}

// backoffRun runs a Runner against server with the clock held at
// backoffStart. HeartbeatInterval is an hour, so every pass of Run's loop
// after the start is a poll tick, and every tick reads the clock at least once.
func backoffRun(t *testing.T, server *httptest.Server) (*heldClock, context.Context, context.CancelFunc, <-chan error) {
	t.Helper()
	clock := &heldClock{at: backoffStart}
	runner := &Runner{
		Client:            &Client{BaseURL: server.URL, Credential: "host-secret", HTTPClient: server.Client(), AllowInsecureLoopback: true},
		Handler:           emittingHandler{},
		PollInterval:      time.Millisecond,
		HeartbeatInterval: time.Hour,
		Log:               &syncBuffer{},
		now:               clock.Now,
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	result := make(chan error, 1)
	go func() { result <- runner.Run(ctx) }()
	return clock, ctx, cancel, result
}

// signalAt closes ch when count reaches n.
func signalAt(count int32, n int32, once *sync.Once, ch chan struct{}) {
	if count == n {
		once.Do(func() { close(ch) })
	}
}

// A failing heartbeat is retried at poll pace, but only once its wait is out:
// with the clock held, poll ticks go by and the heartbeat is not sent again.
// The first wait is twice PollInterval, to the nanosecond.
func TestRunnerHeartbeatRetryWaitsOutItsBackoff(t *testing.T) {
	var heartbeats atomic.Int32
	second := make(chan struct{})
	var once sync.Once
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/v1/chat-host/heartbeat":
			signalAt(heartbeats.Add(1), 2, &once, second)
			w.WriteHeader(http.StatusServiceUnavailable)
		case "/v1/chat-host/commands":
			_, _ = w.Write([]byte(`{"commands":[]}`))
		}
	}))
	defer server.Close()

	clock, ctx, cancel, result := backoffRun(t, server)
	defer cancel()

	// Each poll tick reads the clock for the heartbeat's gate and the poll's:
	// 40 reads span about 20 ticks, every one of them past the start's failed
	// heartbeat. A runner with no backoff sends one heartbeat per tick.
	held := backoffStart.Add(2*time.Millisecond - time.Nanosecond)
	for _, at := range []time.Time{backoffStart, held} {
		clock.Set(at)
		awaitBackoff(t, ctx, result, clock.afterReads(40), "20 poll ticks")
		if got := heartbeats.Load(); got != 1 {
			t.Fatalf("clock %v after the failed heartbeat: heartbeats=%d want 1; the retry did not wait out its backoff", at.Sub(backoffStart), got)
		}
	}
	clock.Set(backoffStart.Add(2 * time.Millisecond))
	awaitBackoff(t, ctx, result, second, "the heartbeat retry once its wait was out")

	cancel()
	if err := <-result; !errors.Is(err, context.Canceled) {
		t.Fatalf("runner error=%v want context.Canceled", err)
	}
}

// A failing poll waits out its backoff too: poll ticks go by with the clock
// held and the poll is not sent again until its wait, twice PollInterval, is
// out.
func TestRunnerPollRetryWaitsOutItsBackoff(t *testing.T) {
	var polls atomic.Int32
	second := make(chan struct{})
	var once sync.Once
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/v1/chat-host/heartbeat":
			_, _ = w.Write([]byte(`{"host":{"id":"host-1"}}`))
		case "/v1/chat-host/commands":
			signalAt(polls.Add(1), 2, &once, second)
			w.WriteHeader(http.StatusBadGateway)
		}
	}))
	defer server.Close()

	clock, ctx, cancel, result := backoffRun(t, server)
	defer cancel()

	// The heartbeat answers, so each tick reads the clock once, for the poll's
	// gate. The first 3 reads are the start's heartbeat and the first poll's
	// gate and wait; 40 reads span at least 18 ticks after the failed poll. A
	// runner with no backoff sends one poll per tick.
	held := backoffStart.Add(2*time.Millisecond - time.Nanosecond)
	for _, at := range []time.Time{backoffStart, held} {
		clock.Set(at)
		awaitBackoff(t, ctx, result, clock.afterReads(40), "18 poll ticks")
		if got := polls.Load(); got != 1 {
			t.Fatalf("clock %v after the failed poll: polls=%d want 1; the retry did not wait out its backoff", at.Sub(backoffStart), got)
		}
	}
	clock.Set(backoffStart.Add(2 * time.Millisecond))
	awaitBackoff(t, ctx, result, second, "the poll retry once its wait was out")

	cancel()
	if err := <-result; !errors.Is(err, context.Canceled) {
		t.Fatalf("runner error=%v want context.Canceled", err)
	}
}

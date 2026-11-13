package chathost

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"slices"
	"sync"
	"time"
)

type Handler interface {
	Handle(context.Context, RemoteCommand, func(map[string]any) error) error
}

type Runner struct {
	Client            *Client
	Handler           Handler
	Capabilities      map[string]any
	PollInterval      time.Duration
	HeartbeatInterval time.Duration
	// Log receives one line when a call starts failing and one when it works
	// again. Nil means os.Stderr.
	Log io.Writer

	mu     sync.Mutex
	active map[string]activeCommand
	// seen: every lease this process has started, and whether it is done with
	// it. A started lease is never handed to the Handler again: listed again
	// while not active, it is only closed. A done lease (its end was taken, or
	// the server refused it for good) is left alone, as when a poll answered
	// just before the end landed still lists it. An entry goes when a poll no
	// longer lists its lease.
	seen map[string]leaseMark
}

type leaseMark int

const (
	leaseStarted leaseMark = iota + 1
	leaseDone
)

type activeCommand struct {
	sessionID string
	cancel    context.CancelFunc
}

func (r *Runner) Run(ctx context.Context) error {
	if r.Client == nil || r.Handler == nil {
		return errors.New("runner requires client and handler")
	}
	if r.PollInterval <= 0 {
		r.PollInterval = time.Second
	}
	if r.HeartbeatInterval <= 0 {
		r.HeartbeatInterval = 15 * time.Second
	}
	r.active = make(map[string]activeCommand)
	r.seen = make(map[string]leaseMark)

	poll := time.NewTicker(r.PollInterval)
	heartbeat := time.NewTicker(r.HeartbeatInterval)
	defer poll.Stop()
	defer heartbeat.Stop()
	defer r.cancelAll()

	// A transient failure (network, timeout, 5xx) never ends Run: the call is
	// retried with a growing wait while active commands keep running. Only
	// ctx, ErrRevoked and errors retrying cannot heal end it; the deferred
	// cancelAll then stops the active commands.
	beat := &outage{name: "heartbeat"}
	polling := &outage{name: "poll"}
	sendHeartbeat := func() error { return r.Client.Heartbeat(ctx, r.Capabilities) }
	fetchCommands := func() error {
		commands, err := r.Client.Commands(ctx)
		if err != nil {
			return err
		}
		r.forgetUnlisted(commands)
		for _, command := range commands {
			r.start(ctx, command)
		}
		return nil
	}

	if err := r.attempt(ctx, beat, sendHeartbeat); err != nil {
		return err
	}

	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-heartbeat.C:
			if err := r.attempt(ctx, beat, sendHeartbeat); err != nil {
				return err
			}
		case <-poll.C:
			// A failing heartbeat is retried at poll pace, not once per
			// HeartbeatInterval, so a host started during a restart comes up.
			if beat.failures > 0 {
				if err := r.attempt(ctx, beat, sendHeartbeat); err != nil {
					return err
				}
			}
			if err := r.attempt(ctx, polling, fetchCommands); err != nil {
				return err
			}
		}
	}
}

const maxRetryWait = 30 * time.Second

// outage tracks one call's run of consecutive transient failures.
type outage struct {
	name     string
	failures int
	retryAt  time.Time
}

// attempt runs call unless it is still waiting out a backoff. It returns an
// error only when Run must end.
func (r *Runner) attempt(ctx context.Context, o *outage, call func() error) error {
	if time.Now().Before(o.retryAt) {
		return nil
	}
	err := call()
	if err == nil {
		if o.failures > 0 {
			r.logf("%s reconnected after %d failed attempts", o.name, o.failures)
		}
		o.failures, o.retryAt = 0, time.Time{}
		return nil
	}
	if ctx.Err() != nil {
		return ctx.Err()
	}
	if !Transient(err) {
		return err
	}
	o.failures++
	if o.failures == 1 {
		r.logf("%s failing, retrying until it answers: %v", o.name, err)
	}
	// The wait doubles from PollInterval and stops growing at maxRetryWait.
	wait := maxRetryWait
	if o.failures < 16 {
		if grown := r.PollInterval << o.failures; grown > 0 && grown < maxRetryWait {
			wait = grown
		}
	}
	o.retryAt = time.Now().Add(wait)
	return nil
}

func (r *Runner) logf(format string, args ...any) {
	w := r.Log
	if w == nil {
		w = os.Stderr
	}
	fmt.Fprintf(w, "barkpark-chat-host: "+format+"\n", args...)
}

func (r *Runner) start(parent context.Context, command RemoteCommand) {
	r.mu.Lock()
	mark := r.seen[command.LeaseID]
	if _, exists := r.active[command.LeaseID]; exists || mark == leaseDone {
		r.mu.Unlock()
		return
	}
	ctx, cancel := context.WithCancel(parent)
	sessionID, _ := command.Command["session_id"].(string)
	r.active[command.LeaseID] = activeCommand{sessionID: sessionID, cancel: cancel}
	if r.seen != nil {
		r.seen[command.LeaseID] = leaseStarted
	}
	r.mu.Unlock()

	go func() {
		defer func() {
			r.mu.Lock()
			delete(r.active, command.LeaseID)
			r.mu.Unlock()
			cancel()
		}()

		// The cursor moves only when the server took the event. A refused event
		// keeps its cursor, so the terminal that follows it is not a gap the
		// server refuses (cursor_gap).
		cursor := command.LastCursor
		publish := func(ctx context.Context, event map[string]any) error {
			if err := r.publish(ctx, command, cursor+1, event); err != nil {
				return err
			}
			cursor++
			return nil
		}
		// The terminal is published under its own deadline, after the turn's
		// ctx is cancelled, so a provider that gave up is not kept alive while
		// it is sent. Taken, or refused for good (409, 422), the lease is done:
		// re-posting a refused close every poll spends the write budget that
		// started this. A refusal retrying can heal leaves it to the next poll.
		terminal := func(state string, err error) {
			cancel()
			publishCtx, publishCancel := context.WithTimeout(context.WithoutCancel(parent), terminalPublishTimeout)
			defer publishCancel()
			perr := publish(publishCtx, map[string]any{
				"kind":           "terminal",
				"terminal_state": state,
				"error":          map[string]any{"message": err.Error()},
			})
			if perr != nil {
				r.logf("lease %s: its %s terminal was not taken: %v", command.LeaseID, state, perr)
			}
			if perr == nil || !Transient(perr) {
				r.markDone(command.LeaseID)
			}
		}

		// The server hands a lease out again on every poll until it holds a
		// completed event. One this process started before, or one the server
		// took events for (started by an earlier host process), had a run that
		// is gone. Running it again restarts the turn from the top: a second
		// paid provider run, a second reply, and, when the first run died
		// because its events were refused, the same failure again on every poll
		// (task-1fa6009d589cd92a). The lease is closed instead.
		if mark == leaseStarted || command.LastCursor > 0 {
			err := fmt.Errorf("this command was cut off on the host after %d events and is not run twice", command.LastCursor)
			r.logf("lease %s: %v", command.LeaseID, err)
			terminal("error", err)
			return
		}

		if err := r.Handler.Handle(ctx, command, func(event map[string]any) error { return publish(ctx, event) }); err != nil {
			terminalState := "error"
			if errors.Is(err, context.Canceled) {
				terminalState = "interrupted"
			}
			r.logf("lease %s ended %s: %v", command.LeaseID, terminalState, err)
			terminal(terminalState, err)
			return
		}
		r.markDone(command.LeaseID)
	}()
}

func (r *Runner) markDone(leaseID string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.seen != nil {
		r.seen[leaseID] = leaseDone
	}
}

// forgetUnlisted drops the marks of leases the server no longer lists. A
// lease still running here keeps its mark.
func (r *Runner) forgetUnlisted(listed []RemoteCommand) {
	r.mu.Lock()
	defer r.mu.Unlock()
	for leaseID := range r.seen {
		if _, running := r.active[leaseID]; running {
			continue
		}
		if !slices.ContainsFunc(listed, func(c RemoteCommand) bool { return c.LeaseID == leaseID }) {
			delete(r.seen, leaseID)
		}
	}
}

// A refused event is retried for this long before the turn gives up.
const maxPublishOutage = 2 * time.Minute

// Bound on the terminal publish after the run has ended. A var so a test can
// end it sooner.
var terminalPublishTimeout = 30 * time.Second

// publish sends one event at cursor and retries an answer that retrying can
// heal (network, timeout, 5xx, 408, 429) with the same cursor and key, so the
// server dedupes a retry of an event it already took. A 429 waits out its
// Retry-After. One refused event used to end the turn.
func (r *Runner) publish(ctx context.Context, command RemoteCommand, cursor uint64, event map[string]any) error {
	key := fmt.Sprintf("%s:%d:%d", command.LeaseID, command.Epoch, cursor)
	giveUp := time.Now().Add(maxPublishOutage)
	for failures := 0; ; failures++ {
		err := r.Client.Publish(ctx, command, cursor, key, event)
		if err == nil {
			if failures > 0 {
				r.logf("lease %s: events taken again after %d refused attempts", command.LeaseID, failures)
			}
			return nil
		}
		if ctx.Err() != nil || !Transient(err) || time.Now().After(giveUp) {
			return err
		}
		if failures == 0 {
			r.logf("lease %s: event %d refused, retrying: %v", command.LeaseID, cursor, err)
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(r.publishWait(err, failures)):
		}
	}
}

func (r *Runner) publishWait(err error, failures int) time.Duration {
	var status *StatusError
	if errors.As(err, &status) && status.RetryAfter > 0 {
		return min(status.RetryAfter, maxRetryWait)
	}
	base := r.PollInterval
	if base <= 0 {
		base = time.Second
	}
	if failures < 16 {
		if grown := base << failures; grown > 0 && grown < maxRetryWait {
			return grown
		}
	}
	return maxRetryWait
}

func (r *Runner) cancelAll() {
	r.mu.Lock()
	defer r.mu.Unlock()
	for leaseID, active := range r.active {
		active.cancel()
		delete(r.active, leaseID)
	}
}

func (r *Runner) cancelSession(sessionID string) {
	if sessionID == "" {
		return
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	for leaseID, active := range r.active {
		if active.sessionID == sessionID {
			active.cancel()
			delete(r.active, leaseID)
		}
	}
}

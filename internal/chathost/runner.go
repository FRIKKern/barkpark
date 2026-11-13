package chathost

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
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
}

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
	if _, exists := r.active[command.LeaseID]; exists {
		r.mu.Unlock()
		return
	}
	ctx, cancel := context.WithCancel(parent)
	sessionID, _ := command.Command["session_id"].(string)
	r.active[command.LeaseID] = activeCommand{sessionID: sessionID, cancel: cancel}
	r.mu.Unlock()

	go func() {
		defer func() {
			r.mu.Lock()
			delete(r.active, command.LeaseID)
			r.mu.Unlock()
			cancel()
		}()

		cursor := command.LastCursor
		emit := func(event map[string]any) error {
			cursor++
			key := fmt.Sprintf("%s:%d:%d", command.LeaseID, command.Epoch, cursor)
			return r.Client.Publish(ctx, command, cursor, key, event)
		}
		if err := r.Handler.Handle(ctx, command, emit); err != nil {
			terminalState := "error"
			if errors.Is(err, context.Canceled) {
				terminalState = "interrupted"
			}
			publishCtx, publishCancel := context.WithTimeout(context.WithoutCancel(parent), 5*time.Second)
			defer publishCancel()
			cursor++
			key := fmt.Sprintf("%s:%d:%d", command.LeaseID, command.Epoch, cursor)
			_ = r.Client.Publish(publishCtx, command, cursor, key, map[string]any{
				"kind":           "terminal",
				"terminal_state": terminalState,
				"error":          map[string]any{"message": err.Error()},
			})
		}
	}()
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

package chathost

import (
	"context"
	"errors"
	"fmt"
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

	if err := r.Client.Heartbeat(ctx, r.Capabilities); err != nil {
		return err
	}

	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-heartbeat.C:
			if err := r.Client.Heartbeat(ctx, r.Capabilities); err != nil {
				if errors.Is(err, ErrRevoked) {
					r.cancelAll()
				}
				return err
			}
		case <-poll.C:
			commands, err := r.Client.Commands(ctx)
			if err != nil {
				if errors.Is(err, ErrRevoked) {
					r.cancelAll()
				}
				return err
			}
			for _, command := range commands {
				r.start(ctx, command)
			}
		}
	}
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

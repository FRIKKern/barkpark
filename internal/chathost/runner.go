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

	mu      sync.Mutex
	cancels map[string]context.CancelFunc
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
	r.cancels = make(map[string]context.CancelFunc)

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
	if _, exists := r.cancels[command.LeaseID]; exists {
		r.mu.Unlock()
		return
	}
	ctx, cancel := context.WithCancel(parent)
	r.cancels[command.LeaseID] = cancel
	r.mu.Unlock()

	go func() {
		defer func() {
			r.mu.Lock()
			delete(r.cancels, command.LeaseID)
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
			_ = emit(map[string]any{
				"kind":           "terminal",
				"terminal_state": "error",
				"error":          map[string]any{"message": err.Error()},
			})
		}
	}()
}

func (r *Runner) cancelAll() {
	r.mu.Lock()
	defer r.mu.Unlock()
	for leaseID, cancel := range r.cancels {
		cancel()
		delete(r.cancels, leaseID)
	}
}

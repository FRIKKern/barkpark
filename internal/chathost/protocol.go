package chathost

import "errors"

var (
	ErrStaleFence = errors.New("stale execution fence")
	ErrCursorGap  = errors.New("event cursor gap")
)

type LeaseFence struct {
	LeaseID string `json:"lease_id"`
	Epoch   uint64 `json:"epoch"`
}

type Event struct {
	Cursor uint64     `json:"cursor"`
	Fence  LeaseFence `json:"fence"`
	Kind   string     `json:"kind"`
}

// Reconciler accepts a host stream exactly once and only for the current
// leased epoch. Replayed events are harmless; gaps fail closed and force an
// explicit cursor reconciliation instead of silently losing output.
type Reconciler struct {
	Fence      LeaseFence
	LastCursor uint64
}

func (r *Reconciler) Accept(event Event) (bool, error) {
	if event.Fence != r.Fence {
		return false, ErrStaleFence
	}
	if event.Cursor <= r.LastCursor {
		return false, nil
	}
	if event.Cursor != r.LastCursor+1 {
		return false, ErrCursorGap
	}
	r.LastCursor = event.Cursor
	return true, nil
}

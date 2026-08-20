package chathost

import (
	"errors"
	"testing"
)

func TestReconcilerOrdersDeduplicatesAndFences(t *testing.T) {
	fence := LeaseFence{LeaseID: "lease-1", Epoch: 7}
	r := Reconciler{Fence: fence}

	accepted, err := r.Accept(Event{Cursor: 1, Fence: fence, Kind: "turn.started"})
	if err != nil || !accepted {
		t.Fatalf("first event: accepted=%v err=%v", accepted, err)
	}
	accepted, err = r.Accept(Event{Cursor: 1, Fence: fence, Kind: "turn.started"})
	if err != nil || accepted {
		t.Fatalf("duplicate: accepted=%v err=%v", accepted, err)
	}
	if _, err := r.Accept(Event{Cursor: 3, Fence: fence, Kind: "turn.completed"}); !errors.Is(err, ErrCursorGap) {
		t.Fatalf("gap: got %v", err)
	}
	stale := LeaseFence{LeaseID: "lease-1", Epoch: 6}
	if _, err := r.Accept(Event{Cursor: 2, Fence: stale, Kind: "approval"}); !errors.Is(err, ErrStaleFence) {
		t.Fatalf("stale fence: got %v", err)
	}
	accepted, err = r.Accept(Event{Cursor: 2, Fence: fence, Kind: "turn.completed"})
	if err != nil || !accepted {
		t.Fatalf("reconciled event: accepted=%v err=%v", accepted, err)
	}
}

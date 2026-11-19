package provisioner

import (
	"context"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
)

// TestClaimPollCarriesWarmPoolTarget pins task-48a556bfbe221dcf: every
// provision-job poll tells the control plane the worker's WARM_POOL_SIZE, and
// 0 (pool off) is SENT, not omitted. A missing header is how the control plane
// recognises an older worker and reports "unknown"; a worker with the pool off
// must never be mistaken for one.
func TestClaimPollCarriesWarmPoolTarget(t *testing.T) {
	for _, tc := range []struct {
		target int
		want   string
	}{
		{target: 2, want: "2"},
		{target: 0, want: "0"},
	} {
		var mu sync.Mutex
		got, seen := "", false
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.URL.Path == claimPath {
				mu.Lock()
				got = r.Header.Get(WarmPoolTargetHeader)
				_, seen = r.Header[http.CanonicalHeaderKey(WarmPoolTargetHeader)]
				mu.Unlock()
			}
			w.WriteHeader(http.StatusNoContent)
		}))

		w := &Worker{
			ControlURL:     srv.URL,
			Token:          "worker-token",
			WarmPoolTarget: tc.target,
			Provision: func(context.Context, JobSpec) (string, string, *BootstrapOutputs, Teardown, error) {
				t.Fatal("no job was queued; Provision must not run")
				return "", "", nil, nil, nil
			},
		}
		if _, err := w.RunOnce(context.Background()); err != nil {
			t.Fatalf("target %d: RunOnce: %v", tc.target, err)
		}
		srv.Close()

		mu.Lock()
		if !seen || got != tc.want {
			t.Fatalf("target %d: claim poll sent %s=%q (present=%v), want %q",
				tc.target, WarmPoolTargetHeader, got, seen, tc.want)
		}
		mu.Unlock()
	}
}

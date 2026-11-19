package cloudclient

// warm_pool.go is the client half of `bp cloud warm-pool`:
// GET /v1/operator/warm-pool, platform-operator gated, on the caller's
// bp-login session (the same door as RolloutStatus).

import (
	"context"
	"encoding/json"
	"fmt"
)

// WarmPoolStatus is the warm-pool read. Ready is the claim store's count of
// warm servers (ready + refreshing). The Worker* fields are what the Go worker
// last reported on its job poll; they are nil (and WorkerPool is "unknown")
// when the control plane has not heard from the worker since it started, or
// when the control plane predates the report. Raw is the body verbatim for
// -o json.
type WarmPoolStatus struct {
	Raw            []byte  `json:"-"`
	Ready          int     `json:"ready"`
	WorkerTarget   *int    `json:"worker_target"`
	WorkerPool     string  `json:"worker_pool"`
	WorkerSeenAt   *string `json:"worker_seen_at"`
	WorkerSeenAgoS *int    `json:"worker_seen_ago_s"`
}

// WarmPool reads GET /v1/operator/warm-pool. Read-only. A 404 (an older
// control plane) and a 403 (signed in, not a platform operator) surface as
// *CloudRouteError so the CLI can say which one happened. A 2xx body that does
// not decode comes back WITH its Raw bytes and the decode error, so -o json can
// still print what the control plane said.
func (c *Client) WarmPool(ctx context.Context) (WarmPoolStatus, error) {
	status, body, err := c.do(ctx, "GET", "/v1/operator/warm-pool", true, nil)
	if err != nil {
		return WarmPoolStatus{}, err
	}
	if !ok(status) {
		return WarmPoolStatus{}, routeError(status, body)
	}
	res := WarmPoolStatus{Raw: body}
	if err := json.Unmarshal(body, &res); err != nil {
		return WarmPoolStatus{Raw: body}, fmt.Errorf("decode warm-pool status: %w", err)
	}
	return res, nil
}

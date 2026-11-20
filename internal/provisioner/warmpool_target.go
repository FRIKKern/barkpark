package provisioner

// warmpool_target.go tells the control plane the warm-pool size this worker is
// configured for (WARM_POOL_SIZE), on every provision-job poll.
//
// Why: the claim store can hold `ready` warm servers while this worker runs
// with the pool off. On 2026-11-19 it held two while a forgotten systemd
// drop-in set WARM_POOL_SIZE=0, and the only operator read said "ready 2".
// The control plane remembers the last value it saw here
// (BarkparkCloud.Registry.WarmPoolTarget) so `GET /v1/operator/warm-pool` and
// `bp cloud warm-pool` can say "the worker's target is 0".
//
// The header rides the claim poll because that poll already runs every few
// seconds with WORKER_TOKEN; no new route or timer is needed. It is ALWAYS
// sent, 0 included: a missing header means "an older worker", which the
// control plane reports as unknown, while 0 means "this worker has the pool
// off". It changes nothing about claim, refill or reconcile.

import (
	"net/http"
	"strconv"
)

// WarmPoolTargetHeader carries Worker.WarmPoolTarget on the provision claim.
const WarmPoolTargetHeader = "X-Barkpark-Warm-Pool-Target"

// stampWarmPoolTarget sets the target header on a claim request. A negative
// value (never produced by warmPoolSize) is sent as 0, the pool-off value.
func (w *Worker) stampWarmPoolTarget(req *http.Request) {
	n := w.WarmPoolTarget
	if n < 0 {
		n = 0
	}
	req.Header.Set(WarmPoolTargetHeader, strconv.Itoa(n))
}

package provisioner

import (
	"fmt"

	"github.com/FRIKKern/barkpark/internal/cli/cloud"
)

// launch_host.go says, on every Hetzner launch, whether the launch took a warm
// server from the pool or creates a new one, and why. On 2026-11-19 a plain
// `bp launch hetzner` created a new server while two warm servers sat ready:
// the worker ran with WARM_POOL_SIZE=0 and nothing said so. acquireHost now
// writes one `create`/`progress` line before the create starts, through the same
// step reporter the chain uses, so the job's console carries the answer.
//
// The control plane accepts only its fixed step names
// (cloud/lib/barkpark_cloud/registry/provision_job.ex @steps), so this rides the
// existing `create` step instead of adding one. Sent before create/started, the
// line has no in-flight step entry to caption, so the control plane keeps it in
// the job's console (`provision_console`), not in `provision_steps`.

// The caption wording lives in internal/cli/cloud/launch_host_line.go, beside
// the parser `bp cloud status` reads it back with. Warm: "Warm server
// warm-52d0bbcf claimed" (sent right after the claim, before the assign runs).
// Cold: "No warm server: <why> — creating a new server".

// hostReason is why a launch got the server it got. The values are stable so a
// test (or a later reader of the console) can tell the cases apart without
// parsing the caption.
type hostReason string

const (
	// hostWarm: a warm server was claimed and is being assigned to the launch.
	hostWarm hostReason = "warm"
	// hostPoolOff: the worker runs with the warm pool off (WARM_POOL_SIZE=0 or
	// unset, or no claim client wired).
	hostPoolOff hostReason = "pool_off"
	// hostPoolEmpty: the pool is on but had no ready server.
	hostPoolEmpty hostReason = "pool_empty"
	// hostPinMismatch: the launch pins a region or server type the pool was not
	// built for, so no warm server is claimed.
	hostPinMismatch hostReason = "pin_mismatch"
	// hostClaimError: asking the control plane for a warm server failed.
	hostClaimError hostReason = "claim_error"
	// hostAssignFailed: a warm server was claimed but could not be set up for the
	// launch; it was torn down.
	hostAssignFailed hostReason = "assign_failed"
)

// hostDecision is one launch's answer: the reason, plus the detail the caption
// shows (the warm server's name for hostWarm, the plain reason otherwise).
type hostDecision struct {
	reason hostReason
	detail string
}

// caption is the line the step feed and console show.
func (d hostDecision) caption() string {
	if d.reason == hostWarm {
		return cloud.WarmHostCaption(d.detail)
	}
	return cloud.ColdHostCaption(d.detail)
}

func poolOffDecision(seams Seams) hostDecision {
	if seams.WarmPoolSize <= 0 {
		return hostDecision{hostPoolOff, "warm pool is off on the worker (WARM_POOL_SIZE=0)"}
	}
	return hostDecision{hostPoolOff, "warm pool has no claim client on the worker"}
}

func pinMismatchDecision(req, base cloud.ServerSpec) hostDecision {
	return hostDecision{hostPinMismatch, fmt.Sprintf("this launch pins region %s / type %s, the pool is %s/%s",
		orDash(req.Region), orDash(req.ServerType), orDash(base.Region), orDash(base.ServerType))}
}

func orDash(s string) string {
	if s == "" {
		return "-"
	}
	return s
}

// hostNarrator returns the callback acquireHost reports its decision through:
// the WarmPool's Progress hook (the job's step reporter, teed to the console) as
// a `create`/`progress` line. nil Progress (a test without a reporter) is silent.
func hostNarrator(wp *cloud.WarmPool) func(hostDecision) {
	return func(d hostDecision) {
		if wp.Progress != nil {
			wp.Progress("create", "progress", d.caption())
		}
	}
}

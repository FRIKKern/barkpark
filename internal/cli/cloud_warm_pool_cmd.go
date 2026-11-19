package cli

// cloud_warm_pool_cmd.go is `bp cloud warm-pool`: how many warm servers stand
// ready in the claim store, and the pool size the Go worker last reported
// (GET /v1/operator/warm-pool, platform operator, the caller's bp-login
// session).
//
// The two numbers belong together. On 2026-11-19 the claim store held two
// ready warm servers while the worker ran with WARM_POOL_SIZE=0, so no go-live
// would ever claim them; the ready count alone read as "2 warm servers
// waiting". This verb leads with the sentence that matters in that case:
// "warm pool is OFF on the worker (target 0) — 2 ready boxes will not be used".
// When the control plane has not heard from the worker, it says unknown and
// never guesses 0 or on.

import (
	"errors"
	"fmt"

	"github.com/FRIKKern/barkpark/internal/cloudclient"
)

// runCloudWarmPool is `bp cloud warm-pool [-o json|yaml]`.
func runCloudWarmPool(out *writer, g globals, args []string) int {
	for _, a := range args {
		if a == "-h" || a == "--help" || a == "help" {
			printCloudWarmPoolHelp(out)
			return exitOK
		}
	}
	if g.help {
		printCloudWarmPoolHelp(out)
		return exitOK
	}
	const usage = "bp cloud warm-pool"
	a, err := parseHzArgs(args, nil, nil, usage)
	if err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	if len(a.pos) != 0 {
		return useError(out, "usage", "warm-pool takes no arguments (usage: "+usage+")", exitUsage)
	}

	cfg, cerr := LoadConfig()
	if cerr != nil {
		return useError(out, "failed", "read config: "+cerr.Error(), exitGeneric)
	}
	if !cfg.HasCloudToken() {
		return useError(out, "auth", "not logged in — run `bp login` to read the warm pool, or set BARKPARK_CLOUD_TOKEN for a CI job", exitAuth)
	}

	st, rerr := cfg.CloudClient().WarmPool(cloudCtx())
	structured := out.output == "json" || out.output == "yaml"
	// A body that answered 2xx but did not decode still carries Raw: -o json
	// passes it through rather than hiding what the control plane said.
	if rerr != nil && !(structured && len(st.Raw) > 0) {
		return warmPoolFail(out, rerr)
	}

	if structured {
		out.renderRaw(st.Raw)
		return exitOK
	}
	for i, line := range warmPoolLines(st) {
		if i == 0 && warmPoolOffWithReady(st) {
			line = out.paintCell(line, "warn")
		}
		out.outf("%s", line)
	}
	return exitOK
}

// warmPoolOffWithReady is the 2026-11-19 case: boxes stand ready, and the
// worker says its pool is off, so nothing will claim them.
func warmPoolOffWithReady(st cloudclient.WarmPoolStatus) bool {
	return st.WorkerTarget != nil && *st.WorkerTarget == 0 && st.Ready > 0
}

// warmPoolLines renders the human view: one headline, plus a second line when
// the headline needs a reason.
func warmPoolLines(st cloudclient.WarmPoolStatus) []string {
	if st.WorkerTarget == nil {
		why := "  the worker has not polled this control plane since it started, or runs a build that does not report its target"
		if st.WorkerPool == "" {
			why = "  this control plane does not report the worker's target yet (update it)"
		}
		return []string{fmt.Sprintf("warm pool: %d ready · worker target unknown", st.Ready), why}
	}
	seen := "seen " + warmPoolAgo(st.WorkerSeenAgoS)
	target := *st.WorkerTarget
	if warmPoolOffWithReady(st) {
		boxes := "boxes"
		if st.Ready == 1 {
			boxes = "box"
		}
		return []string{
			fmt.Sprintf("warm pool is OFF on the worker (target 0) — %d ready %s will not be used", st.Ready, boxes),
			"  worker " + seen,
		}
	}
	targetText := fmt.Sprintf("worker target %d", target)
	if target == 0 {
		targetText += " (off)"
	}
	return []string{fmt.Sprintf("warm pool: %d ready · %s · %s", st.Ready, targetText, seen)}
}

// warmPoolAgo renders the worker's last poll age in whole units.
func warmPoolAgo(s *int) string {
	switch {
	case s == nil:
		return "at an unknown time"
	case *s < 120:
		return fmt.Sprintf("%d s ago", *s)
	case *s < 2*60*60:
		return fmt.Sprintf("%d min ago", *s/60)
	default:
		return fmt.Sprintf("%d h ago", *s/3600)
	}
}

// warmPoolFail maps a refused read onto the `bp:` error seam: 404 is an older
// control plane, 403 is a signed-in account that is not a platform operator;
// anything else (an expired session included) goes through cloudFail.
func warmPoolFail(out *writer, err error) int {
	var re *cloudclient.CloudRouteError
	if errors.As(err, &re) {
		switch re.Code {
		case "not_found":
			return useError(out, "not_found", "this control plane has no warm-pool read (update it)", exitNotFound)
		case "forbidden":
			return useError(out, "auth",
				"you are signed in, but this account is not a platform operator — the warm-pool read is gated on the control plane's "+
					"PLATFORM_ADMIN_EMAILS allowlist (re-running `bp login` will not change this)",
				exitAuth)
		}
	}
	return cloudFail(out, "warm pool", err)
}

// printCloudWarmPoolHelp writes `bp cloud warm-pool` usage.
func printCloudWarmPoolHelp(out *writer) {
	const help = `bp cloud warm-pool — warm servers ready vs the pool size the worker runs with (platform operator).

USAGE
  bp cloud warm-pool [-o json|yaml]

WHAT IT DOES
  Reads the control plane's warm-pool status on YOUR bp-login session. It is
  PLATFORM-OPERATOR gated (the PLATFORM_ADMIN_EMAILS allowlist). It shows:

    ready          warm servers in the claim store (ready + refreshing)
    worker target  the WARM_POOL_SIZE the provisioner worker reported on its
                   last job poll, and how long ago that was

  When the target is 0 and servers stand ready, it says the pool is OFF on the
  worker: a go-live will not use those servers. When the control plane has not
  heard from the worker since it started (a fresh blue/green slot, or an older
  worker build), the target reads unknown.

OUTPUT
  plain lines, for example
    warm pool: 2 ready · worker target 2 · seen 4 s ago
    warm pool is OFF on the worker (target 0) — 2 ready boxes will not be used
  -o json emits the control plane's body: {ready, worker_target, worker_pool,
  worker_seen_at, worker_seen_ago_s}.`
	out.outf("%s", help)
}

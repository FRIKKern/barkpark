// Command barkpark-provisioner is the Go warm-pool worker that closes the ONE
// integration gap in Barkpark Cloud: /v1/launch + /v1/go-live pay and create a
// `provisioning` Barkpark row but do NOT provision — this worker drains the
// provision_jobs queue and runs the cloud-6 WarmPool.Provision chain for each.
//
// It claims jobs from the Elixir control plane with the shared WORKER_TOKEN
// (Authorization: Bearer <WORKER_TOKEN> — a separate principal from user/agent
// tokens), provisions a live host, and reports the IP back so the barkpark
// flips to "up". One job at a time, poll-based (no concurrency/backoff beyond
// --interval — YAGNI).
//
// Usage:
//
//	barkpark-provisioner \
//	  --control-url https://cloud.barkpark.dev \
//	  --token-file  /etc/barkpark/worker.token \
//	  --interval    5s
//
// Production reads the SAME Hetzner Cloud token (HCLOUD_TOKEN / an active
// `hcloud context`) for BOTH the server provider AND DNS — the DNS seam is
// cloud.CloudDNS, which shells out to `hcloud zone rrset` (Hetzner's integrated
// Cloud DNS) rather than the legacy dns.hetzner.com REST API. No separate
// HETZNER_DNS_TOKEN/HETZNER_DNS_ZONE_ID is needed (the legacy cloud.HetznerDNS
// stays available but is no longer the default). With --once it runs a single
// claim→provision→report cycle and exits (smoke tests / a systemd timer).
package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"strings"
	"syscall"

	"github.com/FRIKKern/barkpark/internal/cli/cloud"
	"github.com/FRIKKern/barkpark/internal/provisioner"
)

// sweepEveryCycles runs the orphan sweep every Nth completed claim cycle (on top
// of the startup sweep), so a long-lived worker keeps recovering leaked orphan
// boxes without a separate timer. 200 cycles at the default 5s idle cadence is
// ~one sweep every several minutes when idle, and far less often under load —
// cheap (one labeled `hcloud server list`) and well clear of any rate concern.
const sweepEveryCycles = 200

func main() {
	os.Exit(run(os.Args[1:]))
}

func run(args []string) int {
	fs := flag.NewFlagSet("barkpark-provisioner", flag.ContinueOnError)
	var (
		controlURL = fs.String("control-url", "", "control-plane origin (required), e.g. https://cloud.barkpark.dev")
		token      = fs.String("token", "", "shared WORKER_TOKEN (or set WORKER_TOKEN env; --token-file takes precedence)")
		tokenFile  = fs.String("token-file", "", "path to the WORKER_TOKEN file (overrides --token and $WORKER_TOKEN)")
		interval   = fs.Duration("interval", provisioner.DefaultInterval, "claim-poll cadence when the queue is empty")
		once       = fs.Bool("once", false, "run a single claim→provision→report cycle and exit")
	)
	if err := fs.Parse(args); err != nil {
		return 2
	}

	if *controlURL == "" {
		fmt.Fprintln(os.Stderr, "barkpark-provisioner: --control-url is required")
		fs.Usage()
		return 2
	}

	tok, err := resolveToken(*tokenFile, *token)
	if err != nil {
		fmt.Fprintf(os.Stderr, "barkpark-provisioner: %v\n", err)
		return 1
	}

	// Fail fast on an unset BARKPARK_SERVER_IMAGE: without the baked warm-pool
	// snapshot id, DefaultSpec falls back to bare ubuntu-22.04, which has NO
	// Barkpark installed — every provision would create a server, fail the health
	// gate, and tear it down (paid create churn with no customer ever served). The
	// honest signal is to refuse to start. (BARKPARK_SSH_KEY / BARKPARK_SSH_KEY_FILE
	// are validated lazily by the provider/runner with their own clear errors.)
	if strings.TrimSpace(os.Getenv("BARKPARK_SERVER_IMAGE")) == "" {
		fmt.Fprintln(os.Stderr, "barkpark-provisioner: BARKPARK_SERVER_IMAGE is required (the baked warm-pool snapshot id; without it instances boot bare ubuntu with no Barkpark and fail the health gate)")
		return 1
	}

	// Wire the REAL Hetzner provider + Cloud DNS from the SAME Cloud token. DNS
	// is cloud.CloudDNS (`hcloud zone rrset`, integrated Cloud DNS) — no separate
	// HETZNER_DNS_TOKEN. The Caddy/TLS + migrate steps run ON each provisioned
	// instance over SSH: RunnerFor is the per-host SSHStepRunner factory, so real
	// provisions configure the NEW box (not the worker's own machine). The health
	// gate stays the real default (green-by-real-gate — fail closed). The in-chain
	// registry is a no-op: the authoritative registration is the worker's /succeed
	// POST.
	seams := provisioner.Seams{
		Provider: cloud.HcloudProvider{},
		DNS:      cloud.NewCloudDNS(),
		Registry: provisioner.NopRegistry{},
		RunnerFor: func(host string) cloud.StepRunner {
			return cloud.NewSSHStepRunner(host)
		},
		// Health/Caddy/Secrets left nil → the real cloud-package defaults.
	}

	w := &provisioner.Worker{
		ControlURL: *controlURL,
		Token:      tok,
		Interval:   *interval,
		Provision:  provisioner.DefaultProvision(seams),
		// The Remove drain: delete the real Hetzner box + DNS for a deprovision
		// job (idempotent). Runs in its own goroutine below.
		Deprovision: provisioner.DefaultDeprovision(seams),
		// Auto-recover orphan boxes (a prior double-failure: succeed-report failed →
		// teardown → provider.Delete failed → box marked barkpark-orphaned=true). The
		// sweep deletes ONLY those labeled boxes — never a managed/live box — so it is
		// safe to run on startup and periodically.
		Sweep:      provisioner.DefaultSweep(seams),
		SweepEvery: sweepEveryCycles,
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	// STARTUP sweep: recover any orphan leaked by a prior run before draining jobs.
	// Best-effort — a sweep failure (e.g. the control plane / hcloud briefly down)
	// must not stop the worker from doing its real job.
	if swept, serr := w.SweepOnce(ctx); serr != nil {
		fmt.Fprintf(os.Stderr, "barkpark-provisioner: startup orphan sweep failed (non-fatal): %v\n", serr)
	} else if swept > 0 {
		fmt.Fprintf(os.Stderr, "barkpark-provisioner: startup orphan sweep deleted %d leaked box(es)\n", swept)
	}

	if *once {
		claimed, err := w.RunOnce(ctx)
		if err != nil {
			fmt.Fprintf(os.Stderr, "barkpark-provisioner: cycle failed: %v\n", err)
			return 1
		}
		if !claimed {
			fmt.Fprintln(os.Stderr, "barkpark-provisioner: no pending job")
		}
		return 0
	}

	fmt.Fprintf(os.Stderr, "barkpark-provisioner: draining %s (provision + deprovision) every %s\n", *controlURL, interval.String())

	go func() {
		_ = w.RunDeprovisionWith(ctx, func(claimed bool, err error) {
			switch {
			case err != nil:
				fmt.Fprintf(os.Stderr, "barkpark-provisioner: deprovision cycle error: %v\n", err)
			case claimed:
				fmt.Fprintln(os.Stderr, "barkpark-provisioner: deprovisioned a box")
			}
		})
	}()

	w.RunWith(ctx, func(claimed bool, err error) {
		switch {
		case err != nil:
			fmt.Fprintf(os.Stderr, "barkpark-provisioner: cycle error: %v\n", err)
		case claimed:
			fmt.Fprintln(os.Stderr, "barkpark-provisioner: provisioned a job")
		}
	})
	// RunWith returns only when ctx is cancelled (signal) — a clean shutdown.
	fmt.Fprintln(os.Stderr, "barkpark-provisioner: shutting down")
	return 0
}

// resolveToken loads the shared WORKER_TOKEN, in precedence order: --token-file,
// then --token, then $WORKER_TOKEN. An all-empty result is an error — a blank
// token would let the worker hit the internal endpoints unauthenticated (the
// control plane would 401, but failing here is the honest, early signal).
func resolveToken(tokenFile, tokenFlag string) (string, error) {
	if tokenFile != "" {
		data, err := os.ReadFile(tokenFile)
		if err != nil {
			return "", fmt.Errorf("read token file: %w", err)
		}
		tok := strings.TrimSpace(string(data))
		if tok == "" {
			return "", fmt.Errorf("token file %s is empty", tokenFile)
		}
		return tok, nil
	}
	if tok := strings.TrimSpace(tokenFlag); tok != "" {
		return tok, nil
	}
	if tok := strings.TrimSpace(os.Getenv("WORKER_TOKEN")); tok != "" {
		return tok, nil
	}
	return "", fmt.Errorf("a worker token is required (--token-file, --token, or $WORKER_TOKEN)")
}

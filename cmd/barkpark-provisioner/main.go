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
// Production reads HCLOUD_TOKEN + HETZNER_DNS_TOKEN (+ HETZNER_DNS_ZONE_ID) from
// the environment to wire the REAL Hetzner provider/DNS. With --once it runs a
// single claim→provision→report cycle and exits (smoke tests / a systemd timer).
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

	// Wire the REAL Hetzner provider/DNS from env. The health gate stays the
	// real default (green-by-real-gate — fail closed). The in-chain registry is
	// a no-op: the authoritative registration is the worker's /succeed POST.
	seams := provisioner.Seams{
		Provider: cloud.HcloudProvider{},
		DNS:      cloud.NewHetznerDNS(os.Getenv("HETZNER_DNS_ZONE_ID")),
		Registry: provisioner.NopRegistry{},
		// Health/Caddy/Runner/Secrets left nil → the real cloud-package defaults.
	}

	w := &provisioner.Worker{
		ControlURL: *controlURL,
		Token:      tok,
		Interval:   *interval,
		Provision:  provisioner.DefaultProvision(seams),
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

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

	fmt.Fprintf(os.Stderr, "barkpark-provisioner: draining %s%s every %s\n", *controlURL, "/v1/internal/provision-jobs/claim", interval.String())
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

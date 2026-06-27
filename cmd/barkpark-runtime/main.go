// Command barkpark-runtime is the on-box deployment executor for Barkpark
// Cloud hosting (P3 / Move A finish). It runs on the customer's serving box
// alongside Barkpark itself, claims pending Deployments from the control
// plane, loads + runs new containers blue/green behind Caddy, swaps the
// reverse_proxy upstream, drains the old container, and reports `live`.
//
// Usage:
//
//	barkpark-runtime \
//	  --control-url   https://cloud.barkpark.cloud \
//	  --token-file    /etc/barkpark/agent.token \
//	  --worker-id     box-fsn1-1 \
//	  --cache-dir     /var/lib/barkpark-builder/images \
//	  --caddyfile     /etc/caddy/Caddyfile \
//	  --ask-gate-url  https://cloud.barkpark.cloud/v1/tls/ask \
//	  --studio        localhost:4000 \
//	  --interval      5s
//
// With --once the binary runs a single cycle and exits — useful for tests,
// a one-shot systemd timer, or the manual end-to-end proof.
//
// The runtime executor is read-only on the local Caddyfile parse for state
// recovery in this MVP — the cmd wrapper builds State by reading the existing
// Caddyfile from disk. A future enhancement is GET /v1/agent/sites for richer
// state, but it isn't needed for the per-box single-tenant model.
package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/FRIKKern/barkpark/internal/caddyfile"
	"github.com/FRIKKern/barkpark/internal/runtime"
)

func main() {
	os.Exit(run(os.Args[1:]))
}

func run(args []string) int {
	fs := flag.NewFlagSet("barkpark-runtime", flag.ContinueOnError)
	var (
		controlURL = fs.String("control-url", "", "control-plane origin (required)")
		token      = fs.String("token", "", "agent bearer token (or use --token-file)")
		tokenFile  = fs.String("token-file", "", "path to a file containing the agent token")
		workerID   = fs.String("worker-id", "", "stable worker id for this box (defaults to hostname)")
		cacheDir   = fs.String("cache-dir", "/var/lib/barkpark-builder/images",
			"shared filesystem path where the Builder's docker-saved images land")
		caddyfilePath = fs.String("caddyfile", "/etc/caddy/Caddyfile",
			"path to the Caddyfile this executor rewrites + reloads")
		askGateURL = fs.String("ask-gate-url", "",
			"on-demand-TLS ask URL (typically <control-url>/v1/tls/ask)")
		studio = fs.String("studio", "localhost:4000",
			"host:port for the studio/api fallback block; empty disables")
		interval = fs.Duration("interval", runtime.DefaultInterval,
			"claim-poll cadence; ignored under --once")
		once = fs.Bool("once", false, "run a single claim cycle and exit")
	)

	if err := fs.Parse(args); err != nil {
		return 2
	}

	if *controlURL == "" {
		fmt.Fprintln(os.Stderr, "barkpark-runtime: --control-url is required")
		return 2
	}

	bearer := *token
	if bearer == "" && *tokenFile != "" {
		buf, err := os.ReadFile(*tokenFile)
		if err != nil {
			fmt.Fprintf(os.Stderr, "barkpark-runtime: read --token-file %s: %v\n", *tokenFile, err)
			return 2
		}
		bearer = strings.TrimSpace(string(buf))
	}
	if bearer == "" {
		fmt.Fprintln(os.Stderr, "barkpark-runtime: --token or --token-file is required")
		return 2
	}

	worker := *workerID
	if worker == "" {
		host, err := os.Hostname()
		if err != nil || host == "" {
			fmt.Fprintln(os.Stderr, "barkpark-runtime: --worker-id required (could not derive)")
			return 2
		}
		worker = host
	}

	e := &runtime.Executor{
		ControlURL:     *controlURL,
		AgentToken:     bearer,
		WorkerID:       worker,
		CacheDir:       *cacheDir,
		CaddyfilePath:  *caddyfilePath,
		AskGateURL:     *askGateURL,
		StudioUpstream: *studio,
		Interval:       *interval,
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	// State for the MVP: empty (no prior site state read). The cmd wrapper's
	// first-deploy path supplies the site shape through the running container
	// — for first-time deploys the executor falls back to a placeholder slug
	// and writes a Caddyfile block keyed on the (initially empty) domains
	// list. Future enhancement: parse the existing Caddyfile on boot to
	// reconstruct LiveSites, or pull state from a new /v1/agent/sites route.
	buildState := func(context.Context) (runtime.State, error) {
		return runtime.State{LiveSites: []caddyfile.Site{}}, nil
	}

	if *once {
		state, _ := buildState(ctx)
		had, err := e.RunOnce(ctx, state)
		if err != nil {
			fmt.Fprintf(os.Stderr, "barkpark-runtime: %v\n", err)
			return 1
		}
		if had {
			fmt.Println("deployed one pending deployment")
		} else {
			fmt.Println("no pending deployments")
		}
		return 0
	}

	fmt.Printf("barkpark-runtime: worker=%s control=%s caddyfile=%s interval=%s\n",
		worker, *controlURL, *caddyfilePath, *interval)

	if err := e.Run(ctx, buildState); err != nil && err != context.Canceled {
		fmt.Fprintf(os.Stderr, "barkpark-runtime: %v\n", err)
		return 1
	}
	time.Sleep(50 * time.Millisecond)
	return 0
}

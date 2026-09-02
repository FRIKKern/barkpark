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
//	  --interval      5s \
//	  --retain-images 3
//
// Image retention: every deploy `docker load`s a fresh image and leaves the
// previous container stopped (the instant rollback), and a stopped container
// pins its image against `docker image prune` — so before --retain-images
// existed a box grew one container and one ~1 GB image per deploy, forever
// (jarl: 18 images / 20.76 GB on a 38 GB disk, 100% full, CMS down). After a
// PROVEN cutover the executor now keeps the newest N generations per site —
// 1 live + N-1 rollback targets — and reaps the rest. N defaults to
// runtime.DefaultRetainImages (3); --retain-images -1 restores the old
// never-delete behaviour.
//
// With --once the binary runs a single cycle and exits — useful for tests,
// a one-shot systemd timer, or the manual end-to-end proof.
//
// State recovery: before every claim cycle the executor re-parses the on-box
// Caddyfile — blocks marked "# Managed by barkpark-runtime" come back as live
// sites (slug, domains, upstream port), and every port claimed by a foreign
// vhost is reserved so the allocator never collides with it. The on-disk file
// is the source of truth for what Caddy is actually serving; a future GET
// /v1/agent/sites route could supplement it, but isn't needed for the per-box
// single-tenant model.
package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

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
		once         = fs.Bool("once", false, "run a single claim cycle and exit")
		retainImages = fs.Int("retain-images", 0,
			"container/image generations kept PER SITE after a proven cutover "+
				"(1 live + N-1 rollback); 0 uses the built-in default, -1 disables the sweep")
		buildCacheKeep = fs.String("build-cache-keep", "",
			"BuildKit cache floor swept to after a proven cutover, e.g. 5GB; "+
				"empty uses the built-in default, \"off\" disables that arm")
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
		RetainImages:   *retainImages,
		BuildCacheKeep: *buildCacheKeep,
		Logger:         log.Printf,
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	// State is reconstructed from the on-box Caddyfile before EVERY cycle —
	// never assumed empty, never cached from boot. The old MVP stub returned
	// an empty State each cycle, which broke a real box twice over: (a) the
	// executor rewrote the Caddyfile from nothing, deleting every vhost it did
	// not just create (the instance's own API/Studio vhost and the
	// attach-domain vhost went TLS-dead in production), and (b) with no live
	// ports visible the allocator re-issued the same port on the second deploy
	// while the first container still bound it (`docker run` exit 125).
	// StateFromDisk parses the file fresh per cycle, so a long-running
	// executor also never goes stale against edits by the provisioner,
	// attach-domain, or an operator.
	buildState := e.StateFromDisk

	if *once {
		state, err := buildState(ctx)
		if err != nil {
			fmt.Fprintf(os.Stderr, "barkpark-runtime: %v\n", err)
			return 1
		}
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

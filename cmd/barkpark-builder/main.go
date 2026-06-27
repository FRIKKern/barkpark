// Command barkpark-builder is the off-box build plane for Barkpark Cloud
// (P2 / Move A). It claims queued Deployments from the control plane, runs
// `nixpacks build` against the deployment's artifact, `docker save`s the image
// to a shared cache, and transitions the Deployment to "pushing" (or "failed").
// The binary runs on a host PHYSICALLY SEPARATE from the customer's serving
// box, so a Next.js build never starves the Postgres + Caddy answering live
// traffic.
//
// Usage:
//
//	barkpark-builder \
//	  --control-url https://cloud.barkpark.dev \
//	  --token-file  /etc/barkpark/builder.token \
//	  --worker-id   builder-host-1 \
//	  --cache-dir   /var/lib/barkpark-builder/images \
//	  --log-dir     /var/lib/barkpark-builder/logs \
//	  --platform    linux/arm64 \
//	  --interval    5s
//
// With --once the binary runs a single claim → build → transition cycle and
// exits — useful for tests, a one-shot systemd timer, or manual smoke runs.
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

	"github.com/FRIKKern/barkpark/internal/builder"
)

func main() {
	os.Exit(run(os.Args[1:]))
}

func run(args []string) int {
	fs := flag.NewFlagSet("barkpark-builder", flag.ContinueOnError)
	var (
		controlURL = fs.String("control-url", "", "control-plane origin (required)")
		token      = fs.String("token", "", "builder bearer token (or use --token-file)")
		tokenFile  = fs.String("token-file", "", "path to a file containing the builder token")
		workerID   = fs.String("worker-id", "", "stable worker id for this builder host (defaults to hostname)")
		cacheDir   = fs.String("cache-dir", "/var/lib/barkpark-builder/images",
			"directory for docker-saved image tarballs (consumed by the box agent)")
		logDir = fs.String("log-dir", "/var/lib/barkpark-builder/logs",
			"directory for per-deployment build logs (path → build_log_url file://)")
		platform = fs.String("platform", "",
			"nixpacks --platform value (e.g. linux/arm64); defaults to nixpacks' own default")
		interval = fs.Duration("interval", builder.DefaultInterval,
			"claim-poll cadence; ignored under --once")
		once = fs.Bool("once", false, "run a single claim cycle and exit")
	)

	if err := fs.Parse(args); err != nil {
		return 2
	}

	if *controlURL == "" {
		fmt.Fprintln(os.Stderr, "barkpark-builder: --control-url is required")
		return 2
	}

	bearer := *token
	if bearer == "" && *tokenFile != "" {
		buf, err := os.ReadFile(*tokenFile)
		if err != nil {
			fmt.Fprintf(os.Stderr, "barkpark-builder: read --token-file %s: %v\n", *tokenFile, err)
			return 2
		}
		bearer = strings.TrimSpace(string(buf))
	}
	if bearer == "" {
		fmt.Fprintln(os.Stderr, "barkpark-builder: --token or --token-file is required")
		return 2
	}

	worker := *workerID
	if worker == "" {
		host, err := os.Hostname()
		if err != nil || host == "" {
			fmt.Fprintln(os.Stderr, "barkpark-builder: --worker-id is required (could not derive from hostname)")
			return 2
		}
		worker = host
	}

	b := &builder.Builder{
		ControlURL: *controlURL,
		Token:      bearer,
		WorkerID:   worker,
		Platform:   *platform,
		CacheDir:   *cacheDir,
		LogDir:     *logDir,
		Interval:   *interval,
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	if *once {
		had, err := b.RunOnce(ctx)
		if err != nil {
			fmt.Fprintf(os.Stderr, "barkpark-builder: %v\n", err)
			return 1
		}
		if had {
			fmt.Println("built one deployment")
		} else {
			fmt.Println("no queued deployments")
		}
		return 0
	}

	fmt.Printf("barkpark-builder: worker=%s control=%s platform=%s interval=%s\n",
		worker, *controlURL, *platform, *interval)

	if err := b.Run(ctx); err != nil && err != context.Canceled {
		fmt.Fprintf(os.Stderr, "barkpark-builder: %v\n", err)
		return 1
	}
	// Allow systemd a graceful drain after SIGTERM.
	time.Sleep(50 * time.Millisecond)
	return 0
}

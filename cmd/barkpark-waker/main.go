// Command barkpark-waker is the per-site scale-to-zero front door for
// Barkpark Cloud (P7 stream C). Caddy reverse_proxies the site's domains to
// this binary instead of directly to the container; the waker brings the
// container up on first request, proxies, and reaps it after IdleTimeout of
// zero traffic.
//
// One waker process per site. Memory footprint is ~5 MB resident — cheap
// enough that a single box can host hundreds of zero-traffic sites in the
// memory budget of one always-on container.
//
// Usage:
//
//	barkpark-waker \
//	  --site            shop \
//	  --container       site-shop \
//	  --image           site-shop-d-12345678 \
//	  --external-port   7142 \
//	  --internal-port   7242 \
//	  --idle-timeout    5m \
//	  --memory          256m \
//	  --cpus            0.5
//
// The runtime executor (cmd/barkpark-runtime) spawns this binary when it
// deploys a Site with scale_mode="zero" instead of running the container
// directly.
package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"os"
	"os/signal"
	"syscall"

	"github.com/FRIKKern/barkpark/internal/waker"
)

func main() {
	var (
		site         = flag.String("site", "", "site slug (logs only)")
		container    = flag.String("container", "", "docker container name")
		image        = flag.String("image", "", "docker image tag")
		externalPort = flag.Int("external-port", 0, "loopback port the waker listens on (Caddy upstream)")
		internalPort = flag.Int("internal-port", 0, "loopback port the container binds when up")
		innerPort    = flag.Int("inner-port", waker.DefaultContainerInnerPort, "port inside the container the app binds to")
		memory       = flag.String("memory", "256m", "docker --memory cap")
		cpus         = flag.String("cpus", "1", "docker --cpus cap")
		idle         = flag.Duration("idle-timeout", waker.DefaultIdleTimeout, "zero-traffic window before sleeping the container")
		healthTO     = flag.Duration("health-timeout", waker.DefaultHealthTimeout, "cold-wake health-check budget")
	)
	flag.Parse()

	if *container == "" || *image == "" || *externalPort == 0 || *internalPort == 0 {
		fmt.Fprintln(os.Stderr, "barkpark-waker: --container, --image, --external-port, --internal-port are all required")
		os.Exit(2)
	}

	dc := &waker.DockerContainer{
		Name:               *container,
		Image:              *image,
		InternalPort:       *internalPort,
		ContainerInnerPort: *innerPort,
		Memory:             *memory,
		CPUs:               *cpus,
		HealthTimeout:      *healthTO,
	}

	w := &waker.Waker{
		SiteSlug:     *site,
		InternalPort: *internalPort,
		ExternalPort: *externalPort,
		Container:    dc,
		IdleTimeout:  *idle,
		Logger:       log.Printf,
	}

	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer cancel()

	log.Printf("waker(%s): listening on :%d → 127.0.0.1:%d (idle=%s)",
		*site, *externalPort, *internalPort, *idle)

	if err := w.Run(ctx); err != nil && err != context.Canceled {
		log.Fatalf("waker(%s): %v", *site, err)
	}
}

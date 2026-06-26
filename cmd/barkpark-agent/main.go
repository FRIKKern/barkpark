// Command barkpark-agent is the transparent on-box agent: it reports the
// server's health/status to the control plane and runs APPROVED commands from a
// poll-based queue. It is a plain binary — install it next to a systemd unit,
// remove it with `bp agent uninstall` (cloud-11); it keeps no hidden state.
//
// Usage:
//
//	barkpark-agent \
//	  --control-url https://cloud.barkpark.dev \
//	  --token-file  /etc/barkpark/agent.token \
//	  --checkout    /opt/barkpark \
//	  --health-url  https://this-server.example.com \
//	  --interval    60s
//
// The agent loops report→poll→run on --interval until SIGINT/SIGTERM. With
// --once it runs a single cycle and exits (handy for a systemd timer instead of
// a long-lived service, and for smoke tests).
package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"strings"
	"syscall"

	"github.com/FRIKKern/barkpark/internal/agent"
	"github.com/FRIKKern/barkpark/internal/cli/setup"
)

func main() {
	os.Exit(run(os.Args[1:]))
}

func run(args []string) int {
	fs := flag.NewFlagSet("barkpark-agent", flag.ContinueOnError)
	var (
		controlURL = fs.String("control-url", "", "control-plane origin (required), e.g. https://cloud.barkpark.dev")
		tokenFile  = fs.String("token-file", "", "path to the agent bearer token file (required)")
		interval   = fs.Duration("interval", agent.DefaultInterval, "report+poll cadence")
		once       = fs.Bool("once", false, "run a single report+poll cycle and exit")
		checkout   = fs.String("checkout", "/opt/barkpark", "deployed code dir git is read from")
		healthURL  = fs.String("health-url", "", "this server's public origin for the health gate (empty skips it)")
		healthTok  = fs.String("health-token", "", "token for the health gate's DB-read probe (optional)")
		printCmds  = fs.Bool("print-allowed-commands", false, "print the approved command allowlist and exit")
	)
	if err := fs.Parse(args); err != nil {
		return 2
	}

	if *printCmds {
		fmt.Println(strings.Join(agent.AllowedCommands(), "\n"))
		return 0
	}

	if *controlURL == "" || *tokenFile == "" {
		fmt.Fprintln(os.Stderr, "barkpark-agent: --control-url and --token-file are required")
		fs.Usage()
		return 2
	}

	token, err := readToken(*tokenFile)
	if err != nil {
		fmt.Fprintf(os.Stderr, "barkpark-agent: read token: %v\n", err)
		return 1
	}

	a := &agent.Agent{
		ControlURL: *controlURL,
		Token:      token,
		Interval:   *interval,
		Runner:     agent.ExecRunner{},
		ReportProbes: agent.ReportConfig{
			Checkout:      *checkout,
			DiskProbe:     dfRootProbe,
			HealthBaseURL: *healthURL,
			HealthToken:   *healthTok,
			HealthGateOpts: setup.HealthGate{
				Token: *healthTok,
			},
		},
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	if *once {
		if err := a.RunOnce(ctx); err != nil {
			fmt.Fprintf(os.Stderr, "barkpark-agent: cycle failed: %v\n", err)
			return 1
		}
		return 0
	}

	fmt.Fprintf(os.Stderr, "barkpark-agent: reporting to %s every %s\n", *controlURL, interval.String())
	a.RunWith(ctx, func(err error) {
		if err != nil {
			fmt.Fprintf(os.Stderr, "barkpark-agent: cycle error: %v\n", err)
		}
	})
	// RunWith returns only when ctx is cancelled (signal) — a clean shutdown.
	fmt.Fprintln(os.Stderr, "barkpark-agent: shutting down")
	return 0
}

// readToken reads, trims, and validates the agent token from path. An empty
// file is an error — a blank token would silently send unauthenticated reports.
func readToken(path string) (string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	tok := strings.TrimSpace(string(data))
	if tok == "" {
		return "", fmt.Errorf("token file %s is empty", path)
	}
	return tok, nil
}

// dfRootProbe reports root-filesystem used-percent via `df -P /`. It shells out
// (rather than syscall.Statfs) to stay portable across the supported servers and
// to keep the probe trivially fakeable in tests by swapping ReportConfig.
func dfRootProbe() (int, error) {
	out, err := agent.ExecRunner{}.Run("df", "-P", "/")
	if err != nil {
		return 0, err
	}
	// df -P prints a header then one data line; the Capacity column ends in '%'.
	lines := strings.Split(strings.TrimSpace(out), "\n")
	if len(lines) < 2 {
		return 0, fmt.Errorf("df: unexpected output")
	}
	fields := strings.Fields(lines[len(lines)-1])
	for _, f := range fields {
		if strings.HasSuffix(f, "%") {
			var pct int
			if _, err := fmt.Sscanf(f, "%d%%", &pct); err == nil {
				return pct, nil
			}
		}
	}
	return 0, fmt.Errorf("df: no capacity column")
}

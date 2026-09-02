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
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"

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
		healthTok  = fs.String("health-token", "", "health-gate bearer, VERBATIM (optional; overrides --health-token-file)")
		healthTokF = fs.String("health-token-file", "", "file holding the health-gate bearer (empty resolves BARKPARK_HEALTH_TOKEN_FILE, then "+defaultHealthTokenFile+"); an ABSENT file leaves req/s + p95 + 5xx unmetered, never a crash")
		printCmds  = fs.Bool("print-allowed-commands", false, "print the approved command allowlist and exit")
		sitesDir   = fs.String("sites-dir", "", "sites root measured per-slug (empty resolves BARKPARK_SITES_DIR, then "+defaultSitesDir+")")
		spaceEvery = fs.Duration("space-interval", agent.DefaultSpaceInterval, "cadence of the space report (its own, slower than --interval)")
		consumers  = fs.String("consumer-roots", "", "comma-separated extra disk-consumer roots (empty resolves BARKPARK_CONSUMER_ROOTS, then the built-in build-plane defaults; \"none\" measures none)")
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

	// The sites root is RESOLVED here, once, and travels in the payload — never
	// re-derived downstream. BARKPARK_SITES_DIR is set on no box in the fleet
	// (the agent's own environ carries only BARKPARK_CONTROL_URL and
	// BARKPARK_HEALTH_URL), so an env-read silently falls back on every box;
	// reporting the path that was actually read makes a wrong root visible
	// rather than silent (charter D59).
	resolvedSitesDir := resolveSitesDir(*sitesDir, os.Getenv("BARKPARK_SITES_DIR"))

	// The consumer roots are resolved here for the SAME reason the sites root
	// is: they travel in the payload as configured, so a box measuring the
	// wrong trees says which trees it measured instead of just reporting a
	// small number confidently.
	resolvedConsumerRoots := resolveConsumerRoots(*consumers, os.Getenv("BARKPARK_CONSUMER_ROOTS"))

	// The health-gate bearer is resolved HERE, once, from a FILE the provisioner
	// writes — not from a flag literal in a hand-added drop-in on one box. An
	// absent file is not an error: the token stays empty, the ReqStatsProbe sends
	// no bearer, and req/s + p95 + 5xx keep their -1 unmeasured sentinels. Which
	// source answered is PRINTED, because a silently-empty token is exactly the
	// hole this closes — every box but one read "" and nothing said so.
	healthToken, healthTokenSource := resolveHealthToken(*healthTok, *healthTokF, os.Getenv("BARKPARK_HEALTH_TOKEN_FILE"))
	fmt.Fprintf(os.Stderr, "barkpark-agent: health token %s\n", healthTokenSource)

	a := &agent.Agent{
		ControlURL: *controlURL,
		Token:      token,
		Interval:   *interval,
		Runner:     agent.ExecRunner{},
		// Space rides its OWN cadence and its OWN route — not the 60s beat
		// (charter D58). Every probe is bounded and direct-argv (D59); each
		// failure keeps its unmeasured sentinel rather than landing a partial
		// number.
		SpaceInterval: *spaceEvery,
		SpaceProbes: agent.SpaceConfig{
			RootProbe:    agent.NewRootSpaceProbe(),
			JournalProbe: agent.NewJournalSpaceProbe(),
			// The database measures itself — the SAME probes the beat uses,
			// never a du over PGDATA.
			PGSizeProbe:         agent.NewPGSizeProbe(*checkout),
			PGTopRelationsProbe: agent.NewPGTopRelationsProbe(*checkout),
			SitesDir:            resolvedSitesDir,
			SitesProbe:          agent.NewSitesSpaceProbe(resolvedSitesDir),
			// The build plane's disk. SitesDir does not exist on a builder box
			// at all, so without these roots the space payload names ~1 GiB of
			// a 34 GiB problem on the one box whose job is filling a disk.
			// Presence is a stat, not a du-error guess: a root that is not here
			// reports `absent`, never 0 bytes.
			ConsumerRoots:      resolvedConsumerRoots,
			ConsumerRootExists: agent.NewConsumerRootExists(),
			ConsumerRootProbe:  agent.NewConsumerRootProbe(),
			// The residual's mount guard. `du -x` refuses to cross INTO a
			// mount, so a root that SITS ON one is measured in full while its
			// parent's walk stopped at the boundary — subtracting both from a
			// root-filesystem total is bytes that are not in the denominator,
			// and the residual goes negative. Only st_dev can tell those apart.
			DeviceProbe: agent.NewDeviceProbe(),
			// Where PGDATA is, so a du root covering it and PGSizeBytes are
			// never BOTH subtracted. Nothing walks this path.
			PGDataDir: agent.DefaultPGDataDir,
		},
		ReportProbes: agent.ReportConfig{
			Checkout:  *checkout,
			DiskProbe: dfRootProbe,
			CPUProbe:  cpuProcProbe,
			MemProbe:  memProcProbe,
			LoadProbe: loadProcProbe,
			// Swap is the vital mem_used_percent hides: MemAvailable looks
			// comfortable precisely BECAUSE the BEAM has been paged out.
			SwapProbe: swapProcProbe,
			// The BEAM's own footprint — the biggest single consumer, and the
			// process the kernel keeps OOM-killing.
			BeamProbe: beamSmapsProbe,
			// Postgres size + its named consumers. These shell out to psql
			// using the checkout's own DATABASE_URL (agent runs as root, where
			// a bare psql has no role), each under its own short deadline. On a
			// box without psql or without a readable .env they ERROR, so the
			// fields keep their -1 sentinel — exactly what those boxes report
			// today. db_size has read "unmetered" on every box until now
			// because this declared probe was never wired.
			PGSizeProbe:         agent.NewPGSizeProbe(*checkout),
			PGTopRelationsProbe: agent.NewPGTopRelationsProbe(*checkout),
			// Request stats ride the SAME base+token seam as the health gate: the
			// probe GETs the instance RequestStats route at *healthURL. Empty
			// health-url → nil probe → req/s + p95 report their -1 sentinels.
			ReqStatsProbe: agent.NewReqStatsProbe(*healthURL, healthToken, nil),
			// WHO is spending the box, beside the aggregates that can only
			// say THAT it is being spent. One bounded `ps` per beat, no state.
			// This is the detection half of the 2026-08-06 guerrilla runaway;
			// the lifetime half is runBounded, which every probe above already
			// goes through. On a box without `ps` it ERRORS, so runaway_procs
			// stays null (UNMEASURED) rather than landing an empty list that
			// would read "nothing running here".
			RunawayProbe: agent.NewRunawayProbe(),
			// The blue/green SYSTEMD UNITS themselves. Every vital above is a
			// number about the host; none of them can say that half the
			// deploy pair is sitting in `failed` — which on 2026-08-06 was true
			// on guerrilla while every operator surface read `ok`. Two bounded
			// `systemctl` calls per beat. On a box without systemd or dbus they
			// ERROR, so slot_units stays null (UNMEASURED) rather than landing
			// an empty list that would read "no failed units here".
			SlotUnitsProbe: agent.NewSlotUnitsProbe(),
			HealthBaseURL:  *healthURL,
			HealthToken:    healthToken,
			HealthGateOpts: agentHealthGateOpts(*healthURL, healthToken),
		},
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	if *once {
		if err := a.RunOnce(ctx); err != nil {
			fmt.Fprintf(os.Stderr, "barkpark-agent: cycle failed: %v\n", err)
			return 1
		}
		// The space cycle runs too, but does NOT decide the exit code: a
		// control plane that predates the space route answers 404, and a smoke
		// test of the beat must not fail because of that skew. The error is
		// printed, so the skew is visible instead of silent.
		if err := a.ReportSpaceOnce(ctx); err != nil {
			fmt.Fprintf(os.Stderr, "barkpark-agent: space cycle failed: %v\n", err)
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

func agentHealthGateOpts(base, token string) setup.HealthGate {
	base = strings.TrimRight(base, "/")
	statusURL := ""
	if base != "" {
		statusURL = base + "/status.json"
	}
	return setup.HealthGate{
		Token:                            token,
		PostgresProbeURL:                 statusURL,
		RequireDatabaseStatusOperational: true,
		StubsOptional:                    true,
	}
}

// defaultSitesDir is where site deploys land when nothing says otherwise —
// the same default deploy/site-deploy.sh:128 applies.
const defaultSitesDir = "/opt/barkpark/sites"

// resolveSitesDir picks the sites root the space probe will read, in
// precedence order: the explicit --sites-dir flag, then BARKPARK_SITES_DIR,
// then defaultSitesDir. It NEVER returns empty, and the answer is carried in
// the payload: BARKPARK_SITES_DIR is set on no box today, so every box takes
// the fallback, and a fallback nobody can see is a wrong number nobody can
// explain (charter D59).
func resolveSitesDir(flagValue, envValue string) string {
	if d := strings.TrimSpace(flagValue); d != "" {
		return d
	}
	if d := strings.TrimSpace(envValue); d != "" {
		return d
	}
	return defaultSitesDir
}

// defaultHealthTokenFile is where the provisioner writes the health-gate bearer
// (internal/cli/cloud.agentInstallStep, 0600 root-only), beside the report token
// it has always written. The COMMITTED unit names this same path explicitly in
// its ExecStart — TestCommittedUnitNamesTheHealthTokenFile pins the two together
// so a rename here cannot silently unmeter the fleet.
const defaultHealthTokenFile = "/etc/barkpark/agent.health.token"

// resolveHealthToken answers the health-gate bearer and NAMES the source that
// answered, in precedence order:
//
//  1. --health-token, VERBATIM. This is the pre-existing flag, and the hand-added
//     drop-in on guerrilla passes it (`--health-token "$(cat …)"`), so that box
//     keeps behaving byte-for-byte after this change.
//  2. the file at --health-token-file, else BARKPARK_HEALTH_TOKEN_FILE, else
//     defaultHealthTokenFile.
//
// ABSENCE IS NOT AN ERROR, and no garbage token is ever returned in its place: a
// missing, empty, or unreadable file yields "" and a source string that SAYS so.
// The agent then sends no bearer and req/s, p95 and err_5xx report their -1
// sentinels — the exact behaviour of every box in the fleet today. Crash-looping
// the beat over a missing telemetry credential would trade three unmetered
// numbers for ALL of them.
func resolveHealthToken(flagToken, flagFile, envFile string) (token, source string) {
	if t := strings.TrimSpace(flagToken); t != "" {
		return t, "from --health-token"
	}
	path := strings.TrimSpace(flagFile)
	if path == "" {
		path = strings.TrimSpace(envFile)
	}
	if path == "" {
		path = defaultHealthTokenFile
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return "", "unset (" + path + " unreadable: " + err.Error() + ") — req/s, p95 and 5xx stay unmetered"
	}
	if t := strings.TrimSpace(string(data)); t != "" {
		return t, "read from " + path
	}
	return "", "unset (" + path + " is empty) — req/s, p95 and 5xx stay unmetered"
}

// consumerRootsNone is the explicit opt-OUT. It exists because "" already
// means "use the defaults", so without a spelled word there is no way for an
// operator to say "measure no extra roots" — and silently overloading an empty
// string to mean both would make the defaults unremovable.
const consumerRootsNone = "none"

// resolveConsumerRoots picks the extra consumer roots the space probe will
// walk, in the same precedence order resolveSitesDir uses: the explicit
// --consumer-roots flag, then BARKPARK_CONSUMER_ROOTS, then
// agent.DefaultConsumerRoots.
//
// The value is a comma-separated path list. Blank entries are dropped (a
// trailing comma in a unit file must not become a walk of ""), and the literal
// "none" — at either source — returns nil, which the payload renders as "this
// agent measured no consumer roots" rather than as an empty fleet of them.
//
// It deliberately does NOT validate that the paths exist: a root that is not
// on this box is a REPORTABLE FACT (ConsumerRootAbsent), not a configuration
// error to be silently dropped here. Dropping it here is precisely how a wrong
// root becomes invisible.
func resolveConsumerRoots(flagValue, envValue string) []string {
	for _, raw := range []string{flagValue, envValue} {
		v := strings.TrimSpace(raw)
		if v == "" {
			continue
		}
		if strings.EqualFold(v, consumerRootsNone) {
			return nil
		}
		var roots []string
		for _, part := range strings.Split(v, ",") {
			if p := strings.TrimSpace(part); p != "" {
				roots = append(roots, p)
			}
		}
		// An all-blank value ("  ,  ,") states no roots and is not a fallback
		// cue — falling back there would ignore an operator who spoke.
		return roots
	}
	return agent.DefaultConsumerRoots
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

// cpuProcProbe reports host CPU busy-percent from two /proc/stat samples ~200ms
// apart: busy = 100 * (Δtotal - Δidle) / Δtotal. Dep-free and cgo-free (prod is
// linux/arm64); on a host without /proc (dev macOS) the read errors and the
// vital reports "unwired" via the -1 sentinel upstream — never a fake reading.
func cpuProcProbe() (int, error) {
	t1, i1, err := readCPUStat()
	if err != nil {
		return 0, err
	}
	time.Sleep(200 * time.Millisecond)
	t2, i2, err := readCPUStat()
	if err != nil {
		return 0, err
	}
	dt, di := t2-t1, i2-i1
	if dt <= 0 {
		return 0, fmt.Errorf("cpu: non-positive total delta")
	}
	busy := float64(dt-di) / float64(dt) * 100
	return clampPercent(busy), nil
}

// readCPUStat returns (total, idle) jiffies from the aggregate "cpu " line of
// /proc/stat. idle counts fields idle+iowait (indices 3 and 4 after the label).
func readCPUStat() (total, idle int64, err error) {
	data, err := os.ReadFile("/proc/stat")
	if err != nil {
		return 0, 0, err
	}
	for _, line := range strings.Split(string(data), "\n") {
		if !strings.HasPrefix(line, "cpu ") {
			continue
		}
		fields := strings.Fields(line)[1:] // drop the "cpu" label
		for i, f := range fields {
			v, e := strconv.ParseInt(f, 10, 64)
			if e != nil {
				return 0, 0, fmt.Errorf("cpu stat: %w", e)
			}
			total += v
			if i == 3 || i == 4 { // idle + iowait
				idle += v
			}
		}
		return total, idle, nil
	}
	return 0, 0, fmt.Errorf("cpu: no aggregate cpu line in /proc/stat")
}

// memProcProbe reports used-memory percent from /proc/meminfo:
// used = MemTotal - MemAvailable, percent = 100 * used / MemTotal.
func memProcProbe() (int, error) {
	data, err := os.ReadFile("/proc/meminfo")
	if err != nil {
		return 0, err
	}
	var total, avail int64
	var haveTotal, haveAvail bool
	for _, line := range strings.Split(string(data), "\n") {
		fields := strings.Fields(line)
		if len(fields) < 2 {
			continue
		}
		switch fields[0] {
		case "MemTotal:":
			total, _ = strconv.ParseInt(fields[1], 10, 64)
			haveTotal = true
		case "MemAvailable:":
			avail, _ = strconv.ParseInt(fields[1], 10, 64)
			haveAvail = true
		}
	}
	if !haveTotal || !haveAvail || total <= 0 {
		return 0, fmt.Errorf("meminfo: missing MemTotal/MemAvailable")
	}
	if avail > total {
		avail = total
	}
	return clampPercent(float64(total-avail) / float64(total) * 100), nil
}

// loadProcProbe reports the 1-minute AND 15-minute load averages from
// /proc/loadavg. Like swapProcProbe below, the file read is separated from the
// parse on purpose: parseLoadAvg is pure and table-tested against a REAL
// captured kernel line, which the sibling cpu/mem probes still are not.
func loadProcProbe() (load1 float64, load15 float64, err error) {
	data, err := os.ReadFile("/proc/loadavg")
	if err != nil {
		return 0, 0, err
	}
	return parseLoadAvg(data)
}

// parseLoadAvg extracts the 1-minute and 15-minute load averages from
// /proc/loadavg content — fields[0] and fields[2] of the kernel's line
// (`0.64 1.50 1.89 3/382 67892`).
//
// THE 15-MINUTE FIELD IS THE POINT (charter D67). `/v1/barkparks` serves exactly
// ONE beat — Registry.latest_health_payload_map/1 is a DISTINCT ON … ORDER BY
// inserted_at DESC and merge_pressure/2 folds that single row — so a "2 of the
// last 3 beats" sustain rule is NOT COMPUTABLE by any consumer of the payload
// the console and `bp cloud status` both read. load15 IS a sustained
// measurement: a 15-minute EWMA the kernel already maintains, delivered as one
// scalar, needing no window, no client state and no new syscall. This function
// reads the same bytes the old one-minute-only parser already had in memory.
//
// BOTH FIELDS OR NEITHER: a short/garbled line errors rather than landing a
// half-measurement, because the caller maps an error to the -1 sentinel and a
// load1 landed beside a fabricated load15 would be indistinguishable from a
// quiet box.
func parseLoadAvg(data []byte) (load1 float64, load15 float64, err error) {
	fields := strings.Fields(string(data))
	if len(fields) < 3 {
		return 0, 0, fmt.Errorf("loadavg: want >=3 fields, got %d", len(fields))
	}
	l1, err := strconv.ParseFloat(fields[0], 64)
	if err != nil {
		return 0, 0, fmt.Errorf("loadavg: load1: %w", err)
	}
	l15, err := strconv.ParseFloat(fields[2], 64)
	if err != nil {
		return 0, 0, fmt.Errorf("loadavg: load15: %w", err)
	}
	return l1, l15, nil
}

// swapProcProbe reports (swap used percent, swap total bytes) from
// /proc/meminfo. The file read is separated from the arithmetic on purpose:
// parseSwapPercent below is pure and table-tested, which the sibling cpu/mem/
// load probes are not (they read inline and are unreachable from a test).
//
// No watchdog is needed around the read itself: /proc/meminfo is generated by
// the kernel on read with no I/O behind it, unlike the psql probes, which carry
// their own deadline (agent.pgProbeTimeout).
func swapProcProbe() (int, int64, error) {
	data, err := os.ReadFile("/proc/meminfo")
	if err != nil {
		return -1, -1, err
	}
	return parseSwapPercent(data)
}

// parseSwapPercent extracts SwapTotal/SwapFree from /proc/meminfo content and
// returns (used percent 0..100, total bytes).
//
// A SWAPLESS BOX RETURNS (0, 0, nil) — NOT AN ERROR AND NOT THE -1 SENTINEL.
// SwapTotal: 0 is the ordinary state of a box with no swap configured; it was
// measured, and the answer is none. This diverges from memProcProbe above by
// exactly one branch: memProcProbe errors on `total <= 0` because MemTotal: 0
// can only mean a bad read. Copying that guard here would turn every swapless
// box into "could not measure", which is the precise dishonesty the sentinel
// doctrine forbids — and the companion swap_total_bytes is what lets a consumer
// tell "none configured" (0,0) from "idle" (0, >0) from "unmeasurable" (-1,-1).
// TestSwaplessBoxIsZeroNotSentinel pins this.
//
// Fields are matched by EQUALITY, never by prefix: /proc/meminfo also carries a
// SwapCached: line, and a prefix match reads it as swap sizing.
func parseSwapPercent(data []byte) (pct int, totalBytes int64, err error) {
	var total, free int64
	var haveTotal, haveFree bool
	for _, line := range strings.Split(string(data), "\n") {
		fields := strings.Fields(line)
		if len(fields) < 2 {
			continue
		}
		switch fields[0] {
		case "SwapTotal:":
			v, e := strconv.ParseInt(fields[1], 10, 64)
			if e != nil {
				return -1, -1, fmt.Errorf("meminfo: SwapTotal: %w", e)
			}
			total, haveTotal = v, true
		case "SwapFree:":
			v, e := strconv.ParseInt(fields[1], 10, 64)
			if e != nil {
				return -1, -1, fmt.Errorf("meminfo: SwapFree: %w", e)
			}
			free, haveFree = v, true
		}
	}
	if !haveTotal || !haveFree {
		return -1, -1, fmt.Errorf("meminfo: missing SwapTotal/SwapFree")
	}
	if total < 0 || free < 0 {
		return -1, -1, fmt.Errorf("meminfo: negative swap values")
	}
	if total == 0 {
		// Swapless. Measured; the answer is none. See the doc comment.
		return 0, 0, nil
	}
	if free > total {
		free = total // a torn read must not produce a negative percent
	}
	// /proc/meminfo is in kB.
	return clampPercent(float64(total-free) / float64(total) * 100), total * 1024, nil
}

// beamComm is the process name the BEAM runs under. It is the OOM killer's most
// frequent victim on a Barkpark box, which is why its footprint is a vital.
const beamComm = "beam.smp"

// beamSmapsProbe reports the winning BEAM's (PSS, swap) bytes plus the pid and
// slot it was measured from, read out of /proc/<pid>/smaps_rollup. The byte
// values are -1, and pid/slot empty, when no beam.smp is running or no rollup
// could be read — an un-run BEAM is not a zero-footprint BEAM.
func beamSmapsProbe() (int64, int64, string, string, error) {
	return beamSmapsProbeIn("/proc")
}

// beamSmapsProbeIn is beamSmapsProbe with an injectable /proc root so the
// found, not-found and MULTI-BEAM paths are all testable on any host.
//
// THE BOX RUNS BLUE/GREEN, so this samples EVERY comm-anchored beam.smp and
// reports the MAX across the set — the rule pds-w11-paired-control-measure
// already states ("sample ALL comm-anchored beam.smp slots and report peak =
// MAX across the set"). The predecessor returned the FIRST match in
// os.ReadDir order, which sorts LEXICALLY: on a 4-entry /proc that is
// 1000, 4179607, 4185178, 999. That rule is neither "oldest" (pgrep -o) nor
// "the slot Caddy proxies" — it is a string sort over pid digits, so across a
// cutover's two-BEAM overlap it selected by a coin flip and the series
// silently changed subject.
//
// The winner is chosen by PSS+SWAP, the total committed footprint, because
// that is the quantity the OOM killer acts on (PDS-D114: RSS and VmSwap trade
// against each other, so either alone is a swap-residency meter rather than a
// consumption meter). Choosing by the SUM keeps the reported triple coherent:
// pss, swap and pid all describe ONE real process. Taking max(pss) and
// max(swap) independently could describe two different processes and make
// beam_pid a lie about at least one of them.
func beamSmapsProbeIn(procRoot string) (int64, int64, string, string, error) {
	pids, err := findBeamPIDs(procRoot)
	if err != nil {
		return -1, -1, "", "", err
	}
	var (
		bestPSS, bestSwap int64 = -1, -1
		bestPID           string
		readErr           error
	)
	for _, pid := range pids {
		data, err := os.ReadFile(filepath.Join(procRoot, pid, "smaps_rollup"))
		if err != nil {
			readErr = err
			continue // it exited mid-scan; another slot may still be readable
		}
		pss, swap, err := parseSmapsRollup(data)
		if err != nil {
			readErr = err
			continue
		}
		if bestPID == "" || pss+swap > bestPSS+bestSwap {
			bestPSS, bestSwap, bestPID = pss, swap, pid
		}
	}
	if bestPID == "" {
		if readErr != nil {
			return -1, -1, "", "", readErr
		}
		return -1, -1, "", "", fmt.Errorf("no readable %s rollup under %s", beamComm, procRoot)
	}
	return bestPSS, bestSwap, bestPID, beamSlotOf(procRoot, bestPID), nil
}

// findBeamPIDs scans procRoot for EVERY process whose comm is beam.smp, in
// ascending numeric pid order so the scan itself is deterministic. An
// unreadable /proc, or no such process, is an error — never a guessed pid.
func findBeamPIDs(procRoot string) ([]string, error) {
	entries, err := os.ReadDir(procRoot)
	if err != nil {
		return nil, err
	}
	var pids []int
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		n, err := strconv.Atoi(e.Name())
		if err != nil {
			continue // not a pid directory
		}
		comm, err := os.ReadFile(filepath.Join(procRoot, e.Name(), "comm"))
		if err != nil {
			continue // the process exited between the scan and the read
		}
		if strings.TrimSpace(string(comm)) == beamComm {
			pids = append(pids, n)
		}
	}
	if len(pids) == 0 {
		return nil, fmt.Errorf("no %s process found under %s", beamComm, procRoot)
	}
	sort.Ints(pids)
	out := make([]string, 0, len(pids))
	for _, n := range pids {
		out = append(out, strconv.Itoa(n))
	}
	return out, nil
}

// beamSlotRE matches the blue/green slot in a cgroup line, e.g.
// "0::/system.slice/system-barkpark\x2dslot.slice/barkpark-slot@green.service".
var beamSlotRE = regexp.MustCompile(`barkpark-slot@(blue|green)`)

// beamSlotOf derives which blue/green slot a pid belongs to by reading its
// cgroup. An empty string means "not attributable" — the box may not be
// slotted, or the cgroup may be unreadable — and an empty slot is reported as
// such rather than guessed. beam_pid alone already lets a consumer detect that
// the measured process changed; the slot only names WHICH one it moved to.
func beamSlotOf(procRoot, pid string) string {
	data, err := os.ReadFile(filepath.Join(procRoot, pid, "cgroup"))
	if err != nil {
		return ""
	}
	if m := beamSlotRE.FindSubmatch(data); m != nil {
		return string(m[1])
	}
	return ""
}

// parseSmapsRollup sums the Pss: and Swap: lines of a smaps_rollup file (kB)
// and returns them as bytes. Both keys must be present — a rollup missing one
// is a kernel we do not understand, not a zero.
func parseSmapsRollup(data []byte) (pssBytes int64, swapBytes int64, err error) {
	var pss, swap int64
	var havePss, haveSwap bool
	for _, line := range strings.Split(string(data), "\n") {
		fields := strings.Fields(line)
		if len(fields) < 2 {
			continue
		}
		v, e := strconv.ParseInt(fields[1], 10, 64)
		if e != nil {
			continue
		}
		switch fields[0] {
		case "Pss:":
			pss, havePss = pss+v, true
		case "Swap:":
			// Matched by equality: SwapPss: is a DIFFERENT number and must not
			// be folded into the swap total.
			swap, haveSwap = swap+v, true
		}
	}
	if !havePss || !haveSwap {
		return -1, -1, fmt.Errorf("smaps_rollup: missing Pss/Swap")
	}
	return pss * 1024, swap * 1024, nil
}

// clampPercent rounds v to the nearest int and pins it into 0..100.
func clampPercent(v float64) int {
	if v < 0 {
		return 0
	}
	if v > 100 {
		return 100
	}
	return int(v + 0.5)
}

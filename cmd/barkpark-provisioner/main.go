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
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/FRIKKern/barkpark/internal/cli/cloud"
	"github.com/FRIKKern/barkpark/internal/hetzner"
	"github.com/FRIKKern/barkpark/internal/provisioner"
)

// isTruthy reports whether an env value opts a flag in: "1", "true", "yes",
// "on" (case-insensitive). Empty/unset — and anything else — is off, so the
// default path stays exactly the argv provider.
func isTruthy(v string) bool {
	switch strings.ToLower(strings.TrimSpace(v)) {
	case "1", "true", "yes", "on":
		return true
	}
	return false
}

// sweepEveryCycles runs the orphan sweep every Nth completed claim cycle (on top
// of the startup sweep), so a long-lived worker keeps recovering leaked orphan
// boxes without a separate timer. 200 cycles at the default 5s idle cadence is
// ~one sweep every several minutes when idle, and far less often under load —
// cheap (one labeled `hcloud server list`) and well clear of any rate concern.
const sweepEveryCycles = 200

// reconcileEveryCycles holds the warm pool at its target size every Nth completed
// claim cycle (on top of the startup reconcile), so a long-lived worker keeps the
// ≤15s path warm without a separate timer. 50 cycles at the default 5s idle
// cadence is ~one reconcile every few minutes when idle (a single ready-count
// GET + at most a create/retire), far less often under load.
const reconcileEveryCycles = 50

// refreshEveryCycles kicks the self-refresh loop every Nth completed cycle
// (snapshot-management): keep idle pool boxes at origin/main so a go-live almost
// never rebuilds at claim time. 6 cycles at the 5s idle cadence is a check ~every
// 30s — the check is cheap (a 204 when nothing is due), and the server-side
// min-age gate (~90s) is what actually bounds per-box refresh frequency. Tighter
// than reconcile because staying current is the whole point.
const refreshEveryCycles = 6

// warmPoolSize reads WARM_POOL_SIZE (default 0 = the warm pool DISABLED, so
// provisioning stays on the proven one-shot path). A non-numeric or negative
// value is treated as 0 with a warning — a typo must never silently enable paid
// pool boxes.
func warmPoolSize() int {
	raw := strings.TrimSpace(os.Getenv("WARM_POOL_SIZE"))
	if raw == "" {
		return 0
	}
	n, err := strconv.Atoi(raw)
	if err != nil || n < 0 {
		fmt.Fprintf(os.Stderr, "barkpark-provisioner: WARM_POOL_SIZE=%q is not a non-negative integer; warm pool stays DISABLED\n", raw)
		return 0
	}
	return n
}

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
	//
	// Snapshot-management: at CREATE time the env pin is only the FALLBACK — the
	// newest `role=warm-image` snapshot the nightly bake publishes wins
	// (cloud.ResolveWarmImage), so this value no longer needs hand-updating; it
	// just guarantees a sane floor on a fresh account / first boot.
	if strings.TrimSpace(os.Getenv("BARKPARK_SERVER_IMAGE")) == "" {
		fmt.Fprintln(os.Stderr, "barkpark-provisioner: BARKPARK_SERVER_IMAGE is required (the fallback warm-pool snapshot id; newer role=warm-image snapshots are resolved dynamically at create time)")
		return 1
	}

	// Wire the REAL Hetzner provider + Cloud DNS. Compute uses HCLOUD_TOKEN; DNS
	// is cloud.CloudDNS (`hcloud zone rrset`, integrated Cloud DNS). They are the
	// SAME credential by default — but when the DNS zone lives in a DIFFERENT
	// Cloud project than the servers, BARKPARK_DNS_HCLOUD_TOKEN overrides the
	// token for the DNS execs ONLY (compute stays on HCLOUD_TOKEN). The Caddy/TLS
	// + migrate steps run ON each provisioned instance over SSH: RunnerFor is the
	// per-host SSHStepRunner factory, so real provisions configure the NEW box
	// (not the worker's own machine). The health gate stays the real default
	// (green-by-real-gate — fail closed). The in-chain registry is a no-op: the
	// authoritative registration is the worker's /succeed POST.
	dns := cloud.NewCloudDNS()
	if dnsTok := strings.TrimSpace(os.Getenv("BARKPARK_DNS_HCLOUD_TOKEN")); dnsTok != "" {
		dns.Token = dnsTok
	}

	// OPT-IN native provider: BARKPARK_HETZNER_NATIVE flips the server provider
	// from the argv-shelling cloud.HcloudProvider to the SDK-backed
	// hetzner.APIProvider (same contract, no `hcloud` binary needed). Unset (the
	// default) keeps the argv provider — behavior byte-unchanged.
	var provider cloud.CloudProvider = cloud.HcloudProvider{}
	if isTruthy(os.Getenv("BARKPARK_HETZNER_NATIVE")) {
		tok, err := hetzner.ResolveToken()
		if err != nil {
			fmt.Fprintf(os.Stderr, "barkpark-provisioner: BARKPARK_HETZNER_NATIVE is set but %v\n", err)
			return 1
		}
		provider = hetzner.NewAPIProvider(hetzner.NewClient(tok))
	}

	seams := provisioner.Seams{
		Provider: provider,
		DNS:      dns,
		Registry: provisioner.NopRegistry{},
		RunnerFor: func(host string) cloud.StepRunner {
			return cloud.NewSSHStepRunner(host)
		},
		// dwb-14: report each create→live step transition to the control plane
		// (→ SSE → the /new progress screen). Same ControlURL + WORKER_TOKEN as the
		// job queue; best-effort (ProvisionWith swallows a report error).
		StepReporter: (&provisioner.HTTPStepReporter{
			ControlURL: *controlURL,
			Token:      tok,
		}).Report,
		// dwb-16: tee the create→live chain + content bootstrap narration to the
		// control plane as LIVE console lines (→ SSE → the /new console panel). Same
		// ControlURL + WORKER_TOKEN; best-effort (the emitter swallows a report error).
		ConsoleReporter: (&provisioner.HTTPConsoleReporter{
			ControlURL: *controlURL,
			Token:      tok,
		}).Report,
		// charter Decision 33 — the control-plane origin the on-box barkpark-agent
		// reports to. Threaded into every go-live's spec so the configure step can
		// enable barkpark-agent.service pointed home. Same origin as the claim loop.
		ControlURL: *controlURL,
		// Health/Caddy/Secrets left nil → the real cloud-package defaults.
	}

	// Transactional-mail relay (SMTP_RELAY_*): the SHARED submission relay every
	// provisioned instance is pointed at so magic-link / password-reset /
	// verify-email actually deliver (without it, Barkpark.Mailer stays on the
	// never-delivering Local adapter). Non-secret host/port/username + the SASL
	// password. When unset the instance is provisioned without SMTP exactly as
	// before; a PARTIAL/malformed relay is logged loudly and skipped (rather than
	// silently shipping a broken .env). SMTP_RELAY_PORT defaults to 587.
	seams.Mail = cloud.MailRelay{
		Host:     strings.TrimSpace(os.Getenv("SMTP_RELAY_HOST")),
		Port:     strings.TrimSpace(os.Getenv("SMTP_RELAY_PORT")),
		Username: strings.TrimSpace(os.Getenv("SMTP_RELAY_USERNAME")),
		Password: os.Getenv("SMTP_RELAY_PASSWORD"),
	}
	if err := seams.Mail.Validate(); err != nil {
		fmt.Fprintf(os.Stderr, "barkpark-provisioner: mail relay DISABLED — %v; provisioned instances will not send email until SMTP_RELAY_* is fixed\n", err)
		seams.Mail = cloud.MailRelay{}
	} else if seams.Mail.Enabled() {
		fmt.Fprintf(os.Stderr, "barkpark-provisioner: mail relay ENABLED — provisioned instances relay via %s (password redacted)\n", seams.Mail.Host)
	} else {
		fmt.Fprintln(os.Stderr, "barkpark-provisioner: mail relay not configured (SMTP_RELAY_* unset) — provisioned instances will NOT send email")
	}

	// The control plane's own EGRESS address (BARKPARK_CLOUD_EGRESS_IPS), written
	// into every provisioned instance as BARKPARK_TRUSTED_PROXIES. An instance only
	// believes x-forwarded-for from loopback or a LISTED peer, so without this the
	// caller address the control plane relays on a proxied revoke is DISBELIEVED and
	// the bucket keys on the control plane's own address — one bucket for the whole
	// team instead of one per phone. Same value as the CP_HOST deploy secret (this
	// worker runs ON that box); see deploy/barkpark-provisioner.env.example.
	//
	// Reported at startup either way, and a MALFORMED value is reported HERE rather
	// than discovered mid-provision: runtime.exs raises on a non-IP entry, so a bad
	// value would refuse to boot the instance it was just written to. The value is
	// still passed through (the go-live fails closed on it) — the log is what makes
	// an operator's typo visible before the first job lands.
	seams.CloudEgressIPs = strings.TrimSpace(os.Getenv("BARKPARK_CLOUD_EGRESS_IPS"))
	switch egress, err := cloud.NormalizeTrustedProxies(seams.CloudEgressIPs); {
	case err != nil:
		fmt.Fprintf(os.Stderr, "barkpark-provisioner: BARKPARK_CLOUD_EGRESS_IPS is MALFORMED — %v; every go-live fails closed on it until it is fixed (a non-IP entry raises at the instance's next boot)\n", err)
	case egress == "":
		fmt.Fprintln(os.Stderr, "barkpark-provisioner: BARKPARK_CLOUD_EGRESS_IPS unset — provisioned instances will DISBELIEVE the caller address this control plane relays (per-caller rate-limit buckets collapse to one bucket per team)")
	default:
		fmt.Fprintf(os.Stderr, "barkpark-provisioner: control-plane egress %s — provisioned instances trust it as an x-forwarded-for hop (BARKPARK_TRUSTED_PROXIES)\n", egress)
	}

	// Warm pool (dwb-10): OPT-IN via WARM_POOL_SIZE (default 0 = DISABLED, one-shot
	// only). When enabled, wire the control-plane claim-store client (same
	// ControlURL + WORKER_TOKEN as the job queue) so a go-live assigns a pre-baked
	// box (≤15s) and the pool self-refills + reconciles to size. The claim's
	// atomicity lives server-side (Postgres FOR UPDATE SKIP LOCKED). Fields are set
	// on `seams` BEFORE DefaultProvision/DefaultReconcile capture it.
	poolSize := warmPoolSize()
	if poolSize > 0 {
		seams.WarmPoolSize = poolSize
		seams.WarmClient = &provisioner.HTTPWarmPoolClient{
			ControlURL: *controlURL,
			Token:      tok,
			HTTPClient: &http.Client{Timeout: 30 * time.Second},
		}
		fmt.Fprintf(os.Stderr, "barkpark-provisioner: warm pool ENABLED (target size %d)\n", poolSize)
	}

	// Resurrect drain (charter S14f): the portable-archive RESTORE queue. The bundle
	// store creds + KEK come from WORKER ENV (never the claim JSON, D43); a missing
	// var fails each resurrect job HONESTLY — translate errors before any box is
	// created — so the worker still provisions. seams.Restore wires the real driver
	// (a cold create + pg_restore over the box runner); it must be set on `seams`
	// BEFORE DefaultProvision(seams) captures the struct below.
	bundleDeps, bundleErr := provisioner.ResolveBundleEnv()
	if bundleErr != nil {
		fmt.Fprintf(os.Stderr, "barkpark-provisioner: resurrect drain DEGRADED — %v; resurrect jobs will fail honestly until the bundle env is set (the worker still provisions)\n", bundleErr)
	} else {
		fmt.Fprintln(os.Stderr, "barkpark-provisioner: resurrect drain ENABLED (bundle store configured)")
	}
	seams.Restore = &provisioner.CloudRestoreDriver{
		Exec: &cloud.RestoreExecutor{
			Provider:   provider,
			DNS:        dns,
			RunnerFor:  seams.RunnerFor,
			Store:      bundleDeps.Store, // nil when the env is missing — never reached (translate fails first)
			Mail:       seams.Mail,
			ControlURL: *controlURL,
			// A resurrect is its own chain (no configureHost), so it needs the egress
			// address threaded separately or a resurrected box comes back trusting only
			// loopback — one rate-limit bucket per team for every proxied request.
			TrustedProxies: seams.CloudEgressIPs,
		},
	}

	w := &provisioner.Worker{
		ControlURL: *controlURL,
		Token:      tok,
		Interval:   *interval,
		Provision:  provisioner.DefaultProvision(seams),
		// The resurrect drain: translate a claim's string bundle_ref (store creds +
		// KEK from WORKER ENV) and restore the box through Provision. Runs in its own
		// goroutine below, like deprovision/attach-domain.
		Resurrect: provisioner.DefaultResurrectDeps,
		// The Remove drain: delete the real Hetzner box + DNS for a deprovision
		// job (idempotent). Runs in its own goroutine below.
		Deprovision: provisioner.DefaultDeprovision(seams),
		// The custom-domain drain: point a platform-zone host at a live box (DNS A
		// record + on-box BARKPARK_EXTRA_ORIGINS merge + Caddy vhost + reload/
		// restart) for an attach-domain job (idempotent). Runs in its own
		// goroutine below, exactly like the deprovision loop.
		AttachDomain: provisioner.DefaultAttachDomain(seams),
		// The provision_support drain (Personal Dev Fleet MVP-0, PDF-D83): the
		// server-side support bring-up — create the box, configure it, pull the
		// scrubbed dataset, install the listener runtime, verify the roster reads
		// online-with-capacity — all from claim-payload credentials, so no local
		// Hetzner token is ever needed by the developer. Runs in its own goroutine
		// below, like resurrect/deprovision/attach-domain. Same telemetry seams
		// (steps + live console); the parent main's admin token rides the claim
		// payload and is NEVER logged or written to the box.
		// The push_agent_key drain (PDF-D94, pdf-bl-console-key-custody): deliver a
		// console-pasted provider key to a live support box's listener env over the
		// SSH key already on this worker box. The key exists only on the claim
		// payload (the CP stash is delete-on-read) and is Redact-listed on the one
		// step that carries it. Runs in its own goroutine below.
		AgentKeyPush: provisioner.DefaultAgentKeyPush(provisioner.AgentKeySeams{}),
		SupportProvision: provisioner.DefaultSupportProvision(provisioner.SupportSeams{
			Provider: provider,
			// Full public identity: the support chain's secure step stands up
			// <slug>.barkpark.cloud + Caddy/TLS exactly like a main, so the box
			// needs the SAME Cloud DNS seam the go-live chain uses. Caddy/Health
			// left nil → the real cloud-package defaults.
			DNS: dns,
			StepReporter: (&provisioner.HTTPStepReporter{
				ControlURL: *controlURL,
				Token:      tok,
			}).Report,
			ConsoleReporter: (&provisioner.HTTPConsoleReporter{
				ControlURL: *controlURL,
				Token:      tok,
			}).Report,
		}),
		// Auto-recover orphan boxes (a prior double-failure: succeed-report failed →
		// teardown → provider.Delete failed → box marked barkpark-orphaned=true). The
		// sweep deletes ONLY those labeled boxes — never a managed/live box — so it is
		// safe to run on startup and periodically.
		Sweep:      provisioner.DefaultSweep(seams),
		SweepEvery: sweepEveryCycles,
	}

	// Warm-pool reconcile + self-refresh: hold the pool at size, and keep idle
	// boxes at origin/main so a go-live almost never rebuilds. Only wired when the
	// pool is enabled, so a disabled worker never touches the pool.
	if poolSize > 0 {
		w.Reconcile = provisioner.DefaultReconcile(seams, poolSize)
		w.ReconcileEvery = reconcileEveryCycles
		w.Refresh = provisioner.DefaultRefresh(seams)
		w.RefreshEvery = refreshEveryCycles
	}

	// dwb-15: graceful shutdown. We must NOT use signal.NotifyContext here — that
	// would cancel `ctx` (and so the in-flight provision's child context)
	// IMMEDIATELY on SIGTERM, defeating the grace window. Instead handle the signal
	// manually: on the first signal, run w.Shutdown (which lets the in-flight job
	// finish, or past the deadline interrupts + releases its claim so the next
	// worker re-claims in seconds instead of waiting the >12min reaper), THEN cancel
	// the loop context to stop draining.
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, os.Interrupt, syscall.SIGTERM)
	go func() {
		sig := <-sigCh
		fmt.Fprintf(os.Stderr, "barkpark-provisioner: %s received; draining in-flight job (grace up to %s) then releasing its claim...\n", sig, provisioner.DefaultShutdownDeadline)
		w.Shutdown(ctx)
		cancel()
	}()

	// STARTUP sweep: recover any orphan leaked by a prior run before draining jobs.
	// Best-effort — a sweep failure (e.g. the control plane / hcloud briefly down)
	// must not stop the worker from doing its real job.
	if swept, serr := w.SweepOnce(ctx); serr != nil {
		fmt.Fprintf(os.Stderr, "barkpark-provisioner: startup orphan sweep failed (non-fatal): %v\n", serr)
	} else if swept > 0 {
		fmt.Fprintf(os.Stderr, "barkpark-provisioner: startup orphan sweep deleted %d leaked box(es)\n", swept)
	}

	// STARTUP warm-pool reconcile: top the pool up to size (and shrink any excess a
	// prior run left) before draining jobs, so the ≤15s path is warm from the first
	// go-live. Best-effort — a reconcile failure (control plane / hcloud briefly
	// down) must not stop the worker from provisioning.
	if rerr := w.ReconcileOnce(ctx); rerr != nil {
		fmt.Fprintf(os.Stderr, "barkpark-provisioner: startup warm-pool reconcile failed (non-fatal): %v\n", rerr)
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

	fmt.Fprintf(os.Stderr, "barkpark-provisioner: draining %s (provision + deprovision + attach-domain + resurrect + support + agent-key) every %s\n", *controlURL, interval.String())

	go func() {
		_ = w.RunSupportWith(ctx, func(claimed bool, err error) {
			switch {
			case err != nil:
				fmt.Fprintf(os.Stderr, "barkpark-provisioner: support cycle error: %v\n", err)
			case claimed:
				fmt.Fprintln(os.Stderr, "barkpark-provisioner: provisioned a support")
			}
		})
	}()

	go func() {
		_ = w.RunAgentKeyWith(ctx, func(claimed bool, err error) {
			switch {
			case err != nil:
				fmt.Fprintf(os.Stderr, "barkpark-provisioner: agent-key cycle error: %v\n", err)
			case claimed:
				// The var NAME would be honest telemetry, but the cycle callback only
				// sees claimed/err — and that is enough. NEVER the key.
				fmt.Fprintln(os.Stderr, "barkpark-provisioner: delivered an agent key")
			}
		})
	}()

	go func() {
		_ = w.RunResurrectWith(ctx, func(claimed bool, err error) {
			switch {
			case err != nil:
				fmt.Fprintf(os.Stderr, "barkpark-provisioner: resurrect cycle error: %v\n", err)
			case claimed:
				fmt.Fprintln(os.Stderr, "barkpark-provisioner: resurrected a box")
			}
		})
	}()

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

	go func() {
		_ = w.RunAttachDomainWith(ctx, func(claimed bool, err error) {
			switch {
			case err != nil:
				fmt.Fprintf(os.Stderr, "barkpark-provisioner: attach-domain cycle error: %v\n", err)
			case claimed:
				fmt.Fprintln(os.Stderr, "barkpark-provisioner: attached a custom domain")
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

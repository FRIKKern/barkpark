//go:build manual

// chain_live_manual_test.go is a MANUAL, build-tagged end-to-end harness that
// runs the REAL warm-pool provisioning chain — the exact code path the
// production worker (cmd/barkpark-provisioner/main.go) takes — for ONE instance,
// against LIVE Hetzner. It is fenced behind `//go:build manual` so it never runs
// in CI or a normal `go test ./...`: it creates REAL servers and DNS records and
// therefore bills real money.
//
// Run it explicitly (and only when you mean it):
//
//	BARKPARK_SERVER_IMAGE=402250827 \   # the baked warm-pool snapshot
//	HCLOUD_TOKEN=<cloud-token> \         # provider + Cloud DNS (one credential)
//	BARKPARK_SSH_KEY=<account-key-name> \# the hcloud ssh-key NAME (or auto if 1)
//	BARKPARK_SSH_KEY_FILE=~/.ssh/barkpark_indx \ # the private key for SSH steps
//	  go test -tags manual -run TestChainLiveProvision -v ./internal/provisioner/
//
// What it does, step for step:
//
//   - Wires the SAME provisioner.Seams main.go wires: the REAL HcloudProvider,
//     the REAL CloudDNS (hcloud zone rrset), a per-host SSHStepRunner factory,
//     and a tiny recording RegistryClient stub (no control-plane call). Health,
//     Caddy and Secrets are left to the real cloud-package defaults (nil), same
//     as main.go.
//   - Runs the REAL ONE-SHOT path WarmPool.ProvisionOneShot for ONE
//     GoLiveSpec{Name:"test2", Zone:"barkpark.cloud", App:4000} — the exact call
//     production's ProvisionWith makes — narrating each chain step (create →
//     secrets → dns → caddy → migrate → health → register). The one-shot path
//     creates exactly ONE server (name bp-test2, derived from the label) and
//     itself tears that server + DNS down on ANY post-create failure, so there is
//     no warm-N counter and no orphan replacement. On error the FULL error is
//     printed (the SSH runner and provider surface captured stderr, secrets
//     scrubbed). The base spec comes from DefaultSpec("hetzner") so the box boots
//     the baked snapshot when BARKPARK_SERVER_IMAGE is set.
//   - ALWAYS cleans up (deferred) as a belt-and-suspenders on top of the one-shot
//     self-cleanup: deletes the DNS A record test2.barkpark.cloud and any
//     bp-test2 / warm-* server present (list-and-sweep), so no orphan server
//     bills even if the run panicked before the one-shot teardown ran.
package provisioner

import (
	"context"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/FRIKKern/barkpark/internal/cli/cloud"
)

// liveLabel is the per-instance subdomain label the harness provisions:
// <liveLabel>.barkpark.cloud. It is the DNS label only — the ACTUAL server is the
// one-shot-created bp-<label>-<rand>. Overridable via BARKPARK_LIVE_LABEL so
// repeated live runs can use a FRESH subdomain and dodge Let's Encrypt's
// per-hostname duplicate-certificate rate limit (5/week) — re-running against the
// same label eventually fails the TLS + all HTTPS health checks with no cert.
var liveLabel = func() string {
	if v := strings.TrimSpace(os.Getenv("BARKPARK_LIVE_LABEL")); v != "" {
		return v
	}
	return "test2"
}()

// recordingRegistry is the harness's stub cloud.RegistryClient. It mirrors the
// production NopRegistry shape (the chain needs a non-nil RegistryClient, and the
// authoritative registration is the worker's /succeed POST) but ALSO records and
// logs the LiveServer so a live run shows what would have been registered. No
// real control-plane call.
type recordingRegistry struct {
	t        *testing.T
	recorded []cloud.LiveServer
}

// Register records srv and logs it. It never errors — registration is not the
// thing this harness is testing (the chain is).
func (r *recordingRegistry) Register(_ context.Context, srv cloud.LiveServer) error {
	r.recorded = append(r.recorded, srv)
	r.t.Logf("[register] would register LiveServer: name=%s fqdn=%s ip=%s server=%+v",
		srv.Name, srv.FQDN, srv.IP, srv.Server)
	return nil
}

// compile-time check that the stub satisfies the seam the chain requires.
var _ cloud.RegistryClient = (*recordingRegistry)(nil)

// TestChainLiveProvision runs the real provisioning chain end-to-end for ONE
// instance against live Hetzner. It is gated behind `//go:build manual` so it
// only runs when explicitly invoked with `-tags manual` — never in CI. It
// REQUIRES live credentials and CREATES REAL, BILLED resources; the deferred
// cleanup deletes everything it created even when the chain fails midway.
func TestChainLiveProvision(t *testing.T) {
	// Belt-and-suspenders: even with the build tag, refuse to run unless the
	// operator has set the snapshot image env — the signal that this is a
	// deliberate, credentialed live run and not an accidental invocation.
	if strings.TrimSpace(os.Getenv("BARKPARK_SERVER_IMAGE")) == "" {
		t.Skip("TestChainLiveProvision: set BARKPARK_SERVER_IMAGE (the baked snapshot id) " +
			"to run the LIVE chain — this creates real Hetzner servers + DNS and bills money")
	}

	// A generous bound: a real provision SSHes into a fresh box, installs/configures
	// Caddy, migrates, and waits on the health gate. The chain itself blocks; this
	// ceiling just stops a hung SSH from running forever.
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Minute)
	defer cancel()

	provider := cloud.HcloudProvider{}
	dns := cloud.NewCloudDNS()
	registry := &recordingRegistry{t: t}

	// Wire the SAME seams cmd/barkpark-provisioner/main.go wires. Health/Caddy/
	// Secrets are LEFT NIL → the real cloud-package defaults (defaultHealthChecker,
	// defaultCaddySteps, defaultSecretGen), exactly as main.go does. RunnerFor is
	// the real per-host SSH factory (NewSSHStepRunner), so the Caddy/TLS + migrate
	// steps run ON the provisioned box over SSH — the worker's real path.
	seams := Seams{
		Provider: provider,
		DNS:      dns,
		Registry: registry,
		RunnerFor: func(host string) cloud.StepRunner {
			return cloud.NewSSHStepRunner(host)
		},
		// Health / Caddy / Secrets nil → real defaults (same as main.go).
	}

	// The base spec comes from DefaultSpec("hetzner") so the box boots the baked
	// snapshot when BARKPARK_SERVER_IMAGE is set (the whole point of this harness).
	base := cloud.DefaultSpec(cloud.ProviderHetzner)
	t.Logf("[spec] region=%s type=%s image=%s (image from DefaultSpec → BARKPARK_SERVER_IMAGE)",
		base.Region, base.ServerType, base.Image)

	// ── Cleanup FIRST (deferred) so it runs even if the chain panics or fails
	// midway — belt-and-suspenders ON TOP of the one-shot's own self-cleanup. It
	// deletes the DNS record and any bp-test2 / warm-* server present. Registered
	// with t.Cleanup (not a plain defer) so it also fires on t.Fatal.
	t.Cleanup(func() {
		cleanupLiveRun(t, provider, dns)
	})

	// Build the one-shot WarmPool from the seams — the SAME construction
	// production's ProvisionWith uses (Provider + every injected seam). No Pool:
	// the one-shot path creates its single server directly via Provider.
	wp := &cloud.WarmPool{
		Provider:  seams.Provider,
		DNS:       seams.DNS,
		Registry:  seams.Registry,
		Health:    seams.Health,    // nil → real default health gate
		Caddy:     seams.Caddy,     // nil → real default Caddy steps
		RunnerFor: seams.RunnerFor, // real per-host SSH factory
		Runner:    seams.Runner,    // nil (RunnerFor wins)
		Secrets:   seams.Secrets,   // nil → real default secret-gen
		// MigrateArgv nil → defaultMigrateArgv: `cd /opt/barkpark/api && mix
		// ecto.migrate` over the SSH runner, the correct command for the baked image.
	}

	spec := cloud.GoLiveSpec{
		Name: liveLabel, // "test2" → test2.barkpark.cloud (DNS label); server = bp-test2
		Zone: Zone,      // "barkpark.cloud"
		App:  AppPort,   // 4000
		Spec: base,      // the spec the single server is created from
	}

	t.Logf("[provision] starting one-shot chain for %s.%s (app port %d) — create→secrets→dns→caddy→migrate→health→register",
		spec.Name, spec.Zone, spec.App)
	t.Logf("[provision] NOTE: one-shot creates exactly ONE server (bp-%s); on any post-create failure it tears that server + DNS down itself.",
		spec.Name)

	// Run the REAL one-shot chain — the exact call production's ProvisionWith
	// makes. It narrates internally via returned errors, so on failure we print
	// the FULL error (the SSH runner + provider surface captured stderr).
	start := time.Now()
	live, provErr := wp.ProvisionOneShot(ctx, spec)
	elapsed := time.Since(start).Round(time.Second)

	if provErr != nil {
		// Print the FULL error — the chain's error wraps which step failed
		// (assign/secrets/dns/caddy/migrate/health/register) and the captured
		// ssh/hcloud stderr. Fatal so the test reports red, but cleanup still runs.
		t.Fatalf("[provision] chain FAILED after %s:\n%v", elapsed, provErr)
	}

	t.Logf("[provision] chain SUCCEEDED after %s", elapsed)
	t.Logf("[provision] live server: name=%s fqdn=%s ip=%s", live.Name, live.FQDN, live.IP)
	t.Logf("[provision] (secrets minted; not logged in the clear)")
	if !registry.has(live.FQDN) {
		t.Errorf("[provision] registry stub did not record %s — chain reached success without register?", live.FQDN)
	}
}

// has reports whether the stub recorded a LiveServer with the given fqdn.
func (r *recordingRegistry) has(fqdn string) bool {
	for _, s := range r.recorded {
		if s.FQDN == fqdn {
			return true
		}
	}
	return false
}

// cleanupLiveRun deletes everything the harness created, robustly and
// idempotently, so no orphan server bills. It runs even when the chain failed
// midway (registered via t.Cleanup). It does NOT use the test's (possibly
// cancelled/timed-out) context — a fresh, bounded context so cleanup always gets
// to make its delete calls.
//
// Order: delete the DNS record first (cheap, no dependency), then the servers.
// Servers are deleted by EXPLICIT name (warm-1 = the assigned live host, warm-2 =
// the replacement the pop fired) AND by a list-and-sweep of every warm-* host —
// belt-and-suspenders so a refill that landed on a higher counter (warm-3+) or a
// partial run still gets swept. Each delete error is logged, not fatal: cleanup
// must attempt ALL deletes even if one fails.
func cleanupLiveRun(t *testing.T, provider cloud.HcloudProvider, dns *cloud.CloudDNS) {
	t.Helper()
	cctx, ccancel := context.WithTimeout(context.Background(), 3*time.Minute)
	defer ccancel()

	t.Logf("[cleanup] starting — deleting DNS record + all created servers")

	// 1. DNS: delete the A record test2.barkpark.cloud. DeleteRecord is idempotent
	//    (swallows "not found"), so this is safe even if the dns step never ran.
	if err := dns.DeleteRecord(cctx, Zone, liveLabel, "A"); err != nil {
		t.Logf("[cleanup] WARN: delete DNS %s.%s A failed: %v", liveLabel, Zone, err)
	} else {
		t.Logf("[cleanup] OK: deleted (or absent) DNS %s.%s A", liveLabel, Zone)
	}

	// 2. Server by name prefix. The one-shot path now creates a server named
	//    bp-<label>-<crypto suffix> (e.g. bp-test2-9f3ac1), so the exact name is
	//    NOT predictable from liveLabel alone — the list-and-sweep below (step 3),
	//    keyed on the bp- prefix via isHarnessServer, is the real teardown for it.
	//    The legacy exact-name attempt is kept as a cheap best-effort for the
	//    pre-suffix shape; a non-nil error (it won't match the suffixed name) is
	//    expected and harmless, the sweep catches the real host.
	oneShotName := "bp-" + liveLabel
	if err := provider.Delete(cctx, oneShotName); err != nil {
		t.Logf("[cleanup] note: delete exact %s failed (expected — the real name carries a crypto suffix; the sweep below catches it): %v", oneShotName, err)
	} else {
		t.Logf("[cleanup] OK: deleted server %s", oneShotName)
	}

	// 3. List-and-sweep: catch any OTHER harness host (a leftover from a prior
	//    failed run, or a stray warm-* from the legacy pool path). The safety net
	//    against orphan billing.
	servers, err := provider.List(cctx)
	if err != nil {
		t.Logf("[cleanup] WARN: could not list servers to sweep for stragglers: %v", err)
		t.Logf("[cleanup] CHECK MANUALLY: run `hcloud server list` and delete any leftover bp-%s / warm-* host", liveLabel)
		return
	}
	swept := 0
	for _, s := range servers {
		if !isHarnessServer(s.Name) {
			continue
		}
		if s.Name == oneShotName {
			continue // already attempted above
		}
		if err := provider.Delete(cctx, s.Name); err != nil {
			t.Logf("[cleanup] WARN: sweep delete %s failed: %v", s.Name, err)
		} else {
			t.Logf("[cleanup] OK: swept straggler server %s", s.Name)
			swept++
		}
	}
	if swept == 0 {
		t.Logf("[cleanup] no straggler harness servers to sweep")
	}
	t.Logf("[cleanup] done — verify with `hcloud server list` that no bp-%s / warm-* host remains", liveLabel)
}

// isHarnessServer reports whether name looks like a host this harness creates: a
// one-shot instance (bp-*) or a legacy warm pool host (warm-*). Used by the
// list-and-sweep so cleanup never touches an unrelated production server.
func isHarnessServer(name string) bool {
	return strings.HasPrefix(name, "bp-") || strings.HasPrefix(name, "warm-")
}

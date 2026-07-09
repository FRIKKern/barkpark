package provisioner

// restore.go is the RESURRECT chain (charter S14, Decision 12): rebuild a whole
// instance from a portable archive bundle onto a FRESH box — the bold cross-provider
// bet. A bundle archived on Hetzner comes back on Azure and vice-versa.
//
// A resurrect is NOT a launch. It narrates the SAME seven-step feed a launch does
// (create → freshen → secure → configure → content → verify → ready) so the /new
// screen renders it identically, but each step does something different:
//
//   - create    — a COLD create of a fresh box for the TARGET provider. A resurrect
//                 NEVER warm-assigns (D40): warm inventory carries the wrong (empty)
//                 identity and a resurrect must land the bundle's sealed identity.
//   - freshen   — bring the box to a runnable Barkpark: the baked warm-image on
//                 Hetzner, the from-scratch base install on Azure (no snapshot
//                 substrate there — deploy/azure-base-install.sh, D41).
//   - secure    — repoint the manifest's fqdn A-record at the fresh box (DNS is
//                 provider-orthogonal, Decision 10 — the record moves for free).
//   - configure — install the bundle's SEALED identity secrets, unsealed with the
//                 CARRIED KEK (never minted here — the box keeps its prior identity so
//                 links/tokens survive), then install the freshly-minted agent token.
//                 The empty-DB seed is SKIPPED (the restore supplies the data).
//   - content   — the RESTORE phase: fetch db.dump + media from the bundle store,
//                 DROP + CREATE the database the MANIFEST names, pg_restore --no-owner,
//                 unpack media, best-effort migrate. Template bootstrap is suppressed.
//   - verify    — the golden-path gate against the restored fqdn.
//   - ready     — the box is live and serving its restored content.
//
// The provider/object-store actions live behind the RestoreDriver seam so the whole
// round-trip is proven offline (fakes both directions); the real driver creates the
// box via ProvisionOneShot in restore mode and runs pg_restore over the box runner.

import (
	"context"
	"fmt"
	"os"
	"strings"

	"github.com/FRIKKern/barkpark/internal/cli/cloud"
)

// ResurrectStepOrder is the fixed seven-step feed a resurrect narrates, in order —
// the SAME vocabulary a provision uses (so the control plane's step validator and the
// /new screen treat a resurrect exactly like a launch).
var ResurrectStepOrder = []string{"create", "freshen", "secure", "configure", "content", "verify", "ready"}

// RestoreDriver executes the provider-specific + object-store actions of a portable
// restore. The real implementation (wired at S14a/b/c integration) creates the box
// via ProvisionOneShot in restore mode, fetches the bundle from object storage, and
// runs pg_restore over the box's runner; tests inject a recorder so the round-trip is
// proven with zero live anything. Every method is passed only what it needs; none is
// handed the KEK except InstallSecrets (the single sanctioned unseal).
type RestoreDriver interface {
	// CreateHost provisions a FRESH box for job.Kind and returns its live IP. It is
	// ALWAYS a cold create — a resurrect NEVER warm-assigns (D40).
	CreateHost(ctx context.Context, job JobSpec) (ip string, err error)
	// Freshen brings the fresh box to a runnable Barkpark (warm-image on Hetzner, the
	// from-scratch base install on Azure — cloud.FreshenPlan describes which).
	Freshen(ctx context.Context, job JobSpec, ip string) error
	// RepointDNS points the bundle's fqdn A-record at ip (secure step).
	RepointDNS(ctx context.Context, fqdn, ip string) error
	// InstallSecrets unseals secrets.enc with the CARRIED kek and installs the box's
	// identity secrets (configure step). It MUST NOT mint fresh secrets.
	InstallSecrets(ctx context.Context, ref BundleRef, ip string) error
	// InstallAgent writes the freshly-minted monitoring token + enables the beat.
	// Called only when the job carries an agent token.
	InstallAgent(ctx context.Context, agentToken, ip string) error
	// RestoreData fetches db.dump + media from the bundle store, DROPs + CREATEs the
	// database the manifest names, pg_restore --no-owner, unpacks media, and runs a
	// best-effort migrate (the content/restore phase — seed + template bootstrap are
	// suppressed).
	RestoreData(ctx context.Context, ref BundleRef, ip string) error
	// Verify runs the golden-path gate against the restored fqdn (verify step).
	Verify(ctx context.Context, fqdn string) error
}

// provisionRestore runs the resurrect chain for a job that carries a BundleRef. It
// returns the SAME (ip, adminToken, boot, teardown, err) shape as a normal provision
// so the worker's succeed/orphan-teardown logic is untouched — but adminToken is
// empty (the identity is RESTORED from the bundle, never minted) and boot is nil (no
// template bootstrap on a restore).
func provisionRestore(ctx context.Context, seams Seams, job JobSpec) (string, string, *BootstrapOutputs, Teardown, error) {
	ref := job.BundleRef
	if ref == nil {
		return "", "", nil, nil, fmt.Errorf("provisioner: provisionRestore called without a BundleRef")
	}
	// A resurrect keeps its prior identity, so the KEK that unseals it MUST be carried
	// from the archive — refuse to run if it is missing rather than let the box come
	// back with a freshly-minted (wrong) identity (defaultSecretGen must not run here).
	if strings.TrimSpace(ref.KEK) == "" {
		return "", "", nil, nil, fmt.Errorf("resurrect %s: the bundle KEK is missing — a resurrect must CARRY its key (never mint a new identity); no box was created", ref.Manifest.Fqdn)
	}
	if strings.TrimSpace(ref.Manifest.DBName) == "" {
		return "", "", nil, nil, fmt.Errorf("resurrect %s: the bundle manifest names no database to restore into; no box was created", ref.Manifest.Fqdn)
	}
	driver := seams.Restore
	if driver == nil {
		return "", "", nil, nil, fmt.Errorf("resurrect %s: no restore driver wired (the bundle store + on-box restore) — a resurrect job cannot run as a normal provision", ref.Manifest.Fqdn)
	}

	kind := job.Kind
	if kind == "" {
		kind = cloud.ProviderHetzner
	}
	fqdn := ref.Manifest.Fqdn

	// The same telemetry pair a normal provision uses: a live console emitter + the
	// coarse step reporter. Both are PURE TELEMETRY — a report failure is swallowed and
	// never fails the restore.
	console := newConsoleEmitter(ctx, job.JobID, seams.ConsoleReporter)
	console.logf("resurrecting %s onto %s from bundle %s (archived on %s)…", fqdn, kind, ref.Key, ref.Manifest.SourceProvider)
	report := func(step, status, detail string) {
		if detail != "" {
			console.logf("%s: %s — %s", step, status, detail)
		} else {
			console.logf("%s: %s", step, status)
		}
		if seams.StepReporter == nil {
			return
		}
		if err := seams.StepReporter(ctx, job.JobID, step, status, detail); err != nil {
			fmt.Fprintf(os.Stderr, "barkpark-provisioner: restore step report %s/%s for job %s failed (non-fatal): %v\n", step, status, job.JobID, err)
		}
	}
	// failStep narrates a failed step and returns the error — the worker's fail path
	// releases the job for retry. No box teardown here: a partially-restored box is torn
	// down by the driver's own create cleanup on the failing call, mirroring the
	// provision chain's nil-teardown-on-failure contract.
	failStep := func(step string, err error) (string, string, *BootstrapOutputs, Teardown, error) {
		report(step, "failed", err.Error())
		return "", "", nil, nil, fmt.Errorf("resurrect %s (%s): %w", fqdn, step, err)
	}

	// ── 1. create — a COLD create; a resurrect NEVER warm-assigns (D40) ──
	report("create", "started", "cold create on "+kind+" (resurrect never warm-assigns)")
	ip, err := driver.CreateHost(ctx, job)
	if err != nil {
		return failStep("create", err)
	}
	report("create", "done", ip)

	// ── 2. freshen — provider base image / from-scratch base install ──
	report("freshen", "started", cloud.FreshenPlan(kind))
	if err := driver.Freshen(ctx, job, ip); err != nil {
		return failStep("freshen", err)
	}
	report("freshen", "done", "")

	// ── 3. secure — repoint the fqdn A-record at the fresh box ──
	report("secure", "started", "repoint "+fqdn+" → "+ip)
	if err := driver.RepointDNS(ctx, fqdn, ip); err != nil {
		return failStep("secure", err)
	}
	report("secure", "done", "")

	// ── 4. configure — install SEALED identity (KEK carried, not minted) + agent ──
	report("configure", "started", "install sealed identity (KEK carried, not minted); empty-DB seed skipped")
	if err := driver.InstallSecrets(ctx, *ref, ip); err != nil {
		return failStep("configure", err)
	}
	if strings.TrimSpace(job.AgentToken) != "" {
		if err := driver.InstallAgent(ctx, job.AgentToken, ip); err != nil {
			return failStep("configure", err)
		}
	}
	report("configure", "done", "")

	// ── 5. content — the RESTORE phase: drop → create → pg_restore → media → migrate ──
	report("content", "started", "restore db "+ref.Manifest.DBName+" (drop→create→pg_restore→migrate); template bootstrap suppressed")
	if err := driver.RestoreData(ctx, *ref, ip); err != nil {
		return failStep("content", err)
	}
	report("content", "done", "")

	// ── 6. verify — the golden-path gate against the restored fqdn ──
	report("verify", "started", "")
	if err := driver.Verify(ctx, fqdn); err != nil {
		return failStep("verify", err)
	}
	report("verify", "done", "")

	// ── 7. ready — live + serving the restored content ──
	report("ready", "started", "")
	report("ready", "done", "")

	// Orphan safety, mirroring a normal provision: if the worker's succeed POST fails,
	// the box is live but unknown to the control plane — hand back a teardown so it can
	// be reclaimed. The identity is restored (adminToken ""), so nothing is minted here.
	teardown := func(tdCtx context.Context) error {
		return restoreTearDown(tdCtx, driver, kind, fqdn, ip)
	}
	return ip, "", nil, teardown, nil
}

// restoreTeardowner is the OPTIONAL cleanup facet a RestoreDriver may satisfy so an
// orphaned restored box (succeed-report-failed edge) can be reclaimed. A driver that
// does not implement it leaves the box for the orphan sweep.
type restoreTeardowner interface {
	TearDown(ctx context.Context, kind, fqdn, ip string) error
}

// restoreTearDown dispatches to the driver's optional TearDown, else no-ops — so the
// RestoreDriver interface stays minimal (cleanup is an add-on, not a required method).
func restoreTearDown(ctx context.Context, d RestoreDriver, kind, fqdn, ip string) error {
	if td, ok := d.(restoreTeardowner); ok {
		return td.TearDown(ctx, kind, fqdn, ip)
	}
	return nil
}

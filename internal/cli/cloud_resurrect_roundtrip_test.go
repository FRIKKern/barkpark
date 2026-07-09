package cli

// cloud_resurrect_roundtrip_test.go is the offline PORTABLE-ARCHIVE round-trip proof
// (charter S14, Decision 12) — the bold cross-provider bet, proven with fakes in BOTH
// directions and zero live anything:
//
//	archive on Hetzner → resurrect on Azure
//	archive on Azure   → resurrect on Hetzner
//
// It closes the wave-4-parked "fake round-trip" follow-up. The archive side runs the
// fake provider's Archiver to mint a bundle ref (what S14b's object-storage upload
// produces); the resurrect side runs the real provisioner.ProvisionWith restore chain
// against a RECORDING RestoreDriver, asserting the contract the real driver must
// honour: the seven-step feed order, KEK carried (not minted), the
// drop→create→pg_restore→migrate sequence, the DNS repoint, the freshly-minted agent
// token, and manifest fidelity end to end.

import (
	"context"
	"fmt"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/cli/cloud"
	"github.com/FRIKKern/barkpark/internal/provisioner"
)

// recordingRestoreDriver captures every RestoreDriver call in order plus the
// sensitive arguments the proof asserts on. Its RestoreData records the mandated
// on-box sub-sequence so the round-trip pins the drop→restore→migrate contract.
type recordingRestoreDriver struct {
	t          *testing.T
	assignedIP string

	calls        []string // ordered method names
	freshenKind  string   // job.Kind seen at freshen (the TARGET provider)
	repointFQDN  string
	repointIP    string
	kekSeen      string   // the KEK InstallSecrets received — MUST equal the carried KEK
	installedDB  string   // manifest DB RestoreData restored into
	agentSeen    string   // agent token InstallAgent received (freshly minted)
	restoreOps   []string // the drop→create→pg_restore→migrate sub-sequence RestoreData ran
	verifiedFQDN string
}

func (d *recordingRestoreDriver) CreateHost(_ context.Context, job provisioner.JobSpec) (string, error) {
	d.calls = append(d.calls, "CreateHost")
	// A resurrect NEVER warm-assigns — the driver always cold-creates. Prove the
	// orchestrator handed us the target provider, not the source.
	if job.Kind == "" {
		return "", fmt.Errorf("resurrect create got an empty target kind")
	}
	return d.assignedIP, nil
}

func (d *recordingRestoreDriver) Freshen(_ context.Context, job provisioner.JobSpec, ip string) error {
	d.calls = append(d.calls, "Freshen")
	d.freshenKind = job.Kind
	return nil
}

func (d *recordingRestoreDriver) RepointDNS(_ context.Context, fqdn, ip string) error {
	d.calls = append(d.calls, "RepointDNS")
	d.repointFQDN, d.repointIP = fqdn, ip
	return nil
}

func (d *recordingRestoreDriver) InstallSecrets(_ context.Context, ref provisioner.BundleRef, ip string) error {
	d.calls = append(d.calls, "InstallSecrets")
	d.kekSeen = ref.KEK
	return nil
}

func (d *recordingRestoreDriver) InstallAgent(_ context.Context, token, ip string) error {
	d.calls = append(d.calls, "InstallAgent")
	d.agentSeen = token
	return nil
}

func (d *recordingRestoreDriver) RestoreData(_ context.Context, ref provisioner.BundleRef, ip string) error {
	d.calls = append(d.calls, "RestoreData")
	d.installedDB = ref.Manifest.DBName
	// The mandated on-box restore sequence the real driver runs: drop the target DB,
	// recreate it empty, pg_restore --no-owner the dump, then best-effort migrate.
	d.restoreOps = []string{
		"DROP DATABASE " + ref.Manifest.DBName,
		"CREATE DATABASE " + ref.Manifest.DBName,
		"pg_restore --no-owner " + ref.Manifest.DBName,
		"migrate " + ref.Manifest.DBName,
	}
	return nil
}

func (d *recordingRestoreDriver) Verify(_ context.Context, fqdn string) error {
	d.calls = append(d.calls, "Verify")
	d.verifiedFQDN = fqdn
	return nil
}

// bundleFromArchive builds the BundleRef S14b's upload would produce from a fake
// Archiver's Archive — the "archive side" of the round-trip. The KEK is minted ONCE
// here (at archive time) and CARRIED into the resurrect; the resurrect must reuse it,
// never mint a fresh one.
func bundleFromArchive(t *testing.T, sourceKind, fqdn string) provisioner.BundleRef {
	t.Helper()
	fake := &cloud.FakeProvider{}
	arch, err := fake.Archive(context.Background(), fqdn)
	if err != nil {
		t.Fatalf("archive on %s: %v", sourceKind, err)
	}
	dbName := "bp_" + strings.ReplaceAll(strings.Split(fqdn, ".")[0], "-", "_")
	return provisioner.BundleRef{
		Store: "s3://bp-archives",
		Key:   "bundles/" + arch.ID + ".tar.zst",
		KEK:   "kek-carried-from-" + sourceKind + "-archive-time", // minted at ARCHIVE time
		Manifest: provisioner.BundleManifest{
			SourceProvider: sourceKind,
			Fqdn:           fqdn,
			DBName:         dbName,
			MediaPaths:     []string{"/var/lib/barkpark/media"},
			ArchivedAt:     "2026-07-09T00:00:00Z",
			SchemaVersion:  42,
		},
	}
}

// resurrectOnce runs one direction of the round-trip: restore `bundle` onto a fresh
// box on `targetKind`, capturing the step feed + the driver's calls.
func resurrectOnce(t *testing.T, targetKind string, bundle provisioner.BundleRef) (*recordingRestoreDriver, []string, string, error) {
	t.Helper()
	drv := &recordingRestoreDriver{t: t, assignedIP: "203.0.113.7"}
	var feed []string
	seams := provisioner.Seams{
		Restore: drv,
		StepReporter: func(_ context.Context, _ /*jobID*/, step, status, _ string) error {
			feed = append(feed, step+":"+status)
			return nil
		},
	}
	job := provisioner.JobSpec{
		JobID:      "job-resurrect-1",
		Name:       strings.Split(bundle.Manifest.Fqdn, ".")[0],
		Slug:       strings.Split(bundle.Manifest.Fqdn, ".")[0],
		Kind:       targetKind,
		AgentToken: "agenttoken-freshly-minted",
		BundleRef:  &bundle,
	}
	ip, _, boot, teardown, err := provisioner.ProvisionWith(context.Background(), seams, job)
	if boot != nil {
		t.Errorf("resurrect must NOT run a template bootstrap (boot=%+v)", boot)
	}
	if err == nil && teardown == nil {
		t.Error("a successful resurrect must hand back an orphan teardown")
	}
	return drv, feed, ip, err
}

// TestResurrectRoundTripBothDirections is the proof: archive→resurrect across the
// provider boundary in BOTH directions, asserting the full restore contract.
func TestResurrectRoundTripBothDirections(t *testing.T) {
	cases := []struct {
		name   string
		source string
		target string
		fqdn   string
	}{
		{"hetzner-archive-restores-on-azure", cloud.ProviderHetzner, cloud.ProviderAzure, "okey.barkpark.cloud"},
		{"azure-archive-restores-on-hetzner", cloud.ProviderAzure, cloud.ProviderHetzner, "vega.barkpark.cloud"},
	}
	wantCalls := []string{"CreateHost", "Freshen", "RepointDNS", "InstallSecrets", "InstallAgent", "RestoreData", "Verify"}
	wantFeed := []string{
		"create:started", "create:done",
		"freshen:started", "freshen:done",
		"secure:started", "secure:done",
		"configure:started", "configure:done",
		"content:started", "content:done",
		"verify:started", "verify:done",
		"ready:started", "ready:done",
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			bundle := bundleFromArchive(t, tc.source, tc.fqdn)
			drv, feed, ip, err := resurrectOnce(t, tc.target, bundle)
			if err != nil {
				t.Fatalf("resurrect %s→%s: %v", tc.source, tc.target, err)
			}

			// 1. Seven-step feed, exact order (a resurrect narrates like a launch).
			if strings.Join(feed, ",") != strings.Join(wantFeed, ",") {
				t.Errorf("step feed order wrong:\n got: %v\nwant: %v", feed, wantFeed)
			}

			// 2. Driver called in the mandated order (never a warm-assign — always CreateHost).
			if strings.Join(drv.calls, ",") != strings.Join(wantCalls, ",") {
				t.Errorf("driver call order wrong:\n got: %v\nwant: %v", drv.calls, wantCalls)
			}

			// 3. Cold create landed on the TARGET provider, not the source.
			if drv.freshenKind != tc.target {
				t.Errorf("freshen ran for %q, want the target provider %q", drv.freshenKind, tc.target)
			}

			// 4. KEK CARRIED, not minted: InstallSecrets saw exactly the archive-time KEK.
			if drv.kekSeen != bundle.KEK {
				t.Errorf("InstallSecrets got KEK %q, want the CARRIED %q", drv.kekSeen, bundle.KEK)
			}
			if !strings.Contains(drv.kekSeen, "carried-from-"+tc.source) {
				t.Errorf("KEK %q was not the one minted at %s archive time", drv.kekSeen, tc.source)
			}

			// 5. Manifest fidelity: the restore landed in the DB the MANIFEST named.
			if drv.installedDB != bundle.Manifest.DBName {
				t.Errorf("restored into DB %q, want manifest DB %q", drv.installedDB, bundle.Manifest.DBName)
			}

			// 6. drop→create→pg_restore→migrate, in that order.
			wantOps := []string{
				"DROP DATABASE " + bundle.Manifest.DBName,
				"CREATE DATABASE " + bundle.Manifest.DBName,
				"pg_restore --no-owner " + bundle.Manifest.DBName,
				"migrate " + bundle.Manifest.DBName,
			}
			if strings.Join(drv.restoreOps, "|") != strings.Join(wantOps, "|") {
				t.Errorf("restore sub-sequence wrong:\n got: %v\nwant: %v", drv.restoreOps, wantOps)
			}

			// 7. DNS repoint of the manifest fqdn at the fresh box.
			if drv.repointFQDN != tc.fqdn || drv.repointIP != ip {
				t.Errorf("DNS repoint = %s→%s, want %s→%s", drv.repointFQDN, drv.repointIP, tc.fqdn, ip)
			}

			// 8. A freshly-minted agent token was installed (the beat is per-instance,
			//    unlike the carried identity secrets).
			if drv.agentSeen != "agenttoken-freshly-minted" {
				t.Errorf("agent token not installed on the restored box: %q", drv.agentSeen)
			}

			// 9. Verify probed the restored fqdn.
			if drv.verifiedFQDN != tc.fqdn {
				t.Errorf("verify probed %q, want %q", drv.verifiedFQDN, tc.fqdn)
			}
		})
	}
}

// TestResurrectRefusesMintedIdentity proves the KEK-carried-not-minted invariant at
// the gate: a resurrect with no carried KEK is refused BEFORE any box is created,
// rather than letting defaultSecretGen mint a fresh (wrong) identity.
func TestResurrectRefusesMintedIdentity(t *testing.T) {
	bundle := bundleFromArchive(t, cloud.ProviderHetzner, "okey.barkpark.cloud")
	bundle.KEK = "" // the control plane failed to carry the key
	drv := &recordingRestoreDriver{t: t, assignedIP: "203.0.113.7"}
	seams := provisioner.Seams{Restore: drv}
	job := provisioner.JobSpec{JobID: "j1", Kind: cloud.ProviderAzure, BundleRef: &bundle}

	_, _, _, _, err := provisioner.ProvisionWith(context.Background(), seams, job)
	if err == nil {
		t.Fatal("resurrect with no carried KEK must fail (identity would be minted, not restored)")
	}
	if !strings.Contains(err.Error(), "CARRY") {
		t.Errorf("error should explain the KEK must be carried, got: %v", err)
	}
	if len(drv.calls) != 0 {
		t.Errorf("no box may be created for a KEK-less resurrect; driver was called: %v", drv.calls)
	}
}

// TestResurrectNeedsDriver proves a resurrect job routed at a worker with no restore
// driver fails LOUD — it can never silently fall through to a normal provision.
func TestResurrectNeedsDriver(t *testing.T) {
	bundle := bundleFromArchive(t, cloud.ProviderAzure, "vega.barkpark.cloud")
	job := provisioner.JobSpec{JobID: "j1", Kind: cloud.ProviderHetzner, BundleRef: &bundle}
	_, _, _, _, err := provisioner.ProvisionWith(context.Background(), provisioner.Seams{}, job)
	if err == nil || !strings.Contains(err.Error(), "restore driver") {
		t.Fatalf("a resurrect with no restore driver must fail loud, got: %v", err)
	}
}

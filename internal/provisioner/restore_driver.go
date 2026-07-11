package provisioner

// restore_driver.go — the worker-side of the resurrect drain (charter S14f):
//
//   - resurrectClaimSpec + translateResurrect — the D43 DECODE + TRANSLATE. The
//     claim's bundle_ref is a STRING (the object-store prefix), but JobSpec.BundleRef
//     is a *BundleRef STRUCT under the same json tag, so a direct unmarshal into
//     JobSpec fails; we decode into a dedicated spec, then read the bundle manifest
//     and build the struct (store creds + KEK from WORKER ENV, never the claim JSON).
//   - ResolveBundleEnv / DefaultResurrectDeps — the WORKER-ENV bundle wiring.
//   - CloudRestoreDriver — the real provisioner.RestoreDriver (D46), a thin adapter
//     over the cloud.RestoreExecutor primitives + the existing golden-path verify
//     gate. It lives HERE (not in package cloud) because the interface names
//     provisioner types and Verify reuses the provisioner verify gate — but every
//     provider/object-store/on-box ACTION is the cloud executor's, so the heavy
//     logic stays in the cloud package (import-cycle-free, offline-tested there).

import (
	"context"
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/FRIKKern/barkpark/internal/cli/cloud"
	"github.com/FRIKKern/barkpark/internal/hetzner/objstore"
)

// bundleEnv names the WORKER-ENV vars the resurrect drain reads to reach the
// portable-archive object store + unseal its secrets. They are the SAME S3
// credentials + bucket the archive command uses, plus the bundle-at-rest KEK. The
// creds/KEK NEVER ride the claim JSON (charter S14f/D43) — they are worker config,
// minted once in the Hetzner Console (there is no API for the S3 credential mint).
const (
	envBundleS3AccessKey = "HETZNER_S3_ACCESS_KEY"
	envBundleS3SecretKey = "HETZNER_S3_SECRET_KEY"
	envBundleBucket      = "BARKPARK_BUNDLE_BUCKET"
	envBundleKEK         = "BARKPARK_BUNDLE_KEK"
	envBundleS3Location  = "BARKPARK_BUNDLE_S3_LOCATION"
	defaultBundleS3Loc   = "fsn1"
)

// resurrectClaimSpec is one claimed resurrect job as the control plane hands it
// back (charter S14f/D43): the FULL provision claim payload PLUS bundle_ref as a
// STRING (the object-store prefix of the archive to restore from). It is decoded
// SEPARATELY from JobSpec precisely because JobSpec.BundleRef is a *struct under the
// same json tag — unmarshalling this string into JobSpec would fail. translate
// turns it into a JobSpec carrying the resolved *BundleRef.
type resurrectClaimSpec struct {
	JobID       string            `json:"job_id"`
	ClaimToken  string            `json:"claim_token"`
	Name        string            `json:"name"`
	Slug        string            `json:"slug"`
	Region      string            `json:"region"`
	ServerType  string            `json:"server_type"`
	Kind        string            `json:"kind"`
	Credentials map[string]string `json:"credentials"`
	AgentToken  string            `json:"agent_token"`
	// BundleRef is the object-store PREFIX of the bundle to restore (a STRING, unlike
	// JobSpec.BundleRef). Required — claimResurrect rejects a blank one.
	BundleRef string `json:"bundle_ref"`
}

// ResurrectDeps is the worker-env-sourced bundle wiring the resurrect drain needs:
// the object store the bundle lives in, its bucket (informational, stamped onto the
// resolved BundleRef.Store), and the KEK that unseals the sealed identity. Resolved
// from env, NEVER from the claim JSON.
type ResurrectDeps struct {
	Store  cloud.BundleStore
	Bucket string
	KEK    string
}

// ResurrectDepsFunc resolves ResurrectDeps from the worker environment. It returns
// an error (naming the missing var) when the bundle store is not configured — the
// drain reports that as an honest JOB failure and survives.
type ResurrectDepsFunc func() (ResurrectDeps, error)

// ResolveBundleEnv builds the resurrect drain's object store + KEK from the worker
// environment (the same HETZNER_S3_* creds + BARKPARK_BUNDLE_BUCKET the archive
// command reads, plus BARKPARK_BUNDLE_KEK and an optional BARKPARK_BUNDLE_S3_LOCATION
// that defaults to fsn1). A missing credential/bucket/KEK is a loud, actionable
// error — the resurrect job fails honestly rather than silently restoring nothing.
func ResolveBundleEnv() (ResurrectDeps, error) {
	ak := strings.TrimSpace(os.Getenv(envBundleS3AccessKey))
	sk := strings.TrimSpace(os.Getenv(envBundleS3SecretKey))
	bucket := strings.TrimSpace(os.Getenv(envBundleBucket))
	kek := strings.TrimSpace(os.Getenv(envBundleKEK))
	if ak == "" || sk == "" || bucket == "" || kek == "" {
		return ResurrectDeps{}, fmt.Errorf(
			"resurrect needs the bundle store env: set %s, %s, %s and %s on the provisioner (the S3 credentials + archive bucket are minted once in the Hetzner Console under Object Storage; the KEK is the operator secret the archive was sealed with)",
			envBundleS3AccessKey, envBundleS3SecretKey, envBundleBucket, envBundleKEK)
	}
	location := strings.TrimSpace(os.Getenv(envBundleS3Location))
	if location == "" {
		location = defaultBundleS3Loc
	}
	c, err := objstore.NewClient(location, ak, sk)
	if err != nil {
		return ResurrectDeps{}, fmt.Errorf("resurrect: build object store client: %w", err)
	}
	return ResurrectDeps{Store: cloud.NewObjstoreBundleStore(c, bucket), Bucket: bucket, KEK: kek}, nil
}

// DefaultResurrectDeps is the production ResurrectDepsFunc — ResolveBundleEnv read
// fresh each cycle so a mid-run env fix (systemd EnvironmentFile edit + restart)
// takes effect without special-casing.
func DefaultResurrectDeps() (ResurrectDeps, error) { return ResolveBundleEnv() }

// translateResurrect turns a claimed resurrect spec into a JobSpec carrying a full
// *BundleRef (charter S14f/D43). It reads the bundle MANIFEST from the store at the
// claim's prefix, maps cloud.BundleManifest → provisioner.BundleManifest FIELD BY
// FIELD (two DISTINCT types), and injects the KEK from deps (worker env) — the KEK
// never rides the claim. MediaPaths/SchemaVersion have no source in the pinned
// manifest and stay zero (D44 — no archive-time manifest shape change).
func translateResurrect(ctx context.Context, spec resurrectClaimSpec, deps ResurrectDeps) (JobSpec, error) {
	prefix := strings.TrimSpace(spec.BundleRef)
	if prefix == "" {
		return JobSpec{}, fmt.Errorf("resurrect %s: empty bundle_ref", spec.JobID)
	}
	m, err := cloud.ReadManifest(ctx, deps.Store, prefix)
	if err != nil {
		return JobSpec{}, fmt.Errorf("resurrect %s: read bundle manifest at %q: %w", spec.JobID, prefix, err)
	}

	manifest := BundleManifest{
		SourceProvider: m.SourceProvider,
		Fqdn:           m.FQDN,
		DBName:         m.DBName,
		ArchivedAt:     m.CreatedAt.UTC().Format(time.RFC3339),
		// MediaPaths + SchemaVersion have no source in the pinned bp-bundle-v1 manifest
		// (D44) — left zero; the restore names its media member by the fixed constant.
	}
	ref := &BundleRef{
		Store:    deps.Bucket, // informational — the driver rebuilds its client from env
		Key:      prefix,
		KEK:      deps.KEK,
		Manifest: manifest,
	}
	return JobSpec{
		JobID:       spec.JobID,
		ClaimToken:  spec.ClaimToken,
		Name:        spec.Name,
		Slug:        spec.Slug,
		Region:      spec.Region,
		ServerType:  spec.ServerType,
		Kind:        spec.Kind,
		Credentials: spec.Credentials,
		AgentToken:  spec.AgentToken,
		BundleRef:   ref,
	}, nil
}

// CloudRestoreDriver is the real provisioner.RestoreDriver (charter S14f/D46). It
// satisfies the interface by delegating every provider/object-store/on-box action
// to the injected cloud.RestoreExecutor, and implements Verify with the EXISTING
// golden-path gate (runVerifyGate) — the one step the executor does not own. main()
// wires it into Seams.Restore; tests wire the executor's seams to the fakes so the
// whole restore proves offline.
type CloudRestoreDriver struct {
	// Exec runs the real provider + object-store + on-box actions. Required.
	Exec *cloud.RestoreExecutor
	// VerifyBaseURL overrides the golden-path VERIFY target (tests point it at a fake
	// instance). Empty (production) → https://<fqdn>.
	VerifyBaseURL string
	// VerifyProbeTimeout / VerifyTotalBudget default to the gate's own values when
	// zero (production); tests set tiny values for fast paths.
	VerifyProbeTimeout time.Duration
	VerifyTotalBudget  time.Duration
}

// CreateHost cold-creates the fresh box (D40 — never warm-assigns).
func (d *CloudRestoreDriver) CreateHost(ctx context.Context, job JobSpec) (string, error) {
	base := cloud.ServerSpec{Region: job.Region, ServerType: job.ServerType}
	fqdn := ""
	if job.BundleRef != nil {
		fqdn = job.BundleRef.Manifest.Fqdn
	}
	return d.Exec.CreateHost(ctx, job.Kind, job.Credentials, base, fqdn)
}

// Freshen brings the box to a runnable Barkpark (warm-image on hetzner, base
// install on azure).
func (d *CloudRestoreDriver) Freshen(ctx context.Context, job JobSpec, ip string) error {
	return d.Exec.Freshen(ctx, job.Kind, ip)
}

// RepointDNS points the fqdn A-record at the fresh box.
func (d *CloudRestoreDriver) RepointDNS(ctx context.Context, fqdn, ip string) error {
	return d.Exec.RepointDNS(ctx, fqdn, ip)
}

// InstallSecrets unseals with the CARRIED kek (ref.KEK) and merges the identity
// into the box's .env. job.Kind picks the box's ssh policy (azure → barkpark+sudo).
func (d *CloudRestoreDriver) InstallSecrets(ctx context.Context, job JobSpec, ref BundleRef, ip string) error {
	return d.Exec.InstallSecrets(ctx, job.Kind, ref.Key, ref.KEK, ip)
}

// InstallAgent lights up the monitoring beat with the freshly-minted token.
func (d *CloudRestoreDriver) InstallAgent(ctx context.Context, job JobSpec, agentToken, ip string) error {
	return d.Exec.InstallAgent(ctx, job.Kind, agentToken, ip)
}

// RestoreData runs the on-box drop → pg_restore → media → migrate → restart.
func (d *CloudRestoreDriver) RestoreData(ctx context.Context, job JobSpec, ref BundleRef, ip string) error {
	return d.Exec.RestoreData(ctx, job.Kind, ref.Key, ref.Manifest.DBName, ip)
}

// Verify runs the EXISTING golden-path gate against the restored fqdn — no
// duplicated health logic. A no-op report sink: provisionRestore already narrates
// the verify step; this only needs the verdict.
func (d *CloudRestoreDriver) Verify(ctx context.Context, fqdn string) error {
	base := d.VerifyBaseURL
	if base == "" {
		base = "https://" + fqdn
	}
	return runVerifyGate(ctx, verifyConfig{
		baseURL:      base,
		probeTimeout: d.VerifyProbeTimeout,
		totalBudget:  d.VerifyTotalBudget,
	}, func(step, status, detail string) {})
}

// TearDown reclaims a half-restored or orphaned restored box (any post-create step
// failure, or the succeed-report-failed edge). creds are the claim's decrypted
// per-kind credentials so an azure teardown resolves its own provider; the hetzner
// path ignores them. Best effort — a failure is surfaced, never crashes the drain.
func (d *CloudRestoreDriver) TearDown(ctx context.Context, kind string, creds map[string]string, fqdn, ip string) error {
	return d.Exec.TearDown(ctx, kind, creds, fqdn, ip)
}

// compile-time proof the adapter satisfies the seam (and its optional teardowner).
var (
	_ RestoreDriver     = (*CloudRestoreDriver)(nil)
	_ restoreTeardowner = (*CloudRestoreDriver)(nil)
	_ ResurrectDepsFunc = DefaultResurrectDeps
)

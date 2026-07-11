package provisioner

// restore_test.go — component tests for the worker-side resurrect wiring in
// restore.go / restore_driver.go.
//
// The heavy restore ORCHESTRATION — provisionRestore + restoreTearDown, and the
// CloudRestoreDriver seam methods (CreateHost/Freshen/RepointDNS/InstallSecrets/
// InstallAgent/RestoreData/Verify/TearDown) — is already exercised end-to-end by
// the SCENARIO tests (resurrect_test.go drives full and mid-chain-failure
// resurrect cycles through a fake control plane + fake cloud executor). We do NOT
// duplicate that here.
//
// What the scenario tests did NOT reach are the pure worker-env resolvers and the
// translate error paths: ResolveBundleEnv's missing-var and success branches,
// DefaultResurrectDeps (the production delegator), and translateResurrect's
// empty-ref / manifest-read failure guards. Those are covered below.

import (
	"context"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/cli/cloud"
)

// TestResolveBundleEnvMissingVarErrors: each of the four required bundle-store
// vars, when blank, is a loud actionable error (the resurrect job fails honestly
// rather than silently restoring nothing).
func TestResolveBundleEnvMissingVarErrors(t *testing.T) {
	full := map[string]string{
		envBundleS3AccessKey: "ak",
		envBundleS3SecretKey: "sk",
		envBundleBucket:      "bkt",
		envBundleKEK:         "kek",
	}
	for _, missing := range []string{envBundleS3AccessKey, envBundleS3SecretKey, envBundleBucket, envBundleKEK} {
		t.Run("missing_"+missing, func(t *testing.T) {
			for k, v := range full {
				if k == missing {
					t.Setenv(k, "") // TrimSpace → "" → treated as unset
				} else {
					t.Setenv(k, v)
				}
			}
			if _, err := ResolveBundleEnv(); err == nil {
				t.Fatalf("a blank %s must be a loud error, got nil", missing)
			}
		})
	}
}

// TestResolveBundleEnvBuildsStoreFromEnv: a full env resolves a non-nil store,
// stamps the bucket + KEK, and takes the fsn1 default when the optional location
// var is unset.
func TestResolveBundleEnvBuildsStoreFromEnv(t *testing.T) {
	t.Setenv(envBundleS3AccessKey, "ak")
	t.Setenv(envBundleS3SecretKey, "sk")
	t.Setenv(envBundleBucket, "archive-bucket")
	t.Setenv(envBundleKEK, "operator-kek")
	t.Setenv(envBundleS3Location, "") // exercise the defaultBundleS3Loc fallback

	deps, err := ResolveBundleEnv()
	if err != nil {
		t.Fatalf("ResolveBundleEnv with a full env should succeed: %v", err)
	}
	if deps.Store == nil {
		t.Fatal("a resolved store must be non-nil")
	}
	if deps.Bucket != "archive-bucket" {
		t.Fatalf("Bucket = %q, want archive-bucket", deps.Bucket)
	}
	if deps.KEK != "operator-kek" {
		t.Fatalf("KEK = %q, want operator-kek", deps.KEK)
	}
}

// TestDefaultResurrectDepsDelegatesToResolveBundleEnv: the production
// ResurrectDepsFunc is a thin, env-fresh delegator — it fails without the env and
// resolves the same store with it.
func TestDefaultResurrectDepsDelegatesToResolveBundleEnv(t *testing.T) {
	for _, k := range []string{envBundleS3AccessKey, envBundleS3SecretKey, envBundleBucket, envBundleKEK} {
		t.Setenv(k, "")
	}
	if _, err := DefaultResurrectDeps(); err == nil {
		t.Fatal("DefaultResurrectDeps with no bundle env must surface the ResolveBundleEnv error")
	}

	t.Setenv(envBundleS3AccessKey, "ak")
	t.Setenv(envBundleS3SecretKey, "sk")
	t.Setenv(envBundleBucket, "bkt")
	t.Setenv(envBundleKEK, "kek")
	deps, err := DefaultResurrectDeps()
	if err != nil {
		t.Fatalf("DefaultResurrectDeps with a full env: %v", err)
	}
	if deps.Store == nil || deps.Bucket != "bkt" || deps.KEK != "kek" {
		t.Fatalf("delegation mismapped deps: %+v", deps)
	}
}

// TestTranslateResurrectErrorPaths: translate rejects a blank bundle_ref before
// touching the store, and surfaces a manifest-read failure (never returns a
// half-built JobSpec). The happy field-by-field mapping is proven in
// resurrect_test.go's TestTranslateResurrectMapsManifestFieldByField.
func TestTranslateResurrectErrorPaths(t *testing.T) {
	deps := ResurrectDeps{Store: cloud.NewFakeBundleStore(), Bucket: "bkt", KEK: "kek"}

	t.Run("empty bundle_ref", func(t *testing.T) {
		_, err := translateResurrect(context.Background(), resurrectClaimSpec{JobID: "rj-e"}, deps)
		if err == nil || !strings.Contains(err.Error(), "empty bundle_ref") {
			t.Fatalf("a blank bundle_ref must error, got %v", err)
		}
	})

	t.Run("manifest read failure", func(t *testing.T) {
		// The store has no object at the prefix → ReadManifest fails and translate
		// surfaces it.
		spec := resurrectClaimSpec{JobID: "rj-f", BundleRef: "bundles/missing/"}
		_, err := translateResurrect(context.Background(), spec, deps)
		if err == nil || !strings.Contains(err.Error(), "read bundle manifest") {
			t.Fatalf("a missing manifest must error, got %v", err)
		}
	})
}

// hintJob builds a resurrect JobSpec pinned to (pinRegion,pinType), carrying a
// bundle whose source provider is srcProvider and whose archive-time shape hint is
// (hintRegion,hintType). kind is the TARGET provider (empty → hetzner).
func hintJob(kind, pinRegion, pinType, srcProvider, hintRegion, hintType string) JobSpec {
	return JobSpec{
		Kind:       kind,
		Region:     pinRegion,
		ServerType: pinType,
		BundleRef: &BundleRef{
			Manifest: BundleManifest{
				SourceProvider: srcProvider,
				Spec:           BundleSpec{Region: hintRegion, ServerType: hintType},
			},
		},
	}
}

// TestResolveRestoreBasePrecedence proves the charter-D49 precedence pin > archived
// hint > provider default, field by field, including the two refutations the wave
// owes: a DIFFERING pin still wins, and a CROSS-PROVIDER job ignores the hint.
func TestResolveRestoreBasePrecedence(t *testing.T) {
	// The provider default the bottom tier resolves to (hetzner). Read from the same
	// source the code uses so the test tracks any default change.
	def := cloud.DefaultSpec(cloud.ProviderHetzner)
	if def.Region == "" || def.ServerType == "" {
		t.Fatalf("test premise: hetzner DefaultSpec must be concrete, got %+v", def)
	}

	t.Run("pin wins over a differing hint", func(t *testing.T) {
		// REFUTE: even when the bundle carries a real, DIFFERENT shape, an explicit pin
		// is an operator/CP choice and must win — the hint never overrides it.
		job := hintJob("hetzner", "nbg1", "cax11", "hetzner", "hel1", "cx33")
		got := resolveRestoreBase(job)
		if got.Region != "nbg1" || got.ServerType != "cax11" {
			t.Fatalf("pin must win over hint; got %+v, want {nbg1 cax11}", got)
		}
	})

	t.Run("unpinned same-provider takes the hint", func(t *testing.T) {
		// The core new behavior: an unpinned same-provider claim rebuilds to the
		// archived shape (not the generic provider default).
		job := hintJob("hetzner", "", "", "hetzner", "hel1", "cx33")
		got := resolveRestoreBase(job)
		if got.Region != "hel1" || got.ServerType != "cx33" {
			t.Fatalf("unpinned same-provider must take the hint; got %+v, want {hel1 cx33}", got)
		}
	})

	t.Run("empty Kind normalizes to hetzner and takes the hint", func(t *testing.T) {
		// An OLD control plane omits kind; the zero value must route hetzner, so a
		// hetzner-sourced hint still applies.
		job := hintJob("", "", "", "hetzner", "hel1", "cx33")
		got := resolveRestoreBase(job)
		if got.Region != "hel1" || got.ServerType != "cx33" {
			t.Fatalf("empty kind must be hetzner + take the hint; got %+v", got)
		}
	})

	t.Run("cross-provider job ignores the hint", func(t *testing.T) {
		// REFUTE: a Hetzner-archived shape is meaningless to Azure (D50 — cross-provider
		// size mapping is deferred, no heuristic guessed), so the hint is dropped and the
		// base falls to the provider default. Azure's DefaultSpec is empty today, which is
		// the honest "operator must pin" outcome — assert the hint values did NOT leak in.
		job := hintJob("azure", "", "", "hetzner", "hel1", "cx33")
		got := resolveRestoreBase(job)
		if got.Region == "hel1" || got.ServerType == "cx33" {
			t.Fatalf("cross-provider must ignore the hint; got %+v (hint leaked)", got)
		}
	})

	t.Run("no pin and no hint falls to the provider default", func(t *testing.T) {
		// Same provider but a blank hint (an unpinned archive stamped "") → the provider
		// default fills both fields.
		job := hintJob("hetzner", "", "", "hetzner", "", "")
		got := resolveRestoreBase(job)
		if got.Region != def.Region || got.ServerType != def.ServerType {
			t.Fatalf("blank pin+hint must fall to the default; got %+v, want %+v", got, def)
		}
	})

	t.Run("field-by-field: pin one, hint fills the other", func(t *testing.T) {
		// The pin sets only the region; the same-provider hint fills the unpinned
		// server_type — precedence resolves per field, not all-or-nothing.
		job := hintJob("hetzner", "nbg1", "", "hetzner", "hel1", "cx33")
		got := resolveRestoreBase(job)
		if got.Region != "nbg1" || got.ServerType != "cx33" {
			t.Fatalf("per-field precedence: pin region + hint server_type; got %+v, want {nbg1 cx33}", got)
		}
	})

	t.Run("no bundle ref falls to the provider default", func(t *testing.T) {
		// Defensive: a resurrect JobSpec should always carry a BundleRef, but a nil one
		// must not panic and must resolve to the default.
		job := JobSpec{Kind: "hetzner"}
		got := resolveRestoreBase(job)
		if got.Region != def.Region || got.ServerType != def.ServerType {
			t.Fatalf("nil bundle ref must fall to the default; got %+v, want %+v", got, def)
		}
	})
}

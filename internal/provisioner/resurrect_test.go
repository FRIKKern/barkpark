package provisioner

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/FRIKKern/barkpark/internal/cli/cloud"
)

// restoreRunner is the recording StepRunner + StdinStepRunner the resurrect
// round-trip drives instead of shelling out. Run records each configure/freshen
// step; RunFeed records the restore-data script AND drains its stdin so the test
// asserts BOTH the on-box script bytes and that a real bundle stream was piped in.
// It does NOT implement sshReadyWaiter, so CreateHost's readiness wait is skipped.
type restoreRunner struct {
	mu       sync.Mutex
	steps    []string // recorded step titles
	feedCmd  string   // the RunFeed script
	feedByte []byte   // the drained stdin (the bundle tar)
}

func (r *restoreRunner) Run(_ context.Context, s cloud.CaddyStep) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.steps = append(r.steps, s.Title)
	return nil
}

func (r *restoreRunner) RunFeed(_ context.Context, title, script string, stdin io.Reader) (string, error) {
	b, _ := io.ReadAll(stdin)
	r.mu.Lock()
	defer r.mu.Unlock()
	r.feedCmd = script
	r.feedByte = b
	return "BP_RESTORE_OK\n", nil
}

var _ cloud.StepRunner = (*restoreRunner)(nil)
var _ cloud.StdinStepRunner = (*restoreRunner)(nil)

// writeTestBundle seals a real bp-bundle-v1 into a fake store under kek and returns
// the store + the bundle prefix (bundle_ref). The db.dump/media bytes are arbitrary
// (the recording runner never executes them); the identity secrets are sealed for
// real, so InstallSecrets exercises the CARRIED-KEK unseal end to end.
func writeTestBundle(t *testing.T, kek, fqdn, dbName string) (*cloud.FakeBundleStore, string) {
	t.Helper()
	t.Setenv("BARKPARK_BUNDLE_KEK", kek) // WriteBundle reads this to seal secrets.enc
	store := cloud.NewFakeBundleStore()
	man, err := cloud.WriteBundle(context.Background(), store, cloud.BundleWriteSpec{
		FQDN:           fqdn,
		Slug:           "acme",
		TeamID:         "team-1",
		SourceProvider: "hetzner",
		DBName:         dbName,
		// A real archive-time shape hint — the source box's region + server_type — so
		// the resurrect round-trips it (charter D49). Deliberately NOT the warm-pool
		// default (cloud.DefaultSpec hetzner = nbg1/cx23) so a test asserting the hint
		// was consumed can tell it apart from the provider default.
		Spec: cloud.BundleSpec{Region: "hel1", ServerType: "cx33"},
		DB:             strings.NewReader("PGDMP-fake-custom-format-dump"),
		Media:          strings.NewReader("fake-media-tar-bytes"),
		Secrets: map[string]string{
			"SECRET_KEY_BASE":       strings.Repeat("A", 64),
			"BARKPARK_CLOAK_KEY":    "Y2xvYWtrZXl2YWx1ZQ==",
			"PREVIEW_JWT_SECRET":    "cHJldmlld3NlY3JldA==",
			"BARKPARK_INGEST_TOKEN": "aW5nZXN0dG9rZW4=",
			"BARKPARK_KEK":          "a2VrdmFsdWU=",
		},
	})
	if err != nil {
		t.Fatalf("WriteBundle: %v", err)
	}
	return store, man.Prefix()
}

// resurrectCP is a minimal control plane for the resurrect drain: it serves ONE
// resurrect claim (then 204) and records the succeed/fail report on the reused
// provision-jobs endpoints (a resurrect rides the same job machine, S14c).
type resurrectCP struct {
	mu          sync.Mutex
	claim       map[string]any // served once on resurrect-jobs/claim
	claimCount  int
	succeededIP string
	succeedCall int
	failedError string
	failCall    int
}

func (c *resurrectCP) handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/v1/internal/resurrect-jobs/claim", func(w http.ResponseWriter, _ *http.Request) {
		c.mu.Lock()
		defer c.mu.Unlock()
		c.claimCount++
		if c.claim == nil {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		_ = json.NewEncoder(w).Encode(c.claim)
		c.claim = nil
	})
	mux.HandleFunc("/v1/internal/provision-jobs/", func(w http.ResponseWriter, r *http.Request) {
		c.mu.Lock()
		defer c.mu.Unlock()
		_, verb := parseJobPath(r.URL.Path)
		var body struct {
			IP    string `json:"ip"`
			Error string `json:"error"`
		}
		raw, _ := io.ReadAll(r.Body)
		_ = json.Unmarshal(raw, &body)
		switch verb {
		case "succeed":
			c.succeedCall++
			c.succeededIP = body.IP
			_ = json.NewEncoder(w).Encode(map[string]bool{"ok": true})
		case "fail":
			c.failCall++
			c.failedError = body.Error
			_ = json.NewEncoder(w).Encode(map[string]bool{"ok": true})
		default:
			http.Error(w, "not found", http.StatusNotFound)
		}
	})
	return mux
}

// TestResurrectDrainRoundTripFiresEndToEnd is the S14f gate: a real resurrect claim
// (bundle_ref STRING) drains through decode → translate (FakeBundleStore preloaded
// with a real WriteBundle output under a test KEK) → the REAL CloudRestoreDriver
// over a recording runner → a live succeed report. It asserts the on-box restore
// script bytes AND that a bundle stream was piped in — proving the chain FIRES, not
// a hand-built JobSpec.
func TestResurrectDrainRoundTripFiresEndToEnd(t *testing.T) {
	const (
		kek    = "test-bundle-kek-value"
		fqdn   = "acme.barkpark.cloud"
		dbName = "barkpark_prod"
	)
	store, prefix := writeTestBundle(t, kek, fqdn, dbName)

	prov := cloud.NewFakeProvider()
	dns := cloud.NewFakeDNS()
	runner := &restoreRunner{}
	inst := newFakeInstance(t, fakeInstanceBehavior{}) // all-green golden path for Verify

	driver := &CloudRestoreDriver{
		Exec: &cloud.RestoreExecutor{
			Provider:   prov,
			DNS:        dns,
			RunnerFor:  func(string) cloud.StepRunner { return runner },
			Store:      store,
			ControlURL: "https://cp.example",
		},
		VerifyBaseURL:      inst.URL,
		VerifyProbeTimeout: 2 * time.Second,
		VerifyTotalBudget:  5 * time.Second,
	}
	seams := Seams{Restore: driver}

	cp := &resurrectCP{claim: map[string]any{
		"job_id":      "rj-1",
		"name":        "Acme Co",
		"slug":        "acme",
		"region":      "nbg1",
		"server_type": "cax11",
		"agent_token": "agent-token-xyz",
		"bundle_ref":  prefix, // the STRING prefix — D43 decode fact
	}}
	srv := httptest.NewServer(cp.handler())
	defer srv.Close()

	w := &Worker{
		ControlURL: srv.URL,
		Token:      "worker-tok",
		HTTPClient: srv.Client(),
		Provision:  DefaultProvision(seams),
		Resurrect: func() (ResurrectDeps, error) {
			return ResurrectDeps{Store: store, Bucket: "test-bucket", KEK: kek}, nil
		},
		ReportRetryBackoff: time.Millisecond,
	}

	claimed, err := w.RunOnceResurrect(context.Background())
	if err != nil {
		t.Fatalf("RunOnceResurrect: %v", err)
	}
	if !claimed {
		t.Fatal("expected the resurrect job to be claimed + handled")
	}

	// The box was cold-created (exactly one) + reported to /succeed.
	servers, _ := prov.List(context.Background())
	if len(servers) != 1 {
		t.Fatalf("want exactly 1 created box, got %d", len(servers))
	}
	if cp.succeedCall != 1 {
		t.Fatalf("want 1 succeed report, got %d (fail=%d: %q)", cp.succeedCall, cp.failCall, cp.failedError)
	}
	if cp.succeededIP != servers[0].IP {
		t.Fatalf("succeed reported ip %q, want the created box's %q", cp.succeededIP, servers[0].IP)
	}

	// The box got its fqdn identity label (so a later Remove can find it).
	if got := servers[0].Labels[cloud.FQDNLabelKey]; got != fqdn {
		t.Fatalf("box %s label = %q, want the fqdn %q", cloud.FQDNLabelKey, got, fqdn)
	}

	// The A-record was repointed at the fresh box.
	vals, _ := dns.Resolve(context.Background(), fqdn)
	if len(vals) != 1 || vals[0] != servers[0].IP {
		t.Fatalf("dns for %s = %v, want [%s]", fqdn, vals, servers[0].IP)
	}

	// The on-box restore script carries the load-bearing bytes (the instImportScript
	// inverse), and a real bundle tar was piped into it.
	for _, want := range []string{"DROP DATABASE", "createdb", "pg_restore --no-owner", "uploads", "mix ecto.migrate", dbName} {
		if !strings.Contains(runner.feedCmd, want) {
			t.Fatalf("restore script missing %q; got:\n%s", want, runner.feedCmd)
		}
	}
	assertGzipTarHasMember(t, runner.feedByte, "db.dump")

	// The identity + agent steps ran (the CARRIED-KEK unseal + beat install).
	joined := strings.Join(runner.steps, " | ")
	if !strings.Contains(joined, "identity") {
		t.Fatalf("expected the sealed-identity install step to run; steps: %s", joined)
	}
	if !strings.Contains(joined, "agent") {
		t.Fatalf("expected the agent install step to run (job carried a token); steps: %s", joined)
	}
}

// TestResurrectMissingBundleEnvFailsJobHonestly proves D43's honesty contract: when
// the bundle store env is not configured, the CLAIMED job fails honestly (/fail,
// with actionable copy) and NO box is created — the drain survives.
func TestResurrectMissingBundleEnvFailsJobHonestly(t *testing.T) {
	// Hermetic: a developer machine carrying real S3 creds must not flip this test
	// onto the configured path (and toward a live object store).
	for _, v := range []string{"HETZNER_S3_ACCESS_KEY", "HETZNER_S3_SECRET_KEY", "BARKPARK_BUNDLE_BUCKET", "BARKPARK_BUNDLE_KEK"} {
		t.Setenv(v, "")
	}
	prov := cloud.NewFakeProvider()
	seams := Seams{Restore: &CloudRestoreDriver{Exec: &cloud.RestoreExecutor{Provider: prov, DNS: cloud.NewFakeDNS(), RunnerFor: func(string) cloud.StepRunner { return &restoreRunner{} }}}}

	cp := &resurrectCP{claim: map[string]any{
		"job_id":     "rj-2",
		"name":       "Acme",
		"slug":       "acme",
		"bundle_ref": "archives/team-1/acme.barkpark.cloud/20200101T000000Z/",
	}}
	srv := httptest.NewServer(cp.handler())
	defer srv.Close()

	w := &Worker{
		ControlURL: srv.URL,
		Token:      "worker-tok",
		HTTPClient: srv.Client(),
		Provision:  DefaultProvision(seams),
		// The env resolver errors (no HETZNER_S3_* / bucket / KEK set).
		Resurrect:          ResolveBundleEnv,
		ReportRetryBackoff: time.Millisecond,
	}

	claimed, err := w.RunOnceResurrect(context.Background())
	if err != nil {
		t.Fatalf("RunOnceResurrect: %v", err)
	}
	if !claimed {
		t.Fatal("a translate failure is still a cleanly-handled (failed) cycle")
	}
	if cp.failCall != 1 {
		t.Fatalf("want 1 fail report, got %d", cp.failCall)
	}
	if !strings.Contains(cp.failedError, "bundle store") {
		t.Fatalf("fail error should name the missing bundle store env; got %q", cp.failedError)
	}
	if servers, _ := prov.List(context.Background()); len(servers) != 0 {
		t.Fatalf("no box may be created when the bundle env is missing; got %d", len(servers))
	}
}

// TestResurrectMidChainFailureTearsDownTheBox proves the money edge: a restore
// that fails AFTER the cold create (here: configure — the carried KEK does not
// match the bundle, so the unseal fails GCM) must tear the half-restored box back
// down. Without it the box is billed, carries no orphan label (SweepOrphans is
// blind to it), and the control plane never learned it exists.
func TestResurrectMidChainFailureTearsDownTheBox(t *testing.T) {
	store, prefix := writeTestBundle(t, "the-real-kek", "acme.barkpark.cloud", "barkpark_prod")

	prov := cloud.NewFakeProvider()
	dns := cloud.NewFakeDNS()
	runner := &restoreRunner{}
	driver := &CloudRestoreDriver{
		Exec: &cloud.RestoreExecutor{
			Provider:  prov,
			DNS:       dns,
			RunnerFor: func(string) cloud.StepRunner { return runner },
			Store:     store,
		},
	}
	seams := Seams{Restore: driver}

	cp := &resurrectCP{claim: map[string]any{
		"job_id":     "rj-4",
		"name":       "Acme Co",
		"slug":       "acme",
		"bundle_ref": prefix,
	}}
	srv := httptest.NewServer(cp.handler())
	defer srv.Close()

	w := &Worker{
		ControlURL: srv.URL,
		Token:      "worker-tok",
		HTTPClient: srv.Client(),
		Provision:  DefaultProvision(seams),
		Resurrect: func() (ResurrectDeps, error) {
			// A WRONG carried KEK: create/freshen/secure succeed, configure fails GCM.
			return ResurrectDeps{Store: store, Bucket: "test-bucket", KEK: "wrong-kek"}, nil
		},
		ReportRetryBackoff: time.Millisecond,
	}

	claimed, err := w.RunOnceResurrect(context.Background())
	if err != nil {
		t.Fatalf("RunOnceResurrect: %v", err)
	}
	if !claimed {
		t.Fatal("a mid-chain failure is still a cleanly-handled (failed) cycle")
	}
	if cp.failCall != 1 {
		t.Fatalf("want 1 fail report, got %d (succeed=%d)", cp.failCall, cp.succeedCall)
	}
	if servers, _ := prov.List(context.Background()); len(servers) != 0 {
		t.Fatalf("the half-restored box must be torn down (no unlabeled billed orphan); got %d boxes", len(servers))
	}
}

// TestTranslateResurrectMapsManifestFieldByField proves the D43/D44 mapping: the
// STRING bundle_ref + worker-env KEK become a *BundleRef whose manifest is mapped
// field-by-field, with MediaPaths/SchemaVersion left zero (no archive-time shape
// change) and the KEK sourced from deps (never the claim).
func TestTranslateResurrectMapsManifestFieldByField(t *testing.T) {
	const kek = "carried-kek"
	store, prefix := writeTestBundle(t, kek, "shop.barkpark.cloud", "barkpark_prod")
	deps := ResurrectDeps{Store: store, Bucket: "bkt", KEK: kek}

	spec := resurrectClaimSpec{JobID: "rj-3", Name: "Shop", Slug: "shop", BundleRef: prefix}
	job, err := translateResurrect(context.Background(), spec, deps)
	if err != nil {
		t.Fatalf("translateResurrect: %v", err)
	}
	if job.BundleRef == nil {
		t.Fatal("translate must produce a *BundleRef")
	}
	if job.BundleRef.KEK != kek {
		t.Fatalf("KEK = %q, want the worker-env deps KEK %q (never the claim)", job.BundleRef.KEK, kek)
	}
	if job.BundleRef.Key != prefix {
		t.Fatalf("Key = %q, want the prefix %q", job.BundleRef.Key, prefix)
	}
	m := job.BundleRef.Manifest
	if m.Fqdn != "shop.barkpark.cloud" || m.DBName != "barkpark_prod" || m.SourceProvider != "hetzner" {
		t.Fatalf("manifest mismapped: %+v", m)
	}
	if m.MediaPaths != nil || m.SchemaVersion != 0 {
		t.Fatalf("MediaPaths/SchemaVersion must stay zero (D44); got media=%v schema=%d", m.MediaPaths, m.SchemaVersion)
	}
	if m.ArchivedAt == "" {
		t.Fatal("ArchivedAt should map from the manifest CreatedAt")
	}
	// The archive-time shape hint survives the translate boundary (charter D49) —
	// previously it was dropped here (the whole point of w8).
	if m.Spec.Region != "hel1" || m.Spec.ServerType != "cx33" {
		t.Fatalf("Spec hint must carry through translate; got %+v, want {hel1 cx33}", m.Spec)
	}
}

// assertGzipTarHasMember decodes the fed stdin as a gzip tar and asserts a member.
func assertGzipTarHasMember(t *testing.T, b []byte, member string) {
	t.Helper()
	gz, err := gzip.NewReader(bytes.NewReader(b))
	if err != nil {
		t.Fatalf("fed stdin is not gzip: %v", err)
	}
	tr := tar.NewReader(gz)
	for {
		h, err := tr.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			t.Fatalf("read fed tar: %v", err)
		}
		if h.Name == member {
			return
		}
	}
	t.Fatalf("fed bundle tar has no %q member", member)
}

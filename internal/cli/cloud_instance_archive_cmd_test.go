package cli

// cloud_instance_archive_cmd_test.go proves the S14b portable-archive surface
// fully OFFLINE: the neutral archive writes a bp-bundle-v1 for fake AND for the
// azure/hetzner ssh-collected path (the ssh runner is faked), the store
// credential gate errors loud when unset, --fast is hetzner-only, and the
// archives list renders the stored manifests. The store is S14a's canonical
// cloud.NewFakeBundleStore; sealing rides cloud.WriteBundle for real (the
// wrong-key/authentication proofs live in the bundle library's own tests).
// Zero live cloud/S3/ssh calls.

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/cli/cloud"
)

// ── shared test doubles ──────────────────────────────────────────────────────

// withFakeBundleStore swaps the store provider for the in-memory canonical fake
// and pins the bundle KEK (WriteBundle refuses to seal without one).
func withFakeBundleStore(t *testing.T) *cloud.FakeBundleStore {
	t.Helper()
	st := cloud.NewFakeBundleStore()
	old := bundleStoreProvider
	bundleStoreProvider = func(*writer) (cloud.BundleStore, bool) { return st, true }
	t.Setenv("BARKPARK_BUNDLE_KEK", "test-bundle-kek")
	t.Cleanup(func() { bundleStoreProvider = old })
	return st
}

// bundleManifestKeys lists every stored manifest key, sorted (the store's List
// is deterministic).
func bundleManifestKeys(t *testing.T, st *cloud.FakeBundleStore) []string {
	t.Helper()
	keys, err := st.List(context.Background(), "archives/")
	if err != nil {
		t.Fatalf("list store: %v", err)
	}
	var out []string
	for _, k := range keys {
		if strings.HasSuffix(k, "/manifest.json") {
			out = append(out, k)
		}
	}
	return out
}

// storeObject reads one raw object out of the fake store.
func storeObject(t *testing.T, st *cloud.FakeBundleStore, key string) []byte {
	t.Helper()
	rc, err := st.Get(context.Background(), key)
	if err != nil {
		t.Fatalf("get %s: %v", key, err)
	}
	defer rc.Close()
	b, err := io.ReadAll(rc)
	if err != nil {
		t.Fatalf("read %s: %v", key, err)
	}
	return b
}

// withFakeRemoteStream swaps the ssh collection pipe for one that emits canned
// bytes — the "ssh-runner-faked" path (the box's real dump is not needed to prove
// the writer stores what the script produced).
func withFakeRemoteStream(t *testing.T, tarGz []byte) {
	t.Helper()
	old := bundleRemoteStream
	bundleRemoteStream = func(_, _ string, w io.Writer) error {
		_, err := w.Write(tarGz)
		return err
	}
	t.Cleanup(func() { bundleRemoteStream = old })
}

// cannedBundleTar builds a gzipped tar of db.dump / media.tar.gz / secrets.env,
// the exact members bundleArchiveScript streams, so untarBundle round-trips it.
func cannedBundleTar(t *testing.T) []byte {
	t.Helper()
	var buf bytes.Buffer
	gz := gzip.NewWriter(&buf)
	tw := tar.NewWriter(gz)
	for _, m := range []struct{ name, body string }{
		{"db.dump", "PGDUMP-BYTES"},
		{"media.tar.gz", "MEDIA-BYTES"},
		{"secrets.env", "SECRET_KEY_BASE=x\nBARKPARK_KEK=kek-material\nBARKPARK_KEK_PREVIOUS=\n"},
	} {
		if err := tw.WriteHeader(&tar.Header{Name: m.name, Mode: 0o600, Size: int64(len(m.body))}); err != nil {
			t.Fatalf("tar header: %v", err)
		}
		if _, err := tw.Write([]byte(m.body)); err != nil {
			t.Fatalf("tar write: %v", err)
		}
	}
	if err := tw.Close(); err != nil {
		t.Fatalf("tar close: %v", err)
	}
	if err := gz.Close(); err != nil {
		t.Fatalf("gz close: %v", err)
	}
	return buf.Bytes()
}

// ── azure ssh-collected bundle (offline) ─────────────────────────────────────

// TestNeutralArchiveAzureBundleSSHPath proves azure now archives via the portable
// bundle: the box is resolved through the (faked) azure provider, its bytes come
// over the (faked) ssh runner, and a bp-bundle-v1 lands in the store with the
// identity secrets SEALED (D36: never plaintext at rest). No live ARM, S3 or ssh.
func TestNeutralArchiveAzureBundleSSHPath(t *testing.T) {
	st := withFakeBundleStore(t)
	withFakeRemoteStream(t, cannedBundleTar(t))

	azFake := cloud.NewFakeProvider()
	if _, err := azFake.Create(context.Background(), cloud.ServerSpec{Name: "web-1"}); err != nil {
		t.Fatalf("seed vm: %v", err)
	}
	old := azureProviderBuilder
	azureProviderBuilder = func(map[string]string) (cloud.CloudProvider, error) { return azFake, nil }
	t.Cleanup(func() { azureProviderBuilder = old })

	stdout, stderr, code := runInstanceCapture(t, "json", "archive", "--provider", "azure", "web-1")
	if code != exitOK {
		t.Fatalf("azure bundle archive exit=%d stderr=%s stdout=%s", code, stderr, stdout)
	}
	keys := bundleManifestKeys(t, st)
	if len(keys) != 1 {
		t.Fatalf("azure archive should land one bp-bundle-v1 manifest, got %v", keys)
	}
	if !strings.Contains(keys[0], "web-1.barkpark.cloud") {
		t.Errorf("manifest key missing the fqdn: %s", keys[0])
	}
	// The stored manifest is a real bp-bundle-v1 tagged to azure.
	prefix := strings.TrimSuffix(keys[0], "manifest.json")
	man, err := cloud.ReadManifest(context.Background(), st, prefix)
	if err != nil {
		t.Fatalf("read manifest: %v", err)
	}
	if man.Format != "bp-bundle-v1" || man.SourceProvider != "azure" {
		t.Errorf("manifest not a bp-bundle-v1/azure: %+v", man)
	}
	// The collected db.dump is what the ssh runner emitted.
	if db := storeObject(t, st, prefix+"db.dump"); string(db) != "PGDUMP-BYTES" {
		t.Errorf("db.dump not the collected bytes: %q", db)
	}
	// secrets are SEALED at rest (no plaintext), and unseal to the D36-filtered
	// identity set: SECRET_KEY_BASE + BARKPARK_KEK carried; the EMPTY
	// BARKPARK_KEK_PREVIOUS line is dropped (when-set only).
	raw := storeObject(t, st, prefix+"secrets.enc")
	if bytes.Contains(raw, []byte("SECRET_KEY_BASE")) || bytes.Contains(raw, []byte("kek-material")) {
		t.Errorf("secrets.enc stored PLAINTEXT — the bundle must seal identity secrets: %q", raw)
	}
	secrets, err := cloud.OpenSecrets(context.Background(), st, prefix)
	if err != nil {
		t.Fatalf("unseal secrets: %v", err)
	}
	if secrets["SECRET_KEY_BASE"] != "x" || secrets["BARKPARK_KEK"] != "kek-material" {
		t.Errorf("unsealed secrets missing identity keys: %v", secrets)
	}
	if _, has := secrets["BARKPARK_KEK_PREVIOUS"]; has {
		t.Errorf("empty BARKPARK_KEK_PREVIOUS must be dropped (when-set only): %v", secrets)
	}
}

// TestNeutralArchiveHetznerStampsSpecHints proves the hetzner portable archive
// records the box's resurrection SPEC HINTS ({region, server_type}) read off the
// live hcloud server, so a later resurrect can re-shape its target. The box is
// resolved through the (faked) hcloud API — which returns location=fsn1,
// server_type=cx23 — its bytes come over the (faked) ssh runner, and the written
// manifest carries those hints. No live cloud, S3 or ssh.
func TestNeutralArchiveHetznerStampsSpecHints(t *testing.T) {
	st := withFakeBundleStore(t)
	withFakeRemoteStream(t, cannedBundleTar(t))

	f := newFakeHzAPI(t)
	f.mux.HandleFunc("GET /servers", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Query().Get("name") != "" {
			hzWriteJSON(w, 200, `{"servers":[]}`)
			return
		}
		hzWriteJSON(w, 200, `{"servers":[`+instServerJSON(9, "bp-okey-1", "192.0.2.9", "okey.barkpark.cloud")+`]}`)
	})

	stdout, stderr, code := runInstanceCapture(t, "json", "archive", "--provider", "hetzner", "okey.barkpark.cloud")
	if code != exitOK {
		t.Fatalf("hetzner bundle archive exit=%d stderr=%s stdout=%s", code, stderr, stdout)
	}
	keys := bundleManifestKeys(t, st)
	if len(keys) != 1 {
		t.Fatalf("hetzner archive should land one bp-bundle-v1 manifest, got %v", keys)
	}
	prefix := strings.TrimSuffix(keys[0], "manifest.json")
	man, err := cloud.ReadManifest(context.Background(), st, prefix)
	if err != nil {
		t.Fatalf("read manifest: %v", err)
	}
	if man.SourceProvider != "hetzner" {
		t.Errorf("manifest not tagged hetzner: %+v", man)
	}
	// The load-bearing assertion: the shape hints are stamped from the live box.
	if man.Spec.Region != "fsn1" {
		t.Errorf("spec.region = %q, want fsn1 (read off the hcloud server's location)", man.Spec.Region)
	}
	if man.Spec.ServerType != "cx23" {
		t.Errorf("spec.server_type = %q, want cx23 (read off the hcloud server's server_type)", man.Spec.ServerType)
	}
}

// TestNeutralArchiveEmptySpecHintsTolerated proves a bundle written with NO shape
// hints (every pre-existing bundle, and the azure/fake providers that carry no
// hints) still writes, lists and reads back cleanly — empty hints are legitimate,
// never a failure (charter Decision 12).
func TestNeutralArchiveEmptySpecHintsTolerated(t *testing.T) {
	st := withFakeBundleStore(t)

	_, stderr, code := runInstanceCapture(t, "json", "archive", "--provider", "fake", "web-1")
	if code != exitOK {
		t.Fatalf("fake archive exit=%d stderr=%s", code, stderr)
	}
	keys := bundleManifestKeys(t, st)
	if len(keys) != 1 {
		t.Fatalf("fake archive should land one manifest, got %v", keys)
	}
	prefix := strings.TrimSuffix(keys[0], "manifest.json")
	man, err := cloud.ReadManifest(context.Background(), st, prefix)
	if err != nil {
		t.Fatalf("read manifest (empty-spec bundle must still read): %v", err)
	}
	if man.Spec.Region != "" || man.Spec.ServerType != "" {
		t.Errorf("fake provider carries no shape hints, want empty spec, got %+v", man.Spec)
	}
	// The empty-spec bundle still lists.
	stdout, _, code := runInstanceCapture(t, "json", "archives")
	if code != exitOK {
		t.Fatalf("archives list over an empty-spec bundle exit=%d", code)
	}
	if !strings.Contains(stdout, "web-1.barkpark.cloud") {
		t.Errorf("empty-spec bundle must still appear in the list:\n%s", stdout)
	}
}

// TestNeutralArchiveFastIsHetznerOnly proves --fast is refused on non-hetzner
// providers with an honest usage error (no snapshot substrate elsewhere).
func TestNeutralArchiveFastIsHetznerOnly(t *testing.T) {
	_, stderr, code := runInstanceCapture(t, "table", "archive", "--provider", "azure", "--fast", "web-1")
	if code != exitUsage {
		t.Fatalf("azure --fast should be a usage error (exit %d), got %d\n%s", exitUsage, code, stderr)
	}
	if !strings.Contains(stderr, "--fast") || !strings.Contains(stderr, "snapshot") {
		t.Errorf("--fast refusal should explain it is a hetzner snapshot optimization:\n%s", stderr)
	}
}

// TestNeutralArchiveMissingStoreIsLoud proves the Console-gate: with no S3
// credentials / bucket set, the archive fails AUTH with copy naming the human
// step, before any collection happens.
func TestNeutralArchiveMissingStoreIsLoud(t *testing.T) {
	t.Setenv("HETZNER_S3_ACCESS_KEY", "")
	t.Setenv("HETZNER_S3_SECRET_KEY", "")
	t.Setenv("BARKPARK_BUNDLE_BUCKET", "")

	_, stderr, code := runInstanceCapture(t, "table", "archive", "--provider", "fake", "web-1")
	if code != exitAuth {
		t.Fatalf("missing store should exit %d (auth), got %d\n%s", exitAuth, code, stderr)
	}
	for _, want := range []string{"BARKPARK_BUNDLE_BUCKET", "Object Storage", "Console"} {
		if !strings.Contains(stderr, want) {
			t.Errorf("store-gate error missing %q:\n%s", want, stderr)
		}
	}
}

// TestNeutralArchiveMissingKEKIsLoud proves the seal-key gate: a configured
// store but no BARKPARK_BUNDLE_KEK fails AUTH naming the env var, before any
// collection happens.
func TestNeutralArchiveMissingKEKIsLoud(t *testing.T) {
	st := cloud.NewFakeBundleStore()
	old := bundleStoreProvider
	bundleStoreProvider = func(*writer) (cloud.BundleStore, bool) { return st, true }
	t.Cleanup(func() { bundleStoreProvider = old })
	t.Setenv("BARKPARK_BUNDLE_KEK", "")

	_, stderr, code := runInstanceCapture(t, "table", "archive", "--provider", "fake", "web-1")
	if code != exitAuth {
		t.Fatalf("missing KEK should exit %d (auth), got %d\n%s", exitAuth, code, stderr)
	}
	if !strings.Contains(stderr, "BARKPARK_BUNDLE_KEK") {
		t.Errorf("KEK-gate error should name the env var:\n%s", stderr)
	}
	if keys := bundleManifestKeys(t, st); len(keys) != 0 {
		t.Errorf("no bundle may be written without the seal key, got %v", keys)
	}
}

// ── the archives list ────────────────────────────────────────────────────────

// TestInstanceArchivesList archives two fake boxes and proves the list renders
// them (json + table), newest-first, with the provider as SOURCE.
func TestInstanceArchivesList(t *testing.T) {
	st := withFakeBundleStore(t)
	for _, name := range []string{"web-1", "web-2"} {
		_, stderr, code := runInstanceCapture(t, "json", "archive", "--provider", "fake", name)
		if code != exitOK {
			t.Fatalf("seed archive %s exit=%d stderr=%s", name, code, stderr)
		}
	}
	if len(bundleManifestKeys(t, st)) != 2 {
		t.Fatalf("expected two seeded manifests, got %v", bundleManifestKeys(t, st))
	}

	stdout, stderr, code := runInstanceCapture(t, "json", "archives")
	if code != exitOK {
		t.Fatalf("archives list exit=%d stderr=%s stdout=%s", code, stderr, stdout)
	}
	var env struct {
		Archives []struct {
			FQDN     string `json:"fqdn"`
			Provider string `json:"provider"`
			Bundle   string `json:"bundle"`
		} `json:"archives"`
	}
	if err := json.Unmarshal([]byte(stdout), &env); err != nil {
		t.Fatalf("archives not JSON: %v: %s", err, stdout)
	}
	if len(env.Archives) != 2 {
		t.Fatalf("want two archives, got %d: %s", len(env.Archives), stdout)
	}
	seen := map[string]bool{}
	for _, a := range env.Archives {
		if a.Provider != "fake" {
			t.Errorf("archive SOURCE should be the tagging provider: %+v", a)
		}
		if !strings.HasPrefix(a.Bundle, "archives/") {
			t.Errorf("archive bundle prefix malformed: %+v", a)
		}
		seen[a.FQDN] = true
	}
	if !seen["web-1.barkpark.cloud"] || !seen["web-2.barkpark.cloud"] {
		t.Errorf("both fqdns should be listed: %v", seen)
	}

	// Table mode carries the pinned columns.
	stdout, _, code = runInstanceCapture(t, "table", "archives")
	if code != exitOK {
		t.Fatalf("archives table exit=%d", code)
	}
	for _, want := range []string{"FQDN", "SOURCE", "CREATED", "BUNDLE", "web-1.barkpark.cloud"} {
		if !strings.Contains(stdout, want) {
			t.Errorf("archives table missing %q:\n%s", want, stdout)
		}
	}

	// A provider filter that matches nothing renders the empty-state line.
	stdout, _, code = runInstanceCapture(t, "table", "archives", "--provider", "azure")
	if code != exitOK {
		t.Fatalf("filtered archives exit=%d", code)
	}
	if !strings.Contains(stdout, "no portable archives") {
		t.Errorf("empty filter should show the empty-state line:\n%s", stdout)
	}
}

// ── the collection script ────────────────────────────────────────────────────

// TestBundleArchiveScriptShape pins the corrected secret set: the script collects
// db.dump / media.tar.gz / secrets.env and stages ONLY the identity secrets —
// the D36 set INCLUDING BARKPARK_KEK (+ BARKPARK_KEK_PREVIOUS when set) — it
// does NOT copy the whole .env the way the transfer export did.
func TestBundleArchiveScriptShape(t *testing.T) {
	s := bundleArchiveScript("okey.barkpark.cloud")
	for _, want := range []string{"pg_dump", "db.dump", "media.tar.gz", "secrets.env", "SECRET_KEY_BASE", "BARKPARK_CLOAK_KEY", "PREVIEW_JWT_SECRET", "BARKPARK_INGEST_TOKEN", "BARKPARK_KEK", "BARKPARK_KEK_PREVIOUS"} {
		if !strings.Contains(s, want) {
			t.Errorf("archive script missing %q:\n%s", want, s)
		}
	}
	if strings.Contains(s, `cp /opt/barkpark/.env`) {
		t.Errorf("archive script must NOT copy the whole .env (corrected secret set — seal identity keys only):\n%s", s)
	}
}

// TestParseEnvSecretsD36 pins the CLI-side filter: collected lines project down
// to EXACTLY the D36 identity set — foreign keys are dropped, BARKPARK_KEK rides
// along, and an empty BARKPARK_KEK_PREVIOUS is omitted.
func TestParseEnvSecretsD36(t *testing.T) {
	got := parseEnvSecrets([]byte("SECRET_KEY_BASE=a\nDATABASE_URL=postgres://nope\nBARKPARK_KEK=k\nBARKPARK_KEK_PREVIOUS=\n# comment\n"))
	if got["SECRET_KEY_BASE"] != "a" || got["BARKPARK_KEK"] != "k" {
		t.Errorf("identity keys must survive: %v", got)
	}
	if _, has := got["DATABASE_URL"]; has {
		t.Errorf("non-identity keys must be dropped (a resurrected box keeps its own): %v", got)
	}
	if _, has := got["BARKPARK_KEK_PREVIOUS"]; has {
		t.Errorf("empty BARKPARK_KEK_PREVIOUS must be omitted: %v", got)
	}
}

// ── --stop is fast-only, and says so ─────────────────────────────────────────

// TestNeutralArchiveStopWithoutFastIsLoud is the regression for the silent
// accept: `--stop` was registered in runNeutralArchive's bool list (so
// parseHzArgs' `unknown flag` arm never fired) and then read NOWHERE on the
// portable path — `bp cloud instance archive x --stop` exited 0 having quiesced
// nothing, while the operator believed the writers were stopped. The portable
// bundle does not need a quiesce (pg_dump --format=custom is MVCC-consistent by
// construction), so the honest answer is a usage error, not a no-op.
func TestNeutralArchiveStopWithoutFastIsLoud(t *testing.T) {
	withFakeBundleStore(t)
	_, stderr, code := runInstanceCapture(t, "table", "archive", "--provider", "fake", "--stop", "web-1")
	if code != exitUsage {
		t.Fatalf("--stop without --fast should be a usage error (exit %d), got %d\n%s", exitUsage, code, stderr)
	}
	for _, want := range []string{"--stop", "--fast"} {
		if !strings.Contains(stderr, want) {
			t.Errorf("--stop refusal should name %q:\n%s", want, stderr)
		}
	}
}

// TestNeutralArchiveStopIsAdvertised proves the flag is no longer swallowed
// SILENTLY *and* undocumented: the usage line the refusal quotes names --stop
// and the --fast it depends on, so a reader learns the real availability from
// the error itself.
func TestNeutralArchiveStopIsAdvertised(t *testing.T) {
	withFakeBundleStore(t)
	_, stderr, _ := runInstanceCapture(t, "table", "archive", "--provider", "fake", "--stop", "web-1")
	if !strings.Contains(stderr, "[--fast [--stop]]") {
		t.Errorf("usage should advertise --stop as a --fast-only flag:\n%s", stderr)
	}
}

// TestNeutralArchiveFastStopStillForwards proves the registration was NOT
// simply deleted: `--fast --stop` on hetzner is a legitimate combination — line
// 201's stripFlag removes only --fast, so --stop reaches runInstanceArchive,
// which passes a.bools["stop"] into instArchive. The guard must not fire here.
// The run still fails LATER (no hetzner credential in a test), and that is the
// point: the failure must not be the new usage refusal.
func TestNeutralArchiveFastStopStillForwards(t *testing.T) {
	withFakeBundleStore(t)
	t.Setenv("HCLOUD_TOKEN", "")
	t.Setenv("HETZNER_API_TOKEN", "")
	_, stderr, code := runInstanceCapture(t, "table", "archive", "--provider", "hetzner", "--fast", "--stop", "web-1")
	if code == exitUsage && strings.Contains(stderr, "--stop needs --fast") {
		t.Fatalf("--fast --stop is a working combination and must not be refused:\n%s", stderr)
	}
}

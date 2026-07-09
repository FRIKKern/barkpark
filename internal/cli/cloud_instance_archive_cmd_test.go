package cli

// cloud_instance_archive_cmd_test.go proves the S14b portable-archive surface
// fully OFFLINE: the neutral archive writes a bp-bundle-v1 for fake AND for the
// azure/hetzner ssh-collected path (the ssh runner is faked), the store
// credential gate errors loud when unset, --fast is hetzner-only, and the
// archives list renders the stored manifests. Zero live cloud/S3/ssh calls.

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"context"
	"encoding/json"
	"io"
	"sort"
	"strings"
	"sync"
	"testing"

	"github.com/FRIKKern/barkpark/internal/cli/cloud"
)

// ── shared test doubles ──────────────────────────────────────────────────────

// fakeBundleStore is an in-memory BundleStore (S14a's substrate faked) so the
// full write path is exercised without object storage.
type fakeBundleStore struct {
	mu   sync.Mutex
	objs map[string][]byte
}

func newFakeBundleStore() *fakeBundleStore { return &fakeBundleStore{objs: map[string][]byte{}} }

func (f *fakeBundleStore) Put(_ context.Context, key string, body io.Reader) error {
	b, err := io.ReadAll(body)
	if err != nil {
		return err
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	f.objs[key] = b
	return nil
}

func (f *fakeBundleStore) List(_ context.Context, prefix string) ([]bundleObject, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	var out []bundleObject
	for k, v := range f.objs {
		if strings.HasPrefix(k, prefix) {
			out = append(out, bundleObject{Key: k, Size: int64(len(v))})
		}
	}
	return out, nil
}

func (f *fakeBundleStore) Get(_ context.Context, key string) ([]byte, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	b, ok := f.objs[key]
	if !ok {
		return nil, io.EOF
	}
	return b, nil
}

func (f *fakeBundleStore) manifestKeys() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	var keys []string
	for k := range f.objs {
		if strings.HasSuffix(k, "/manifest.json") {
			keys = append(keys, k)
		}
	}
	sort.Strings(keys)
	return keys
}

// withFakeBundleStore swaps the store provider for an in-memory one for the test.
func withFakeBundleStore(t *testing.T) *fakeBundleStore {
	t.Helper()
	st := newFakeBundleStore()
	old := bundleStoreProvider
	bundleStoreProvider = func(*writer) (bundleStore, bool) { return st, true }
	t.Cleanup(func() { bundleStoreProvider = old })
	return st
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

// cannedBundleTar builds a gzipped tar of db.dump / media.tar.gz / secrets.enc,
// the exact members bundleArchiveScript streams, so untarBundle round-trips it.
func cannedBundleTar(t *testing.T) []byte {
	t.Helper()
	var buf bytes.Buffer
	gz := gzip.NewWriter(&buf)
	tw := tar.NewWriter(gz)
	for _, m := range []struct{ name, body string }{
		{"db.dump", "PGDUMP-BYTES"},
		{"media.tar.gz", "MEDIA-BYTES"},
		{"secrets.enc", "SECRET_KEY_BASE=x\n"},
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
// over the (faked) ssh runner, and a bp-bundle-v1 lands in the store. No live ARM,
// S3 or ssh.
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
	keys := st.manifestKeys()
	if len(keys) != 1 {
		t.Fatalf("azure archive should land one bp-bundle-v1 manifest, got %v", keys)
	}
	if !strings.Contains(keys[0], "web-1.barkpark.cloud") {
		t.Errorf("manifest key missing the fqdn: %s", keys[0])
	}
	// The stored manifest is a real bp-bundle-v1 tagged to azure.
	raw, err := st.Get(context.Background(), keys[0])
	if err != nil {
		t.Fatalf("read manifest: %v", err)
	}
	var man bundleManifest
	if err := json.Unmarshal(raw, &man); err != nil {
		t.Fatalf("manifest not JSON: %v: %s", err, raw)
	}
	if man.Format != "bp-bundle-v1" || man.Provider != "azure" {
		t.Errorf("manifest not a bp-bundle-v1/azure: %+v", man)
	}
	// The collected db.dump is what the ssh runner emitted.
	dbKey := strings.TrimSuffix(keys[0], "manifest.json") + "db.dump"
	db, err := st.Get(context.Background(), dbKey)
	if err != nil || string(db) != "PGDUMP-BYTES" {
		t.Errorf("db.dump not the collected bytes: %q (err=%v)", db, err)
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
	if len(st.manifestKeys()) != 2 {
		t.Fatalf("expected two seeded manifests, got %v", st.manifestKeys())
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
// db.dump / media.tar.gz / secrets.enc and seals ONLY the identity secrets — it
// does NOT copy the whole .env the way the transfer export did.
func TestBundleArchiveScriptShape(t *testing.T) {
	s := bundleArchiveScript("okey.barkpark.cloud")
	for _, want := range []string{"pg_dump", "db.dump", "media.tar.gz", "secrets.enc", "SECRET_KEY_BASE", "BARKPARK_CLOAK_KEY", "PREVIEW_JWT_SECRET", "BARKPARK_INGEST_TOKEN"} {
		if !strings.Contains(s, want) {
			t.Errorf("archive script missing %q:\n%s", want, s)
		}
	}
	if strings.Contains(s, `cp /opt/barkpark/.env`) {
		t.Errorf("archive script must NOT copy the whole .env (corrected secret set — seal identity keys only):\n%s", s)
	}
}

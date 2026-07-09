package cloud

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"strings"
	"testing"
	"time"
)

// withBundleKEK sets a deterministic bundle key for the test's lifetime.
func withBundleKEK(t *testing.T, kek string) {
	t.Helper()
	t.Setenv(bundleKEKEnv, kek)
}

// TestWriteBundleRoundTrip proves a bundle written through the fake store reads
// back byte-faithfully: the manifest carries the pinned shape, the four members
// land under the stamped prefix with manifest LAST, and db/media/secrets round-
// trip (secrets through the KEK envelope).
func TestWriteBundleRoundTrip(t *testing.T) {
	withBundleKEK(t, "unit-test-kek")
	store := NewFakeBundleStore()
	ctx := context.Background()

	dbBytes := []byte("PGDMP fake custom dump bytes")
	mediaBytes := []byte("fake media tarball")
	secrets := map[string]string{
		"BARKPARK_CLOAK_KEY": "cloak-abc",
		"BARKPARK_KEK":       "kek-xyz",
	}
	at := time.Date(2026, 7, 9, 12, 0, 0, 0, time.UTC)

	man, err := WriteBundle(ctx, store, BundleWriteSpec{
		FQDN:           "acme-12.barkpark.cloud",
		Slug:           "acme-12",
		TeamID:         "team_7",
		SourceProvider: ProviderHetzner,
		DBName:         "barkpark_prod",
		Spec:           BundleSpec{Region: "nbg1", ServerType: "cx23"},
		CreatedAt:      at,
		DB:             bytes.NewReader(dbBytes),
		Media:          bytes.NewReader(mediaBytes),
		Secrets:        secrets,
	})
	if err != nil {
		t.Fatalf("WriteBundle: %v", err)
	}

	// Manifest shape.
	if man.Format != BundleFormat {
		t.Errorf("format=%q want %q", man.Format, BundleFormat)
	}
	if man.SecretsCipher != bundleCipher {
		t.Errorf("secrets_cipher=%q want %q", man.SecretsCipher, bundleCipher)
	}
	if man.TeamID != "team_7" || man.SourceProvider != ProviderHetzner || man.Spec.ServerType != "cx23" {
		t.Errorf("manifest fields wrong: %+v", man)
	}
	if man.Objects != (BundleObjects{DB: "db.dump", Media: "media.tar.gz", Secrets: "secrets.enc"}) {
		t.Fatalf("objects directory drifted from the pinned filename map: %+v", man.Objects)
	}

	// Prefix + member set + manifest LAST.
	wantPrefix := "archives/team_7/acme-12.barkpark.cloud/20260709T120000Z/"
	keys, err := store.List(ctx, wantPrefix)
	if err != nil {
		t.Fatalf("List: %v", err)
	}
	for i := range keys {
		keys[i] = strings.TrimPrefix(keys[i], wantPrefix)
	}
	got := strings.Join(keys, ",")
	if want := "db.dump,manifest.json,media.tar.gz,secrets.enc"; got != want {
		t.Errorf("member set = %q want %q", got, want)
	}

	// Reader path: newest, manifest, db/media, secrets.
	ref, ok, err := NewestBundle(ctx, store, "team_7", "acme-12.barkpark.cloud")
	if err != nil || !ok {
		t.Fatalf("NewestBundle ok=%v err=%v", ok, err)
	}
	if ref.Prefix != wantPrefix {
		t.Errorf("newest prefix=%q want %q", ref.Prefix, wantPrefix)
	}

	rman, err := ReadManifest(ctx, store, ref.Prefix)
	if err != nil {
		t.Fatalf("ReadManifest: %v", err)
	}
	if rman.FQDN != "acme-12.barkpark.cloud" {
		t.Errorf("read manifest fqdn=%q", rman.FQDN)
	}

	if got := readMember(t, ctx, store, ref.Prefix, bundleDBName); got != string(dbBytes) {
		t.Errorf("db.dump=%q want %q", got, dbBytes)
	}
	if got := readMember(t, ctx, store, ref.Prefix, bundleMediaName); got != string(mediaBytes) {
		t.Errorf("media=%q want %q", got, mediaBytes)
	}

	rsec, err := OpenSecrets(ctx, store, ref.Prefix)
	if err != nil {
		t.Fatalf("OpenSecrets: %v", err)
	}
	if rsec["BARKPARK_CLOAK_KEY"] != "cloak-abc" || rsec["BARKPARK_KEK"] != "kek-xyz" {
		t.Errorf("secrets round-trip wrong: %+v", rsec)
	}
}

func readMember(t *testing.T, ctx context.Context, store BundleStore, prefix, name string) string {
	t.Helper()
	rc, err := OpenObject(ctx, store, prefix, name)
	if err != nil {
		t.Fatalf("OpenObject %s: %v", name, err)
	}
	defer rc.Close()
	b, _ := io.ReadAll(rc)
	return string(b)
}

// TestWriteBundleNilMediaEmptyArchive: a box with no media still gets a
// media.tar.gz member (empty), so the member set is uniform for every bundle.
func TestWriteBundleNilMediaEmptyArchive(t *testing.T) {
	withBundleKEK(t, "k")
	store := NewFakeBundleStore()
	ctx := context.Background()
	man, err := WriteBundle(ctx, store, BundleWriteSpec{
		FQDN: "x.barkpark.cloud",
		DB:   strings.NewReader("dump"),
		// Media nil.
	})
	if err != nil {
		t.Fatalf("WriteBundle: %v", err)
	}
	if man.Objects.Media != bundleMediaName {
		t.Fatalf("media member missing from manifest: %+v", man.Objects)
	}
	prefix := "archives/_/x.barkpark.cloud/" + man.CreatedAt.Format(bundleStampFmt) + "/"
	if got := readMember(t, ctx, store, prefix, bundleMediaName); got != "" {
		t.Errorf("nil media should write an EMPTY media.tar.gz, got %q", got)
	}
}

// TestBundleManifestPinnedBytes locks the exact serialized manifest shape S14b/
// c/d/e build against: the objects filename map, spec always carrying region +
// server_type, and secrets_cipher.
func TestBundleManifestPinnedBytes(t *testing.T) {
	withBundleKEK(t, "k")
	store := NewFakeBundleStore()
	man, err := WriteBundle(context.Background(), store, BundleWriteSpec{
		FQDN: "p.barkpark.cloud", Slug: "p", SourceProvider: ProviderFake,
		CreatedAt: time.Date(2026, 7, 9, 8, 0, 0, 0, time.UTC),
		DB:        strings.NewReader("d"),
	})
	if err != nil {
		t.Fatalf("WriteBundle: %v", err)
	}
	b, _ := json.Marshal(man)
	want := `{"format":"bp-bundle-v1","fqdn":"p.barkpark.cloud","slug":"p","team_id":"","source_provider":"fake","created_at":"2026-07-09T08:00:00Z","db_name":"barkpark_prod","spec":{"region":"","server_type":""},"objects":{"db":"db.dump","media":"media.tar.gz","secrets":"secrets.enc"},"secrets_cipher":"aes-256-gcm"}`
	if string(b) != want {
		t.Errorf("manifest bytes drifted from the pinned shape:\n got: %s\nwant: %s", b, want)
	}
}

// TestBundleNewestFirst: with several bundles for one instance, ListBundles
// returns them newest→oldest and NewestBundle picks the latest stamp.
func TestBundleNewestFirst(t *testing.T) {
	withBundleKEK(t, "k")
	store := NewFakeBundleStore()
	ctx := context.Background()
	stamps := []time.Time{
		time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC),
		time.Date(2026, 7, 9, 9, 0, 0, 0, time.UTC),
		time.Date(2026, 3, 15, 6, 30, 0, 0, time.UTC),
	}
	for _, at := range stamps {
		if _, err := WriteBundle(ctx, store, BundleWriteSpec{
			FQDN: "box.barkpark.cloud", TeamID: "t1", CreatedAt: at, DB: strings.NewReader("d"),
		}); err != nil {
			t.Fatalf("WriteBundle @%v: %v", at, err)
		}
	}
	refs, err := ListBundles(ctx, store, "t1", "box.barkpark.cloud")
	if err != nil {
		t.Fatalf("ListBundles: %v", err)
	}
	if len(refs) != 3 {
		t.Fatalf("want 3 bundles, got %d", len(refs))
	}
	if !refs[0].CreatedAt.Equal(stamps[1]) || !refs[2].CreatedAt.Equal(stamps[0]) {
		t.Errorf("not newest-first: %v", []time.Time{refs[0].CreatedAt, refs[1].CreatedAt, refs[2].CreatedAt})
	}
	newest, ok, _ := NewestBundle(ctx, store, "t1", "box.barkpark.cloud")
	if !ok || !newest.CreatedAt.Equal(stamps[1]) {
		t.Errorf("NewestBundle = %v ok=%v want %v", newest.CreatedAt, ok, stamps[1])
	}
}

// TestBundleTornUploadSkipped: a prefix with members but NO manifest.json (the
// upload died before the last write) is invisible to the reader — the manifest-
// present completeness fence.
func TestBundleTornUploadSkipped(t *testing.T) {
	withBundleKEK(t, "k")
	store := NewFakeBundleStore()
	ctx := context.Background()
	// One complete bundle.
	if _, err := WriteBundle(ctx, store, BundleWriteSpec{
		FQDN: "b.barkpark.cloud", CreatedAt: time.Date(2026, 2, 2, 0, 0, 0, 0, time.UTC), DB: strings.NewReader("d"),
	}); err != nil {
		t.Fatalf("WriteBundle: %v", err)
	}
	// A torn one: db.dump only, no manifest, at a LATER stamp.
	torn := "archives/_/b.barkpark.cloud/20260909T000000Z/"
	if err := store.PutLarge(ctx, torn+bundleDBName, strings.NewReader("half")); err != nil {
		t.Fatalf("seed torn: %v", err)
	}
	refs, err := ListBundles(ctx, store, "", "b.barkpark.cloud")
	if err != nil {
		t.Fatalf("ListBundles: %v", err)
	}
	if len(refs) != 1 {
		t.Fatalf("torn upload must be skipped; want 1 complete bundle, got %d: %+v", len(refs), refs)
	}
	if strings.Contains(refs[0].Prefix, "20260909") {
		t.Errorf("reader picked the torn bundle: %s", refs[0].Prefix)
	}
}

// TestBundleWrongKEKFailsAuth: secrets sealed under one key MUST NOT decrypt
// under another — GCM authentication fails, no garbage plaintext.
func TestBundleWrongKEKFailsAuth(t *testing.T) {
	store := NewFakeBundleStore()
	ctx := context.Background()

	withBundleKEK(t, "right-key")
	man, err := WriteBundle(ctx, store, BundleWriteSpec{
		FQDN: "s.barkpark.cloud", DB: strings.NewReader("d"),
		Secrets: map[string]string{"BARKPARK_KEK": "top-secret"},
	})
	if err != nil {
		t.Fatalf("WriteBundle: %v", err)
	}
	prefix := "archives/_/s.barkpark.cloud/" + man.CreatedAt.Format(bundleStampFmt) + "/"

	// Right key opens.
	if _, err := OpenSecrets(ctx, store, prefix); err != nil {
		t.Fatalf("right key should open: %v", err)
	}
	// Wrong key fails auth.
	withBundleKEK(t, "wrong-key")
	if _, err := OpenSecrets(ctx, store, prefix); err == nil {
		t.Fatal("wrong KEK must fail authentication, but OpenSecrets succeeded")
	} else if !strings.Contains(err.Error(), "authentication") {
		t.Errorf("want an authentication error, got: %v", err)
	}
}

// TestBundleKEKRequired: writing or reading a bundle without BARKPARK_BUNDLE_KEK
// is a loud error, never a silent unencrypted write.
func TestBundleKEKRequired(t *testing.T) {
	t.Setenv(bundleKEKEnv, "")
	store := NewFakeBundleStore()
	if _, err := WriteBundle(context.Background(), store, BundleWriteSpec{FQDN: "x", DB: strings.NewReader("d")}); err == nil {
		t.Fatal("WriteBundle without a KEK must error")
	} else if !strings.Contains(err.Error(), bundleKEKEnv) {
		t.Errorf("error should name %s: %v", bundleKEKEnv, err)
	}
}

// TestSelectIdentitySecrets_D36: the bundle identity set INCLUDES BARKPARK_KEK
// (the export set omits it) and carries BARKPARK_KEK_PREVIOUS only when set.
func TestSelectIdentitySecrets_D36(t *testing.T) {
	env := map[string]string{
		"SECRET_KEY_BASE":       "skb",
		"BARKPARK_CLOAK_KEY":    "cloak",
		"PREVIEW_JWT_SECRET":    "jwt",
		"BARKPARK_INGEST_TOKEN": "ingest",
		"BARKPARK_KEK":          "kek",
		"UNRELATED":             "leak-me-not",
	}
	got := SelectIdentitySecrets(env)
	if got["BARKPARK_KEK"] != "kek" {
		t.Error("D36: bundle identity set MUST include BARKPARK_KEK")
	}
	if _, ok := got["UNRELATED"]; ok {
		t.Error("unrelated env leaked into the identity set")
	}
	if _, ok := got["BARKPARK_KEK_PREVIOUS"]; ok {
		t.Error("KEK_PREVIOUS must be absent when unset")
	}

	// When set (and non-empty), previous KEK rides along; empty is dropped.
	env["BARKPARK_KEK_PREVIOUS"] = "old-kek"
	if SelectIdentitySecrets(env)["BARKPARK_KEK_PREVIOUS"] != "old-kek" {
		t.Error("KEK_PREVIOUS must be carried when set")
	}
	env["BARKPARK_KEK_PREVIOUS"] = ""
	if _, ok := SelectIdentitySecrets(env)["BARKPARK_KEK_PREVIOUS"]; ok {
		t.Error("an empty KEK_PREVIOUS must be dropped, not shipped blank")
	}
}

// TestFakeProviderArchiveRecordsAndResurrects: the stateful fake records an
// archive box-agnostically (no live server needed) and Resurrect rebuilds from
// the newest; an fqdn with no archive is an honest not-found.
func TestFakeProviderArchiveRecordsAndResurrects(t *testing.T) {
	f := NewFakeProvider()
	ctx := context.Background()

	// Resurrect with nothing on record → not-found.
	if _, err := f.Resurrect(ctx, "ghost.barkpark.cloud"); err == nil {
		t.Fatal("resurrect with no archive must be a not-found error")
	}

	// Archive is box-agnostic: no Create first.
	a, err := f.Archive(ctx, "web-1")
	if err != nil {
		t.Fatalf("Archive: %v", err)
	}
	if a.ID != "fake-archive-web-1" || a.Provider != ProviderFake {
		t.Errorf("archive receipt wrong: %+v", a)
	}

	// Now resurrect boots a fresh box under the fqdn.
	srv, err := f.Resurrect(ctx, "web-1")
	if err != nil {
		t.Fatalf("Resurrect after archive: %v", err)
	}
	if srv.Name != "web-1" {
		t.Errorf("resurrected server name=%q", srv.Name)
	}

	// Empty target still guarded.
	if _, err := f.Archive(ctx, ""); err == nil {
		t.Error("empty archive target must error")
	}
}

// TestFakeBundleStoreSeam exercises the in-memory store directly: put/get,
// prefix list ordering, not-found, and idempotent delete.
func TestFakeBundleStoreSeam(t *testing.T) {
	s := NewFakeBundleStore()
	ctx := context.Background()

	if err := s.PutLarge(ctx, "a/2", strings.NewReader("two")); err != nil {
		t.Fatalf("put: %v", err)
	}
	if err := s.PutLarge(ctx, "a/1", strings.NewReader("one")); err != nil {
		t.Fatalf("put: %v", err)
	}
	if err := s.PutLarge(ctx, "b/1", strings.NewReader("other")); err != nil {
		t.Fatalf("put: %v", err)
	}

	rc, err := s.Get(ctx, "a/1")
	if err != nil {
		t.Fatalf("get: %v", err)
	}
	b, _ := io.ReadAll(rc)
	rc.Close()
	if string(b) != "one" {
		t.Errorf("get a/1 = %q", b)
	}

	keys, err := s.List(ctx, "a/")
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	if len(keys) != 2 || keys[0] != "a/1" || keys[1] != "a/2" {
		t.Errorf("prefix list wrong/unsorted: %+v", keys)
	}

	if _, err := s.Get(ctx, "missing"); err == nil {
		t.Error("get missing must be not-found")
	}

	if err := s.Delete(ctx, "a/1"); err != nil {
		t.Fatalf("delete: %v", err)
	}
	if err := s.Delete(ctx, "a/1"); err != nil {
		t.Errorf("delete is idempotent; second delete errored: %v", err)
	}
	if _, err := s.Get(ctx, "a/1"); err == nil {
		t.Error("deleted object still readable")
	}
}

// TestReadManifestRejectsForeignFormat: a manifest with the wrong format tag is
// refused, mirroring bp-export-v1's import guard.
func TestReadManifestRejectsForeignFormat(t *testing.T) {
	s := NewFakeBundleStore()
	ctx := context.Background()
	bad, _ := json.Marshal(BundleManifest{Format: "bp-export-v1", FQDN: "x"})
	prefix := "archives/_/x/20260101T000000Z/"
	if err := s.PutLarge(ctx, prefix+bundleManifestName, bytes.NewReader(bad)); err != nil {
		t.Fatalf("seed: %v", err)
	}
	if _, err := ReadManifest(ctx, s, prefix); err == nil {
		t.Fatal("a foreign format tag must be refused")
	} else if !strings.Contains(err.Error(), BundleFormat) {
		t.Errorf("error should name the expected format: %v", err)
	}
}

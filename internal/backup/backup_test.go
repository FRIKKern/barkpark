package backup

// backup_test.go proves the executor's whole contract against in-memory fakes
// — no Postgres, no S3, no network. The assertions are byte-level (gunzip the
// stored object and compare to the ORIGINAL dump bytes; recompute the sha256)
// so a pipeline that mangles, truncates or double-gzips data fails loudly.

import (
	"bytes"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math/rand"
	"reflect"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/FRIKKern/barkpark/internal/hetzner/objstore"
)

// fakeObjStore is the in-memory ObjStore: bucket → key → bytes, plus a log of
// which method stored each key so the multipart-vs-single path is observable.
type fakeObjStore struct {
	objects  map[string]map[string][]byte // bucket → key → content
	modified map[string]time.Time         // "bucket/key" → LastModified
	putVia   map[string]string            // key → "PutObject" | "PutLarge"
	deletes  []string                     // keys DeleteObject saw, in order
}

func newFakeObjStore() *fakeObjStore {
	return &fakeObjStore{
		objects:  map[string]map[string][]byte{},
		modified: map[string]time.Time{},
		putVia:   map[string]string{},
	}
}

func (f *fakeObjStore) store(bucket, key string, b []byte) {
	if f.objects[bucket] == nil {
		f.objects[bucket] = map[string][]byte{}
	}
	f.objects[bucket][key] = b
}

func (f *fakeObjStore) PutObject(ctx context.Context, bucket, key string, body io.Reader) error {
	b, err := io.ReadAll(body)
	if err != nil {
		return err
	}
	f.store(bucket, key, b)
	f.putVia[key] = "PutObject"
	return nil
}

func (f *fakeObjStore) PutLarge(ctx context.Context, bucket, key string, body io.Reader) error {
	b, err := io.ReadAll(body)
	if err != nil {
		return err // a failed pipe aborts the "multipart" upload: nothing stored
	}
	f.store(bucket, key, b)
	f.putVia[key] = "PutLarge"
	return nil
}

func (f *fakeObjStore) GetObject(ctx context.Context, bucket, key string) (io.ReadCloser, error) {
	b, ok := f.objects[bucket][key]
	if !ok {
		return nil, fmt.Errorf("fake: %s/%s not found", bucket, key)
	}
	return io.NopCloser(bytes.NewReader(b)), nil
}

func (f *fakeObjStore) ListObjects(ctx context.Context, bucket, prefix string) ([]objstore.Object, error) {
	var out []objstore.Object
	for key, b := range f.objects[bucket] {
		if !strings.HasPrefix(key, prefix) {
			continue
		}
		out = append(out, objstore.Object{Key: key, Size: int64(len(b)), LastModified: f.modified[bucket+"/"+key]})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Key < out[j].Key })
	return out, nil
}

func (f *fakeObjStore) DeleteObject(ctx context.Context, bucket, key string) error {
	delete(f.objects[bucket], key) // S3 DELETE is idempotent — absent keys succeed
	f.deletes = append(f.deletes, key)
	return nil
}

// fakeDumpSource streams fixed bytes; closeErr simulates a producer (pg_dump)
// that exits dirty AFTER its stream ended.
type fakeDumpSource struct {
	name     string
	data     []byte
	closeErr error
}

func (s *fakeDumpSource) Database() string { return s.name }
func (s *fakeDumpSource) Open(ctx context.Context) (io.ReadCloser, error) {
	return &errCloser{Reader: bytes.NewReader(s.data), err: s.closeErr}, nil
}

type errCloser struct {
	io.Reader
	err error
}

func (e *errCloser) Close() error { return e.err }

// fakeSink records exactly the bytes Restore streamed into it.
type fakeSink struct {
	got []byte
}

func (s *fakeSink) Restore(ctx context.Context, r io.Reader) error {
	b, err := io.ReadAll(r)
	s.got = b
	return err
}

// pinNow pins the package clock and restores it after the test.
func pinNow(t *testing.T, at time.Time) {
	t.Helper()
	old := nowFunc
	nowFunc = func() time.Time { return at }
	t.Cleanup(func() { nowFunc = old })
}

func gunzip(t *testing.T, b []byte) []byte {
	t.Helper()
	gzr, err := gzip.NewReader(bytes.NewReader(b))
	if err != nil {
		t.Fatalf("stored object is not gzip: %v", err)
	}
	out, err := io.ReadAll(gzr)
	if err != nil {
		t.Fatalf("gunzip: %v", err)
	}
	if err := gzr.Close(); err != nil {
		t.Fatalf("gzip close: %v", err)
	}
	return out
}

// TestBackupRoundTrip: Backup gzips, uploads via the MULTIPART method, writes
// a truthful manifest and returns the key — all verified byte-for-byte.
func TestBackupRoundTrip(t *testing.T) {
	at := time.Date(2026, 7, 1, 3, 15, 0, 0, time.UTC)
	pinNow(t, at)
	dump := []byte("CREATE TABLE dogs (id serial);\nINSERT INTO dogs DEFAULT VALUES;\n")
	store := newFakeObjStore()

	key, err := Backup(context.Background(), &fakeDumpSource{name: "barkpark", data: dump}, store, "bk", "prod")
	if err != nil {
		t.Fatalf("Backup: %v", err)
	}
	// The key is prod/<ns-stamp>-<randhex>.sql.gz — the stamp is fixed by the
	// pinned clock, the random suffix is not, so match the shape, not a literal.
	if wantPrefix := "prod/20260701T031500.000000000Z-"; !strings.HasPrefix(key, wantPrefix) || !strings.HasSuffix(key, ".sql.gz") {
		t.Fatalf("Backup key = %q, want %q<randhex>.sql.gz", key, wantPrefix)
	}
	stored, ok := store.objects["bk"][key]
	if !ok {
		t.Fatalf("no object stored at bk/%s; stored: %v", key, store.putVia)
	}
	if store.putVia[key] != "PutLarge" {
		t.Errorf("dump stored via %s, want the multipart PutLarge path", store.putVia[key])
	}
	if got := gunzip(t, stored); !bytes.Equal(got, dump) {
		t.Errorf("gunzip(stored) = %q, want the original dump %q", got, dump)
	}

	manRaw, ok := store.objects["bk"][key+".manifest.json"]
	if !ok {
		t.Fatal("no manifest stored alongside the dump")
	}
	var man Manifest
	if err := json.Unmarshal(manRaw, &man); err != nil {
		t.Fatalf("manifest is not JSON: %v\n%s", err, manRaw)
	}
	sum := sha256.Sum256(dump)
	if man.Database != "barkpark" || man.Bytes != int64(len(dump)) ||
		man.SHA256 != hex.EncodeToString(sum[:]) || !man.CreatedAt.Equal(at) {
		t.Errorf("manifest = %+v, want database=barkpark bytes=%d sha256=%s created_at=%s",
			man, len(dump), hex.EncodeToString(sum[:]), at)
	}
}

// TestBackupLargeMultipart pushes >5 MB of incompressible bytes through the
// pipeline — the stream never fits one gzip flush, so this exercises the
// chunked pipe → PutLarge path with byte-exact verification.
func TestBackupLargeMultipart(t *testing.T) {
	pinNow(t, time.Date(2026, 7, 1, 4, 0, 0, 0, time.UTC))
	dump := make([]byte, 6<<20) // 6 MiB, incompressible so the gzip stays >5 MB
	rnd := rand.New(rand.NewSource(42))
	if _, err := rnd.Read(dump); err != nil {
		t.Fatal(err)
	}
	store := newFakeObjStore()

	key, err := Backup(context.Background(), &fakeDumpSource{name: "big", data: dump}, store, "bk", "")
	if err != nil {
		t.Fatalf("Backup: %v", err)
	}
	if strings.HasPrefix(key, "/") || !strings.HasPrefix(key, "20260701T040000.000000000Z-") || !strings.HasSuffix(key, ".sql.gz") {
		t.Fatalf("empty prefix key = %q, want <ns-stamp>-<randhex>.sql.gz with no leading slash", key)
	}
	stored := store.objects["bk"][key]
	if int64(len(stored)) <= 5<<20 {
		t.Fatalf("stored gzip is %d bytes; want >5MB so the multipart claim is real", len(stored))
	}
	if store.putVia[key] != "PutLarge" {
		t.Errorf("large dump stored via %s, want PutLarge", store.putVia[key])
	}
	if got := gunzip(t, stored); !bytes.Equal(got, dump) {
		t.Errorf("large round-trip mismatch: got %d bytes, want %d identical bytes", len(got), len(dump))
	}
	var man Manifest
	if err := json.Unmarshal(store.objects["bk"][key+".manifest.json"], &man); err != nil {
		t.Fatalf("manifest: %v", err)
	}
	if man.Bytes != int64(len(dump)) {
		t.Errorf("manifest bytes = %d, want the uncompressed %d", man.Bytes, len(dump))
	}
}

// TestBackupDirtySourceClose: a producer that exits dirty after a clean EOF
// (pg_dump killed mid-dump) must FAIL the backup and write no manifest.
func TestBackupDirtySourceClose(t *testing.T) {
	pinNow(t, time.Date(2026, 7, 1, 5, 0, 0, 0, time.UTC))
	store := newFakeObjStore()
	src := &fakeDumpSource{name: "db", data: []byte("partial"), closeErr: errors.New("pg_dump: exit status 1")}

	_, err := Backup(context.Background(), src, store, "bk", "p")
	if err == nil || !strings.Contains(err.Error(), "exit status 1") {
		t.Fatalf("Backup with a dirty source close = %v, want the pg_dump error", err)
	}
	for key := range store.objects["bk"] {
		if strings.HasSuffix(key, ".manifest.json") {
			t.Errorf("a manifest %q was written for a FAILED backup", key)
		}
	}
}

// TestBackupSameInstantNoClobber: two Backups at the IDENTICAL wall-clock
// instant (pinned clock) must produce DISTINCT keys, so the second dump can
// never silently overwrite the first dump or its manifest. Both dumps and both
// manifests must survive and list as two separate backups.
func TestBackupSameInstantNoClobber(t *testing.T) {
	pinNow(t, time.Date(2026, 7, 1, 7, 0, 0, 0, time.UTC))
	store := newFakeObjStore()

	key1, err := Backup(context.Background(), &fakeDumpSource{name: "db", data: []byte("first")}, store, "bk", "prod")
	if err != nil {
		t.Fatalf("Backup #1: %v", err)
	}
	key2, err := Backup(context.Background(), &fakeDumpSource{name: "db", data: []byte("second")}, store, "bk", "prod")
	if err != nil {
		t.Fatalf("Backup #2: %v", err)
	}
	if key1 == key2 {
		t.Fatalf("two same-instant Backups returned the identical key %q — the second clobbered the first", key1)
	}

	// Both dumps and both manifests must coexist.
	for _, k := range []string{key1, key2} {
		if _, ok := store.objects["bk"][k]; !ok {
			t.Errorf("dump %s is missing — it was overwritten", k)
		}
		if _, ok := store.objects["bk"][k+".manifest.json"]; !ok {
			t.Errorf("manifest %s.manifest.json is missing — it was overwritten", k)
		}
	}

	infos, err := List(context.Background(), store, "bk", "prod")
	if err != nil {
		t.Fatalf("List: %v", err)
	}
	if len(infos) != 2 {
		t.Fatalf("List returned %d backups, want 2 distinct dumps taken in the same instant", len(infos))
	}
}

// TestRestoreRoundTrip: what Backup wrote, Restore streams back — the exact
// original bytes, through a fake sink.
func TestRestoreRoundTrip(t *testing.T) {
	pinNow(t, time.Date(2026, 7, 1, 6, 0, 0, 0, time.UTC))
	dump := []byte("SELECT 'hello barkpark';\n-- the exact bytes matter\n")
	store := newFakeObjStore()
	key, err := Backup(context.Background(), &fakeDumpSource{name: "db", data: dump}, store, "bk", "prod")
	if err != nil {
		t.Fatalf("Backup: %v", err)
	}

	sink := &fakeSink{}
	rep, err := Restore(context.Background(), store, "bk", key, sink)
	if err != nil {
		t.Fatalf("Restore: %v", err)
	}
	if !bytes.Equal(sink.got, dump) {
		t.Errorf("Restore streamed %q, want the original dump %q", sink.got, dump)
	}
	if !rep.Verified() {
		t.Errorf("a dump restored straight from Backup reported %q (%s), want %q",
			rep.Verification, rep.Reason, RestoreVerified)
	}
	if rep.Bytes != int64(len(dump)) {
		t.Errorf("report counted %d bytes, want %d", rep.Bytes, len(dump))
	}

	// A key that is not gzip must fail loudly, not restore garbage.
	store.store("bk", "prod/garbage.sql.gz", []byte("not gzip at all"))
	if _, err := Restore(context.Background(), store, "bk", "prod/garbage.sql.gz", &fakeSink{}); err == nil {
		t.Error("Restore of a non-gzip object did not error")
	}
}

// TestList parses keys + manifests newest-first, keeps manifest-less dumps
// visible, and ignores non-backup keys.
func TestList(t *testing.T) {
	store := newFakeObjStore()
	mk := func(stamp, db string, dump []byte) string {
		pinNow(t, mustTime(t, stamp))
		key, err := Backup(context.Background(), &fakeDumpSource{name: db, data: dump}, store, "bk", "prod")
		if err != nil {
			t.Fatalf("Backup(%s): %v", stamp, err)
		}
		return key
	}
	oldKey := mk("2026-06-01T00:00:00Z", "barkpark", []byte("old"))
	newKey := mk("2026-07-01T00:00:00Z", "barkpark", []byte("newer"))
	// A hand-uploaded dump without a manifest, dated by LastModified.
	store.store("bk", "prod/manual.sql.gz", gzipBytes(t, []byte("manual")))
	store.modified["bk/prod/manual.sql.gz"] = mustTime(t, "2026-06-15T00:00:00Z")
	// Noise that must not list.
	store.store("bk", "prod/readme.txt", []byte("not a backup"))

	infos, err := List(context.Background(), store, "bk", "prod")
	if err != nil {
		t.Fatalf("List: %v", err)
	}
	gotKeys := make([]string, len(infos))
	for i, in := range infos {
		gotKeys[i] = in.Key
	}
	wantKeys := []string{newKey, "prod/manual.sql.gz", oldKey}
	if !reflect.DeepEqual(gotKeys, wantKeys) {
		t.Fatalf("List keys = %v, want newest-first %v", gotKeys, wantKeys)
	}
	if infos[0].Database != "barkpark" || infos[0].Bytes != int64(len("newer")) || infos[0].SHA256 == "" {
		t.Errorf("newest info = %+v, want manifest fields filled", infos[0])
	}
	if infos[1].Database != "" || !infos[1].CreatedAt.Equal(mustTime(t, "2026-06-15T00:00:00Z")) {
		t.Errorf("manifest-less info = %+v, want empty database and the LastModified date", infos[1])
	}
}

// TestPruneKeep keeps the N newest and deletes the rest — dumps AND manifests.
func TestPruneKeep(t *testing.T) {
	store := newFakeObjStore()
	stamps := []string{"2026-06-01T00:00:00Z", "2026-06-10T00:00:00Z", "2026-06-20T00:00:00Z", "2026-07-01T00:00:00Z"}
	keys := make([]string, len(stamps))
	for i, s := range stamps {
		pinNow(t, mustTime(t, s))
		k, err := Backup(context.Background(), &fakeDumpSource{name: "db", data: []byte(s)}, store, "bk", "prod")
		if err != nil {
			t.Fatalf("Backup(%s): %v", s, err)
		}
		keys[i] = k
	}

	deleted, err := Prune(context.Background(), store, "bk", "prod", PrunePolicy{Keep: 2})
	if err != nil {
		t.Fatalf("Prune: %v", err)
	}
	// keys[3] and keys[2] are the two newest → keys[1] then keys[0] go.
	if want := []string{keys[1], keys[0]}; !reflect.DeepEqual(deleted, want) {
		t.Fatalf("Prune deleted %v, want %v", deleted, want)
	}
	for _, k := range []string{keys[2], keys[3]} {
		if _, ok := store.objects["bk"][k]; !ok {
			t.Errorf("kept backup %s is gone", k)
		}
		if _, ok := store.objects["bk"][k+".manifest.json"]; !ok {
			t.Errorf("kept manifest %s.manifest.json is gone", k)
		}
	}
	for _, k := range deleted {
		if _, ok := store.objects["bk"][k]; ok {
			t.Errorf("pruned backup %s still exists", k)
		}
		if _, ok := store.objects["bk"][k+".manifest.json"]; ok {
			t.Errorf("pruned manifest %s.manifest.json still exists", k)
		}
	}

	// Keep larger than the population deletes nothing.
	deleted, err = Prune(context.Background(), store, "bk", "prod", PrunePolicy{Keep: 10})
	if err != nil || len(deleted) != 0 {
		t.Errorf("Prune keep=10 = (%v, %v), want no deletions", deleted, err)
	}
}

// TestPruneOlderThan deletes exactly the set older than the window, judged
// against the pinned clock.
func TestPruneOlderThan(t *testing.T) {
	store := newFakeObjStore()
	mk := func(stamp string) string {
		pinNow(t, mustTime(t, stamp))
		k, err := Backup(context.Background(), &fakeDumpSource{name: "db", data: []byte(stamp)}, store, "bk", "")
		if err != nil {
			t.Fatalf("Backup(%s): %v", stamp, err)
		}
		return k
	}
	ancient := mk("2026-05-01T00:00:00Z") // 61 days before "now"
	old := mk("2026-05-30T00:00:00Z")     // 32 days
	fresh := mk("2026-06-20T00:00:00Z")   // 11 days

	pinNow(t, mustTime(t, "2026-07-01T00:00:00Z"))
	deleted, err := Prune(context.Background(), store, "bk", "", PrunePolicy{OlderThan: 30 * 24 * time.Hour})
	if err != nil {
		t.Fatalf("Prune: %v", err)
	}
	if want := []string{old, ancient}; !reflect.DeepEqual(deleted, want) {
		t.Fatalf("Prune deleted %v, want the >30d set %v (newest first)", deleted, want)
	}
	if _, ok := store.objects["bk"][fresh]; !ok {
		t.Errorf("the 11-day-old backup %s was wrongly deleted", fresh)
	}
}

// TestPrunePolicyValidation: zero or two rules is an error, and nothing is
// deleted.
func TestPrunePolicyValidation(t *testing.T) {
	store := newFakeObjStore()
	for _, policy := range []PrunePolicy{{}, {Keep: 3, OlderThan: time.Hour}} {
		if _, err := Prune(context.Background(), store, "bk", "", policy); err == nil {
			t.Errorf("Prune(%+v) did not error", policy)
		}
	}
	if len(store.deletes) != 0 {
		t.Errorf("an invalid policy deleted %v", store.deletes)
	}
}

func mustTime(t *testing.T, s string) time.Time {
	t.Helper()
	at, err := time.Parse(time.RFC3339, s)
	if err != nil {
		t.Fatal(err)
	}
	return at
}

func gzipBytes(t *testing.T, b []byte) []byte {
	t.Helper()
	var buf bytes.Buffer
	gzw := gzip.NewWriter(&buf)
	if _, err := gzw.Write(b); err != nil {
		t.Fatal(err)
	}
	if err := gzw.Close(); err != nil {
		t.Fatal(err)
	}
	return buf.Bytes()
}

// TestRestoreManifestMismatchFails: the manifest is the declared truth and
// Restore now READS it. A dump/manifest pair that drifted — a re-uploaded
// object, a half-written backup, anything that gunzips cleanly but is not the
// stream the manifest describes — must FAIL, naming both sides.
//
// The same-length case is the one that matters: it is invisible to a length
// check, so it proves the SHA256 comparison specifically.
func TestRestoreManifestMismatchFails(t *testing.T) {
	pinNow(t, time.Date(2026, 7, 2, 6, 0, 0, 0, time.UTC))
	dump := []byte("SELECT 'the manifest describes THIS';\n")

	for _, tc := range []struct {
		name    string
		planted []byte
	}{
		{"different length", []byte("SELECT 'but the object holds this instead, and it is longer';\n")},
		{"SAME length, different bytes", []byte("SELECT 'the manifest describes THAT';\n")},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if tc.name == "SAME length, different bytes" && len(tc.planted) != len(dump) {
				t.Fatalf("fixture bug: planted %d bytes, dump %d — the case is not same-length", len(tc.planted), len(dump))
			}
			store := newFakeObjStore()
			key, err := Backup(context.Background(), &fakeDumpSource{name: "db", data: dump}, store, "bk", "prod")
			if err != nil {
				t.Fatalf("Backup: %v", err)
			}
			// The manifest stays exactly as Backup wrote it; only the dump drifts.
			store.store("bk", key, gzipBytes(t, tc.planted))

			sink := &fakeSink{}
			rep, rerr := Restore(context.Background(), store, "bk", key, sink)
			if rerr == nil {
				t.Fatalf("Restore reported success (%q) on a dump that disagrees with its manifest", rep.Verification)
			}
			if rep.Verified() {
				t.Errorf("a failed restore reported %q", rep.Verification)
			}
			msg := rerr.Error()
			for _, want := range []string{
				"does not match its manifest",
				hex.EncodeToString(sha256Sum(dump)),       // what the manifest declares
				hex.EncodeToString(sha256Sum(tc.planted)), // what actually streamed
				fmt.Sprintf("%d bytes", len(dump)),
			} {
				if !strings.Contains(msg, want) {
					t.Errorf("mismatch error does not name %q:\n%s", want, msg)
				}
			}
		})
	}
}

// sha256Sum is the test's own digest helper — deliberately independent of the
// production hashing path so a bug there cannot make the expectation agree.
func sha256Sum(b []byte) []byte {
	h := sha256.Sum256(b)
	return h[:]
}

// TestRestoreWithoutManifestIsUnverified: backups taken before manifests
// existed have none. Those still restore — but they come back UNVERIFIED, with
// their own name and their own reason, never counted as a verified pass.
func TestRestoreWithoutManifestIsUnverified(t *testing.T) {
	pinNow(t, time.Date(2026, 7, 3, 6, 0, 0, 0, time.UTC))
	dump := []byte("SELECT 'an old backup, no manifest';\n")
	store := newFakeObjStore()
	key, err := Backup(context.Background(), &fakeDumpSource{name: "db", data: dump}, store, "prod", "old")
	if err != nil {
		t.Fatalf("Backup: %v", err)
	}
	// Age the object back to the manifest-less era.
	delete(store.objects["prod"], key+manifestSuffix)

	sink := &fakeSink{}
	rep, rerr := Restore(context.Background(), store, "prod", key, sink)
	if rerr != nil {
		t.Fatalf("a manifest-less backup must still restore, got: %v", rerr)
	}
	if !bytes.Equal(sink.got, dump) {
		t.Errorf("Restore streamed %q, want %q", sink.got, dump)
	}
	if rep.Verified() || rep.Verification != RestoreUnverified {
		t.Fatalf("a manifest-less restore reported %q, want %q — it must NEVER read as a verified pass",
			rep.Verification, RestoreUnverified)
	}
	if !strings.Contains(rep.Reason, manifestSuffix) {
		t.Errorf("unverified reason does not name the missing manifest: %q", rep.Reason)
	}
	// The counter is still honest about what streamed, even unverified.
	if rep.Bytes != int64(len(dump)) || rep.SHA256 != hex.EncodeToString(sha256Sum(dump)) {
		t.Errorf("unverified report mis-counts the stream: %d bytes / %s", rep.Bytes, rep.SHA256)
	}

	// A manifest that exists but declares no sha256 cannot verify either.
	key2, err := Backup(context.Background(), &fakeDumpSource{name: "db", data: dump}, store, "prod", "old")
	if err != nil {
		t.Fatalf("Backup: %v", err)
	}
	store.store("prod", key2+manifestSuffix, []byte(`{"database":"db","bytes":0}`))
	rep2, rerr2 := Restore(context.Background(), store, "prod", key2, &fakeSink{})
	if rerr2 != nil {
		t.Fatalf("Restore: %v", rerr2)
	}
	if rep2.Verified() {
		t.Errorf("a manifest with no sha256 reported %q, want %q", rep2.Verification, RestoreUnverified)
	}
}

package cli

// hetzner_backup_cmd_test.go drives `bp cloud hetzner backup …` end-to-end
// through the REAL pipeline — internal/backup streaming into the real objstore
// client — with only the two hard edges faked: the S3 network (recording
// transport, same as the storage tests) and pg_dump (a fixed-bytes DumpSource
// via the newDumpSource seam). The multipart wire conversation, the gzip
// framing and the manifest JSON are all asserted from recorded bytes.

import (
	"bytes"
	"compress/gzip"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os/exec"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/backup"
)

// TestPGURLPasswordOffArgv proves the DB password never lands on pg_dump/psql
// argv (CWE-214 — argv is world-readable via ps aux / /proc/<pid>/cmdline) and
// instead rides PGPASSWORD. Both sibling exec sites are checked in lockstep.
func TestPGURLPasswordOffArgv(t *testing.T) {
	const url = "postgres://u:secretpw@h:5432/db"
	ctx := context.Background()

	dumpCmd := (&pgDumpSource{databaseURL: url}).buildCmd(ctx)
	restoreCmd := (&psqlSink{databaseURL: url}).buildCmd(ctx)

	for _, tc := range []struct {
		name string
		cmd  *exec.Cmd
	}{
		{"pg_dump", dumpCmd},
		{"psql", restoreCmd},
	} {
		args := strings.Join(tc.cmd.Args, " ")
		if strings.Contains(args, "secretpw") {
			t.Errorf("%s argv leaks the password: %q", tc.name, args)
		}
		// The password-less DSN still names user, host and db.
		if !strings.Contains(args, "postgres://u@h:5432/db") {
			t.Errorf("%s argv = %q, want a password-less DSN", tc.name, args)
		}
		if !containsEnv(tc.cmd.Env, "PGPASSWORD=secretpw") {
			t.Errorf("%s env = %v, want PGPASSWORD=secretpw", tc.name, tc.cmd.Env)
		}
	}
}

// TestPGURLNoPassword: a URL without a password sets no PGPASSWORD (env stays
// nil so the child inherits the parent's, unchanged) and argv is untouched.
func TestPGURLNoPassword(t *testing.T) {
	const url = "postgres://u@h:5432/db"
	cmd := (&pgDumpSource{databaseURL: url}).buildCmd(context.Background())
	if cmd.Env != nil {
		t.Errorf("no-password URL set cmd.Env = %v, want nil (inherit parent)", cmd.Env)
	}
	if !strings.Contains(strings.Join(cmd.Args, " "), url) {
		t.Errorf("argv = %q, want the unchanged URL", cmd.Args)
	}
}

// TestSplitPGURLMalformed: an unparseable URL is passed through unchanged with
// no password, preserving the pre-fix behavior for bad input.
func TestSplitPGURLMalformed(t *testing.T) {
	const raw = "://not a url"
	dsn, pw := splitPGURL(raw)
	if dsn != raw || pw != "" {
		t.Errorf("splitPGURL(%q) = (%q, %q), want the raw URL and no password", raw, dsn, pw)
	}
}

func containsEnv(env []string, want string) bool {
	for _, e := range env {
		if e == want {
			return true
		}
	}
	return false
}

// fixedDumpSource is the pg_dump stand-in: fixed bytes, a named database.
type fixedDumpSource struct {
	db   string
	data []byte
}

func (s *fixedDumpSource) Database() string { return s.db }
func (s *fixedDumpSource) Open(ctx context.Context) (io.ReadCloser, error) {
	return io.NopCloser(bytes.NewReader(s.data)), nil
}

// withFixedDump swaps the pg_dump seam for fixed bytes and records the URL the
// command tried to dump.
func withFixedDump(t *testing.T, db string, data []byte) *string {
	t.Helper()
	var gotURL string
	old := newDumpSource
	newDumpSource = func(databaseURL string) (backup.DumpSource, error) {
		gotURL = databaseURL
		return &fixedDumpSource{db: db, data: data}, nil
	}
	t.Cleanup(func() { newDumpSource = old })
	return &gotURL
}

// TestHetznerBackupCreate proves the whole create path: pg_dump bytes → gzip →
// a REAL multipart S3 conversation (initiate/part/complete on the timestamped
// key) → the manifest PUT — and the receipt names the key.
func TestHetznerBackupCreate(t *testing.T) {
	f, parts := multipartS3()
	withFakeS3(t, f)
	dump := []byte("CREATE TABLE parks (id serial);\n")
	gotURL := withFixedDump(t, "barkpark", dump)

	stdout, stderr, code := runHzCLI(t, "json", storageArgs("hetzner", "backup", "create",
		"--database-url", "postgres://bp@db.internal/barkpark", "--bucket", "bkt", "--prefix", "prod")...)
	if code != exitOK {
		t.Fatalf("backup create exited %d, stderr: %s", code, stderr)
	}
	if *gotURL != "postgres://bp@db.internal/barkpark" {
		t.Errorf("dump source got url %q, want the --database-url", *gotURL)
	}

	var payload map[string]any
	if err := json.Unmarshal([]byte(stdout), &payload); err != nil {
		t.Fatalf("receipt is not JSON: %v\n%s", err, stdout)
	}
	bk, _ := payload["backup"].(map[string]any)
	key, _ := bk["name"].(string)
	if payload["ok"] != true || payload["action"] != "create" || payload["database"] != "barkpark" {
		t.Errorf("receipt = %v, want ok/create/database=barkpark", payload)
	}
	if !strings.HasPrefix(key, "prod/") || !strings.HasSuffix(key, ".sql.gz") {
		t.Fatalf("receipt key = %q, want prod/<stamp>.sql.gz", key)
	}

	// The multipart conversation happened on the returned key…
	if _, ok := f.find("POST", "/"+key); !ok {
		t.Fatalf("no multipart initiate on /%s; requests: %+v", key, f.requests())
	}
	// …and the uploaded parts gunzip back to the EXACT dump bytes.
	var joined []byte
	for _, p := range *parts {
		joined = append(joined, p...)
	}
	gzr, err := gzip.NewReader(bytes.NewReader(joined))
	if err != nil {
		t.Fatalf("uploaded parts are not a gzip stream: %v", err)
	}
	restored, err := io.ReadAll(gzr)
	if err != nil {
		t.Fatalf("gunzip uploaded parts: %v", err)
	}
	if !bytes.Equal(restored, dump) {
		t.Errorf("uploaded gunzipped bytes = %q, want the dump %q", restored, dump)
	}

	// The manifest rode along with truthful fields.
	man, ok := f.find("PUT", "/"+key+".manifest.json")
	if !ok {
		t.Fatalf("no manifest PUT on /%s.manifest.json", key)
	}
	var manifest map[string]any
	if err := json.Unmarshal(man.Body, &manifest); err != nil {
		t.Fatalf("manifest body is not JSON: %v\n%s", err, man.Body)
	}
	if manifest["database"] != "barkpark" || manifest["bytes"] != float64(len(dump)) || manifest["sha256"] == "" {
		t.Errorf("manifest = %v, want database=barkpark bytes=%d sha256 set", manifest, len(dump))
	}

	// …and the receipt is built from a HEAD of that key, not from the key the
	// library composed. `database` rides along DECLARED, because no object store
	// can report which database produced a blob of gzip.
	if _, ok := f.find("HEAD", "/"+key); !ok {
		t.Errorf("no confirming HEAD on /%s; requests: %+v", key, f.requests())
	}
	if payload["confirmed_present"] != true || payload["bytes"] == nil {
		t.Errorf("receipt = %v, want confirmed_present with the STORED length", payload)
	}
	if payload["database_confirmed"] != false {
		t.Errorf("receipt = %v, want database_confirmed false — the store cannot report a database name", payload)
	}
}

// TestHetznerBackupCreateSilentDropRefuses is the receipt that matters most in
// this file. The endpoint completes the whole multipart conversation with 200s
// and persists NOTHING — and the pre-slice verb printed
// `✓ create — backup prod/<stamp>.sql.gz / database: barkpark`, a green backup
// receipt for a dump that exists nowhere. That is the failure this epic is
// named for: nobody discovers it until a restore.
func TestHetznerBackupCreateSilentDropRefuses(t *testing.T) {
	f, _ := multipartS3()
	f.dropWrites = true
	withFakeS3(t, f)
	withFixedDump(t, "barkpark", []byte("CREATE TABLE parks (id serial);\n"))

	stdout, stderr, code := runHzCLI(t, "table", storageArgs("hetzner", "backup", "create",
		"--database-url", "postgres://bp@db.internal/barkpark", "--bucket", "bkt", "--prefix", "prod")...)
	if code == exitOK {
		t.Fatalf("a backup that was never stored exited 0\nstdout: %s\nstderr: %s", stdout, stderr)
	}
	said := stdout + stderr
	if !strings.Contains(said, "NOT READABLE") || !strings.Contains(said, "prod/") {
		t.Errorf("the refusal must name the backup key that is not there:\n%s", said)
	}
	for _, r := range f.requests() {
		if r.Method == "HEAD" {
			return
		}
	}
	t.Errorf("no HEAD was issued at all — the refusal came from somewhere other than the post-read: %+v", f.requests())
}

// TestHetznerBackupCreateNoPgDump: with an empty PATH the real seam refuses
// with a plain "pg_dump is not on PATH" error before touching the network.
func TestHetznerBackupCreateNoPgDump(t *testing.T) {
	f := &fakeS3{}
	withFakeS3(t, f)
	t.Setenv("PATH", t.TempDir())

	_, stderr, code := runHzCLI(t, "table", storageArgs("hetzner", "backup", "create",
		"--database-url", "postgres://x/y", "--bucket", "bkt")...)
	if code == exitOK {
		t.Fatal("backup create without pg_dump succeeded")
	}
	if !strings.Contains(stderr, "pg_dump is not on PATH") {
		t.Errorf("error %q does not name the missing pg_dump", stderr)
	}
	if len(f.requests()) != 0 {
		t.Errorf("%d S3 requests were sent despite the missing pg_dump", len(f.requests()))
	}
}

// backupListingS3 SEEDS a bucket holding three backups and their manifests —
// real stored objects, so the listing, the manifest GETs and the prune DELETEs
// all read and write the same state. Shared by the list and prune tests.
func backupListingS3() *fakeS3 {
	manifest := func(db, stamp string) string {
		return fmt.Sprintf(`{"database":%q,"bytes":100,"sha256":"abc","created_at":%q}`, db, stamp)
	}
	f := newFakeS3()
	for _, stamp := range []string{"20260601T000000Z", "20260615T000000Z", "20260701T000000Z"} {
		created := stamp[:4] + "-" + stamp[4:6] + "-" + stamp[6:8] + "T00:00:00Z"
		key := "prod/" + stamp + ".sql.gz"
		f.seedObject("bkt", key, "gz-bytes", created)
		f.seedObject("bkt", key+".manifest.json", manifest("barkpark", created), created)
	}
	return f
}

// TestHetznerBackupList asserts the listing rides manifests: newest first,
// database and created_at from the manifest JSON, manifest keys not listed as
// backups.
func TestHetznerBackupList(t *testing.T) {
	f := backupListingS3()
	withFakeS3(t, f)

	stdout, stderr, code := runHzCLI(t, "json", storageArgs("hetzner", "backup", "list", "--bucket", "bkt", "--prefix", "prod")...)
	if code != exitOK {
		t.Fatalf("backup list exited %d, stderr: %s", code, stderr)
	}
	var payload map[string]any
	if err := json.Unmarshal([]byte(stdout), &payload); err != nil {
		t.Fatalf("list output is not JSON: %v\n%s", err, stdout)
	}
	backups, _ := payload["backups"].([]any)
	if len(backups) != 3 {
		t.Fatalf("backups = %v, want 3 (manifests must not list as backups)", payload)
	}
	first, _ := backups[0].(map[string]any)
	if first["key"] != "prod/20260701T000000Z.sql.gz" || first["database"] != "barkpark" ||
		first["created_at"] != "2026-07-01T00:00:00Z" || first["bytes"] != float64(100) {
		t.Errorf("first row = %v, want the NEWEST backup with manifest fields", first)
	}
	last, _ := backups[2].(map[string]any)
	if last["key"] != "prod/20260601T000000Z.sql.gz" {
		t.Errorf("last row = %v, want the oldest key", last)
	}
}

// TestHetznerBackupPruneKeep asserts --keep 1 deletes exactly the two older
// dumps AND their manifests, and reports the deleted keys.
func TestHetznerBackupPruneKeep(t *testing.T) {
	f := backupListingS3()
	withFakeS3(t, f)

	stdout, stderr, code := runHzCLI(t, "json", storageArgs("hetzner", "backup", "prune", "--bucket", "bkt", "--prefix", "prod", "--keep", "1")...)
	if code != exitOK {
		t.Fatalf("backup prune exited %d, stderr: %s", code, stderr)
	}
	var payload map[string]any
	if err := json.Unmarshal([]byte(stdout), &payload); err != nil {
		t.Fatalf("prune output is not JSON: %v\n%s", err, stdout)
	}
	deleted, _ := payload["deleted"].([]any)
	if payload["ok"] != true || payload["count"] != float64(2) || len(deleted) != 2 {
		t.Fatalf("prune receipt = %v, want ok count=2", payload)
	}
	if deleted[0] != "prod/20260615T000000Z.sql.gz" || deleted[1] != "prod/20260601T000000Z.sql.gz" {
		t.Errorf("deleted = %v, want the two OLDER keys newest-first", deleted)
	}
	for _, key := range []string{
		"/prod/20260615T000000Z.sql.gz", "/prod/20260615T000000Z.sql.gz.manifest.json",
		"/prod/20260601T000000Z.sql.gz", "/prod/20260601T000000Z.sql.gz.manifest.json",
	} {
		if _, ok := f.find("DELETE", key); !ok {
			t.Errorf("no DELETE was issued for %s", key)
		}
	}
	if _, ok := f.find("DELETE", "/prod/20260701T000000Z.sql.gz"); ok {
		t.Error("the newest backup was wrongly deleted under --keep 1")
	}
}

// TestHetznerBackupPruneUsage: zero or two retention rules is a usage error
// and nothing is deleted.
func TestHetznerBackupPruneUsage(t *testing.T) {
	f := backupListingS3()
	withFakeS3(t, f)

	for _, extra := range [][]string{
		{},
		{"--keep", "2", "--older-than", "30d"},
	} {
		args := append([]string{"hetzner", "backup", "prune", "--bucket", "bkt"}, extra...)
		_, stderr, code := runHzCLI(t, "table", storageArgs(args...)...)
		if code != exitUsage {
			t.Errorf("prune %v exited %d, want exitUsage", extra, code)
		}
		if !strings.Contains(stderr, "exactly one retention rule") {
			t.Errorf("prune %v error = %q, want the retention-rule usage message", extra, stderr)
		}
	}
	if len(f.requests()) != 0 {
		t.Errorf("an invalid prune sent %d requests, want 0", len(f.requests()))
	}
}

// TestHetznerBackupRestore wires the sink seam and asserts the downloaded
// object is gunzipped and streamed as the ORIGINAL SQL bytes.
func TestHetznerBackupRestore(t *testing.T) {
	sql := []byte("INSERT INTO parks VALUES (1);\n")
	var gz bytes.Buffer
	gzw := gzip.NewWriter(&gz)
	if _, err := gzw.Write(sql); err != nil {
		t.Fatal(err)
	}
	if err := gzw.Close(); err != nil {
		t.Fatal(err)
	}
	f := newFakeS3().seedObject("bkt", "prod/20260701T000000Z.sql.gz", gz.String(), "")
	withFakeS3(t, f)

	var got []byte
	var gotURL string
	old := newRestoreSink
	newRestoreSink = func(databaseURL string) (backup.RestoreSink, error) {
		gotURL = databaseURL
		return restoreSinkFunc(func(ctx context.Context, r io.Reader) error {
			b, err := io.ReadAll(r)
			got = b
			return err
		}), nil
	}
	t.Cleanup(func() { newRestoreSink = old })

	stdout, stderr, code := runHzCLI(t, "json", storageArgs("hetzner", "backup", "restore",
		"--bucket", "bkt", "--key", "prod/20260701T000000Z.sql.gz", "--database-url", "postgres://bp@db/restored")...)
	if code != exitOK {
		t.Fatalf("backup restore exited %d, stderr: %s", code, stderr)
	}
	if gotURL != "postgres://bp@db/restored" {
		t.Errorf("sink got url %q, want the --database-url", gotURL)
	}
	if !bytes.Equal(got, sql) {
		t.Errorf("sink received %q, want the original SQL %q", got, sql)
	}
	if req, ok := f.find("GET", "/prod/20260701T000000Z.sql.gz"); !ok || req.Host != "bkt.fsn1.your-objectstorage.com" {
		t.Errorf("restore GET = %+v, want the virtual-hosted dump key", req)
	}
	var payload map[string]any
	if err := json.Unmarshal([]byte(stdout), &payload); err != nil {
		t.Fatalf("restore receipt is not JSON: %v\n%s", err, stdout)
	}
	if payload["ok"] != true || payload["action"] != "restore" {
		t.Errorf("restore receipt = %v, want ok/restore", payload)
	}
	// THE DECLARED EXEMPTION, asserted as data. A restore's post-condition is
	// inside the target Postgres and this verb holds S3 credentials only, so the
	// receipt must SAY the restored state is not confirmed rather than carry a
	// confirmed_present nothing read.
	if payload["confirmation"] != "unavailable" || payload["confirmed_present"] != false {
		t.Errorf("restore receipt = %v, want confirmation:unavailable and confirmed_present:false", payload)
	}
	note, _ := payload["note"].(string)
	if !strings.Contains(note, "not confirmed") || !strings.Contains(note, "Postgres") {
		t.Errorf("restore receipt note = %q, want it to name the unconfirmed post-condition and where it lives", note)
	}
	if _, invented := payload["bytes"]; invented {
		t.Errorf("restore receipt = %v, must not invent a byte count for a stream it did not measure", payload)
	}
	// This fixture is a manifest-LESS dump (an object from before manifests
	// existed). It restores — and the receipt says UNVERIFIED under its own
	// key, with a reason, so a reader never counts it as a manifest that
	// passed. The measured length/digest it DID observe ride alongside.
	if payload["manifest_check"] != "unverified" {
		t.Errorf("restore receipt manifest_check = %v, want \"unverified\" for a dump with no manifest", payload["manifest_check"])
	}
	reason, _ := payload["manifest_unverified_reason"].(string)
	if !strings.Contains(reason, ".manifest.json") {
		t.Errorf("restore receipt manifest_unverified_reason = %q, want it to name the manifest key it could not read", reason)
	}
	if payload["restored_bytes"] != float64(len(sql)) {
		t.Errorf("restore receipt restored_bytes = %v, want the %d bytes actually streamed", payload["restored_bytes"], len(sql))
	}
}

// restoreSinkFunc adapts a func to backup.RestoreSink.
type restoreSinkFunc func(ctx context.Context, r io.Reader) error

func (f restoreSinkFunc) Restore(ctx context.Context, r io.Reader) error { return f(ctx, r) }

// TestPgDumpSourceDatabaseName covers the manifest's database-name parsing
// from the URL path, with the postgres fallback.
func TestPgDumpSourceDatabaseName(t *testing.T) {
	for url, want := range map[string]string{
		"postgres://bp:pw@db.internal:5432/barkpark?sslmode=require": "barkpark",
		"postgres://bp@db.internal/":                                 "postgres",
		"postgres://bp@db.internal":                                  "postgres",
	} {
		s := &pgDumpSource{databaseURL: url}
		if got := s.Database(); got != want {
			t.Errorf("Database(%q) = %q, want %q", url, got, want)
		}
	}
}

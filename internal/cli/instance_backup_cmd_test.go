package cli

import (
	"archive/tar"
	"compress/gzip"
	"context"
	"encoding/json"
	"fmt"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// TestInstanceBackupRoundTripPostgres backs up a seeded database and media
// directory, restores both into a fresh database and directory, and expects
// the restore's own verification to pass. It needs a Postgres server and the
// matching client tools: set BARKPARK_TEST_PG_URL to a URL whose role may
// create databases, for example postgresql://localhost/postgres. The test
// creates and drops its own databases.
func TestInstanceBackupRoundTripPostgres(t *testing.T) {
	admin := os.Getenv("BARKPARK_TEST_PG_URL")
	if admin == "" {
		t.Skip("BARKPARK_TEST_PG_URL is not set")
	}
	ctx := context.Background()
	stamp := fmt.Sprintf("%d", time.Now().UnixNano())
	src := testPGDatabase(t, admin, "bp_backup_src_"+stamp)
	dst := testPGDatabase(t, admin, "bp_backup_dst_"+stamp)

	seed := `CREATE TABLE documents (id serial PRIMARY KEY, doc_id text NOT NULL, type text NOT NULL, content jsonb);
INSERT INTO documents (doc_id, type, content) SELECT 'b' || g, 'book', '{}' FROM generate_series(1, 7) g;
INSERT INTO documents (doc_id, type, content) SELECT 'a' || g, 'author', '{}' FROM generate_series(1, 3) g;`
	if _, err := psqlQuery(ctx, src, seed); err != nil {
		t.Fatal(err)
	}
	media := t.TempDir()
	writeTestFile(t, filepath.Join(media, "covers", "b1.jpg"), "cover one")
	writeTestFile(t, filepath.Join(media, "covers", "nested", "b2.png"), "cover two")
	writeTestFile(t, filepath.Join(media, "readme.txt"), "")

	out := filepath.Join(t.TempDir(), "backup")
	man, err := instanceBackup(ctx, src, media, out)
	if err != nil {
		t.Fatal(err)
	}
	if man.Documents["book"] != 7 || man.Documents["author"] != 3 || len(man.Media) != 3 {
		t.Fatalf("manifest counts = %v, media = %d files; want book 7, author 3, 3 files", man.Documents, len(man.Media))
	}
	raw, _ := os.ReadFile(filepath.Join(out, instanceBackupManifest))
	for _, key := range man.Secrets.Keys {
		if v := os.Getenv(key); v != "" && strings.Contains(string(raw), v) {
			t.Fatalf("manifest contains the value of %s", key)
		}
	}

	restored := filepath.Join(t.TempDir(), "media")
	if _, err := instanceRestore(ctx, out, dst, restored); err != nil {
		t.Fatalf("restore: %v", err)
	}
	got, _ := os.ReadFile(filepath.Join(restored, "covers", "nested", "b2.png"))
	if string(got) != "cover two" {
		t.Fatalf("restored media = %q", got)
	}

	// A second restore into the now populated database is refused.
	if _, err := instanceRestore(ctx, out, dst, t.TempDir()); err == nil || !strings.Contains(err.Error(), "empty database") {
		t.Fatalf("restore into a populated database: err = %v, want an empty-database refusal", err)
	}
}

// TestInstanceRestoreRefusesTamperedMember checks that a changed member fails
// before any database is contacted.
func TestInstanceRestoreRefusesTamperedMember(t *testing.T) {
	dir := t.TempDir()
	writeTestFile(t, filepath.Join(dir, instanceBackupDB), "dump")
	writeTestFile(t, filepath.Join(dir, instanceBackupMedia), "media")
	db, _ := hashFile(dir, instanceBackupDB)
	mediaArchive, _ := hashFile(dir, instanceBackupMedia)
	b, _ := json.Marshal(instanceBackupManifestV1{Format: instanceBackupFormat, DB: db, MediaArchive: mediaArchive})
	writeTestFile(t, filepath.Join(dir, instanceBackupManifest), string(b))
	writeTestFile(t, filepath.Join(dir, instanceBackupDB), "dump changed")

	_, err := instanceRestore(context.Background(), dir, "postgresql://127.0.0.1:1/none", t.TempDir())
	if err == nil || !strings.Contains(err.Error(), "db.dump does not match the manifest") {
		t.Fatalf("err = %v, want a db.dump checksum mismatch", err)
	}
}

func TestInstanceRestoreDiffs(t *testing.T) {
	counts := diffCounts(map[string]int64{"book": 7, "author": 3}, map[string]int64{"book": 6, "tag": 1})
	if len(counts) != 3 {
		t.Fatalf("diffCounts = %q, want the book shortfall, the missing author and the extra tag", counts)
	}
	a := instanceBackupFile{Path: "a", Bytes: 1, SHA256: "x"}
	media := diffMedia([]instanceBackupFile{a, {Path: "b"}}, []instanceBackupFile{{Path: "a", Bytes: 1, SHA256: "y"}, {Path: "c"}})
	if len(media) != 3 {
		t.Fatalf("diffMedia = %q, want a changed a, a missing b and an extra c", media)
	}
	if diffCounts(map[string]int64{"book": 7}, map[string]int64{"book": 7}) != nil || diffMedia([]instanceBackupFile{a}, []instanceBackupFile{a}) != nil {
		t.Fatal("identical inputs reported a difference")
	}
	if m, err := pgMajor("170004"); err != nil || m != 17 {
		t.Fatalf("pgMajor(170004) = %d, %v", m, err)
	}
}

func TestExtractMediaRefusesEscape(t *testing.T) {
	archive := filepath.Join(t.TempDir(), "media.tar.gz")
	f, _ := os.Create(archive)
	gz := gzip.NewWriter(f)
	tw := tar.NewWriter(gz)
	_ = tw.WriteHeader(&tar.Header{Name: "../escape", Typeflag: tar.TypeReg, Mode: 0o644, Size: 1})
	_, _ = tw.Write([]byte("x"))
	_ = tw.Close()
	_ = gz.Close()
	_ = f.Close()
	if err := extractMedia(archive, t.TempDir()); err == nil || !strings.Contains(err.Error(), "outside the media directory") {
		t.Fatalf("err = %v, want an outside-the-directory refusal", err)
	}
}

// testPGDatabase creates a database next to admin and drops it after the test.
func testPGDatabase(t *testing.T, admin, name string) string {
	t.Helper()
	ctx := context.Background()
	if _, err := psqlQuery(ctx, admin, "CREATE DATABASE "+name+";"); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _, _ = psqlQuery(ctx, admin, "DROP DATABASE IF EXISTS "+name+" WITH (FORCE);") })
	u, err := url.Parse(admin)
	if err != nil {
		t.Fatal(err)
	}
	u.Path = "/" + name
	if _, err := exec.LookPath("pg_dump"); err != nil {
		t.Skip("pg_dump is not on PATH")
	}
	return u.String()
}

func writeTestFile(t *testing.T, path, body string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}

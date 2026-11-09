package cli

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// fakeVMDir lays out /opt/barkpark as deploy.sh leaves it: a .env with an
// ecto:// DATABASE_URL and an uploads directory. It points instanceVMDir at
// it and clears the environment the flags fall back to.
func fakeVMDir(t *testing.T, dbURL string) string {
	t.Helper()
	dir := t.TempDir()
	writeTestFile(t, filepath.Join(dir, ".env"), "DATABASE_URL="+dbURL+"\nSECRET_KEY_BASE=not-read\nPHX_HOST=pensum.example.test\n")
	if err := os.MkdirAll(filepath.Join(dir, "uploads"), 0o755); err != nil {
		t.Fatal(err)
	}
	old := instanceVMDir
	instanceVMDir = dir
	t.Cleanup(func() { instanceVMDir = old })
	t.Setenv("DATABASE_URL", "")
	t.Setenv("BARKPARK_MEDIA_DIR", "")
	return dir
}

// fakePGTools puts stand-ins for pg_dump, pg_restore and psql first on PATH,
// so the flag tests run without the Postgres client tools.
func fakePGTools(t *testing.T) {
	t.Helper()
	bin := t.TempDir()
	for _, tool := range []string{"pg_dump", "pg_restore", "psql"} {
		if err := os.WriteFile(filepath.Join(bin, tool), []byte("#!/bin/sh\nexit 1\n"), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	t.Setenv("PATH", bin+string(os.PathListSeparator)+os.Getenv("PATH"))
}

func backupArgs(t *testing.T, args ...string) *hzArgs {
	t.Helper()
	a, err := parseHzArgs(args, []string{"database-url", "media-dir", "env-file", "out"}, nil, "test")
	if err != nil {
		t.Fatal(err)
	}
	return a
}

// On a VM from deploy.sh, backup finds the database and media with no flag.
func TestInstanceBackupFlagsReadVMEnv(t *testing.T) {
	fakePGTools(t)
	dir := fakeVMDir(t, "ecto://barkpark:pw-from-env@localhost/barkpark_prod")
	dbURL, media, source, err := instanceBackupFlags(backupArgs(t, "--out", "x"), true)
	if err != nil {
		t.Fatal(err)
	}
	if dbURL != "postgresql://barkpark:pw-from-env@localhost/barkpark_prod" {
		t.Errorf("database URL = %q; want the .env URL with postgresql://", dbURL)
	}
	if media != filepath.Join(dir, "uploads") {
		t.Errorf("media = %q; want %s", media, filepath.Join(dir, "uploads"))
	}
	if source != filepath.Join(dir, ".env") || strings.Contains(source, "pw-from-env") {
		t.Errorf("source = %q; want the .env path and no password", source)
	}
}

// A BARKPARK_MEDIA_DIR in the VM's .env is a path in the container, so the
// VM default keeps the host's uploads directory.
func TestInstanceBackupFlagsVMEnvKeepsHostMedia(t *testing.T) {
	fakePGTools(t)
	dir := fakeVMDir(t, "ecto://u:p@localhost/db")
	writeTestFile(t, filepath.Join(dir, ".env"), "DATABASE_URL=ecto://u:p@localhost/db\nBARKPARK_MEDIA_DIR=/app/uploads\n")
	_, media, _, err := instanceBackupFlags(backupArgs(t), true)
	if err != nil {
		t.Fatal(err)
	}
	if media != filepath.Join(dir, "uploads") {
		t.Errorf("media = %q; want the host's %s", media, filepath.Join(dir, "uploads"))
	}
}

func TestInstanceBackupFlagsPrecedence(t *testing.T) {
	fakePGTools(t)
	fakeVMDir(t, "ecto://vm:p@localhost/vm")

	// A flag wins over every file.
	got, _, _, err := instanceBackupFlags(backupArgs(t, "--database-url", "postgresql://flag/db", "--media-dir", "/m"), true)
	if err != nil || got != "postgresql://flag/db" {
		t.Errorf("flag: %q, %v", got, err)
	}

	// DATABASE_URL in the environment wins over the VM default.
	t.Setenv("DATABASE_URL", "postgresql://env/db")
	got, _, source, err := instanceBackupFlags(backupArgs(t, "--media-dir", "/m"), true)
	if err != nil || got != "postgresql://env/db" || source != "DATABASE_URL" {
		t.Errorf("environment: %q from %q, %v", got, source, err)
	}

	// An explicit --env-file wins over the environment and takes its media dir.
	other := t.TempDir()
	writeTestFile(t, filepath.Join(other, "barkpark.env"), "DATABASE_URL=ecto://file:p@db.example.test/file\nBARKPARK_MEDIA_DIR=/srv/media\n")
	got, media, _, err := instanceBackupFlags(backupArgs(t, "--env-file", filepath.Join(other, "barkpark.env")), true)
	if err != nil || got != "postgresql://file:p@db.example.test/file" || media != "/srv/media" {
		t.Errorf("--env-file: %q, media %q, %v", got, media, err)
	}
}

// Restore never reads the live instance's .env on its own.
func TestInstanceRestoreFlagsNeedATarget(t *testing.T) {
	fakePGTools(t)
	fakeVMDir(t, "ecto://u:p@localhost/db")
	if _, _, _, err := instanceBackupFlags(backupArgs(t), false); err == nil {
		t.Fatal("restore found a database with no flag, file or environment")
	}
}

func TestInstanceBackupFlagsUnreadableEnv(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root reads every file")
	}
	fakePGTools(t)
	dir := fakeVMDir(t, "ecto://u:p@localhost/db")
	if err := os.Chmod(filepath.Join(dir, ".env"), 0); err != nil {
		t.Fatal(err)
	}
	_, _, _, err := instanceBackupFlags(backupArgs(t), true)
	if err == nil || !strings.Contains(err.Error(), "sudo") {
		t.Fatalf("err = %v; want a hint to run with sudo", err)
	}
}

// TestInstanceBackupVMEnvPostgres runs bp instance backup --out <dir> with
// nothing else against a database named only in a deploy.sh style .env. It
// needs BARKPARK_TEST_PG_URL, as TestInstanceBackupRoundTripPostgres does.
func TestInstanceBackupVMEnvPostgres(t *testing.T) {
	admin := os.Getenv("BARKPARK_TEST_PG_URL")
	if admin == "" {
		t.Skip("BARKPARK_TEST_PG_URL is not set")
	}
	ctx := context.Background()
	src := testPGDatabase(t, admin, fmt.Sprintf("bp_backup_vm_%d", time.Now().UnixNano()))
	if _, err := psqlQuery(ctx, src, `CREATE TABLE documents (id serial PRIMARY KEY, doc_id text NOT NULL, type text NOT NULL, content jsonb);
INSERT INTO documents (doc_id, type, content) SELECT 'b' || g, 'book', '{}' FROM generate_series(1, 4) g;`); err != nil {
		t.Fatal(err)
	}
	ectoURL := "ecto://" + strings.TrimPrefix(strings.TrimPrefix(src, "postgresql://"), "postgres://")
	dir := fakeVMDir(t, ectoURL)
	writeTestFile(t, filepath.Join(dir, "uploads", "covers", "b1.jpg"), "cover one")

	out := filepath.Join(t.TempDir(), "backup")
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	w.applyGlobals(globals{output: "json", outputSet: true})
	if code := runInstanceBackup(w, []string{"--out", out}); code != exitOK {
		t.Fatalf("exit %d: %s", code, stderr.String())
	}
	var res struct {
		Manifest instanceBackupManifestV1 `json:"manifest"`
	}
	if err := json.Unmarshal(stdout.Bytes(), &res); err != nil {
		t.Fatalf("%v\n%s", err, stdout.String())
	}
	if res.Manifest.Documents["book"] != 4 || len(res.Manifest.Media) != 1 {
		t.Fatalf("manifest documents %v, %d media files; want book 4 and 1 file", res.Manifest.Documents, len(res.Manifest.Media))
	}
	if !strings.Contains(stderr.String(), filepath.Join(dir, ".env")) {
		t.Errorf("backup does not say it read %s:\n%s", filepath.Join(dir, ".env"), stderr.String())
	}
}

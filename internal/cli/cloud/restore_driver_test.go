package cloud

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"context"
	"io"
	"strings"
	"testing"
)

// TestRestoreDataScriptCarriesLoadBearingBytes pins the on-box restore pipeline
// (the instImportScript inverse): drop → createdb → pg_restore --no-owner → media →
// migrate → restart, addressing the fixed bp-bundle-v1 member names and the
// manifest-named database.
func TestRestoreDataScriptCarriesLoadBearingBytes(t *testing.T) {
	script := restoreDataScript("barkpark_prod")
	for _, want := range []string{
		"tar -C \"$STAGE\" -xzf -",
		"DROP DATABASE IF EXISTS barkpark_prod",
		"createdb -O \"${DBUSER:-postgres}\" barkpark_prod",
		"pg_restore --no-owner --role=\"${DBUSER:-postgres}\" -d barkpark_prod",
		bundleDBName,
		bundleMediaName,
		"/opt/barkpark/api/uploads",
		"mix ecto.migrate",
		"systemctl start barkpark",
		"BP_RESTORE_OK",
	} {
		if !strings.Contains(script, want) {
			t.Fatalf("restore script missing %q; got:\n%s", want, script)
		}
	}
}

// TestRestoreSecretsEnvStepMergesFullIdentity proves the .env merge carries the
// FULL bundle identity set (BARKPARK_INGEST_TOKEN + BARKPARK_KEK included — the keys
// the typed secretsInstallStep drops), idempotently, with no restart (the data
// restore restarts), and every value redacted.
func TestRestoreSecretsEnvStepMergesFullIdentity(t *testing.T) {
	step, err := restoreSecretsEnvStep(map[string]string{
		"SECRET_KEY_BASE":       strings.Repeat("A", 64),
		"BARKPARK_INGEST_TOKEN": "aW5nZXN0",
		"BARKPARK_KEK":          "a2Vr",
		"EMPTY":                 "", // dropped, never installed blank
	})
	if err != nil {
		t.Fatalf("restoreSecretsEnvStep: %v", err)
	}
	script := step.Argv[2]
	for _, want := range []string{
		"-e '^SECRET_KEY_BASE='",
		"-e '^BARKPARK_INGEST_TOKEN='",
		"-e '^BARKPARK_KEK='",
		"grep -v",
		".bpnew",
	} {
		if !strings.Contains(script, want) {
			t.Fatalf("merge script missing %q; got:\n%s", want, script)
		}
	}
	if strings.Contains(script, "^EMPTY=") {
		t.Fatal("a blank secret must never be installed")
	}
	if strings.Contains(script, "systemctl restart") {
		t.Fatal("the identity step must NOT restart — the data restore restarts")
	}
	if len(step.Redact) != 3 {
		t.Fatalf("want 3 redacted values, got %d", len(step.Redact))
	}
	if !step.RedactEnvSecrets {
		t.Fatal("the .env-writing step must pattern-scrub env secrets")
	}
}

// TestRestoreSecretsEnvStepRejectsUnsafeValue proves a shell-unsafe identity value
// fails loudly rather than being interpolated into the box's shell.
func TestRestoreSecretsEnvStepRejectsUnsafeValue(t *testing.T) {
	if _, err := restoreSecretsEnvStep(map[string]string{"SECRET_KEY_BASE": "value; rm -rf /"}); err == nil {
		t.Fatal("expected an unsafe secret value to be rejected")
	}
	if _, err := restoreSecretsEnvStep(map[string]string{"BAD'KEY": "safevalue"}); err == nil {
		t.Fatal("expected a non-env-var-shaped secret KEY to be rejected")
	}
	if _, err := restoreSecretsEnvStep(map[string]string{}); err == nil {
		t.Fatal("expected an empty identity set to be rejected")
	}
}

// TestBuildRestoreTarRoundTrips proves the fed stream is a gzip tar with both
// members, sized correctly.
func TestBuildRestoreTarRoundTrips(t *testing.T) {
	r, err := buildRestoreTar([]byte("DUMP"), []byte("MEDIA"))
	if err != nil {
		t.Fatalf("buildRestoreTar: %v", err)
	}
	raw, _ := io.ReadAll(r)
	gz, err := gzip.NewReader(bytes.NewReader(raw))
	if err != nil {
		t.Fatalf("not gzip: %v", err)
	}
	got := map[string]string{}
	tr := tar.NewReader(gz)
	for {
		h, err := tr.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			t.Fatalf("tar: %v", err)
		}
		b, _ := io.ReadAll(tr)
		got[h.Name] = string(b)
	}
	if got[bundleDBName] != "DUMP" || got[bundleMediaName] != "MEDIA" {
		t.Fatalf("tar members wrong: %+v", got)
	}
}

// TestSSHFeedArgvKeepsStdin proves the feed argv drops the `</dev/null` redirect
// (so the fed bytes reach the remote script) while the ordinary step argv keeps it.
func TestSSHFeedArgvKeepsStdin(t *testing.T) {
	feed := sshFeedArgv("root", "1.2.3.4", "/k", "tar -xzf -", false)
	if strings.Contains(feed[len(feed)-1], "</dev/null") {
		t.Fatalf("feed argv must NOT redirect stdin from /dev/null; got %q", feed[len(feed)-1])
	}
	step := sshStepArgv("root", "1.2.3.4", "/k", "echo hi", false)
	if !strings.Contains(step[len(step)-1], "</dev/null") {
		t.Fatal("the ordinary step argv must keep </dev/null")
	}
}

// TestOpenSecretsWithKEKRoundTrip proves the CARRIED-KEK unseal returns the sealed
// identity and REJECTS a wrong key (GCM auth), the guarantee a resurrect leans on.
func TestOpenSecretsWithKEKRoundTrip(t *testing.T) {
	const kek = "carried-key"
	t.Setenv(bundleKEKEnv, kek)
	store := NewFakeBundleStore()
	man, err := WriteBundle(context.Background(), store, BundleWriteSpec{
		FQDN:    "x.barkpark.cloud",
		DBName:  "barkpark_prod",
		DB:      strings.NewReader("dump"),
		Secrets: map[string]string{"SECRET_KEY_BASE": "skb"},
	})
	if err != nil {
		t.Fatalf("WriteBundle: %v", err)
	}
	got, err := OpenSecretsWithKEK(context.Background(), store, man.Prefix(), kek)
	if err != nil {
		t.Fatalf("OpenSecretsWithKEK: %v", err)
	}
	if got["SECRET_KEY_BASE"] != "skb" {
		t.Fatalf("unsealed = %v, want SECRET_KEY_BASE=skb", got)
	}
	if _, err := OpenSecretsWithKEK(context.Background(), store, man.Prefix(), "wrong-key"); err == nil {
		t.Fatal("a wrong carried KEK must fail GCM authentication")
	}
	if _, err := OpenSecretsWithKEK(context.Background(), store, man.Prefix(), ""); err == nil {
		t.Fatal("an empty carried KEK must be refused")
	}
}

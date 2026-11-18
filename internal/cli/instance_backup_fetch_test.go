package cli

import (
	"archive/tar"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// instance_backup_fetch_test.go covers bp instance backup fetch with a
// stubbed ssh: the list of backups and the tar stream come from the test.

type fetchFake struct {
	list    string
	tars    map[string][]byte
	calls   []string
	streams []string
}

func memberOf(name string, body []byte) instanceBackupFile {
	sum := sha256.Sum256(body)
	return instanceBackupFile{Path: name, Bytes: int64(len(body)), SHA256: hex.EncodeToString(sum[:])}
}

// backupTar builds the tar that sudo tar -C <remote> -cf - <name> prints.
// mutate may change the bodies after the manifest is written.
func backupTar(t *testing.T, name string, mutate func(map[string][]byte), extra ...string) []byte {
	t.Helper()
	db, media := []byte("PGDMP dump of "+name), []byte("gzip media of "+name)
	man := instanceBackupManifestV1{Format: instanceBackupFormat, DB: memberOf(instanceBackupDB, db), MediaArchive: memberOf(instanceBackupMedia, media)}
	mb, _ := json.Marshal(man)
	files := map[string][]byte{instanceBackupDB: db, instanceBackupMedia: media, instanceBackupManifest: mb}
	if mutate != nil {
		mutate(files)
	}
	var buf bytes.Buffer
	tw := tar.NewWriter(&buf)
	_ = tw.WriteHeader(&tar.Header{Name: name + "/", Typeflag: tar.TypeDir, Mode: 0o700})
	for _, m := range []string{instanceBackupDB, instanceBackupMedia, instanceBackupManifest} {
		_ = tw.WriteHeader(&tar.Header{Name: name + "/" + m, Typeflag: tar.TypeReg, Mode: 0o600, Size: int64(len(files[m]))})
		_, _ = tw.Write(files[m])
	}
	for _, e := range extra {
		_ = tw.WriteHeader(&tar.Header{Name: e, Typeflag: tar.TypeReg, Mode: 0o600, Size: 1})
		_, _ = tw.Write([]byte("x"))
	}
	_ = tw.Close()
	return buf.Bytes()
}

func stubFetch(t *testing.T) *fetchFake {
	t.Helper()
	f := &fetchFake{tars: map[string][]byte{}}
	oldRun, oldStream := instanceUpRun, instanceBackupStream
	instanceUpRun = func(_ context.Context, _ io.Writer, c instanceUpCmd) (string, error) {
		f.calls = append(f.calls, c.String())
		return f.list, nil
	}
	instanceBackupStream = func(_ context.Context, name string, args []string, w io.Writer) error {
		f.streams = append(f.streams, name+" "+strings.Join(args, " "))
		last := args[len(args)-1]
		b := f.tars[last[strings.LastIndex(last, " ")+1:]]
		_, err := w.Write(b)
		return err
	}
	t.Cleanup(func() { instanceUpRun, instanceBackupStream = oldRun, oldStream })
	dir := t.TempDir()
	wd, _ := os.Getwd()
	_ = os.Chdir(dir)
	t.Cleanup(func() { _ = os.Chdir(wd) })
	st := instanceUpState{Format: instanceUpStateFormat, Path: instanceTargetVM, SSHKey: "key/barkpark", Done: map[string]string{"vm": "x"}}
	st.Out.IP = "20.1.2.3"
	writeTestState(t, st)
	return f
}

func writeTestState(t *testing.T, st instanceUpState) {
	t.Helper()
	b, _ := json.Marshal(st)
	if err := os.WriteFile(instanceUpStateFile, b, 0o600); err != nil {
		t.Fatal(err)
	}
}

func runFetch(t *testing.T, args ...string) (string, string, int) {
	t.Helper()
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	g := globals{output: "table", outputSet: true}
	w.applyGlobals(g)
	code := runInstance(w, g, append([]string{"backup", "fetch"}, args...))
	return stdout.String(), stderr.String(), code
}

func TestBackupFetchTakesTheNewest(t *testing.T) {
	f := stubFetch(t)
	f.list = "/var/backups/barkpark/2026-11-17\n/var/backups/barkpark/2026-11-18\n/var/backups/barkpark/2026-11-16\n"
	f.tars["2026-11-18"] = backupTar(t, "2026-11-18", nil)
	stdout, stderr, code := runFetch(t, "--to", "copies")
	if code != exitOK {
		t.Fatalf("exit %d: %s", code, stderr)
	}
	if len(f.streams) != 1 || !strings.HasSuffix(f.streams[0], "azureuser@20.1.2.3 sudo tar -C /var/backups/barkpark -cf - 2026-11-18") ||
		!strings.Contains(f.streams[0], "-i key/barkpark") || !strings.Contains(f.streams[0], "UserKnownHostsFile="+instanceUpStateFile+".known_hosts") {
		t.Errorf("streams = %v", f.streams)
	}
	if !strings.Contains(stdout, "fetched 2026-11-18") {
		t.Errorf("stdout %q", stdout)
	}
	if _, err := checkFetchedBackup(filepath.Join("copies", "2026-11-18")); err != nil {
		t.Errorf("fetched copy: %v", err)
	}
	for _, m := range []string{instanceBackupDB, instanceBackupMedia, instanceBackupManifest} {
		if fi, err := os.Stat(filepath.Join("copies", "2026-11-18", m)); err != nil || fi.Mode().Perm() != 0o600 {
			t.Errorf("%s: %v %v", m, fi, err)
		}
	}
	entries, _ := os.ReadDir("copies")
	if len(entries) != 1 {
		t.Errorf("copies holds %d entries, want only the backup", len(entries))
	}

	// Again: already here, nothing streamed.
	f.streams = nil
	stdout, _, code = runFetch(t, "--to", "copies")
	if code != exitOK || len(f.streams) != 0 || !strings.Contains(stdout, "already here") {
		t.Errorf("second fetch: exit %d streams %v stdout %q", code, f.streams, stdout)
	}
}

func TestBackupFetchByName(t *testing.T) {
	f := stubFetch(t)
	f.list = "/var/backups/barkpark/2026-11-17\n/var/backups/barkpark/2026-11-18\n"
	f.tars["2026-11-17"] = backupTar(t, "2026-11-17", nil)
	if _, stderr, code := runFetch(t, "--to", "copies", "--name", "2026-11-17"); code != exitOK {
		t.Fatalf("exit %d: %s", code, stderr)
	}
	if _, err := os.Stat(filepath.Join("copies", "2026-11-17", instanceBackupDB)); err != nil {
		t.Error(err)
	}
	if _, stderr, code := runFetch(t, "--to", "copies", "--name", "2026-01-01"); code == exitOK || !strings.Contains(stderr, "2026-11-17, 2026-11-18") {
		t.Errorf("unknown name: exit %d %s", code, stderr)
	}
}

func TestBackupFetchRefusesABadCopy(t *testing.T) {
	for name, tarball := range map[string]func(t *testing.T) []byte{
		"checksum": func(t *testing.T) []byte {
			return backupTar(t, "b1", func(m map[string][]byte) { m[instanceBackupDB] = []byte("changed in transit") })
		},
		"extra member": func(t *testing.T) []byte { return backupTar(t, "b1", nil, "b1/../../evil") },
		"other path":   func(t *testing.T) []byte { return backupTar(t, "b1", nil, "etc/passwd") },
	} {
		t.Run(name, func(t *testing.T) {
			f := stubFetch(t)
			f.list = "/var/backups/barkpark/b1\n"
			f.tars["b1"] = tarball(t)
			_, stderr, code := runFetch(t, "--to", "copies")
			if code == exitOK {
				t.Fatalf("a bad copy was accepted")
			}
			entries, _ := os.ReadDir("copies")
			if len(entries) != 0 {
				t.Errorf("copies keeps %v after: %s", entries, stderr)
			}
		})
	}
}

func TestBackupFetchUsage(t *testing.T) {
	f := stubFetch(t)
	f.list = "/var/backups/barkpark/2026-11-18\n/var/backups/barkpark/bad name;rm\n"
	for _, c := range []struct {
		args []string
		want string
	}{
		{nil, "--to <dir> is required"},
		{[]string{"--to", "c", "--name", "../etc"}, "--name"},
		{[]string{"--to", "c", "--name", "a;b"}, "--name"},
		{[]string{"--to", "c", "--remote-dir", "/var/x;rm -rf /"}, "--remote-dir"},
		{[]string{"--to", "c", "--remote-dir", "/var/../etc"}, "--remote-dir"},
		{[]string{"--to", "c", "--ssh-host", "-oProxyCommand=x"}, "--ssh-host"},
	} {
		if _, stderr, code := runFetch(t, c.args...); code != exitUsage || !strings.Contains(stderr, c.want) {
			t.Errorf("%v: exit %d %q, want %q", c.args, code, stderr, c.want)
		}
	}
	if len(f.streams) != 0 {
		t.Errorf("a usage error streamed: %v", f.streams)
	}
	_ = os.Remove(instanceUpStateFile)
	if _, stderr, code := runFetch(t, "--to", "c"); code != exitUsage || !strings.Contains(stderr, "--ssh-host") {
		t.Errorf("no state file: exit %d %q", code, stderr)
	}
	// A listed name that is not plain is never fetched.
	f.list = "/var/backups/barkpark/x y\n"
	if _, _, code := runFetch(t, "--to", "c", "--ssh-host", "azureuser@20.1.2.3"); code == exitOK {
		t.Errorf("a name with a space was fetched")
	}
}

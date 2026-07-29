package cli

// sites_tarball_test.go covers the tarball ignore-set builder. loadGitignore
// reads `<root>/.gitignore` line by line; the scanner is hardened to a 1MB
// token cap and falls back to the safe defaults on any read/oversize error so a
// pathological .gitignore never silently drops entries the user meant to keep.

import (
	"archive/tar"
	"compress/gzip"
	"crypto/sha256"
	"encoding/hex"
	"io"
	"math/rand"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestTarballMaxBytesAbortsEarly proves the MaxBytes cap trips mid-file rather
// than after a single oversized file has fully streamed to the upload. The
// archive reader is drained to completion; we assert it errors AND that the
// bytes emitted before the error are far below the full file size — i.e. the
// LimitReader bound stopped the copy near the budget instead of at EOF.
func TestTarballMaxBytesAbortsEarly(t *testing.T) {
	dir := t.TempDir()

	const maxBytes = 64 * 1024
	const fileSize = 4 * 1024 * 1024 // 64x the cap

	// Incompressible payload so the emitted (gzip) byte count tracks the number
	// of file bytes actually copied — a repetitive file would gzip to nothing
	// and hide a runaway copy.
	buf := make([]byte, fileSize)
	if _, err := rand.New(rand.NewSource(1)).Read(buf); err != nil {
		t.Fatalf("fill payload: %v", err)
	}
	if err := os.WriteFile(filepath.Join(dir, "big.bin"), buf, 0o644); err != nil {
		t.Fatalf("write big.bin: %v", err)
	}

	// Non-nil empty Ignores keeps loadGitignore (and its defaults) out of the way.
	r, err := streamTarball(tarballOptions{Root: dir, Ignores: []string{}, MaxBytes: maxBytes})
	if err != nil {
		t.Fatalf("streamTarball: %v", err)
	}
	defer r.Close()

	emitted, err := io.Copy(io.Discard, r)
	if err == nil {
		t.Fatalf("expected size-exceeded error, got nil (emitted %d bytes)", emitted)
	}
	if !strings.Contains(err.Error(), "exceeds") {
		t.Fatalf("expected size-exceeded error, got: %v", err)
	}
	// The offending file overshoots the budget by at most one byte, so the
	// compressed stream should be near the cap — nowhere near the 4 MB file.
	// Allow generous slack for gzip/tar framing.
	const slack = 128 * 1024
	if emitted > maxBytes+slack {
		t.Fatalf("emitted %d bytes before abort — cap did not stop the copy early (max %d + slack %d)", emitted, maxBytes, slack)
	}
}

func TestLoadGitignoreLongLine(t *testing.T) {
	cases := []struct {
		name    string
		content string
	}{
		{
			name:    "over-64KB line before a real entry",
			content: strings.Repeat("a", 70*1024) + "\nsecret/\n",
		},
		{
			name:    "over-64KB line after a real entry",
			content: "secret/\n" + strings.Repeat("a", 70*1024) + "\n",
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			dir := t.TempDir()
			if err := os.WriteFile(filepath.Join(dir, ".gitignore"), []byte(tc.content), 0o644); err != nil {
				t.Fatalf("write .gitignore: %v", err)
			}
			var found bool
			for _, l := range loadGitignore(dir) {
				if l == "secret/" {
					found = true
					break
				}
			}
			if !found {
				t.Fatalf("loadGitignore dropped \"secret/\" — the long line truncated the scan")
			}
		})
	}
}

// TestTarballExcludesDotenvSecrets proves the default ignore family keeps a
// secret-bearing `.env.production` out of the deploy tarball even when no
// .gitignore lists it (Ignores:nil → loadGitignore → defaults). A leaked
// production dotenv is the exact secret path this guards.
func TestTarballExcludesDotenvSecrets(t *testing.T) {
	dir := t.TempDir()

	if err := os.WriteFile(filepath.Join(dir, ".env.production"), []byte("API_KEY=supersecret\n"), 0o644); err != nil {
		t.Fatalf("write .env.production: %v", err)
	}
	if err := os.WriteFile(filepath.Join(dir, "app.js"), []byte("console.log('hi')\n"), 0o644); err != nil {
		t.Fatalf("write app.js: %v", err)
	}

	// Ignores:nil so streamTarball falls through to loadGitignore, which layers
	// defaultTarballIgnores (the dotenv family) on top.
	r, err := streamTarball(tarballOptions{Root: dir, Ignores: nil})
	if err != nil {
		t.Fatalf("streamTarball: %v", err)
	}
	defer r.Close()

	names := tarEntryNames(t, r)
	if _, ok := names[".env.production"]; ok {
		t.Fatalf(".env.production was packed into the tarball — secret leak; entries: %v", names)
	}
	if _, ok := names["app.js"]; !ok {
		t.Fatalf("app.js missing from the tarball — the ignore set over-excluded; entries: %v", names)
	}
}

// TestLoadGitignoreOversizeLineKeepsParsedEntries proves the scanner.Err()
// fallback now UNIONS the entries parsed before the >1MB line with the defaults
// instead of discarding them. A user's `secrets/` entry preceding a pathological
// line must survive, and the defaults (e.g. .git) must still be present.
func TestLoadGitignoreOversizeLineKeepsParsedEntries(t *testing.T) {
	dir := t.TempDir()

	// `secrets/` first, then a line past the 1MB scanner cap so scanner.Err()
	// fires and the fallback branch runs.
	content := "secrets/\n" + strings.Repeat("a", 2<<20) + "\n"
	if err := os.WriteFile(filepath.Join(dir, ".gitignore"), []byte(content), 0o644); err != nil {
		t.Fatalf("write .gitignore: %v", err)
	}

	got := loadGitignore(dir)

	var haveSecrets, haveGit bool
	for _, l := range got {
		switch strings.TrimRight(l, "/") {
		case "secrets":
			haveSecrets = true
		case ".git":
			haveGit = true
		}
	}
	if !haveSecrets {
		t.Fatalf("loadGitignore discarded user entry \"secrets/\" on the oversize-line fallback; got %v", got)
	}
	if !haveGit {
		t.Fatalf("loadGitignore dropped the defaults (.git) on the oversize-line fallback; got %v", got)
	}
}

// tarEntryNames drains a gzip'd tar stream and returns the set of entry names
// (trailing slash trimmed so a dir and its file key the same way).
func tarEntryNames(t *testing.T, r io.Reader) map[string]struct{} {
	t.Helper()
	gz, err := gzip.NewReader(r)
	if err != nil {
		t.Fatalf("gzip reader: %v", err)
	}
	defer gz.Close()
	names := make(map[string]struct{})
	tr := tar.NewReader(gz)
	for {
		hdr, err := tr.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			t.Fatalf("tar next: %v", err)
		}
		names[strings.TrimRight(hdr.Name, "/")] = struct{}{}
	}
	return names
}

// --- prebuilt packer (charter D93) -------------------------------------------
//
// The prebuilt lane packs BUILD OUTPUT — the exact payload the project packer is
// designed to throw away. These tests pin both halves: the explicit ignore list
// keeps the output and drops secrets, and the nil/[] hazards cannot be reached
// by accident.

// writePrebuiltFixture lays down a dist/-shaped tree: a root index.html, a
// hashed-asset dir, a page route literally named `build` (a real site can route
// /build/, and `build` is on defaultTarballIgnores — so it is the control that
// proves WHICH ignore list ran), an empty directory, a symlink, an executable
// file, and a `.env` a framework dropped next to the assets.
func writePrebuiltFixture(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	mk := func(rel, body string, mode os.FileMode) {
		t.Helper()
		full := filepath.Join(dir, rel)
		if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
			t.Fatalf("mkdir %s: %v", rel, err)
		}
		if err := os.WriteFile(full, []byte(body), mode); err != nil {
			t.Fatalf("write %s: %v", rel, err)
		}
	}
	mk("index.html", `<html><head><meta name="bp-build-id" content="abc123"></head><body>hi</body></html>`, 0o644)
	mk("_astro/app.a1b2.css", "body{color:red}", 0o644)
	mk("build/index.html", "<html>a page route named build</html>", 0o644)
	mk("404.html", "<html>gone</html>", 0o644)
	mk("run.sh", "#!/bin/sh\necho hi\n", 0o755)
	mk(".env", "SECRET=hunter2\n", 0o600)
	if err := os.MkdirAll(filepath.Join(dir, "empty-dir"), 0o755); err != nil {
		t.Fatalf("mkdir empty-dir: %v", err)
	}
	if err := os.Symlink("index.html", filepath.Join(dir, "home.html")); err != nil {
		t.Fatalf("symlink: %v", err)
	}
	return dir
}

// tarEntry is one decoded archive member — enough of it to prove a round trip.
type tarEntry struct {
	typeflag byte
	mode     int64
	link     string
	body     string
}

func readTarGzFile(t *testing.T, path string) map[string]tarEntry {
	t.Helper()
	f, err := os.Open(path)
	if err != nil {
		t.Fatalf("open archive: %v", err)
	}
	defer f.Close()
	gz, err := gzip.NewReader(f)
	if err != nil {
		t.Fatalf("gzip: %v", err)
	}
	defer gz.Close()
	out := map[string]tarEntry{}
	tr := tar.NewReader(gz)
	for {
		hdr, err := tr.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			t.Fatalf("tar next: %v", err)
		}
		body, err := io.ReadAll(tr)
		if err != nil {
			t.Fatalf("tar read %s: %v", hdr.Name, err)
		}
		out[strings.TrimRight(hdr.Name, "/")] = tarEntry{
			typeflag: hdr.Typeflag,
			mode:     hdr.Mode,
			link:     hdr.Linkname,
			body:     string(body),
		}
	}
	return out
}

func tarEntryKeys(m map[string]tarEntry) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	return out
}

// TestPackPrebuiltDirShipsTheBuildOutput is the round trip: every file survives
// byte-for-byte with its mode, the empty dir and the symlink survive, index.html
// lands at the ARCHIVE ROOT with no dist/ prefix, `.env` is gone — and the same
// fixture packed the DEFAULT way loses `build/index.html`, which is what "today's
// packer would delete the payload" means in one assertion.
func TestPackPrebuiltDirShipsTheBuildOutput(t *testing.T) {
	dir := writePrebuiltFixture(t)

	art, err := packPrebuiltDir(dir)
	if err != nil {
		t.Fatalf("packPrebuiltDir: %v", err)
	}
	defer art.Cleanup()

	entries := readTarGzFile(t, art.Path)

	// index.html at the archive ROOT — the box extracts straight into the release
	// dir, so a `dist/` prefix would bury the site one level down.
	idx, ok := entries["index.html"]
	if !ok {
		t.Fatalf("index.html missing from archive root; entries: %v", tarEntryKeys(entries))
	}
	if !strings.Contains(idx.body, "bp-build-id") {
		t.Fatalf("index.html body did not round-trip: %q", idx.body)
	}
	for _, name := range []string{"_astro/app.a1b2.css", "build/index.html", "404.html", "run.sh"} {
		if _, ok := entries[name]; !ok {
			t.Fatalf("%s missing from prebuilt archive; entries: %v", name, tarEntryKeys(entries))
		}
	}
	if got := entries["_astro/app.a1b2.css"].body; got != "body{color:red}" {
		t.Fatalf("asset body drifted: %q", got)
	}
	if got := entries["run.sh"].mode; got&0o111 == 0 {
		t.Fatalf("executable bit lost: mode %o", got)
	}
	if e, ok := entries["empty-dir"]; !ok || e.typeflag != tar.TypeDir {
		t.Fatalf("empty dir did not survive: %+v ok=%v", e, ok)
	}
	if e, ok := entries["home.html"]; !ok || e.typeflag != tar.TypeSymlink || e.link != "index.html" {
		t.Fatalf("symlink did not survive as a symlink: %+v ok=%v", e, ok)
	}
	if _, ok := entries[".env"]; ok {
		t.Fatalf(".env was packed — the prebuilt ignore list must keep secrets off the wire")
	}

	// The digest is over the bytes on disk, i.e. the exact wire bytes.
	raw, err := os.ReadFile(art.Path)
	if err != nil {
		t.Fatalf("read archive: %v", err)
	}
	if int64(len(raw)) != art.WireBytes {
		t.Fatalf("WireBytes=%d but the file is %d bytes", art.WireBytes, len(raw))
	}
	sum := sha256.Sum256(raw)
	if hex.EncodeToString(sum[:]) != art.SHA256 {
		t.Fatalf("sha256 %s does not match the archive bytes %s", art.SHA256, hex.EncodeToString(sum[:]))
	}

	// The control: the DEFAULT ignore path (nil Ignores → loadGitignore → the
	// project defaults) strips a page route named `build`, because isIgnored
	// matches any path SEGMENT. That is the payload deletion, reproduced.
	r, err := streamTarball(tarballOptions{Root: dir})
	if err != nil {
		t.Fatalf("streamTarball default: %v", err)
	}
	defer r.Close()
	def := tarEntryNames(t, r)
	if _, ok := def["build/index.html"]; ok {
		t.Fatalf("default ignores kept build/index.html — the control no longer proves anything")
	}
	if _, ok := def["build"]; ok {
		// The dir header survives as an empty entry: not an obviously empty
		// archive, a hollow shell that uploads, deploys and 404s.
		t.Logf("default archive kept a HOLLOW build/ dir entry with no contents — the shell D93 describes")
	}
}

// TestBufferTarballRefusesNilIgnores pins BOTH nil/[] hazards. `Ignores` is
// nil-sensitive in two directions: nil silently reaches loadGitignore and the
// payload-deleting project defaults, while an empty slice ignores NOTHING —
// including `.env`. Neither is a safe default for build output, so the prebuilt
// path refuses nil outright instead of quietly picking one.
func TestBufferTarballRefusesNilIgnores(t *testing.T) {
	dir := writePrebuiltFixture(t)

	if _, err := bufferTarball(tarballOptions{Root: dir}); err == nil {
		t.Fatalf("nil Ignores must be refused — it is the payload-deleting default")
	} else if !strings.Contains(err.Error(), "nil") {
		t.Fatalf("the refusal must name the nil hazard, got: %v", err)
	}

	// The other direction, demonstrated rather than asserted in prose: [] packs
	// the secret. This is why the prebuilt list is constructed explicitly.
	art, err := bufferTarball(tarballOptions{Root: dir, Ignores: []string{}})
	if err != nil {
		t.Fatalf("bufferTarball with []: %v", err)
	}
	defer art.Cleanup()
	if _, ok := readTarGzFile(t, art.Path)[".env"]; !ok {
		t.Fatalf("empty Ignores was expected to pack .env — if it no longer does, this test's premise (and the explicit list) needs rewriting")
	}

	// And the list the prebuilt lane actually passes is neither of those.
	if len(prebuiltTarballIgnores) == 0 {
		t.Fatalf("prebuiltTarballIgnores must be explicitly populated; nil and empty are the two hazards above")
	}
}

// TestPackPrebuiltDirRefusesOverTheWireCap: the client cap is stated in the
// SERVER's units — wire bytes — and it is checked while the artifact is still a
// temp file, i.e. before any connection is opened. The old streaming shape could
// not do this: a chunked upload declares Content-Length -1, so the client pushes
// its whole payload before anyone can say no.
func TestPackPrebuiltDirRefusesOverTheWireCap(t *testing.T) {
	dir := writePrebuiltFixture(t)
	orig := prebuiltMaxWireBytes
	prebuiltMaxWireBytes = 1 // any real archive is bigger than this
	t.Cleanup(func() { prebuiltMaxWireBytes = orig })

	art, err := packPrebuiltDir(dir)
	if err == nil {
		art.Cleanup()
		t.Fatalf("an over-cap artifact must be refused")
	}
	if !strings.Contains(err.Error(), "on the wire") {
		t.Fatalf("the refusal must state the cap in wire bytes, got: %v", err)
	}
}

// TestValidatePrebuiltDirRefusals covers the guards the packer does not give:
// an empty dir packs SILENTLY into a valid zero-entry archive, and a project
// directory handed to --prebuilt by mistake would ship source. Both are refused
// with DISTINCT messages, before any network call.
func TestValidatePrebuiltDirRefusals(t *testing.T) {
	empty := t.TempDir()
	_, err := validatePrebuiltDir(empty)
	if err == nil || !strings.Contains(err.Error(), "is empty") {
		t.Fatalf("an empty dir must be refused as empty, got: %v", err)
	}

	noIndex := t.TempDir()
	if werr := os.WriteFile(filepath.Join(noIndex, "package.json"), []byte("{}"), 0o644); werr != nil {
		t.Fatalf("write: %v", werr)
	}
	_, err = validatePrebuiltDir(noIndex)
	if err == nil || !strings.Contains(err.Error(), "no index.html") {
		t.Fatalf("a dir without a root index.html must be refused for that reason, got: %v", err)
	}
	if strings.Contains(err.Error(), "is empty") {
		t.Fatalf("the two refusals must not share a message: %v", err)
	}

	if _, err := validatePrebuiltDir(filepath.Join(empty, "nope")); err == nil {
		t.Fatalf("a missing directory must be refused")
	}
	if _, err := validatePrebuiltDir(""); err == nil {
		t.Fatalf("an empty --prebuilt value must be refused")
	}
}

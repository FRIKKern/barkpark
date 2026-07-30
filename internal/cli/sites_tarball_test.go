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
// proves WHICH ignore list ran), an empty directory, an executable file, and a
// `.env` a framework dropped next to the assets.
//
// It carries NO symlink. It used to, and the fixture was the bug: a contained
// symlink is now a client-side refusal (charter D120), so a fixture that packs
// one could not reach the packer at all. addPrettyURLSymlink adds one back for
// the tests that are ABOUT that refusal.
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
	return dir
}

// addPrettyURLSymlink adds the live vector: a hand-made `home.html -> index.html`
// alias INSIDE the dist. It escapes nothing, so no traversal guard would ever
// name it — and the box refuses it anyway, because a staged symlink is SERVED.
func addPrettyURLSymlink(t *testing.T, dir string) {
	t.Helper()
	if err := os.Symlink("index.html", filepath.Join(dir, "home.html")); err != nil {
		t.Fatalf("symlink: %v", err)
	}
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
// byte-for-byte with its mode, the empty dir survives, index.html lands at the
// ARCHIVE ROOT with no dist/ prefix, `.env` is gone, a contained symlink is
// REFUSED — and the same fixture packed the DEFAULT way loses
// `build/index.html`, which is what "today's packer would delete the payload"
// means in one assertion.
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
	// THE FLIPPED ASSERTION (charter D120 — a CONTRACT CHANGE, not a deleted
	// guard). This used to assert that `home.html -> index.html` SURVIVED as
	// typeflag 2. Surviving was the defect: the box's stage/4 answers E_SYMLINK on
	// that entry and throws the whole upload away, after the deployment is already
	// minted. The client now refuses it first, by name. TestPackPrebuiltDirRefuses
	// ContainedSymlink below proves both halves on raw bytes.
	symDir := writePrebuiltFixture(t)
	addPrettyURLSymlink(t, symDir)
	if _, err := packPrebuiltDir(symDir); err == nil {
		t.Fatalf("a contained symlink must be refused by the preflight, not packed as typeflag 2")
	} else if !strings.Contains(err.Error(), "home.html") || !strings.Contains(err.Error(), "E_SYMLINK") {
		t.Fatalf("the symlink refusal must name the path and the box's code, got: %v", err)
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

// --- the client never ships what the box will refuse (wave 11) ---------------
//
// Everything below was established by reading RAW 512-byte BLOCKS out of the
// REAL packer, not by reading code that reads bytes. The extractor's own accept
// list (Barkpark.Sites.PrebuiltArtifact.entry_type/1) is regular file ('0'/NUL)
// and directory ('5'); every other byte at offset 156 is a typed refusal there.

// packWithTheRealPacker packs `dir` with the REAL prebuilt packer (bufferTarball
// + streamTarball + writeTarball — every line the wire bytes go through, minus
// the validate the preflight now owns) and returns the entries it actually
// emitted, decoded from the gzip'd tar.
func packWithTheRealPacker(t *testing.T, dir string) map[string]tarEntry {
	t.Helper()
	art, err := bufferTarball(tarballOptions{
		Root:     dir,
		Ignores:  prebuiltTarballIgnores,
		MaxBytes: prebuiltMaxUncompressedBytes,
	})
	if err != nil {
		t.Fatalf("bufferTarball: %v", err)
	}
	t.Cleanup(art.Cleanup)
	return readTarGzFile(t, art.Path)
}

// TestPackPrebuiltDirRefusesContainedSymlink is the FAIL-BEFORE and the fix in
// one test.
//
// FAIL-BEFORE, on the real packer's bytes: writeTarball emits `home.html` with
// typeflag 2 (tar.TypeSymlink) and linkname `index.html`. Those bytes are DEAD ON
// ARRIVAL — api/lib/barkpark/sites/prebuilt_artifact.ex answers
//
//	{:error, "E_SYMLINK", "the archive contains a symlink — refused (a staged
//	 symlink is SERVED)"}
//
// and never creates the destination. The deployment has already been minted with
// a nonced build id by then, so today the user pays a round trip to learn it.
//
// THE FIX: the same tree is refused locally, first, naming the path, its target
// and the fix.
func TestPackPrebuiltDirRefusesContainedSymlink(t *testing.T) {
	dir := writePrebuiltFixture(t)
	addPrettyURLSymlink(t, dir)

	// FAIL-BEFORE: the packer itself still emits the symlink verbatim. This is not
	// a mock of the packer — it IS the packer's bytes.
	entries := packWithTheRealPacker(t, dir)
	home, ok := entries["home.html"]
	if !ok {
		t.Fatalf("the packer no longer emits home.html at all; entries: %v", tarEntryKeys(entries))
	}
	if home.typeflag != tar.TypeSymlink || home.link != "index.html" {
		t.Fatalf("fail-before premise broken: home.html is typeflag %q link %q, expected 2/index.html — the E_SYMLINK refusal this test guards would no longer trigger", string(home.typeflag), home.link)
	}
	t.Logf("fail-before: real packer emitted home.html typeflag=%q link=%q → box answers E_SYMLINK", string(home.typeflag), home.link)

	// THE FIX: refused locally, before any mint.
	_, verr := validatePrebuiltDir(dir)
	if verr == nil {
		t.Fatalf("validatePrebuiltDir must refuse a contained symlink")
	}
	for _, want := range []string{"home.html", "index.html", "E_SYMLINK", "a staged symlink is SERVED", "cp "} {
		if !strings.Contains(verr.Error(), want) {
			t.Fatalf("the refusal must carry %q (path, target, the box's own code, the fix); got: %v", want, verr)
		}
	}

	// And the whole packer refuses too, since packPrebuiltDir validates first.
	if _, perr := packPrebuiltDir(dir); perr == nil || perr.Error() != verr.Error() {
		t.Fatalf("packPrebuiltDir must refuse with the SAME string as validatePrebuiltDir:\n  pack:     %v\n  validate: %v", perr, verr)
	}
}

// TestPrebuiltRefusalReachesBothCallSites drives BOTH entry points and compares
// the rendered refusal. cloud_site_cmd.go's deploy branch validates PRE-MINT —
// above siteCloudConfig and resolveOpenSiteID — so this test opens no socket and
// needs no config: the refusal returns before any of that runs.
//
// It asserts the usage/exitUsage shape, NOT failed/exitGeneric. The post-mint arm
// inside runCloudSitePrebuiltDeploy does render exitGeneric, but the pre-mint arm
// always fires first on the real command, so asserting the generic shape would be
// asserting an unreachable branch.
func TestPrebuiltRefusalReachesBothCallSites(t *testing.T) {
	dir := writePrebuiltFixture(t)
	addPrettyURLSymlink(t, dir)

	var stdout, stderr strings.Builder
	w := newWriter(&stdout, &stderr)
	code := runCloudSiteDeploy(w, globals{}, []string{"some-site", "--prebuilt", dir, "--no-follow"})
	if code != exitUsage {
		t.Fatalf("the pre-mint refusal renders as usage/exitUsage; got exit %d (stdout=%q stderr=%q)", code, stdout.String(), stderr.String())
	}

	// Call site 2: the packer's own validate. Byte-identical message.
	_, perr := packPrebuiltDir(dir)
	if perr == nil {
		t.Fatalf("packPrebuiltDir must refuse the same tree")
	}
	if !strings.Contains(stderr.String(), perr.Error()) {
		t.Fatalf("the two call sites must emit the same refusal string:\n  cli:  %q\n  pack: %q", stderr.String(), perr.Error())
	}
}

// TestValidatePrebuiltDirResolvesASymlinkedRoot: `dist -> packages/site/dist` is
// the monorepo shape. os.Stat and os.ReadDir FOLLOW it, so every D93 guard used
// to pass — and then filepath.Walk LSTATS the root, sees a non-directory, calls
// its walkFn once with rel="." and returns, producing a valid archive with ZERO
// entries. The fail-before count is asserted, not described.
func TestValidatePrebuiltDirResolvesASymlinkedRoot(t *testing.T) {
	base := t.TempDir()
	real := filepath.Join(base, "packages", "site", "dist")
	if err := os.MkdirAll(real, 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	if err := os.WriteFile(filepath.Join(real, "index.html"), []byte(`<meta name="bp-build-id" content="abc123">`), 0o644); err != nil {
		t.Fatalf("write: %v", err)
	}
	if err := os.WriteFile(filepath.Join(real, "app.css"), []byte("body{}"), 0o644); err != nil {
		t.Fatalf("write: %v", err)
	}
	link := filepath.Join(base, "dist")
	if err := os.Symlink(real, link); err != nil {
		t.Fatalf("symlink root: %v", err)
	}

	// FAIL-BEFORE: hand the packer the UNRESOLVED path, which is exactly what main
	// passed, and count the entries.
	before := packWithTheRealPacker(t, link)
	if len(before) != 0 {
		t.Fatalf("fail-before premise broken: packing a symlinked root emitted %d entries (%v); it used to emit ZERO", len(before), tarEntryKeys(before))
	}
	art, err := bufferTarball(tarballOptions{Root: link, Ignores: prebuiltTarballIgnores, MaxBytes: prebuiltMaxUncompressedBytes})
	if err != nil {
		t.Fatalf("bufferTarball: %v", err)
	}
	defer art.Cleanup()
	t.Logf("fail-before: symlinked root packed %d wire bytes, entries: 0 → box answers E_MALFORMED \"the archive holds no entries\"", art.WireBytes)

	// THE FIX: validate resolves the root, so the packer walks the real tree.
	abs, verr := validatePrebuiltDir(link)
	if verr != nil {
		t.Fatalf("a symlinked dist root must resolve (or be refused by name), got: %v", verr)
	}
	if abs == link {
		t.Fatalf("validatePrebuiltDir returned the unresolved symlink %q — the packer would walk it and emit zero entries", abs)
	}
	fixed, perr := packPrebuiltDir(link)
	if perr != nil {
		t.Fatalf("packPrebuiltDir over a symlinked root: %v", perr)
	}
	defer fixed.Cleanup()
	after := readTarGzFile(t, fixed.Path)
	for _, name := range []string{"index.html", "app.css"} {
		if _, ok := after[name]; !ok {
			t.Fatalf("%s missing after the fix; entries: %v", name, tarEntryKeys(after))
		}
	}
}

// TestPrebuiltNameShapeMatchesTheRealPackerByte156 is the differential that makes
// the preflight's verdict trustworthy: for each name shape, the DRY ENCODE's
// verdict is compared against the typeflags the REAL packer wrote for the same
// tree, read out of the raw 512-byte blocks. No predicate is asserted — Go's
// USTAR/PAX election lives in the unexported Header.allowedFormats, and the
// trigger is UNSPLITTABILITY, not length. Measured on go1.26.2: a 141-byte path
// that splits at a '/' takes no PAX; a 121-byte DIRECTORY component does, and the
// PAX lands on the DIRECTORY entry, not on its 137-byte child.
func TestPrebuiltNameShapeMatchesTheRealPackerByte156(t *testing.T) {
	long121 := strings.Repeat("d", 121)
	deep := strings.TrimRight(strings.Repeat("ab/", 26), "/")

	cases := []struct {
		label   string
		rel     string
		wantPax bool
		// paxOn names the entry the refusal must name, which is not always the
		// file: for long121 the PAX header lands on the DIRECTORY.
		paxOn string
	}{
		{label: "plain ascii", rel: "blog/post.html", wantPax: false},
		{label: "accented NFC leaf", rel: "blog/hvorfor-nå.html", wantPax: true, paxOn: "blog/hvorfor-nå.html"},
		{label: "accented directory", rel: "kafé/index.html", wantPax: true, paxOn: "kafé"},
		{label: "121-byte unsplittable DIRECTORY component — the DIRECTORY is the trigger, not its 137-byte child", rel: long121 + "/leaf.html", wantPax: true, paxOn: long121},
		{label: "141-byte path splittable at '/' — a length predicate would be WRONG here", rel: strings.Repeat("a", 60) + "/" + strings.Repeat("b", 60) + "/" + strings.Repeat("c", 14) + ".html", wantPax: false},
		{label: "deep 26-segment short-component path", rel: deep + "/i.html", wantPax: false},
	}

	for _, tc := range cases {
		dir := t.TempDir()
		if err := os.WriteFile(filepath.Join(dir, "index.html"), []byte(`<meta name="bp-build-id" content="abc123">`), 0o644); err != nil {
			t.Fatalf("write index: %v", err)
		}
		full := filepath.Join(dir, filepath.FromSlash(tc.rel))
		if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
			t.Fatalf("%s: mkdir: %v", tc.label, err)
		}
		if err := os.WriteFile(full, []byte("x"), 0o644); err != nil {
			t.Fatalf("%s: write: %v", tc.label, err)
		}

		// GROUND TRUTH: the raw 512-byte blocks the real packer produced.
		flags := rawBlockTypeflags(t, dir)
		gotRealPax := false
		for _, f := range flags {
			if f == 'x' {
				gotRealPax = true
			}
		}
		if gotRealPax != tc.wantPax {
			t.Fatalf("%s: REAL PACKER emitted pax=%v, expected %v (raw block typeflags: %s)", tc.label, gotRealPax, tc.wantPax, flagString(flags))
		}

		// THE PREFLIGHT: same verdict, from a dry encode, over the same walk.
		verr := preflightPrebuiltEntries(dir, "./dist")
		if tc.wantPax && verr == nil {
			t.Fatalf("%s: the real packer emitted a pax header but the preflight allowed it", tc.label)
		}
		if !tc.wantPax && verr != nil {
			t.Fatalf("%s: the real packer emitted plain USTAR headers but the preflight refused: %v", tc.label, verr)
		}
		if tc.wantPax {
			if !strings.Contains(verr.Error(), tc.paxOn) {
				t.Fatalf("%s: the refusal must name the offending path %q, got: %v", tc.label, tc.paxOn, verr)
			}
			for _, want := range []string{"E_UNKNOWN_TYPE", "extension header"} {
				if !strings.Contains(verr.Error(), want) {
					t.Fatalf("%s: the refusal must carry %q, got: %v", tc.label, want, verr)
				}
			}
		}
	}
}

// rawBlockTypeflags walks the REAL packer's output as 512-byte blocks and returns
// every typeflag byte in wire order — the same traversal the Elixir extractor
// performs (header block, then a size-derived body skip). Reading the blocks is
// the point: a verdict about a header format that was not taken from an actual
// block is not evidence.
func rawBlockTypeflags(t *testing.T, dir string) []byte {
	t.Helper()
	art, err := bufferTarball(tarballOptions{Root: dir, Ignores: prebuiltTarballIgnores, MaxBytes: prebuiltMaxUncompressedBytes})
	if err != nil {
		t.Fatalf("bufferTarball: %v", err)
	}
	defer art.Cleanup()
	f, err := os.Open(art.Path)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	defer f.Close()
	gz, err := gzip.NewReader(f)
	if err != nil {
		t.Fatalf("gzip: %v", err)
	}
	defer gz.Close()
	raw, err := io.ReadAll(gz)
	if err != nil {
		t.Fatalf("inflate: %v", err)
	}

	var flags []byte
	for off := 0; off+512 <= len(raw); {
		block := raw[off : off+512]
		if isZeroBlock(block) {
			break
		}
		flags = append(flags, block[156])
		size := octalSizeField(block[124:136])
		off += 512 + int(size) + int((512-(size%512))%512)
	}
	return flags
}

// octalSizeField decodes the tar size field the way the extractor does: NUL/space
// trimmed octal digits.
func octalSizeField(field []byte) int64 {
	var size int64
	for _, c := range field {
		if c < '0' || c > '7' {
			continue
		}
		size = size*8 + int64(c-'0')
	}
	return size
}

func isZeroBlock(b []byte) bool {
	for _, c := range b {
		if c != 0 {
			return false
		}
	}
	return true
}

func flagString(flags []byte) string {
	out := make([]string, 0, len(flags))
	for _, f := range flags {
		out = append(out, string(f))
	}
	return strings.Join(out, ",")
}

// TestPrebuiltPreflightSharesThePackersSkipDirArm: sharing the ignore SET is not enough,
// the CONTROL FLOW is load-bearing. A pax-triggering name under `.git` must
// produce ZERO complaints, because writeTarball returns filepath.SkipDir on an
// ignored directory and therefore never emits it. Measured before this slice: a
// naive walk flagged `.git/refs/heads/café-branch` while the real packer emitted
// only [index.html].
func TestPrebuiltPreflightSharesThePackersSkipDirArm(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "index.html"), []byte(`<meta name="bp-build-id" content="abc123">`), 0o644); err != nil {
		t.Fatalf("write: %v", err)
	}
	refs := filepath.Join(dir, ".git", "refs", "heads")
	if err := os.MkdirAll(refs, 0o755); err != nil {
		t.Fatalf("mkdir .git: %v", err)
	}
	if err := os.WriteFile(filepath.Join(refs, "café-branch"), []byte("deadbeef\n"), 0o644); err != nil {
		t.Fatalf("write ref: %v", err)
	}

	// The real packer's entry list: .git contributes nothing.
	entries := packWithTheRealPacker(t, dir)
	if len(entries) != 1 {
		t.Fatalf("the real packer emitted %d entries (%v); expected only index.html", len(entries), tarEntryKeys(entries))
	}
	if err := preflightPrebuiltEntries(dir, "./dist"); err != nil {
		t.Fatalf("the preflight complained about an entry the packer never emits: %v", err)
	}
	if _, err := validatePrebuiltDir(dir); err != nil {
		t.Fatalf("validatePrebuiltDir must accept this tree: %v", err)
	}
}

// TestPrebuiltPreflightDryEncodeCostsOneBlockAndNoBody pins the two claims that make the
// preflight cheap enough to run twice per deploy: the encode emits exactly one
// 512-byte block for a well-formed name, REGARDLESS of the file's size (a
// 200 000-byte file is never read — tar.Writer writes body bytes only on Write,
// and observedTarTypeflag never Writes and never Closes).
func TestPrebuiltPreflightDryEncodeCostsOneBlockAndNoBody(t *testing.T) {
	dir := t.TempDir()
	big := filepath.Join(dir, "big.bin")
	if err := os.WriteFile(big, make([]byte, 200000), 0o644); err != nil {
		t.Fatalf("write: %v", err)
	}
	info, err := os.Stat(big)
	if err != nil {
		t.Fatalf("stat: %v", err)
	}
	hdr, err := tarHeaderFor(big, "big.bin", info)
	if err != nil {
		t.Fatalf("tarHeaderFor: %v", err)
	}
	if hdr.Size != 200000 {
		t.Fatalf("header size %d — the fixture is not the size this test claims", hdr.Size)
	}
	flag, n, err := observedTarTypeflag(hdr)
	if err != nil {
		t.Fatalf("observedTarTypeflag: %v", err)
	}
	if n != 512 {
		t.Fatalf("a USTAR header must cost exactly one 512-byte block, got %d bytes (a body read would be ~200 704)", n)
	}
	if flag != '0' {
		t.Fatalf("a plain file must encode as typeflag '0', got %q", string(flag))
	}

	// A pax name costs three blocks (extension header + its record + the real
	// header) — still no body.
	hdr.Name = "hvorfor-nå.bin"
	_, paxN, err := observedTarTypeflag(hdr)
	if err != nil {
		t.Fatalf("observedTarTypeflag pax: %v", err)
	}
	if paxN != 1536 {
		t.Fatalf("a pax name must cost three header blocks, got %d bytes", paxN)
	}
}

// TestPrebuiltStageableTypeflagsMatchTheExtractor: the accept list is transcribed
// from api/lib/barkpark/sites/prebuilt_artifact.ex's entry_type/1 table. If it
// ever grows a fourth member, the client would start shipping something the box
// answers with a typed refusal.
func TestPrebuiltStageableTypeflagsMatchTheExtractor(t *testing.T) {
	for flag := range prebuiltStageableTypeflags {
		switch flag {
		case '0', 0, '5':
		default:
			t.Fatalf("prebuiltStageableTypeflags drifted from the extractor's accept list: %q", string(flag))
		}
	}
	if len(prebuiltStageableTypeflags) != 3 {
		t.Fatalf("the extractor stages exactly regular files ('0', NUL) and dirs ('5'); got %d entries", len(prebuiltStageableTypeflags))
	}
}

// TestTarballIgnoreSetVerbatimDifferential pins the factored-out ignore-set build
// against a VERBATIM COPY of the pre-factoring body from streamTarball. It exists
// because the suite going green is VACUOUS evidence for this refactor: measured,
// every Tarball|Prebuilt|Ignore|Gitignore test passes with
// `strings.TrimRight(p, "/")` mutated to a bare `p`.
func TestTarballIgnoreSetVerbatimDifferential(t *testing.T) {
	// legacyIgnoreSet is the body that lived inline in streamTarball before this
	// slice factored it out — copied character for character.
	legacyIgnoreSet := func(root string, ignoresIn []string) map[string]struct{} {
		ignores := ignoresIn
		if ignores == nil {
			ignores = loadGitignore(root)
		}
		ignoreSet := make(map[string]struct{}, len(ignores))
		for _, p := range ignores {
			p = strings.TrimSpace(p)
			if p == "" || strings.HasPrefix(p, "#") {
				continue
			}
			ignoreSet[strings.TrimRight(p, "/")] = struct{}{}
		}
		return ignoreSet
	}

	withGitignore := t.TempDir()
	if err := os.WriteFile(filepath.Join(withGitignore, ".gitignore"), []byte("secrets/\n# a comment\n\n  spaced/  \n!negated\nnode_modules\n"), 0o644); err != nil {
		t.Fatalf("write .gitignore: %v", err)
	}
	noGitignore := t.TempDir()

	cases := []struct {
		label   string
		root    string
		ignores []string
	}{
		{label: "nil + .gitignore present (nil means loadGitignore, NOT empty)", root: withGitignore, ignores: nil},
		{label: "nil + no .gitignore (loadGitignore falls back to the defaults)", root: noGitignore, ignores: nil},
		{label: "empty slice (ignores NOTHING — the other nil hazard)", root: withGitignore, ignores: []string{}},
		{label: "the prebuilt list the deploy lane actually passes", root: noGitignore, ignores: prebuiltTarballIgnores},
		{label: "the project defaults", root: noGitignore, ignores: defaultTarballIgnores},
		{label: "trailing slashes, comments, blanks and whitespace", root: noGitignore, ignores: []string{"dist/", "  build/  ", "", "   ", "# comment", "out"}},
		{label: "a nested path with a trailing slash", root: noGitignore, ignores: []string{"pkg/node_modules/", "a/b/c"}},
	}
	for _, tc := range cases {
		want := legacyIgnoreSet(tc.root, tc.ignores)
		got := tarballIgnoreSet(tc.root, tc.ignores)
		if len(want) != len(got) {
			t.Fatalf("%s: factored set has %d keys, legacy body had %d", tc.label, len(got), len(want))
		}
		for k := range want {
			if _, ok := got[k]; !ok {
				t.Fatalf("%s: factored set is missing legacy key %q", tc.label, k)
			}
		}
		// And the keys are load-bearing, not merely counted: the differential must
		// notice a mutated normalization, so assert the trailing slash is gone.
		for k := range got {
			if strings.HasSuffix(k, "/") && k != "/" {
				t.Fatalf("%s: key %q kept its trailing slash — isIgnored compares against basenames and path SEGMENTS, which never carry one", tc.label, k)
			}
		}
	}
}

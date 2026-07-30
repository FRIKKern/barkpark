package cli

// sites_tarball_pax_test.go is the RAW-BLOCK drift tripwire between this packer
// and the box's extractor (api/lib/barkpark/sites/prebuilt_artifact.ex).
//
// Why it cannot live in sites_tarball_test.go's idiom: every existing typeflag
// assertion in this package reads through `tar.NewReader`, and tar.NewReader
// CONSUMES a PAX ('x') extension header TRANSPARENTLY — it reports the fully
// restored name with typeflag '0' and never hands the 'x' block to the caller.
// So a test written the repo's existing way STRUCTURALLY CANNOT see the header
// the extractor has to have an opinion about. That is exactly how the
// packer→extractor format seam shipped uncaught: `hdr.Name = filepath.ToSlash(rel)`
// on a tar.FileInfoHeader emits a PAX header for any non-ASCII name and for any
// single path component over 100 bytes, and until this wave the extractor
// refused every extension header with E_UNKNOWN_TYPE — our own first-party
// client could not deploy a Norwegian slug.
//
// So this file walks the packer's real output as RAW 512-byte blocks and asserts
// every typeflag it emits is inside the extractor's ACCEPTED set. If Go's header
// policy ever widens (a GNU 'L'/'K', a global 'g', a base-256 size field), this
// test reds HERE, in the client, instead of at a customer's deploy.
//
// Go toolchain pinned for the record: the fallback-name and PAX-emission policy
// is Go's, not ours. Measured on **go1.26.2 darwin/arm64**
// (archive/tar: writeHeader → allowedFormats picks USTAR|PAX|GNU, and a name
// that will not fit the ustar name/prefix split, or carries a byte >0x7f, drops
// USTAR and writes a PAX record block first).

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"encoding/base64"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// paxAcceptedTypeflags is the extractor's accepted set, transcribed from
// `type/1` in api/lib/barkpark/sites/prebuilt_artifact.ex: NUL and '0' (regular),
// '5' (directory), and — as of this wave — 'x' (a pax extension header, whose
// `path`/`size` records are applied and then RE-VALIDATED through the whole of
// name/1 + safe_path/2). Everything else is a typed refusal there: '1' hardlink,
// '2' symlink, '3'/'4'/'6' devices and fifos, 'g' global header, 'L'/'K' the GNU
// long-name extensions.
var paxAcceptedTypeflags = map[byte]string{
	0x00: "regular (NUL)",
	'0':  "regular",
	'5':  "directory",
	'x':  "pax extension header",
}

// writePaxProbeFixture lays down a dist/-shaped tree that FORCES Go down its
// PAX path, twice, for the two independent triggers measured this wave:
//
//   - a NON-ASCII path component (`café/`) — the Norwegian-slug case, and the
//     one that killed the lane on real bytes;
//   - a single path component over 100 bytes (`d…d/` at 120 bytes) — long but
//     UNSPLITTABLE, so the ustar name/prefix split cannot express it. Note the
//     DIRECTORY entry is the trigger here: the leaf `<120>/page.html` splits
//     cleanly into prefix+name and is emitted as a plain ustar block.
//
// Deliberately NO symlink: this fixture has to be stageable by the extractor
// end-to-end, and a symlink is an unconditional E_SYMLINK refusal there. (The
// package's other fixture, writePrebuiltFixture, ships home.html as a typeflag
// '2' symlink on purpose — which is why this tripwire needs its own tree and
// must not be pointed at that one.)
func writePaxProbeFixture(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	// NFC "café" written as explicit bytes so the fixture does not depend on the
	// editor's normalization: c a f U+00E9 = 0x63 0x61 0x66 0xc3 0xa9.
	accented := string([]byte{'c', 'a', 'f', 0xc3, 0xa9})
	longComponent := strings.Repeat("d", 120)

	mustWrite := func(rel, body string) {
		p := filepath.Join(dir, rel)
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatalf("mkdir %s: %v", rel, err)
		}
		if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
			t.Fatalf("write %s: %v", rel, err)
		}
	}

	mustWrite("index.html", "<!doctype html><title>bp</title><h1>hello</h1>")
	mustWrite(filepath.Join(accented, "index.html"), "<!doctype html><title>kafé</title>")
	mustWrite(filepath.Join(longComponent, "page.html"), "<!doctype html><title>long</title>")
	return dir
}

// rawBlock is one 512-byte tar header, read as bytes rather than through any
// reader that would interpret (and hide) it.
type rawBlock struct {
	typeflag byte
	name     string
	size     int64
}

// rawTarBlocks inflates a .tar.gz and walks it as 512-byte blocks: a header, then
// ceil(size/512) body blocks, until the first zero block. This is the same walk
// the Elixir extractor's state machine performs, on purpose — reading the archive
// the way the machine that refuses it reads the archive is the whole point.
func rawTarBlocks(t *testing.T, path string) []rawBlock {
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
	raw, err := io.ReadAll(gz)
	if err != nil {
		t.Fatalf("inflate: %v", err)
	}
	if len(raw)%512 != 0 {
		t.Fatalf("archive is %d bytes, not a whole number of 512-byte blocks", len(raw))
	}

	var out []rawBlock
	zero := make([]byte, 512)
	for off := 0; off+512 <= len(raw); off += 512 {
		block := raw[off : off+512]
		if bytes.Equal(block, zero) {
			break
		}
		size, err := parseOctalField(block[124:136])
		if err != nil {
			t.Fatalf("block at %d: size field %q: %v", off, block[124:136], err)
		}
		out = append(out, rawBlock{
			typeflag: block[156],
			name:     string(bytes.TrimRight(block[0:100], "\x00")),
			size:     size,
		})
		// Skip the body blocks so the next iteration lands on a HEADER. A pax
		// header's body is its record block, and it is padded the same way.
		off += int((size+511)/512) * 512
	}
	return out
}

func parseOctalField(field []byte) (int64, error) {
	s := strings.TrimSpace(string(bytes.TrimRight(field, "\x00")))
	if s == "" {
		return 0, nil
	}
	var v int64
	for _, c := range []byte(s) {
		if c < '0' || c > '7' {
			return 0, fmt.Errorf("not octal: %q", s)
		}
		v = v*8 + int64(c-'0')
	}
	return v, nil
}

func flagSequence(blocks []rawBlock) string {
	parts := make([]string, 0, len(blocks))
	for _, b := range blocks {
		if b.typeflag == 0 {
			parts = append(parts, "NUL")
			continue
		}
		parts = append(parts, string(b.typeflag))
	}
	return strings.Join(parts, " ")
}

// TestPrebuiltPackerEmitsOnlyExtractorAcceptedTypeflags is the tripwire. It reds
// if this packer ever emits a header type the box refuses.
func TestPrebuiltPackerEmitsOnlyExtractorAcceptedTypeflags(t *testing.T) {
	dir := writePaxProbeFixture(t)
	art, err := packPrebuiltDir(dir)
	if err != nil {
		t.Fatalf("packPrebuiltDir: %v", err)
	}
	defer art.Cleanup()

	blocks := rawTarBlocks(t, art.Path)
	t.Logf("raw 512-byte header typeflags: %s", flagSequence(blocks))

	pax := 0
	offending := 0
	for i, b := range blocks {
		if _, ok := paxAcceptedTypeflags[b.typeflag]; !ok {
			offending++
			t.Errorf("block %d (%q): typeflag %q is NOT in the extractor's accepted set — this archive is dead on arrival with E_UNKNOWN_TYPE", i, b.name, string(b.typeflag))
			continue
		}
		if b.typeflag == 'x' {
			pax++
		}
	}
	if offending > 0 {
		t.Fatalf("%d/%d header blocks would be refused by the box", offending, len(blocks))
	}

	// The tripwire must not be VACUOUS: if the packer stopped emitting 'x' for
	// these two triggers, the accepted-set assertion above would pass over an
	// archive that never exercises the seam at all.
	if pax < 2 {
		t.Fatalf("expected at least 2 pax ('x') headers (one for the accented component, one for the 120-byte component), got %d — the fixture no longer exercises the seam; flags were: %s", pax, flagSequence(blocks))
	}
}

// TestPrebuiltPaxHeadersAreInvisibleThroughTarNewReader is the NECESSITY proof
// for the test above: the same archive, read the way every other test in this
// package reads one, reports NOTHING unusual. Every typeflag comes back '0' or
// '5' and the accented name comes back fully restored — so no amount of
// tar.NewReader-based assertion could have caught the seam.
func TestPrebuiltPaxHeadersAreInvisibleThroughTarNewReader(t *testing.T) {
	dir := writePaxProbeFixture(t)
	art, err := packPrebuiltDir(dir)
	if err != nil {
		t.Fatalf("packPrebuiltDir: %v", err)
	}
	defer art.Cleanup()

	raw := rawTarBlocks(t, art.Path)
	rawPax := 0
	for _, b := range raw {
		if b.typeflag == 'x' {
			rawPax++
		}
	}
	if rawPax == 0 {
		t.Fatalf("raw blocks carry no pax header — nothing to be blind to")
	}

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

	accented := string([]byte{'c', 'a', 'f', 0xc3, 0xa9}) + "/index.html"
	sawAccented := false
	tr := tar.NewReader(gz)
	for {
		hdr, err := tr.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			t.Fatalf("tar next: %v", err)
		}
		if hdr.Typeflag == tar.TypeXHeader || hdr.Typeflag == tar.TypeXGlobalHeader {
			t.Fatalf("tar.NewReader surfaced a pax header for %q — the blindness this test pins has changed", hdr.Name)
		}
		if hdr.Typeflag != tar.TypeReg && hdr.Typeflag != tar.TypeDir {
			t.Fatalf("unexpected typeflag %q for %q", string(hdr.Typeflag), hdr.Name)
		}
		if hdr.Name == accented {
			sawAccented = true
		}
	}
	if !sawAccented {
		t.Fatalf("tar.NewReader did not restore %q", accented)
	}
	t.Logf("tar.NewReader reported %d entries, ALL typeflag '0'/'5', accented name fully restored — while the raw blocks carry %d 'x' headers the box has to decide about", len(raw)-rawPax, rawPax)
}

// TestPrebuiltPaxFixturesForTheExtractor regenerates the byte fixtures the
// Elixir side pins (@go_packer_accented_b64 / @go_packer_long_component_b64 in
// api/test/barkpark/sites/prebuilt_artifact_test.exs). Those two constants are
// the repo's first packer→extractor end-to-end proof and they are checked in AS
// BYTES so CI needs no Go toolchain to run the Elixir half; this test is how you
// re-derive them (`go test ./internal/cli/ -run Prebuilt -v`) after any change
// to the packer or the Go toolchain.
//
// RE-DERIVE means REPLACE, not reproduce: `tar.FileInfoHeader` copies each file's
// ModTime into the header, so a fresh run of this test can never emit the bytes
// already checked in — only an equivalent archive with the same typeflag
// sequence. Do NOT diff the logged base64 against the committed constant and
// read the difference as drift; compare the `flags=[…]` line instead, which is
// the property the Elixir fixtures exist to carry.
func TestPrebuiltPaxFixturesForTheExtractor(t *testing.T) {
	cases := []struct {
		name  string
		build func(t *testing.T) string
	}{
		{"accented", func(t *testing.T) string {
			dir := t.TempDir()
			accented := string([]byte{'c', 'a', 'f', 0xc3, 0xa9})
			if err := os.MkdirAll(filepath.Join(dir, accented), 0o755); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(filepath.Join(dir, "index.html"), []byte("<!doctype html><title>bp</title><h1>hello</h1>"), 0o644); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(filepath.Join(dir, accented, "index.html"), []byte("<!doctype html><title>kafé</title>"), 0o644); err != nil {
				t.Fatal(err)
			}
			return dir
		}},
		{"long-component", func(t *testing.T) string {
			dir := t.TempDir()
			long := strings.Repeat("d", 120)
			if err := os.MkdirAll(filepath.Join(dir, long), 0o755); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(filepath.Join(dir, "index.html"), []byte("<!doctype html><title>bp</title><h1>hello</h1>"), 0o644); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(filepath.Join(dir, long, "page.html"), []byte("<!doctype html><title>long</title>"), 0o644); err != nil {
				t.Fatal(err)
			}
			return dir
		}},
	}

	for _, tc := range cases {
		dir := tc.build(t)
		art, err := packPrebuiltDir(dir)
		if err != nil {
			t.Fatalf("%s: packPrebuiltDir: %v", tc.name, err)
		}
		blocks := rawTarBlocks(t, art.Path)
		body, err := os.ReadFile(art.Path)
		art.Cleanup()
		if err != nil {
			t.Fatalf("%s: read artifact: %v", tc.name, err)
		}
		t.Logf("%s: flags=[%s] wire=%d sha256=%s", tc.name, flagSequence(blocks), art.WireBytes, art.SHA256)
		t.Logf("%s b64: %s", tc.name, base64.StdEncoding.EncodeToString(body))
	}
}

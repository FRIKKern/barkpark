package cli

// context_render_atomic_test.go — the file-destination-sink pin for
// renderContextBundle. The property: a page write that FAILS leaves outdir
// exactly as it found it. A bare os.Create cannot hold that property — it
// creates (and truncates) the destination before the encoder writes a byte, so
// every failure path it guards is already too late. These tests are RED
// against that sink and GREEN against the atomicWriteStream seam.

import (
	"bytes"
	"errors"
	"image"
	"image/png"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// withFailingPageEncoder swaps in an encoder that writes a plausible PNG
// preamble and THEN fails, which is the torn write a partial file is made of.
func withFailingPageEncoder(t *testing.T, boom error) {
	t.Helper()
	prev := ctxPNGEncode
	ctxPNGEncode = func(w io.Writer, m image.Image) error {
		_, _ = w.Write([]byte("\x89PNG\r\n\x1a\nHALF-WRITTEN-PAGE"))
		return boom
	}
	t.Cleanup(func() { ctxPNGEncode = prev })
}

// TestRenderContextBundleFailedWriteLeavesNoPartialPage is THE DETECTOR.
// On origin/main (`f, err := os.Create(filepath.Join(outdir, name))`) outdir
// holds a truncated page_1.png the moment the encoder fails.
func TestRenderContextBundleFailedWriteLeavesNoPartialPage(t *testing.T) {
	dir := t.TempDir()
	boom := errors.New("encoder died mid-page")
	withFailingPageEncoder(t, boom)

	pages, err := renderContextBundle([]string{"alpha", "beta", "gamma"}, 0.4, dir)
	if err == nil {
		t.Fatalf("want the encoder failure to surface, got nil error (pages=%v)", pages)
	}
	if !errors.Is(err, boom) {
		t.Fatalf("want the encoder's own error back, got %v", err)
	}
	if pages != nil {
		t.Fatalf("want no manifest on failure, got %v", pages)
	}

	ents, rerr := os.ReadDir(dir)
	if rerr != nil {
		t.Fatalf("read outdir: %v", rerr)
	}
	// Print the key set: an empty read is only evidence once you can see what
	// was actually there.
	var names []string
	for _, e := range ents {
		names = append(names, e.Name())
	}
	if len(names) != 0 {
		t.Fatalf("a failed write left %d file(s) in outdir: %v — outdir must gain NOTHING", len(names), names)
	}
}

// TestRenderContextBundleFailedWriteDoesNotClobberExistingPage is the second
// half of the same property: a re-render into an outdir that already holds a
// good page must not destroy it. os.Create truncates it to zero bytes before
// the encoder is even called.
func TestRenderContextBundleFailedWriteDoesNotClobberExistingPage(t *testing.T) {
	dir := t.TempDir()
	prior := []byte("the operator's previous page_1.png, still good")
	page1 := filepath.Join(dir, "page_1.png")
	if err := os.WriteFile(page1, prior, 0o644); err != nil {
		t.Fatalf("seed prior page: %v", err)
	}
	withFailingPageEncoder(t, errors.New("encoder died mid-page"))

	if _, err := renderContextBundle([]string{"alpha"}, 0.4, dir); err == nil {
		t.Fatal("want an error from the failing encoder, got nil")
	}
	got, err := os.ReadFile(page1)
	if err != nil {
		t.Fatalf("the prior page is gone entirely: %v", err)
	}
	if !bytes.Equal(got, prior) {
		t.Fatalf("a failed write clobbered the prior page: want %d bytes %q, got %d bytes %q",
			len(prior), prior, len(got), got)
	}
	// And no promoted-but-unpromotable temp left lying around either.
	ents, _ := os.ReadDir(dir)
	for _, e := range ents {
		if e.Name() != "page_1.png" {
			t.Fatalf("failed write left debris in outdir: %s", e.Name())
		}
	}
}

// TestRenderContextBundleSuccessIsByteIdentical is THE CONTROL: the conversion
// changed the write PATH, not the bytes. Each page file must equal exactly what
// png.Encode produces for the image the renderer built, and land 0644 — what a
// bare os.Create produced under the usual 0022 umask.
func TestRenderContextBundleSuccessIsByteIdentical(t *testing.T) {
	dir := t.TempDir()
	lines := []string{"package main", "", "func main() {}", strings.Repeat("x", 60)}

	pages, err := renderContextBundle(lines, 0.4, dir)
	if err != nil {
		t.Fatalf("render: %v", err)
	}
	if len(pages) != 1 {
		t.Fatalf("want 1 page for %d lines, got %d", len(lines), len(pages))
	}

	var want bytes.Buffer
	if err := png.Encode(&want, downscaleGray(renderContextPage(lines), 0.4)); err != nil {
		t.Fatalf("reference encode: %v", err)
	}
	got, err := os.ReadFile(filepath.Join(dir, pages[0].Name))
	if err != nil {
		t.Fatalf("read written page: %v", err)
	}
	if !bytes.Equal(got, want.Bytes()) {
		t.Fatalf("written page is not byte-identical to png.Encode: got %d bytes, want %d", len(got), want.Len())
	}

	info, err := os.Stat(filepath.Join(dir, pages[0].Name))
	if err != nil {
		t.Fatalf("stat page: %v", err)
	}
	if perm := info.Mode().Perm(); perm != 0o644 {
		t.Fatalf("want the page to land 0644 (os.Create under umask 0022), got %#o", perm)
	}

	// outdir holds the manifest's pages and nothing else — no stranded .part-*.
	ents, _ := os.ReadDir(dir)
	if len(ents) != len(pages) {
		var names []string
		for _, e := range ents {
			names = append(names, e.Name())
		}
		t.Fatalf("want exactly %d file(s) in outdir, got %d: %v", len(pages), len(ents), names)
	}
}

// TestRenderContextBundleSinkCarriesNoBareOsCreate is the grep-shaped pin. It
// counts only as a pin, never as the detector — the three tests above are the
// behaviour proof.
func TestRenderContextBundleSinkCarriesNoBareOsCreate(t *testing.T) {
	src, err := os.ReadFile("context_render.go")
	if err != nil {
		t.Fatalf("read source: %v", err)
	}
	// Control: the string the file MUST contain, so an empty match below is a
	// real absence and not a mis-scoped read.
	if !bytes.Contains(src, []byte("atomicWriteStream(filepath.Join(outdir, name)")) {
		t.Fatal("control failed: context_render.go does not route the page sink through atomicWriteStream — this test is reading the wrong file")
	}
	for i, line := range strings.Split(string(src), "\n") {
		if strings.Contains(line, "os.Create(") && !strings.HasPrefix(strings.TrimSpace(line), "//") {
			t.Fatalf("context_render.go:%d still writes through a bare os.Create: %s", i+1, strings.TrimSpace(line))
		}
	}
}

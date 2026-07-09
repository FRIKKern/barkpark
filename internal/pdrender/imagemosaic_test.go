package pdrender

import (
	"bytes"
	"image"
	"image/color"
	"image/png"
	"strings"
	"testing"

	"github.com/charmbracelet/lipgloss"
	"github.com/muesli/termenv"
)

// withTrueColor binds lipgloss's GLOBAL termenv profile to TrueColor for one
// test (the heatmap_test pattern) — without it a non-TTY test run strips the
// 24-bit SGR the mosaic emits.
func withTrueColor(t *testing.T) {
	t.Helper()
	old := lipgloss.ColorProfile()
	lipgloss.SetColorProfile(termenv.TrueColor)
	t.Cleanup(func() { lipgloss.SetColorProfile(old) })
}

// pngBytes encodes a w×h test image: left half red, right half blue, with the
// given alpha (0xff = opaque).
func pngBytes(t *testing.T, w, h int, alpha uint8) []byte {
	t.Helper()
	img := image.NewNRGBA(image.Rect(0, 0, w, h))
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			c := color.NRGBA{R: 200, A: alpha}
			if x >= w/2 {
				c = color.NRGBA{B: 200, A: alpha}
			}
			img.SetNRGBA(x, y, c)
		}
	}
	var buf bytes.Buffer
	if err := png.Encode(&buf, img); err != nil {
		t.Fatalf("encode test png: %v", err)
	}
	return buf.Bytes()
}

func imageBlock(src string) Block {
	return Block{Type: "image", Attrs: map[string]any{"src": src, "alt": "a test image"}}
}

func mosaicCtx(w int, raw []byte, profile Profile) RenderCtx {
	return RenderCtx{
		Width:   w,
		Theme:   DarkTheme(),
		Profile: profile,
		ImageResolver: func(src string) []byte {
			if src == "/media/x.png" {
				return raw
			}
			return nil
		},
	}
}

// TestImageMosaicRenders: a resolvable image under TrueColor paints half-block
// rows with 24-bit SGR, pixel-for-pixel for a small image (no upscale), plus a
// dim caption — every line exactly ctx.Width wide.
func TestImageMosaicRenders(t *testing.T) {
	withTrueColor(t)
	raw := pngBytes(t, 8, 4, 0xff)
	ctx := mosaicCtx(60, raw, TrueColor)
	reg := DefaultRegistry(DarkTheme())

	lines := reg.Render(imageBlock("/media/x.png"), ctx)
	// 4 px tall → 2 mosaic rows + 1 caption.
	if len(lines) != 3 {
		t.Fatalf("got %d lines, want 3:\n%s", len(lines), strings.Join(lines, "\n"))
	}
	joined := strings.Join(lines[:2], "\n")
	if !strings.Contains(joined, "▀") {
		t.Errorf("no half-block glyphs in mosaic")
	}
	if !strings.Contains(joined, "38;2;") || !strings.Contains(joined, "48;2;") {
		t.Errorf("mosaic missing truecolor fg/bg SGR")
	}
	for i, l := range lines {
		if w := lipgloss.Width(l); w != 60 {
			t.Errorf("line %d width = %d, want 60", i, w)
		}
	}
	if !strings.Contains(lines[2], "a test image") {
		t.Errorf("caption missing alt: %q", lines[2])
	}
}

// TestImageMosaicDownscales: a 200×100 image at width 40 box-samples to
// 40 cols × 20 px rows → 10 mosaic rows (+ caption), aspect preserved.
func TestImageMosaicDownscales(t *testing.T) {
	raw := pngBytes(t, 200, 100, 0xff)
	lines, ok := renderImageMosaic(raw, "big", "/media/x.png", mosaicCtx(40, raw, TrueColor))
	if !ok {
		t.Fatal("mosaic refused a decodable image")
	}
	if len(lines) != 11 {
		t.Fatalf("got %d lines, want 10 mosaic rows + caption", len(lines))
	}
}

// TestImageMosaicDegrades: every miss keeps the honest labeled box — lower
// profile, nil resolver, resolver miss, corrupt bytes.
func TestImageMosaicDegrades(t *testing.T) {
	raw := pngBytes(t, 8, 4, 0xff)
	reg := DefaultRegistry(DarkTheme())

	boxed := func(lines []string) bool {
		return strings.Contains(strings.Join(lines, "\n"), "view in Studio")
	}

	// ANSI256 → box (no 24-bit SGR into a 256-color terminal).
	if !boxed(reg.Render(imageBlock("/media/x.png"), mosaicCtx(60, raw, ANSI256))) {
		t.Errorf("ANSI256 did not degrade to the box")
	}
	// nil resolver → box.
	ctx := RenderCtx{Width: 60, Theme: DarkTheme(), Profile: TrueColor}
	if !boxed(reg.Render(imageBlock("/media/x.png"), ctx)) {
		t.Errorf("nil resolver did not degrade to the box")
	}
	// resolver miss (unknown src) → box.
	if !boxed(reg.Render(imageBlock("/media/other.png"), mosaicCtx(60, raw, TrueColor))) {
		t.Errorf("resolver miss did not degrade to the box")
	}
	// corrupt bytes → box.
	junk := mosaicCtx(60, []byte("not an image"), TrueColor)
	if !boxed(reg.Render(imageBlock("/media/x.png"), junk)) {
		t.Errorf("corrupt bytes did not degrade to the box")
	}
}

// TestImageMosaicAlphaBlendsOntoGround: a fully transparent image composites
// to the theme ground, not to black — the dark ground's red channel is 0x0e.
func TestImageMosaicAlphaBlendsOntoGround(t *testing.T) {
	withTrueColor(t)
	raw := pngBytes(t, 4, 4, 0x00)
	lines, ok := renderImageMosaic(raw, "ghost", "/media/x.png", mosaicCtx(20, raw, TrueColor))
	if !ok {
		t.Fatal("mosaic refused transparent png")
	}
	joined := strings.Join(lines, "\n")
	// ground #0e1614 → SGR "38;2;14;22;20"
	if !strings.Contains(joined, "38;2;14;22;20") {
		t.Errorf("transparent pixels did not composite onto the dark ground:\n%q", joined)
	}
}

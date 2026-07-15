package cli

// context_render.go — the optical renderer behind `bp context pack`: draws the
// packed body as monospace glyphs, downscales to the validated operating
// point, and paginates so every page clears the provider's image long-edge
// cap. The load-bearing invariant (research report §5): verbatim recall is
// governed by EFFECTIVE GLYPH PIXELS, not token budget — a whole-file render
// that exceeds the 2576px cap gets resized AGAIN by the provider, silently
// pushing the glyph below legibility. Pagination makes glyph size a constant
// of the encoding, independent of input size.
//
// Font: basicfont.Face7x13 (golang.org/x/image), a crisp bitmap face with a
// 7px advance and 13px line height. At the default 0.4 scale the delivered
// glyph is ~2.8px advance / 5.2px line height — inside the envelope the
// boundary probe validated (report §7: meaning holds to ~0.30 of a 13px face;
// 0.35 was the zero-silent-failure operating point; exact bytes never ride
// the image at all — they are sidecar-routed by context_detect.go).

import (
	"fmt"
	"image"
	"image/color"
	"image/png"
	"math"
	"os"
	"path/filepath"

	"golang.org/x/image/font"
	"golang.org/x/image/font/basicfont"
	"golang.org/x/image/math/fixed"
)

const (
	// ctxImgLongEdgeCap is the provider-side image resize threshold: any image
	// whose long edge exceeds this is downscaled before the model sees it,
	// which would silently shrink our glyph. Every page stays under it.
	ctxImgLongEdgeCap = 2576
	// ctxImgTokenDivisor: image tokens = ceil(w*h / 750) on delivered pixels.
	ctxImgTokenDivisor = 750
	// ctxTextTokenDivisor: the text-baseline estimate, chars/4.
	ctxTextTokenDivisor = 4
	ctxGlyphAdvance     = 7  // basicfont.Face7x13 horizontal advance
	ctxGlyphHeight      = 13 // basicfont.Face7x13 line height
	ctxGlyphAscent      = 11 // basicfont.Face7x13 baseline offset
	ctxPagePad          = 8  // white margin around each page, pre-scale
	// ctxDefaultScale is the validated operating point: 0.4 of the 13px face
	// ≈ the research harness's 0.35 of a 13px Menlo (2.8px vs 2.73px advance).
	ctxDefaultScale = 0.4
	// ctxDefaultCols wraps long lines so page width stays far under the cap.
	ctxDefaultCols = 150
)

// imageTokensFor is the provider token formula applied to delivered pixels,
// including the cap resize it would apply to an oversized image.
func imageTokensFor(w, h int) int {
	long := w
	if h > long {
		long = h
	}
	if long > ctxImgLongEdgeCap {
		s := float64(ctxImgLongEdgeCap) / float64(long)
		w = int(float64(w) * s)
		h = int(float64(h) * s)
	}
	return (w*h + ctxImgTokenDivisor - 1) / ctxImgTokenDivisor
}

// wrapContextLines hard-wraps any line longer than cols so page width is
// bounded; short lines pass through untouched.
func wrapContextLines(text string, cols int) []string {
	var out []string
	start := 0
	for i := 0; i <= len(text); i++ {
		if i == len(text) || text[i] == '\n' {
			l := text[start:i]
			for len(l) > cols {
				out = append(out, l[:cols])
				l = l[cols:]
			}
			out = append(out, l)
			start = i + 1
		}
	}
	return out
}

// renderContextPage draws one page of lines at full glyph size on white.
func renderContextPage(lines []string) *image.Gray {
	maxLen := 1
	for _, l := range lines {
		if len(l) > maxLen {
			maxLen = len(l)
		}
	}
	w := maxLen*ctxGlyphAdvance + 2*ctxPagePad
	h := len(lines)*ctxGlyphHeight + 2*ctxPagePad
	img := image.NewGray(image.Rect(0, 0, w, h))
	for i := range img.Pix {
		img.Pix[i] = 0xff
	}
	d := font.Drawer{Dst: img, Src: image.Black, Face: basicfont.Face7x13}
	for i, l := range lines {
		d.Dot = fixed.P(ctxPagePad, ctxPagePad+i*ctxGlyphHeight+ctxGlyphAscent)
		d.DrawString(l)
	}
	return img
}

// downscaleGray is a deterministic area-average (box filter): each source
// pixel is accumulated into the destination bucket it lands in. Adequate for
// glyph downscaling and dependency-free beyond the stdlib.
func downscaleGray(src *image.Gray, scale float64) *image.Gray {
	sw, sh := src.Rect.Dx(), src.Rect.Dy()
	dw := int(math.Max(1, math.Floor(float64(sw)*scale)))
	dh := int(math.Max(1, math.Floor(float64(sh)*scale)))
	sum := make([]float64, dw*dh)
	cnt := make([]float64, dw*dh)
	for y := 0; y < sh; y++ {
		dy := int(float64(y) * scale)
		if dy >= dh {
			dy = dh - 1
		}
		row := y * src.Stride
		for x := 0; x < sw; x++ {
			dx := int(float64(x) * scale)
			if dx >= dw {
				dx = dw - 1
			}
			i := dy*dw + dx
			sum[i] += float64(src.Pix[row+x])
			cnt[i]++
		}
	}
	dst := image.NewGray(image.Rect(0, 0, dw, dh))
	for i := range sum {
		if cnt[i] > 0 {
			dst.Pix[i] = uint8(sum[i]/cnt[i] + 0.5)
		} else {
			dst.Pix[i] = 0xff
		}
	}
	return dst
}

// contextPage is one delivered page: its file name, dimensions, and cost.
type contextPage struct {
	Name   string `json:"name"`
	Width  int    `json:"width"`
	Height int    `json:"height"`
	Tokens int    `json:"tokens"`
}

// renderContextBundle paginates body lines so each delivered page clears the
// cap at the requested scale, renders and downscales each page, and writes
// page_N.png files into outdir. Returns the page manifest.
func renderContextBundle(lines []string, scale float64, outdir string) ([]contextPage, error) {
	// lines/page such that a page rendered at full size then downscaled stays
	// under the cap vertically. Width is bounded by the column wrap.
	linesPerPage := int((float64(ctxImgLongEdgeCap)/scale - 2*ctxPagePad) / float64(ctxGlyphHeight))
	if linesPerPage < 1 {
		linesPerPage = 1
	}
	var pages []contextPage
	for start, pi := 0, 0; start < len(lines); start, pi = start+linesPerPage, pi+1 {
		end := start + linesPerPage
		if end > len(lines) {
			end = len(lines)
		}
		img := downscaleGray(renderContextPage(lines[start:end]), scale)
		w, h := img.Rect.Dx(), img.Rect.Dy()
		if w > ctxImgLongEdgeCap || h > ctxImgLongEdgeCap {
			// By construction this cannot happen; guard anyway so a future
			// parameter change can never silently ship a capped (re-blurred) page.
			return nil, fmt.Errorf("page %d is %dx%d, over the %dpx cap — refusing to emit a page the provider would re-downscale", pi+1, w, h, ctxImgLongEdgeCap)
		}
		name := fmt.Sprintf("page_%d.png", pi+1)
		f, err := os.Create(filepath.Join(outdir, name))
		if err != nil {
			return nil, err
		}
		if err := png.Encode(f, img); err != nil {
			f.Close()
			return nil, err
		}
		if err := f.Close(); err != nil {
			return nil, err
		}
		pages = append(pages, contextPage{Name: name, Width: w, Height: h, Tokens: imageTokensFor(w, h)})
	}
	return pages, nil
}

// grayWhite is exported-for-tests sugar: the background level pages start at.
var grayWhite = color.Gray{Y: 0xff}

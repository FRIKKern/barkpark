package pdrender

import (
	"bytes"
	"image"
	"strings"

	// Stdlib decoders only (the package's go-list-deps import discipline):
	// register PNG / JPEG / GIF for image.Decode. Anything else (webp, avif…)
	// fails decode and takes the honest labeled-box degrade.
	_ "image/gif"
	_ "image/jpeg"
	_ "image/png"

	"github.com/charmbracelet/lipgloss"
)

// ── image mosaic: real pictures in the terminal ──────────────────────────────
//
// "Some terminals can handle images" — and the scroll-safe way to serve them
// from a bubbletea viewport is NOT a graphics protocol (kitty / iTerm2 / sixel
// escapes don't survive line slicing, and the viewport re-slices every frame).
// It is the half-block mosaic: each character cell is the upper-half block ▀
// with the TOP pixel as the foreground color and the BOTTOM pixel as the
// background — two vertical pixels per cell, pure text + SGR (the chafa/timg
// technique). That keeps every pdrender invariant: rectangular padded lines,
// scroll-safe, byte-deterministic for a given input, and it even survives the
// wasm ANSI→HTML bridge.
//
// AUTO-DEGRADE (load-bearing, mirrors heatmap.go): the mosaic emits 24-bit
// SGR, so it renders ONLY under ctx.Profile == TrueColor AND when the caller
// wired an ImageResolver that returned bytes that decode. Every other case —
// nil resolver, fetch miss, corrupt/unsupported bytes, ANSI256/NoColor —
// keeps the labeled "🖼 … (view in Studio)" box. Goldens run without a
// resolver, so they are byte-stable by construction.
//
// GEOMETRY: no-upscale box-sample scaling. The target grid is at most
// ctx.Width columns wide and mosaicMaxRows rows tall (each row = 2 pixels);
// the scale factor is min(fit-width, fit-height, 1) so small images render
// pixel-for-pixel and large ones downsample with box averaging (cheap,
// dependency-free, and visually fine at terminal resolution). Alpha is
// composited against the theme ground so transparent PNGs sit on the page
// color instead of black.

// mosaicMaxRows caps the mosaic height (rows × 2 = pixel rows): tall enough to
// read a photo, short enough that an image never floods a scroll page.
const mosaicMaxRows = 22

// mosaicMaxBytes caps the decoded input size — the resolver seam is caller-
// controlled, but a hostile 200MB "png" must die here, not in image.Decode.
const mosaicMaxBytes = 16 << 20

// renderImageMosaic paints src's bytes as a half-block truecolor mosaic plus a
// dim caption line. ok=false → the caller renders its degrade box instead.
func renderImageMosaic(raw []byte, alt, src string, ctx RenderCtx) (lines []string, ok bool) {
	if len(raw) == 0 || len(raw) > mosaicMaxBytes || ctx.Profile != TrueColor {
		return nil, false
	}
	img, _, err := image.Decode(bytes.NewReader(raw))
	if err != nil {
		return nil, false
	}

	bounds := img.Bounds()
	iw, ih := bounds.Dx(), bounds.Dy()
	if iw <= 0 || ih <= 0 {
		return nil, false
	}

	maxCols := clampWidth(ctx.Width)
	if maxCols < MinWidth {
		return nil, false
	}
	maxPxH := mosaicMaxRows * 2

	// No-upscale fit: 1 image pixel ≥ 1 cell column / half-cell row.
	scale := 1.0
	if fit := float64(maxCols) / float64(iw); fit < scale {
		scale = fit
	}
	if fit := float64(maxPxH) / float64(ih); fit < scale {
		scale = fit
	}
	cols := int(float64(iw) * scale)
	pxRows := int(float64(ih) * scale)
	if cols < 1 {
		cols = 1
	}
	if pxRows < 1 {
		pxRows = 1
	}
	if pxRows%2 == 1 {
		pxRows++ // half-blocks consume pixel rows in pairs
	}

	bgR, bgG, bgB := mosaicGround(ctx)
	grid := mosaicSample(img, cols, pxRows, bgR, bgG, bgB)

	rows := pxRows / 2
	out := make([]string, 0, rows+1)
	var sb strings.Builder
	for r := 0; r < rows; r++ {
		sb.Reset()
		for c := 0; c < cols; c++ {
			top := grid[r*2][c]
			bot := grid[r*2+1][c]
			sb.WriteString(lipgloss.NewStyle().
				Foreground(lipgloss.Color(hexRGB(top))).
				Background(lipgloss.Color(hexRGB(bot))).
				Render("▀"))
		}
		out = append(out, sb.String())
	}

	caption := "🖼 " + alt
	if strings.TrimSpace(alt) == "" {
		caption = "🖼 " + src
	}
	out = append(out, ctx.Theme.Dim.Render(truncateANSI(sanitizeText(caption), clampWidth(ctx.Width))))
	return out, true
}

type mosaicPx struct{ r, g, b uint32 }

// mosaicSample box-averages img onto a cols×pxRows grid, compositing alpha
// against the (r,g,b) ground. Pure stdlib — at terminal resolution a box
// filter is indistinguishable from fancier kernels.
func mosaicSample(img image.Image, cols, pxRows int, bgR, bgG, bgB uint32) [][]mosaicPx {
	bounds := img.Bounds()
	iw, ih := bounds.Dx(), bounds.Dy()
	grid := make([][]mosaicPx, pxRows)
	for y := 0; y < pxRows; y++ {
		grid[y] = make([]mosaicPx, cols)
		y0 := bounds.Min.Y + y*ih/pxRows
		y1 := bounds.Min.Y + (y+1)*ih/pxRows
		if y1 <= y0 {
			y1 = y0 + 1
		}
		for x := 0; x < cols; x++ {
			x0 := bounds.Min.X + x*iw/cols
			x1 := bounds.Min.X + (x+1)*iw/cols
			if x1 <= x0 {
				x1 = x0 + 1
			}
			var sr, sg, sb2, n uint64
			for py := y0; py < y1; py++ {
				for px := x0; px < x1; px++ {
					r, g, b, a := img.At(px, py).RGBA() // 16-bit premultiplied
					// Composite over the ground: out = px + ground*(1-a).
					inv := 0xffff - a
					r = r + bgR*inv/0xffff
					g = g + bgG*inv/0xffff
					b = b + bgB*inv/0xffff
					sr += uint64(r >> 8)
					sg += uint64(g >> 8)
					sb2 += uint64(b >> 8)
					n++
				}
			}
			if n == 0 {
				n = 1
			}
			grid[y][x] = mosaicPx{
				r: clamp255(uint32(sr / n)),
				g: clamp255(uint32(sg / n)),
				b: clamp255(uint32(sb2 / n)),
			}
		}
	}
	return grid
}

// mosaicGround is the alpha-compositing backdrop, 16-bit per channel: the
// page color the theme paints on (dark ground for the dark theme, paper-white
// otherwise). Approximate is fine — it only shows through transparency.
func mosaicGround(ctx RenderCtx) (r, g, b uint32) {
	if ctx.Theme.name == "light" {
		return 0xf6f6, 0xfafa, 0xf9f9 // --paper-bg light
	}
	return 0x0e0e, 0x1616, 0x1414 // --paper-bg dark
}

func clamp255(v uint32) uint32 {
	if v > 255 {
		return 255
	}
	return v
}

// hexRGB formats an 8-bit-per-channel pixel as the #rrggbb literal lipgloss
// parses for truecolor output.
func hexRGB(p mosaicPx) string {
	const digits = "0123456789abcdef"
	return string([]byte{
		'#',
		digits[(p.r>>4)&0xf], digits[p.r&0xf],
		digits[(p.g>>4)&0xf], digits[p.g&0xf],
		digits[(p.b>>4)&0xf], digits[p.b&0xf],
	})
}

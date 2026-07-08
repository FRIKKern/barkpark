package pdrender

import (
	"strings"

	"github.com/charmbracelet/lipgloss"
)

// ── braille dot-canvas (TUI creative slate, W3) ──────────────────────────────
//
// A 2×4 dot rasteriser: the sub-cell primitive the `chart` block draws a line
// through. A braille glyph packs a 2-dot-column × 4-dot-row grid into one
// terminal cell, so a W×H-cell plot has a 2W×4H DOT canvas — eight times the
// spatial resolution of a bare block-glyph plot, all in ANSI-plain Unicode
// (U+2800…U+28FF), which is why the mono render is byte-stable.
//
// The canvas is deliberately import-thin (lipgloss + stdlib only, the package
// rule): points are mapped to dot-rows by chart.go through the REUSED W2
// sparkline normaliser (sparkNorm — honouring pinned axes.min/max, clamping
// out-of-span to a plot edge), then Bresenham-connected here into a continuous
// stroke. Multiple series OR their bitmasks into ONE canvas (a mono union);
// per-series colour is applied only under a TrueColor profile (last-writer-wins
// per cell), so a 24-bit escape never reaches a terminal that can't render it.

// brailleDots maps a (dot-column, dot-row) sub-cell to its Unicode braille bit.
// Base is U+2800 and each lit dot ORs in its bit — the standard 2×4 layout:
//
//	(0,0)=0x01  (0,1)=0x02  (0,2)=0x04  (0,3)=0x40
//	(1,0)=0x08  (1,1)=0x10  (1,2)=0x20  (1,3)=0x80
var brailleDots = [2][4]byte{
	{0x01, 0x02, 0x04, 0x40}, // dot-column 0, rows 0..3 (top→bottom)
	{0x08, 0x10, 0x20, 0x80}, // dot-column 1, rows 0..3
}

// brailleBlank is the empty braille pattern (U+2800). An unlit cell renders as
// this rather than a space so the plot stays a solid rectangle the x-rule and
// the tick gutter align against.
const brailleBlank = 0x2800

// brailleCanvas is a 2W×4H dot grid over a W×H terminal-cell plot. mask holds
// one accumulated braille bitmask per cell (row-major); owner records which
// series last lit each cell, used only for the truecolor colour pick.
type brailleCanvas struct {
	w, h  int    // plot size in terminal cells
	dotW  int    // 2*w dot columns
	dotH  int    // 4*h dot rows
	mask  []byte // len w*h, accumulated dot bits per cell
	owner []int  // len w*h, series index that last lit the cell (-1 = none)
}

// newBrailleCanvas allocates a blank W×H-cell canvas (each dimension floored at
// 1 so the dot grid is never degenerate).
func newBrailleCanvas(w, h int) *brailleCanvas {
	if w < 1 {
		w = 1
	}
	if h < 1 {
		h = 1
	}
	n := w * h
	owner := make([]int, n)
	for i := range owner {
		owner[i] = -1
	}
	return &brailleCanvas{w: w, h: h, dotW: 2 * w, dotH: 4 * h, mask: make([]byte, n), owner: owner}
}

// set lights the dot at dot-coordinate (x,y) for series s. Origin is top-left;
// y=0 is the TOP dot-row. Out-of-range coordinates are dropped — a clamped or
// off-canvas point can never panic.
func (c *brailleCanvas) set(x, y, s int) {
	if x < 0 || y < 0 || x >= c.dotW || y >= c.dotH {
		return
	}
	cell := (y/4)*c.w + (x / 2)
	c.mask[cell] |= brailleDots[x%2][y%4]
	c.owner[cell] = s
}

// line Bresenham-connects (x0,y0)→(x1,y1) in dot-space, lighting every dot for
// series s — the continuous stroke between two successive points. Integer
// Bresenham, so it is deterministic and allocation-free.
func (c *brailleCanvas) line(x0, y0, x1, y1, s int) {
	dx := absInt(x1 - x0)
	dy := -absInt(y1 - y0)
	sx := 1
	if x0 > x1 {
		sx = -1
	}
	sy := 1
	if y0 > y1 {
		sy = -1
	}
	err := dx + dy
	for {
		c.set(x0, y0, s)
		if x0 == x1 && y0 == y1 {
			break
		}
		e2 := 2 * err
		if e2 >= dy {
			err += dy
			x0 += sx
		}
		if e2 <= dx {
			err += dx
			y0 += sy
		}
	}
}

// column fills the vertical dot-run from the floor (bottom dot-row) up to y at
// dot-x for series s — the `kind:"bars"` stroke.
func (c *brailleCanvas) column(x, y, s int) {
	if x < 0 || x >= c.dotW {
		return
	}
	if y < 0 {
		y = 0
	}
	for yy := c.dotH - 1; yy >= y; yy-- {
		c.set(x, yy, s)
	}
}

// rows renders the canvas top-to-bottom into H strings, one per cell row. Every
// cell is a braille glyph (blank = U+2800), so the plot is a solid rectangle.
// Under a TrueColor profile a lit cell is drawn in its owning series' colour;
// every lower profile (and the mono union) uses the body tone — braille glyphs
// carry no colour of their own, so the mono output is byte-stable.
func (c *brailleCanvas) rows(ctx RenderCtx, colors []lipgloss.Color, trueColor bool) []string {
	out := make([]string, c.h)
	for cy := 0; cy < c.h; cy++ {
		var sb strings.Builder
		for cx := 0; cx < c.w; cx++ {
			idx := cy*c.w + cx
			r := rune(brailleBlank | int(c.mask[idx]))
			if trueColor && c.mask[idx] != 0 {
				if o := c.owner[idx]; o >= 0 && o < len(colors) {
					sb.WriteString(lipgloss.NewStyle().Foreground(colors[o]).Render(string(r)))
					continue
				}
			}
			sb.WriteString(ctx.Theme.Body.Render(string(r)))
		}
		out[cy] = sb.String()
	}
	return out
}

// absInt is the small integer abs the Bresenham stepper needs (stdlib math.Abs
// is float64-only).
func absInt(n int) int {
	if n < 0 {
		return -n
	}
	return n
}

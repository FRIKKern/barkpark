package pdrender

// route.go — the TUI twin of the web `route` block (sport tracks:
// api/lib/barkpark/portable_doc/render/data_viz.ex §route). The block's
// `polyline` attr carries a Google encoded polyline (the whole GPS trace as one
// ASCII string); this renderer decodes it and rasterises the track SHAPE
// through the W3 braille canvas — the same 2×4 dot primitive chart.go plots
// with, so the route survives an ANSI strip at every profile exactly like a
// chart does. Below the plot: the meta row (sport · distance · elevation ·
// duration, all author DISPLAY strings, never coerced) and the caption.
//
// Projection mirrors the Elixir side: equirectangular with a cos(mid-lat)
// x-scale — the shape of a run, not a survey. Fewer than two decodable points
// → the dim unresolved placeholder (the honest empty box's twin).

import (
	"math"
	"strings"
)

type routeRenderer struct{}

// Track plot ceilings: braille cells (each 2×4 dots). Height follows the
// track's own aspect inside these caps, so a flat coastal ride stays flat.
const (
	routeMaxPlotW = 56
	routeMaxPlotH = 12
	routeMinPlotH = 3
)

func (routeRenderer) Render(b Block, ctx RenderCtx) []string {
	pts := decodePolyline(attrStr(b.Attrs, "polyline"))
	if len(pts) < 2 {
		return []string{unresolvedPlaceholder(ctx, "route")}
	}

	// Project: x = lng·cos(mid-lat), y = −lat (north up).
	midLat := 0.0
	for _, p := range pts {
		midLat += p[0]
	}
	midLat /= float64(len(pts))
	k := math.Cos(midLat * math.Pi / 180)

	xs := make([]float64, len(pts))
	ys := make([]float64, len(pts))
	minX, maxX := math.Inf(1), math.Inf(-1)
	minY, maxY := math.Inf(1), math.Inf(-1)
	for i, p := range pts {
		xs[i] = p[1] * k
		ys[i] = -p[0]
		minX = math.Min(minX, xs[i])
		maxX = math.Max(maxX, xs[i])
		minY = math.Min(minY, ys[i])
		maxY = math.Max(maxY, ys[i])
	}

	spanX := math.Max(maxX-minX, 1e-9)
	spanY := math.Max(maxY-minY, 1e-9)

	// Cell budget: width from the surface (capped), height from the track's
	// aspect in DOT space (2 dots/cell across, 4 down), clamped to the caps.
	plotW := clampWidth(ctx.Width)
	if plotW > routeMaxPlotW {
		plotW = routeMaxPlotW
	}
	if plotW < MinWidth {
		plotW = MinWidth
	}
	dotW := 2 * plotW
	dotH := int(math.Round(float64(dotW) * (spanY / spanX)))
	if dotH > 4*routeMaxPlotH {
		dotH = 4 * routeMaxPlotH
	}
	if dotH < 4*routeMinPlotH {
		dotH = 4 * routeMinPlotH
	}
	plotH := (dotH + 3) / 4

	canvas := newBrailleCanvas(plotW, plotH)
	toDot := func(i int) (int, int) {
		x := int(math.Round((xs[i] - minX) / spanX * float64(dotW-1)))
		y := int(math.Round((ys[i] - minY) / spanY * float64(dotH-1)))
		return x, y
	}
	px, py := toDot(0)
	for i := 1; i < len(pts); i++ {
		x, y := toDot(i)
		canvas.line(px, py, x, y, 0)
		px, py = x, y
	}

	out := canvas.rows(ctx, nil, false)

	// Meta row: the present display strings, dot-separated — the exact fields
	// the web meta row shows, in the same order.
	var meta []string
	for _, key := range []string{"sport", "distance", "elevation", "duration"} {
		if v := sanitizeText(strings.TrimSpace(attrStr(b.Attrs, key))); v != "" {
			meta = append(meta, v)
		}
	}
	if len(meta) > 0 {
		out = append(out, firstLine(wrapLines(ctx.Theme.Dim.Render(strings.Join(meta, " · ")), clampWidth(ctx.Width))))
	}
	if cap := sanitizeText(strings.TrimSpace(attrStr(b.Attrs, "caption"))); cap != "" {
		out = append(out, firstLine(wrapLines(ctx.Theme.Caption.Render(cap), clampWidth(ctx.Width))))
	}

	return out
}

// decodePolyline is the Google encoded-polyline decoder (ASCII 63–126,
// 5-decimal fixed point, zig-zag deltas) — the Go twin of
// DataViz.decode_polyline/1, with the same contract: a malformed tail drops at
// the last whole {lat,lng} pair, never inventing a point.
func decodePolyline(s string) [][2]float64 {
	var out [][2]float64
	lat, lng := 0, 0
	i := 0

	next := func() (int, bool) {
		shift, acc := 0, 0
		for i < len(s) {
			c := int(s[i])
			if c < 63 || c > 126 {
				return 0, false
			}
			i++
			acc |= ((c - 63) & 0x1F) << shift
			if (c-63)&0x20 == 0 {
				if acc&1 != 0 {
					return -((acc >> 1) + 1), true
				}
				return acc >> 1, true
			}
			shift += 5
		}
		return 0, false
	}

	for i < len(s) {
		dlat, ok := next()
		if !ok {
			break
		}
		dlng, ok := next()
		if !ok {
			break
		}
		lat += dlat
		lng += dlng
		out = append(out, [2]float64{float64(lat) / 1e5, float64(lng) / 1e5})
	}
	return out
}

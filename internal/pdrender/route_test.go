package pdrender

// The route renderer: decoder proven against the Google reference vector and
// an encode→decode round-trip (encoder test-side, like the Elixir twin's
// suite), the braille plot's shape/meta/caption composition, and the honest
// placeholder for absent or malformed data.

import (
	"math"
	"strings"
	"testing"
)

// test-side encoder — the inverse of decodePolyline, used only to prove it.
func encodePolyline(points [][2]float64) string {
	var sb strings.Builder
	plat, plng := 0, 0
	enc := func(v int) {
		if v < 0 {
			v = ^(v << 1)
		} else {
			v = v << 1
		}
		for v >= 0x20 {
			sb.WriteByte(byte((v&0x1F)|0x20) + 63)
			v >>= 5
		}
		sb.WriteByte(byte(v) + 63)
	}
	for _, p := range points {
		ilat := int(math.Round(p[0] * 1e5))
		ilng := int(math.Round(p[1] * 1e5))
		enc(ilat - plat)
		enc(ilng - plng)
		plat, plng = ilat, ilng
	}
	return sb.String()
}

var routeTrack = [][2]float64{
	{59.9615, 10.7735},
	{59.9642, 10.7761},
	{59.9668, 10.7742},
	{59.9689, 10.7788},
	{59.9701, 10.7845},
	{59.9683, 10.7891},
	{59.9651, 10.7902},
	{59.9628, 10.7867},
	{59.9611, 10.7801},
	{59.9615, 10.7735},
}

func TestDecodePolylineReferenceVector(t *testing.T) {
	got := decodePolyline("_p~iF~ps|U_ulLnnqC_mqNvxq`@")
	want := [][2]float64{{38.5, -120.2}, {40.7, -120.95}, {43.252, -126.453}}
	if len(got) != len(want) {
		t.Fatalf("decoded %d points, want %d", len(got), len(want))
	}
	for i := range want {
		if math.Abs(got[i][0]-want[i][0]) > 1e-9 || math.Abs(got[i][1]-want[i][1]) > 1e-9 {
			t.Fatalf("point %d = %v, want %v", i, got[i], want[i])
		}
	}
}

func TestDecodePolylineRoundTrip(t *testing.T) {
	got := decodePolyline(encodePolyline(routeTrack))
	if len(got) != len(routeTrack) {
		t.Fatalf("decoded %d points, want %d", len(got), len(routeTrack))
	}
	for i := range routeTrack {
		if math.Abs(got[i][0]-routeTrack[i][0]) > 1e-5 || math.Abs(got[i][1]-routeTrack[i][1]) > 1e-5 {
			t.Fatalf("point %d = %v, want %v", i, got[i], routeTrack[i])
		}
	}
}

func TestDecodePolylineMalformedTailDrops(t *testing.T) {
	good := encodePolyline(routeTrack[:3])
	if n := len(decodePolyline(good + "_p")); n != 3 {
		t.Fatalf("malformed tail decoded to %d points, want the 3 whole pairs", n)
	}
	if n := len(decodePolyline("")); n != 0 {
		t.Fatalf("empty string decoded to %d points", n)
	}
}

func routeCtx() RenderCtx {
	return RenderCtx{Width: 72, Theme: DarkTheme(), Profile: NoColor}
}

func TestRouteRenderPlotsTrackWithMetaAndCaption(t *testing.T) {
	b := Block{Type: "route", Attrs: map[string]any{
		"polyline": encodePolyline(routeTrack),
		"sport":    "sykling",
		"distance": "42.3 km",
		"duration": "1t 48m",
		"caption":  "Rundt vannet",
	}}

	lines := routeRenderer{}.Render(b, routeCtx())
	if len(lines) < routeMinPlotH+2 {
		t.Fatalf("expected plot + meta + caption, got %d line(s):\n%s", len(lines), strings.Join(lines, "\n"))
	}

	// The plot must actually light braille dots (not a blank rectangle).
	plot := strings.Join(lines[:len(lines)-2], "\n")
	lit := false
	for _, r := range plot {
		if r >= 0x2801 && r <= 0x28FF {
			lit = true
			break
		}
	}
	if !lit {
		t.Fatalf("no braille dots lit in the plot:\n%s", plot)
	}

	meta := lines[len(lines)-2]
	for _, want := range []string{"sykling", "42.3 km", "1t 48m", "·"} {
		if !strings.Contains(meta, want) {
			t.Fatalf("meta row %q misses %q", meta, want)
		}
	}
	if !strings.Contains(lines[len(lines)-1], "Rundt vannet") {
		t.Fatalf("caption line %q misses the caption", lines[len(lines)-1])
	}
}

func TestRouteRenderHonestPlaceholderWithoutData(t *testing.T) {
	for name, attrs := range map[string]map[string]any{
		"absent":    {},
		"malformed": {"polyline": "!!"},
		"one point": {"polyline": encodePolyline(routeTrack[:1])},
	} {
		lines := routeRenderer{}.Render(Block{Type: "route", Attrs: attrs}, routeCtx())
		if len(lines) != 1 || !strings.Contains(lines[0], "route") {
			t.Fatalf("%s: want the single unresolved placeholder, got %q", name, lines)
		}
	}
}

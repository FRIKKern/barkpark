package pdrender

import (
	"encoding/json"
	"fmt"
	"runtime"
	"runtime/debug"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/charmbracelet/x/ansi"
)

// The wall-clock bound in limits_bound_test.go catches a render that blows up
// by an order of magnitude, but the slowest limit doc takes about 40 ms on a
// CI runner, so a doc could get 20 times slower and still pass one second.
// This check catches a smaller slowdown. It times each limit doc's render
// against a fixed calibration doc's render on the same machine, in the same
// process, and compares that ratio with the doc's base measured on main.
// Decoding is not timed: for some limit docs it costs more than the render and
// would dilute a renderer's slowdown.
//
// Three choices keep it from failing on a slow or loaded machine:
//   - It reads process CPU time, not the wall clock, so other processes
//     competing for the CPU do not count.
//   - Each doc render is paired with a calibration render right before it, and
//     the check takes the median of limitDocCostPairs pair ratios.
//   - It divides every doc's ratio by the median over the docs with a base. That
//     median is the machine factor: how much more or less the calibration doc
//     costs on this CPU than on the machine that measured the bases. A
//     slowdown in one renderer moves one or two docs, not the median.
//
// While measuring, GOMAXPROCS is 1 and the garbage collector is off, so the
// CPU time is the renderer's own work and does not depend on the core count.
// The alloc bound covers allocation.
//
// What it does not catch: a slowdown in decoding, a slowdown in code the
// calibration doc also runs (inline text and marks, headings, lists), a
// slowdown in more than half of the checked docs at once, and a render that
// waits rather than computes. The wall-clock bound still covers those when
// they are large.

// limitDocCostBase is each limit doc's render CPU time divided by the
// calibration doc's, measured on main (Apple M-series, 20 runs, median). Zero
// marks a doc whose render costs under limitDocCostFloor of the calibration
// render. Such a doc is too short to hold to its own base, so it is held to
// the floor instead. That still catches a blowup (a quadratic polyline scan
// takes the route doc from 0.005 to over 100), not a 5x slowdown.
//
// To re-measure after a change that legitimately makes a doc more expensive,
// run `go test ./internal/pdrender -run '^TestLimitDocsRenderWithinTheirBound$'
// -count=20 -v` and take the median of the "ratio" column per doc.
var limitDocCostBase = map[string]float64{
	"toc":            0,
	"sheet":          0,
	"table":          9.606,
	"heatmap":        1.673,
	"route":          0,
	"record table":   0,
	"tool diff":      3.119,
	"multi edit":     3.933,
	"nested columns": 0.311,
	"nested section": 2.970,
	"big number":     0,
	"nested strong":  0.230,
	"many merges":    2.229,
	"many spans":     2.151,
	"many marks":     0,
	"flat line":      0,
	"flat line high": 0,
}

const (
	// limitDocCostSlack is how far a doc's normalised cost may rise above its
	// base. On the measuring Mac the normalised cost of the docs with a base
	// stayed within 0.73 to 1.86 over 50 runs, 20 of them with eight extra
	// busy processes (load average up to 38). A renderer made 5x slower moved
	// its doc to 2.3 to 5.4, depending on how much of the doc's render that
	// renderer is.
	limitDocCostSlack = 2.5
	limitDocCostFloor = 0.2
	limitDocCostPairs = 7
)

// calibrationDoc is a fixed page of headings, wrapped paragraphs with marks,
// and short lists: block types the limit docs do not stress. It renders in
// about 4 ms on the measuring Mac.
func calibrationDoc() []byte {
	var blocks []any
	for i := range 60 {
		blocks = append(blocks,
			map[string]any{"type": "heading", "level": 2, "text": fmt.Sprintf("Section %d", i)},
			map[string]any{"type": "paragraph", "content": []any{
				map[string]any{"type": "text", "value": "The reader wraps this sentence at the screen width and keeps "},
				map[string]any{"type": "text", "value": "bold words", "marks": []any{"strong"}},
				map[string]any{"type": "text", "value": " and "},
				map[string]any{"type": "text", "value": "italic words", "marks": []any{"em"}},
				map[string]any{"type": "text", "value": " inside one paragraph that runs long enough to wrap twice or more at one hundred columns."},
			}},
			map[string]any{"type": "list", "items": []any{"first item of the list", "second item, a little longer than the first", "third"}},
		)
	}
	body, err := json.Marshal(map[string]any{"blocks": blocks})
	if err != nil {
		panic(err)
	}
	return body
}

// renderCPU decodes doc, then renders it once and returns the CPU time the
// render took. Decoding stays outside the measurement: for some limit docs it
// costs more than the render, and it would dilute a renderer's slowdown.
func renderCPU(t *testing.T, reg *Registry, doc []byte) (time.Duration, string) {
	t.Helper()
	blocks, err := Decode(doc)
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	runtime.GC()
	before, _ := processCPUTime()
	out := reg.RenderDoc(blocks, RenderCtx{Width: 100, Theme: LightTheme()})
	after, _ := processCPUTime()
	return after - before, out
}

func median(v []float64) float64 {
	s := slices.Clone(v)
	slices.Sort(s)
	if n := len(s); n%2 == 1 {
		return s[n/2]
	}
	return (s[len(s)/2-1] + s[len(s)/2]) / 2
}

func checkLimitDocCost(t *testing.T, reg *Registry, docs []limitDoc) {
	if raceDetector {
		t.Skip("the race detector changes each doc's cost relative to the calibration doc; the wall-clock bound applies")
	}
	if _, ok := processCPUTime(); !ok {
		t.Skip("no process CPU time on this OS; the wall-clock bound applies")
	}
	seen := map[string]bool{}
	for _, d := range docs {
		seen[d.Name] = true
		if _, ok := limitDocCostBase[d.Name]; !ok {
			t.Errorf("limit doc %q has no entry in limitDocCostBase; measure it as that comment says", d.Name)
		}
	}
	for name := range limitDocCostBase {
		if !seen[name] {
			t.Errorf("limitDocCostBase names %q, which is not in limit-docs.json; remove it", name)
		}
	}

	defer runtime.GOMAXPROCS(runtime.GOMAXPROCS(1))
	defer debug.SetGCPercent(debug.SetGCPercent(-1))

	cal := calibrationDoc()
	if _, out := renderCPU(t, reg, cal); !strings.Contains(ansi.Strip(out), "Section 59") {
		t.Fatalf("the calibration doc did not render its last heading:\n%.300s", out)
	}
	ratio := map[string]float64{}
	var normal []float64
	for _, d := range docs {
		pairs := make([]float64, 0, limitDocCostPairs)
		for range limitDocCostPairs {
			c, _ := renderCPU(t, reg, cal)
			r, _ := renderCPU(t, reg, d.Doc)
			if c > 0 {
				pairs = append(pairs, float64(r)/float64(c))
			}
		}
		if len(pairs) == 0 {
			t.Fatalf("%s: the calibration render took no measurable CPU time", d.Name)
		}
		ratio[d.Name] = median(pairs)
		if base := limitDocCostBase[d.Name]; base > 0 {
			normal = append(normal, ratio[d.Name]/base)
		}
	}
	factor := median(normal)
	t.Logf("machine factor %.2f (about 1.00 on the machine that measured the bases)", factor)
	for _, d := range docs {
		base, held := limitDocCostBase[d.Name], "base"
		if base == 0 {
			base, held = limitDocCostFloor, "floor"
		}
		cost := ratio[d.Name] / base / factor
		t.Logf("%-16s ratio %7.3f  %-5s %7.3f  normalised %5.2f", d.Name, ratio[d.Name], held, base, cost)
		if cost > limitDocCostSlack {
			t.Errorf("%s costs %.2f times its %s against the calibration render, over %.1f: a slowdown in its renderer, or a change that made it legitimately more expensive (then re-measure limitDocCostBase)", d.Name, cost, held, limitDocCostSlack)
		}
	}
}

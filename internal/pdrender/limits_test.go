package pdrender

import (
	"bytes"
	"cmp"
	"encoding/json"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"reflect"
	"runtime"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/charmbracelet/x/ansi"
)

// limitDocTime lives in limits_bound_test.go and limits_bound_race_test.go:
// the race detector needs a wider bound.
const limitDocAlloc = 100 << 20

var limitEdgeWidth = map[string]int{"flat line at the largest value": 200}

type limitEdge struct {
	Name  string            `json:"name"`
	Input json.RawMessage   `json:"input"`
	Shape []json.RawMessage `json:"shape"`
}

type limitDoc struct {
	Name string
	Doc  []byte
}

func loadLimitEdges(t *testing.T) []limitEdge {
	t.Helper()
	files, _ := filepath.Glob(filepath.Join(conformancePack, "limits", "*.golden.json"))
	sort.Strings(files)
	if len(files) == 0 {
		t.Fatal("no limit edges in the pack")
	}
	edges := make([]limitEdge, 0, len(files))
	for _, f := range files {
		raw, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		var e limitEdge
		if err := json.Unmarshal(raw, &e); err != nil {
			t.Fatalf("%s: %v", f, err)
		}
		edges = append(edges, e)
	}
	return edges
}

func loadLimitDocs(t *testing.T) []limitDoc {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join(conformancePack, "limit-docs.json"))
	if err != nil {
		t.Fatal(err)
	}
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	var pack struct {
		Docs []struct {
			Name string `json:"name"`
			Doc  any    `json:"doc"`
		} `json:"docs"`
	}
	if err := dec.Decode(&pack); err != nil {
		t.Fatal(err)
	}
	docs := make([]limitDoc, 0, len(pack.Docs))
	for _, d := range pack.Docs {
		body, err := json.Marshal(map[string]any{"blocks": []any{expandLimitDoc(d.Doc)}})
		if err != nil {
			t.Fatalf("%s: %v", d.Name, err)
		}
		docs = append(docs, limitDoc{Name: d.Name, Doc: body})
	}
	return docs
}

func expandLimitDoc(v any) any {
	switch x := v.(type) {
	case []any:
		out := make([]any, len(x))
		for i, e := range x {
			out[i] = expandLimitDoc(e)
		}
		return out
	case map[string]any:
		if n, ok := x["$repeat"]; ok {
			item := expandLimitDoc(x["of"])
			out := make([]any, limitCount(n))
			for i := range out {
				out[i] = item
			}
			return out
		}
		if s, ok := x["$text"].(string); ok {
			return strings.Repeat(s, limitCount(x["times"]))
		}
		if parts, ok := x["$concat"].([]any); ok {
			return concatLimitParts(parts)
		}
		if n, ok := x["$nest"]; ok {
			node := expandLimitDoc(x["leaf"])
			for range limitCount(n) {
				node = fillLimitHole(x["wrap"], node)
			}
			return node
		}
		out := make(map[string]any, len(x))
		for k, e := range x {
			out[k] = expandLimitDoc(e)
		}
		return out
	}
	return v
}

func concatLimitParts(parts []any) any {
	all := make([]any, len(parts))
	for i, p := range parts {
		all[i] = expandLimitDoc(p)
	}
	if len(all) > 0 {
		if _, ok := all[0].(string); ok {
			var b strings.Builder
			for _, s := range all {
				b.WriteString(s.(string))
			}
			return b.String()
		}
	}
	var out []any
	for _, l := range all {
		out = append(out, l.([]any)...)
	}
	return out
}

func fillLimitHole(v, inner any) any {
	switch x := v.(type) {
	case string:
		if x == "$hole" {
			return inner
		}
	case []any:
		out := make([]any, len(x))
		for i, e := range x {
			out[i] = fillLimitHole(e, inner)
		}
		return out
	case map[string]any:
		out := make(map[string]any, len(x))
		for k, e := range x {
			out[k] = fillLimitHole(e, inner)
		}
		return out
	}
	return v
}

func limitCount(v any) int {
	n, _ := v.(json.Number).Int64()
	return int(n)
}

func renderLimitText(t *testing.T, raw []byte, width int) string {
	t.Helper()
	blocks, err := Decode(raw)
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	return ansi.Strip(DefaultRegistry(LightTheme()).RenderDoc(blocks, RenderCtx{Width: width, Theme: LightTheme()}))
}

func TestLimitEdgesMatchTheElixirText(t *testing.T) {
	edges := loadLimitEdges(t)
	checked := 0
	for _, e := range edges {
		expected := goldenWords(e.Shape)
		if len(expected) == 0 {
			continue
		}
		checked++
		text := renderLimitText(t, []byte("["+string(e.Input)+"]"), cmp.Or(limitEdgeWidth[e.Name], 100))
		if diff := diffWords(text, expected); len(diff) > 0 {
			if len(diff) > conformanceDiffCap {
				diff = diff[:conformanceDiffCap]
			}
			t.Errorf("%s:\n  %s", e.Name, strings.Join(diff, "\n  "))
		}
	}
	t.Logf("%d edges, %d with words", len(edges), checked)
}

func TestLimitDocsRenderWithinTheirBound(t *testing.T) {
	reg := DefaultRegistry(LightTheme())
	for _, d := range loadLimitDocs(t) {
		runtime.GC()
		var before, after runtime.MemStats
		runtime.ReadMemStats(&before)
		start := time.Now()
		blocks, err := Decode(d.Doc)
		if err != nil {
			t.Errorf("%s: decode: %v", d.Name, err)
			continue
		}
		out := reg.RenderDoc(blocks, RenderCtx{Width: 100, Theme: LightTheme()})
		took := time.Since(start)
		runtime.ReadMemStats(&after)
		alloc := after.TotalAlloc - before.TotalAlloc
		t.Logf("%-16s %8s %6.1f MB", d.Name, took.Round(time.Millisecond), float64(alloc)/(1<<20))
		if took > limitDocTime {
			t.Errorf("%s took %s, over %s", d.Name, took, limitDocTime)
		}
		if alloc > limitDocAlloc {
			t.Errorf("%s allocated %.1f MB, over %d MB", d.Name, float64(alloc)/(1<<20), limitDocAlloc>>20)
		}
		if strings.HasPrefix(d.Name, "nested") && diffWords(ansi.Strip(out), conformanceWords(nestedTooDeep)) != nil {
			t.Errorf("%s does not show %q", d.Name, nestedTooDeep)
		}
	}
}

func renderBlockText(t *testing.T, block string, width int) string {
	t.Helper()
	return renderLimitText(t, []byte("["+block+"]"), width)
}

func recordTable(rows, keys int) string {
	cols := make([]string, keys)
	for i := range cols {
		cols[i] = fmt.Sprintf(`{"key":"k%d"}`, i)
	}
	return `{"type":"table","columns":[` + strings.Join(cols, ",") + `],"rows":[` + strings.TrimSuffix(strings.Repeat(`{"k0":"x"},`, rows), ",") + `]}`
}

func TestRecordTableShowsTheNoticePastTenThousandCells(t *testing.T) {
	if text := renderBlockText(t, recordTable(100, 100), 100); strings.Contains(text, tableTooLarge) || !strings.Contains(text, "┌") {
		t.Errorf("100x100 record table did not render as a table:\n%.300s", text)
	}
	if text := renderBlockText(t, recordTable(101, 100), 100); strings.TrimSpace(text) != tableTooLarge {
		t.Errorf("101x100 record table: %.300s", text)
	}
	if text := renderBlockText(t, recordTable(10001, 1), 100); strings.TrimSpace(text) != tableTooLarge {
		t.Errorf("10001x1 record table: %.300s", text)
	}
	plain := `{"type":"table","rows":[` + strings.TrimSuffix(strings.Repeat(`["x"],`, 20000), ",") + `]}`
	if strings.Contains(renderBlockText(t, plain, 100), tableTooLarge) {
		t.Error("a plain table was capped")
	}
}

func TestPlainTablePastTheCellCapDrawsOnlyTheColumnsThatFit(t *testing.T) {
	head := make([]string, 200)
	for i := range head {
		head[i] = fmt.Sprintf("%d", i)
	}
	rows := [][]string{head}
	for range 100 {
		rows = append(rows, []string{"x"})
	}
	if got := tableColumnsDrawn(nil, rows, 90); got != 30 {
		t.Errorf("101 rows x 200 columns at width 90 drew %d columns, want 30", got)
	}
	for range 900 {
		rows = append(rows, []string{"x"})
	}
	if got := tableColumnsDrawn(nil, rows, 90); got != 9 {
		t.Errorf("1001 rows x 200 columns drew %d columns, want 9", got)
	}
	if got := tableColumnsDrawn(nil, append(rows, make([][]string, 20000)...), 90); got != 1 {
		t.Errorf("21001 rows drew %d columns, want 1", got)
	}
	if got := tableColumnsDrawn(nil, rows[:50], 90); got != 200 {
		t.Errorf("50 rows x 200 columns drew %d columns, want all 200", got)
	}
}

func TestTocDepthClampsToSixAndDefaultsToTwo(t *testing.T) {
	var items []string
	for l := 1; l <= 8; l++ {
		items = append(items, fmt.Sprintf(`{"text":"h%d","level":%d}`, l, l))
	}
	toc := func(depth string) string {
		return renderBlockText(t, `{"type":"toc","numbered":true,"depth":`+depth+`,"items":[`+strings.Join(items, ",")+`]}`, 100)
	}
	if six, seven := toc("6"), toc("7"); six != seven || !strings.Contains(six, "h6") || strings.Contains(six, "h7") {
		t.Errorf("depth 7 is not depth 6:\n%s\n---\n%s", seven, six)
	}
	if toc("10000000") != toc("6") {
		t.Error("depth 10000000 is not depth 6")
	}
	if two, zero := toc("2"), toc("0"); zero != two || strings.Contains(two, "h3") {
		t.Errorf("depth 0 is not depth 2:\n%s\n---\n%s", zero, two)
	}
}

func TestFlatChartLineAtLargeValuesKeepsASpan(t *testing.T) {
	for _, v := range []float64{1e16, 1e20, 1e100, -1e100} {
		lo, hi := applyAxes(map[string]any{}, nil, v, v)
		if want := v + math.Max(1, math.Abs(v)*1e-9); hi <= lo || hi != want {
			t.Errorf("flat line at %g: span [%g, %g], want [%g, %g]", v, lo, hi, v, want)
		}
	}
	if lo, hi := applyAxes(map[string]any{}, nil, 3, 3); lo != 3 || hi != 4 {
		t.Errorf("flat line at 3: [%g, %g], want [3, 4]", lo, hi)
	}
}

func TestHeatmapPadsShortRowsOnlyWithinTheStoredCells(t *testing.T) {
	grid := [][]float64{{1, 2, 3, 4, 5, 6}, {7}, {8}}
	if got := heatPaddedRows(grid, 6); !reflect.DeepEqual(got, []bool{true, true, false}) {
		t.Errorf("padded rows %v, want [true true false]", got)
	}
	if got := heatPaddedRows([][]float64{{1, 2, 3}, {}, {4}}, 3); !reflect.DeepEqual(got, []bool{true, false, true}) {
		t.Errorf("an empty row took padding: %v", got)
	}
	matrix := `{"type":"heatmap","values":true,"cells":[[1,2,3,4,5,6],[7],[8]]}`
	lines := strings.Split(renderBlockText(t, matrix, 100), "\n")
	if got := strings.Fields(lines[1]); !reflect.DeepEqual(got, []string{"7", "0", "0", "0", "0", "0"}) {
		t.Errorf("matrix row 2 %q, want 7 then five zeros", got)
	}
	if got := strings.Fields(lines[2]); !reflect.DeepEqual(got, []string{"8"}) {
		t.Errorf("matrix row 3 %q, want 8 alone", got)
	}
	ledger := renderBlockText(t, `{"type":"heatmap","values":true,"rowLabels":["a","b","c"],"cells":[[1,2,3,4,5,6],[7],[8]]}`, 12)
	if got := strings.Count(ledger, "=0"); got != 5 {
		t.Errorf("ledger shows %d padded zeros, want 5:\n%s", got, ledger)
	}
	cal := strings.Split(renderBlockText(t, `{"type":"heatmap","mode":"calendar","cells":[[1,2,3,4,5,6],[7],[8]]}`, 100), "\n")
	if a, b := strings.Count(cal[1], heatZeroGlyph), strings.Count(cal[2], heatZeroGlyph); a != 5 || b != 0 {
		t.Errorf("calendar zero cells %d and %d, want 5 and 0", a, b)
	}
}

func TestPolylineValueStopsPastSevenGroups(t *testing.T) {
	if got := len(decodePolyline("_p~iF~ps|U_ulLnnqC~~~~~~??")); got != 3 {
		t.Errorf("seven groups: %d points, want 3", got)
	}
	if got := len(decodePolyline("_p~iF~ps|U_ulLnnqC~~~~~~~??")); got != 2 {
		t.Errorf("eight groups: %d points, want 2", got)
	}
}

func TestNumericTakesZeroAndFiniteMagnitudesInRange(t *testing.T) {
	for _, v := range []any{0.0, 1e100, -1e100, 1e-100, 3.5, "1e100", " 2 ", "0"} {
		if _, ok := numeric(v); !ok {
			t.Errorf("numeric(%#v) missed", v)
		}
	}
	for _, v := range []any{1e101, -1e101, 1e-101, "1e101", "NaN", "Inf", "-Infinity", "1e400", "x", nil, true} {
		if f, ok := numeric(v); ok {
			t.Errorf("numeric(%#v) = %g", v, f)
		}
	}
	for _, v := range []any{"NaN", "Inf"} {
		if f, ok := toFloat(v); ok {
			t.Errorf("toFloat(%#v) = %g", v, f)
		}
	}
	if f, ok := toFloat(1e101); !ok || f != 1e101 {
		t.Error("toFloat no longer takes a finite number past the range")
	}
}

func TestDataBlocksLeaveOutNumbersPastTheRange(t *testing.T) {
	bars := strings.Split(renderBlockText(t, `{"type":"bar-chart","bars":[{"label":"a","value":1e101},{"label":"b","value":2}]}`, 40), "\n")
	if strings.ContainsAny(bars[0], "▓█") || !strings.Contains(bars[1], "▓") && !strings.Contains(bars[1], "█") {
		t.Errorf("bar chart:\n%s", strings.Join(bars, "\n"))
	}
	if got := parseChartPoints([]any{1.0, 1e101, 3.0, -1e101, 5.0}); !reflect.DeepEqual(got, []float64{1, 3, 5}) {
		t.Errorf("chart points %v", got)
	}
	grid, _ := parseHeatCells(map[string]any{"cells": []any{[]any{1e101, 2.0}}})
	if !reflect.DeepEqual(grid, [][]float64{{0, 2}}) {
		t.Errorf("heat cells %v", grid)
	}
	if got := attrNumeric(map[string]any{"met": 1e101}, "met"); got != 0 {
		t.Errorf("criteria met %g", got)
	}
}

func TestDecodeKeepsABlockWithANumberPastFloat64(t *testing.T) {
	blocks, err := Decode([]byte(`[{"type":"heatmap","cells":[[1e400,2.5,` + "1" + strings.Repeat("0", 400) + `]]},{"type":"paragraph","text":"after"}]`))
	if err != nil || len(blocks) != 2 {
		t.Fatalf("Decode: %d blocks, %v", len(blocks), err)
	}
	row := blocks[0].Attrs["cells"].([]any)[0].([]any)
	if row[0] != "1e400" || row[1] != 2.5 || row[2] != "1"+strings.Repeat("0", 400) {
		t.Errorf("cells %#v", row)
	}
	if _, ok := numeric(row[0]); ok {
		t.Error("1e400 read as a number")
	}
}

func TestDecodeClipsJSONPastTheParserDepth(t *testing.T) {
	deep := strings.Repeat(`{"type":"strong","children":[`, 6000) + `"leaf"` + strings.Repeat(`]}`, 6000)
	text := renderBlockText(t, `{"type":"paragraph","content":[`+deep+`]}`, 100)
	if diffWords(text, conformanceWords(nestedTooDeep)) != nil {
		t.Errorf("a doc past the JSON depth: %.200q", text)
	}
	if got := string(clipJSONDepth([]byte(`{"a":[[1],"[{"],"b":{"c":{}}}`), 2)); got != `{"a":[null,"[{"],"b":{"c":null}}` {
		t.Errorf("clip: %s", got)
	}
}

var limitSlots = []struct {
	typ  string
	path []string
}{
	{"section", []string{"blocks", slotEach}},
	{"section", []string{"children", slotEach}},
	{"columns", []string{"columns", slotEach, slotEach}},
	{"terminal", []string{"blocks", slotEach}},
	{"terminal", []string{"children", slotEach}},
	{"expandable", []string{"blocks", slotEach}},
	{"expandable", []string{"children", slotEach}},
	{"tabs", []string{"tabs", slotEach, "blocks", slotEach}},
	{"steps", []string{"steps", slotEach, "blocks", slotEach}},
	{"steps", []string{"steps", slotEach, "children", slotEach}},
	{"figure", []string{"child"}},
	{"card", []string{"slots", "action", slotEach}},
	{"card", []string{"slots", "body", slotEach}},
	{"card", []string{"slots", "media", slotEach}},
	{"card", []string{"slots", "title", slotEach}},
	{"callout", []string{"slots", "body", slotEach}},
	{"note", []string{"slots", "body", slotEach}},
	{"note", []string{"slots", "label", slotEach}},
	{"note", []string{"slots", "lead", slotEach}},
	{"stage", []string{"slots", "detail", slotEach}},
	{"stage", []string{"slots", "kind", slotEach}},
	{"stage", []string{"slots", "title", slotEach}},
	{"list", []string{"items", slotEach, "children", slotEach}},
	{"ordered-list", []string{"items", slotEach, "children", slotEach}},
	{"numbered_list", []string{"items", slotEach, "children", slotEach}},
	{"bulletList", []string{"items", slotEach, "children", slotEach}},
	{"bullet_list", []string{"items", slotEach, "children", slotEach}},
	{"bulleted-list", []string{"items", slotEach, "children", slotEach}},
	{"bulleted_list", []string{"items", slotEach, "children", slotEach}},
}

func slotWrap(path []string, inner any) any {
	if len(path) == 0 {
		return inner
	}
	if path[0] == slotEach {
		return []any{slotWrap(path[1:], inner)}
	}
	return map[string]any{path[0]: slotWrap(path[1:], inner)}
}

func slotDig(v any, path []string) any {
	for _, k := range path {
		if k == slotEach {
			v = v.([]any)[0]
		} else {
			v = v.(map[string]any)[k]
		}
	}
	return v
}

func TestCapDepthWalksEverySlotAndStopsAtOneHundred(t *testing.T) {
	for _, s := range limitSlots {
		for _, levels := range []int{maxNestDepth - 1, maxNestDepth} {
			var node any = map[string]any{"type": "paragraph", "text": "leaf"}
			for range levels {
				block := slotWrap(s.path, node).(map[string]any)
				block["type"] = s.typ
				node = block
			}
			capped := capDepth(node, 0)
			for range levels {
				capped = slotDig(capped, s.path)
			}
			text := capped.(map[string]any)["text"]
			if want := map[int]string{maxNestDepth - 1: "leaf", maxNestDepth: nestedTooDeep}[levels]; text != want {
				t.Errorf("%s %v at %d levels: leaf reads %q, want %q", s.typ, s.path, levels, text, want)
			}
		}
	}
	if len(blockSlots) != 18 {
		t.Errorf("blockSlots has %d types, the Elixir table has 18", len(blockSlots))
	}
}

func TestInlineDepthCountsNodesListsAndMarks(t *testing.T) {
	ir := InlineRenderer{theme: LightTheme()}
	nest := func(levels int, wrap func(any) any) any {
		var n any = "leaf"
		for range levels {
			n = wrap(n)
		}
		return n
	}
	strong := func(n any) any { return map[string]any{"type": "strong", "children": []any{n}} }
	list := func(n any) any { return []any{n} }
	unknown := func(n any) any { return map[string]any{"type": "highlight", "children": []any{n}} }
	for name, wrap := range map[string]func(any) any{"strong": strong, "bare list": list, "unknown": unknown} {
		if got := ansi.Strip(ir.Inline([]any{nest(maxNestDepth-1, wrap)}, RenderCtx{})); got != "leaf" {
			t.Errorf("%s at 99: %q", name, got)
		}
		if got := ansi.Strip(ir.Inline([]any{nest(maxNestDepth, wrap)}, RenderCtx{})); got != nestedTooDeep {
			t.Errorf("%s at 100: %q", name, got)
		}
	}
	marks := func(n int) []any {
		m := make([]any, n)
		for i := range m {
			m[i] = "strong"
		}
		return m
	}
	text := func(n int) map[string]any { return map[string]any{"type": "text", "value": "x", "marks": marks(n)} }
	if got := ansi.Strip(ir.Inline([]any{text(maxNestDepth - 1)}, RenderCtx{})); got != "x" {
		t.Errorf("99 marks: %q", got)
	}
	if got := ansi.Strip(ir.Inline([]any{text(maxNestDepth)}, RenderCtx{})); got != nestedTooDeep {
		t.Errorf("100 marks: %q", got)
	}
	if got := ansi.Strip(ir.Inline([]any{strong(text(maxNestDepth - 1))}, RenderCtx{})); got != nestedTooDeep {
		t.Errorf("99 marks under a strong: %q", got)
	}
}

func TestNestingKeepsItsIndentAtTwentyColumns(t *testing.T) {
	raw, err := os.ReadFile("../../api/test/support/fixtures/nested-list-carriers.json")
	if err != nil {
		t.Fatal(err)
	}
	text := renderLimitText(t, raw, 20)
	for _, line := range []string{"• Plan", "  1. Build", "     • Verify", "  2. Ship", "  1. Alias child"} {
		if !strings.Contains(text, line) {
			t.Errorf("missing %q at 20 columns:\n%s", line, text)
		}
	}
	for _, block := range []string{
		`{"type":"expandable","summary":"S","blocks":[{"type":"paragraph","text":"inner"}]}`,
		`{"type":"steps","steps":[{"title":"T","blocks":[{"type":"paragraph","text":"inner"}]}]}`,
	} {
		if text := renderBlockText(t, block, 20); !strings.Contains(text, "\n  inner") {
			t.Errorf("child lost its indent at 20 columns:\n%s", text)
		}
	}
}

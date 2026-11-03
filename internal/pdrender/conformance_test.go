package pdrender

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"testing"
	"unicode"

	"github.com/charmbracelet/x/ansi"
)

const conformanceDiffCap = 12

var (
	conformancePack = filepath.Join("..", "..", "api", "priv", "portable_doc", "goldens")
	conformanceOut  = filepath.Join("..", "..", "api", "priv", "portable_doc", "conformance", "pdrender.json")
)

type goldenCase struct {
	Type  string            `json:"type"`
	Input json.RawMessage   `json:"input"`
	Shape []json.RawMessage `json:"shape"`
}

type conformanceRow struct {
	Type   string   `json:"type"`
	Status string   `json:"status"`
	Diff   []string `json:"diff,omitempty"`
}

type conformanceReport struct {
	Renderer  string           `json:"renderer"`
	Compare   string           `json:"compare"`
	PackStamp string           `json:"pack_stamp"`
	RanAtSha  string           `json:"ran_at_sha"`
	Rows      []conformanceRow `json:"rows"`
}

func loadGoldenPack(dir string) (string, []goldenCase, error) {
	stamp, err := os.ReadFile(filepath.Join(dir, "stamp.json"))
	if err != nil {
		return "", nil, fmt.Errorf("no golden pack at %s: %w", dir, err)
	}
	files, _ := filepath.Glob(filepath.Join(dir, "blocks", "*.golden.json"))
	sort.Strings(files)
	if len(files) == 0 {
		return "", nil, fmt.Errorf("golden pack at %s has zero block cases", dir)
	}
	cases := make([]goldenCase, 0, len(files))
	for _, f := range files {
		raw, err := os.ReadFile(f)
		if err != nil {
			return "", nil, err
		}
		var c goldenCase
		if err := json.Unmarshal(raw, &c); err != nil {
			return "", nil, fmt.Errorf("%s: %w", f, err)
		}
		cases = append(cases, c)
	}
	sum := sha256.Sum256(stamp)
	return hex.EncodeToString(sum[:]), cases, nil
}

type shapeNode struct {
	Text     *string     `json:"text"`
	Children []shapeNode `json:"children"`
}

func goldenWords(shape []json.RawMessage) []string {
	var leaves []string
	var walk func([]shapeNode)
	walk = func(nodes []shapeNode) {
		for _, n := range nodes {
			if n.Text != nil {
				leaves = append(leaves, *n.Text)
			} else {
				walk(n.Children)
			}
		}
	}
	for _, raw := range shape {
		var n shapeNode
		_ = json.Unmarshal(raw, &n)
		walk([]shapeNode{n})
	}
	return conformanceWords(strings.Join(leaves, " "))
}

func conformanceWords(s string) []string {
	edge := func(r rune) bool { return !unicode.IsLetter(r) && !unicode.IsNumber(r) }
	var out []string
	for _, w := range strings.Fields(strings.ToLower(s)) {
		if w = strings.TrimFunc(w, edge); w != "" {
			out = append(out, w)
		}
	}
	return out
}

func conformanceWordsSplitPunctuation(s string) []string {
	return strings.FieldsFunc(strings.ToLower(s), func(r rune) bool {
		return !unicode.IsLetter(r) && !unicode.IsNumber(r)
	})
}

func diffWords(actual string, expected []string) []string {
	return diffWordsFrom(conformanceWords(actual), expected)
}

func diffWordsSplitPunctuation(actual string, expected []string) []string {
	return diffWordsFrom(normalizeFigureWords(conformanceWordsSplitPunctuation(actual)), conformanceWordsSplitPunctuation(strings.Join(expected, " ")))
}

func diffWordsFrom(seen, expected []string) []string {
	var out []string
	at := 0
	for i, word := range expected {
		found := -1
		for j := at; j < len(seen); j++ {
			if seen[j] == word {
				found = j
				break
			}
		}
		if found == -1 {
			out = append(out, fmt.Sprintf("word %d/%d %q not found in order", i+1, len(expected), word))
		} else {
			at = found + 1
		}
	}
	return out
}

func diffWordsUnordered(actual string, expected []string) []string {
	available := map[string]int{}
	for _, word := range normalizeFigureWords(conformanceWords(actual)) {
		available[word]++
	}
	var out []string
	for i, word := range expected {
		if available[word] == 0 {
			out = append(out, fmt.Sprintf("word %d/%d %q not found", i+1, len(expected), word))
			continue
		}
		available[word]--
	}
	return out
}

func columnMajorText(actual string) string {
	lines := strings.Split(actual, "\n")
	var starts []int
	for _, line := range lines {
		runes := []rune(line)
		for i := 0; i < len(runes); {
			for i < len(runes) && unicode.IsSpace(runes[i]) {
				i++
			}
			if i == len(runes) {
				break
			}
			start := i
			for i < len(runes) && !unicode.IsSpace(runes[i]) {
				i++
			}
			if len(starts) == 0 || start-starts[len(starts)-1] >= 3 {
				starts = append(starts, start)
			}
		}
		break
	}
	if len(starts) < 2 {
		return actual
	}

	var cells, footer []string
	for col, start := range starts {
		end := -1
		if col+1 < len(starts) {
			end = starts[col+1]
		}
		for _, line := range lines {
			trimmed := strings.TrimSpace(line)
			if strings.HasPrefix(trimmed, "Kilde:") || strings.HasPrefix(trimmed, "Kilder:") ||
				strings.HasPrefix(trimmed, "Source:") || strings.HasPrefix(trimmed, "Sources:") {
				if col == 0 {
					footer = append(footer, trimmed)
				}
				continue
			}
			runes := []rune(line)
			if start >= len(runes) {
				continue
			}
			to := len(runes)
			if end >= 0 && end < to {
				to = end
			}
			if part := strings.TrimSpace(string(runes[start:to])); part != "" {
				cells = append(cells, part)
			}
		}
	}
	return strings.Join(append(cells, footer...), "\n")
}

func duelAssociationDiff(actual string, attrs map[string]any) []string {
	lines := strings.Split(actual, "\n")
	var out []string
	for i, row := range itemMaps(attrs, "rows") {
		label := sanitizeText(strings.TrimSpace(attrStr(row, "label")))
		valueA := sanitizeText(strings.TrimSpace(attrStr(row, "valueA")))
		valueB := sanitizeText(strings.TrimSpace(attrStr(row, "valueB")))
		unit := sanitizeText(strings.TrimSpace(attrStr(row, "unit")))
		if label == "" {
			continue
		}
		armA, armB := valueA, valueB
		if unit != "" {
			armA += " " + unit
			armB += " " + unit
		}
		expected := strings.Join(strings.Fields(label+" "+armA+" vs "+armB), " ")
		associated := false
		for _, line := range lines {
			if strings.Join(strings.Fields(line), " ") == expected {
				associated = true
				break
			}
		}
		if !associated {
			out = append(out, fmt.Sprintf("row %d %q is not associated with values %q and %q", i+1, label, valueA, valueB))
		}
	}
	return out
}

func normalizeFigureWords(words []string) []string {
	out := append([]string(nil), words...)
	for i, word := range out {
		switch word {
		case "kilde":
			out[i] = "source"
		case "kilder":
			out[i] = "sources"
		}
	}
	return out
}

func diffFigureWords(actual string, expected []string) []string {
	return diffWordsFrom(normalizeFigureWords(conformanceWords(actual)), expected)
}

func diffTrackedEyebrow(actual string, expected []string) []string {
	seen := conformanceWords(actual)
	allSingle := len(seen) > 1
	for _, word := range seen {
		if len([]rune(word)) != 1 {
			allSingle = false
			break
		}
	}
	if allSingle {
		seen = []string{strings.Join(seen, "")}
	}
	return diffWordsFrom(seen, expected)
}

func conformanceRowFor(reg *Registry, c goldenCase) conformanceRow {
	if _, ok := reg.blocks[c.Type]; !ok {
		return conformanceRow{Type: c.Type, Status: "missing"}
	}
	blocks, err := Decode([]byte("[" + string(c.Input) + "]"))
	if err != nil {
		return conformanceVerdict(c.Type, []string{"decode: " + err.Error()})
	}
	expected := goldenWords(c.Shape)
	if len(expected) == 0 {
		return conformanceRow{Type: c.Type, Status: "unchecked"}
	}
	text := ansi.Strip(reg.RenderDoc(blocks, RenderCtx{Width: 100, Theme: LightTheme()}))
	// Multi-column terminal layouts are read row-major in plain text while the
	// canonical DOM is read cell-major. Duel likewise keeps values and the
	// authored delta on separate visual rows. For those layouts, conformance is
	// presence-with-multiplicity; order would report visible words as missing.
	if c.Type == "duel" {
		diff := diffWordsUnordered(text, expected)
		diff = append(diff, duelAssociationDiff(text, blocks[0].Attrs)...)
		return conformanceVerdict(c.Type, diff)
	}
	if c.Type == "stat-grid" || c.Type == "stats" {
		return conformanceVerdict(c.Type, diffFigureWords(columnMajorText(text), expected))
	}
	if c.Type == "stat" {
		return conformanceVerdict(c.Type, diffWordsSplitPunctuation(text, expected))
	}
	if c.Type == "lineage" {
		return conformanceVerdict(c.Type, diffFigureWords(text, expected))
	}
	if c.Type == "eyebrow" {
		return conformanceVerdict(c.Type, diffTrackedEyebrow(text, expected))
	}
	return conformanceVerdict(c.Type, diffWords(text, expected))
}

func conformanceVerdict(typ string, diff []string) conformanceRow {
	if len(diff) == 0 {
		return conformanceRow{Type: typ, Status: "pass"}
	}
	if len(diff) > conformanceDiffCap {
		diff = append(diff[:conformanceDiffCap:conformanceDiffCap], fmt.Sprintf("… %d more", len(diff)-conformanceDiffCap))
	}
	return conformanceRow{Type: typ, Status: "fail", Diff: diff}
}

func runConformance(pack string, reg *Registry) (conformanceReport, error) {
	stamp, cases, err := loadGoldenPack(pack)
	if err != nil {
		return conformanceReport{}, err
	}
	probe := goldenCase{Type: "conformance-unknown", Input: json.RawMessage(`{"type":"conformance-unknown"}`)}
	if r := conformanceRowFor(reg, probe); r.Status != "missing" {
		return conformanceReport{}, fmt.Errorf("the runner cannot see a missing type: an unknown block read as %s", r.Status)
	}
	report := conformanceReport{Renderer: "pdrender", Compare: "text", PackStamp: stamp, RanAtSha: "unknown"}
	if sha, err := exec.Command("git", "rev-parse", "HEAD").Output(); err == nil {
		report.RanAtSha = strings.TrimSpace(string(sha))
	}
	for _, c := range cases {
		report.Rows = append(report.Rows, conformanceRowFor(reg, c))
	}
	return report, nil
}

func conformanceDrift(committed, report conformanceReport) []string {
	var out []string
	if committed.PackStamp != report.PackStamp {
		out = append(out, fmt.Sprintf("pack_stamp: committed %s != now %s", committed.PackStamp, report.PackStamp))
	}
	if committed.Renderer != report.Renderer || committed.Compare != report.Compare {
		out = append(out, fmt.Sprintf("renderer/compare: committed %s/%s", committed.Renderer, committed.Compare))
	}
	before := map[string]conformanceRow{}
	for _, r := range committed.Rows {
		before[r.Type] = r
	}
	for _, r := range report.Rows {
		if b, ok := before[r.Type]; !ok || !reflect.DeepEqual(b, r) {
			out = append(out, fmt.Sprintf("row %s drifted: committed %+v now %+v; rerun with CONFORMANCE_WRITE=1", r.Type, b, r))
		}
	}
	if len(committed.Rows) != len(report.Rows) {
		out = append(out, fmt.Sprintf("committed %d rows, pack has %d", len(committed.Rows), len(report.Rows)))
	}
	return out
}

func TestConformanceDriftRedsAStaleStampARowAndARenderer(t *testing.T) {
	report := conformanceReport{Renderer: "pdrender", Compare: "text", PackStamp: "a", Rows: []conformanceRow{{Type: "t", Status: "pass"}}}
	if d := conformanceDrift(report, report); d != nil {
		t.Errorf("an identical report drifted: %v", d)
	}
	stale, flipped, renamed := report, report, report
	stale.PackStamp = "b"
	flipped.Rows = []conformanceRow{{Type: "t", Status: "fail", Diff: []string{"d"}}}
	renamed.Compare = "dom"
	for name, r := range map[string]conformanceReport{"stamp": stale, "row": flipped, "compare": renamed} {
		if len(conformanceDrift(report, r)) != 1 {
			t.Errorf("a changed %s did not drift", name)
		}
	}
	if d := conformanceDrift(report, flipped); !strings.HasPrefix(d[0], "row t drifted") {
		t.Errorf("a drifted row is not named: %v", d)
	}
	extra := report
	extra.Rows = append([]conformanceRow{}, report.Rows...)
	extra.Rows = append(extra.Rows, conformanceRow{Type: "u", Status: "pass"})
	if d := conformanceDrift(extra, report); !reflect.DeepEqual(d, []string{"committed 2 rows, pack has 1"}) {
		t.Errorf("a committed report with an extra row: %v", d)
	}
}

func TestConformanceVerdictCapsTheDiffAtTwelveLines(t *testing.T) {
	var lines []string
	for i := 1; i <= 13; i++ {
		lines = append(lines, fmt.Sprintf("d%d", i))
	}
	if r := conformanceVerdict("t", lines); r.Status != "fail" || len(r.Diff) != 13 || r.Diff[11] != "d12" || r.Diff[12] != "… 1 more" {
		t.Errorf("13 diff lines: %+v", r)
	}
	if r := conformanceVerdict("t", lines[:12]); !reflect.DeepEqual(r.Diff, lines[:12]) {
		t.Errorf("12 diff lines: %+v", r)
	}
	if r := conformanceVerdict("t", nil); r.Status != "pass" {
		t.Errorf("no diff: %+v", r)
	}
}

func TestConformanceWordsSplitPunctuationAndLayoutComparisonCountsDuplicates(t *testing.T) {
	if got := conformanceWordsSplitPunctuation("71/118 add-error-shape"); !reflect.DeepEqual(got, []string{"71", "118", "add", "error", "shape"}) {
		t.Fatalf("punctuation tokenization: %v", got)
	}
	if diff := diffWordsUnordered("3 target 5 today", []string{"5", "today", "3", "target"}); diff != nil {
		t.Fatalf("row-major grid text should satisfy cell-major golden words: %v", diff)
	}
	if diff := diffWordsUnordered("one", []string{"one", "one"}); len(diff) != 1 {
		t.Fatalf("unordered comparison must preserve multiplicity: %v", diff)
	}
	if diff := diffTrackedEyebrow("D I S P A T C H E S", []string{"dispatches"}); diff != nil {
		t.Fatalf("tracked eyebrow should remain one semantic word: %v", diff)
	}
	if diff := diffFigureWords("Kilder: task:one", []string{"sources", "task:one"}); diff != nil {
		t.Fatalf("localized provenance label should match the canonical word: %v", diff)
	}
	gridExpected := []string{"5", "today", "3", "target"}
	if diff := diffFigureWords(columnMajorText("5     3\ntoday target"), gridExpected); diff != nil {
		t.Fatalf("column-major grid should preserve each value/label pair: %v", diff)
	}
	if diff := diffFigureWords(columnMajorText("5     3\ntarget today"), gridExpected); diff == nil {
		t.Fatal("swapped grid labels must not pass by word presence alone")
	}
	duel := map[string]any{"rows": []any{
		map[string]any{"label": "first", "valueA": "1", "valueB": "2"},
		map[string]any{"label": "second", "valueA": "3", "valueB": "4"},
	}}
	if diff := duelAssociationDiff("first  1 vs 2\nsecond  3 vs 4", duel); diff != nil {
		t.Fatalf("duel associations: %v", diff)
	}
	if diff := duelAssociationDiff("first  3 vs 4\nsecond  1 vs 2", duel); diff == nil {
		t.Fatal("swapped duel values must not pass by word presence alone")
	}
	if diff := duelAssociationDiff("first  2 vs 1\nsecond  3 vs 4", duel); diff == nil {
		t.Fatal("swapped duel arms must not pass by word presence alone")
	}
}

func TestConformanceRefusesARunnerThatCannotSeeMissing(t *testing.T) {
	reg := DefaultRegistry(LightTheme())
	reg.blocks["conformance-unknown"] = reg.blocks["paragraph"]
	if _, err := runConformance(conformancePack, reg); err == nil || !strings.Contains(err.Error(), "cannot see a missing type") {
		t.Errorf("a registry that renders the probe ran: %v", err)
	}
}

func TestConformanceNeverPassesACaseWithNoWords(t *testing.T) {
	reg := DefaultRegistry(LightTheme())
	r := conformanceRowFor(reg, goldenCase{Type: "divider", Input: json.RawMessage(`{"type":"divider"}`), Shape: []json.RawMessage{json.RawMessage(`{"tag":"hr","children":[]}`)}})
	if r.Status != "unchecked" {
		t.Errorf("a case with no golden words read %s", r.Status)
	}
}

func TestConformance(t *testing.T) {
	report, err := runConformance(conformancePack, DefaultRegistry(LightTheme()))
	if err != nil {
		t.Fatal(err)
	}
	counts := map[string]int{}
	for _, r := range report.Rows {
		counts[r.Status]++
	}
	t.Logf("pdrender: %d pass, %d fail, %d missing, %d unchecked of %d", counts["pass"], counts["fail"], counts["missing"], counts["unchecked"], len(report.Rows))

	if os.Getenv("CONFORMANCE_WRITE") == "1" {
		var buf bytes.Buffer
		enc := json.NewEncoder(&buf)
		enc.SetEscapeHTML(false)
		enc.SetIndent("", "  ")
		if err := enc.Encode(report); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(conformanceOut, buf.Bytes(), 0o644); err != nil {
			t.Fatal(err)
		}
	} else {
		raw, err := os.ReadFile(conformanceOut)
		if err != nil {
			t.Fatalf("%s is not committed; run with CONFORMANCE_WRITE=1: %v", conformanceOut, err)
		}
		var committed conformanceReport
		if err := json.Unmarshal(raw, &committed); err != nil {
			t.Fatal(err)
		}
		for _, d := range conformanceDrift(committed, report) {
			t.Error(d)
		}
	}
	if os.Getenv("CONFORMANCE_STRICT") == "1" {
		for _, r := range report.Rows {
			if r.Status != "pass" {
				t.Errorf("strict: %s is %s", r.Type, r.Status)
			}
		}
	}
}

func TestConformanceRefusesAnEmptyPack(t *testing.T) {
	if _, err := runConformance(filepath.Join(t.TempDir(), "absent"), DefaultRegistry(LightTheme())); err == nil {
		t.Error("an absent pack ran")
	}
	empty := t.TempDir()
	if err := os.WriteFile(filepath.Join(empty, "stamp.json"), []byte("{}"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := runConformance(empty, DefaultRegistry(LightTheme())); err == nil || !strings.Contains(err.Error(), "zero block cases") {
		t.Errorf("a pack with zero cases ran: %v", err)
	}
}

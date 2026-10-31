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

func goldenWords(shape []json.RawMessage) []string {
	var leaves []string
	var walk func([]json.RawMessage)
	walk = func(nodes []json.RawMessage) {
		for _, raw := range nodes {
			var n struct {
				Text     *string           `json:"text"`
				Children []json.RawMessage `json:"children"`
			}
			_ = json.Unmarshal(raw, &n)
			if n.Text != nil {
				leaves = append(leaves, *n.Text)
			} else {
				walk(n.Children)
			}
		}
	}
	walk(shape)
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

func diffWords(actual string, expected []string) []string {
	seen := conformanceWords(actual)
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

func conformanceRowFor(reg *Registry, c goldenCase) conformanceRow {
	if _, ok := reg.blocks[c.Type]; !ok {
		return conformanceRow{Type: c.Type, Status: "missing"}
	}
	blocks, err := Decode([]byte("[" + string(c.Input) + "]"))
	var diff []string
	if err != nil {
		diff = []string{"decode: " + err.Error()}
	} else {
		text := ansi.Strip(reg.RenderDoc(blocks, RenderCtx{Width: 100, Theme: LightTheme()}))
		diff = diffWords(text, goldenWords(c.Shape))
	}
	if len(diff) == 0 {
		return conformanceRow{Type: c.Type, Status: "pass"}
	}
	if len(diff) > conformanceDiffCap {
		diff = append(diff[:conformanceDiffCap], fmt.Sprintf("… %d more", len(diff)-conformanceDiffCap))
	}
	return conformanceRow{Type: c.Type, Status: "fail", Diff: diff}
}

func runConformance(pack string) (conformanceReport, error) {
	stamp, cases, err := loadGoldenPack(pack)
	if err != nil {
		return conformanceReport{}, err
	}
	reg := DefaultRegistry(LightTheme())
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
	if !reflect.DeepEqual(committed.Rows, report.Rows) {
		out = append(out, "rows drifted from "+conformanceOut+"; rerun with CONFORMANCE_WRITE=1")
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
}

func TestConformance(t *testing.T) {
	report, err := runConformance(conformancePack)
	if err != nil {
		t.Fatal(err)
	}
	counts := map[string]int{}
	for _, r := range report.Rows {
		counts[r.Status]++
	}
	t.Logf("pdrender: %d pass, %d fail, %d missing of %d", counts["pass"], counts["fail"], counts["missing"], len(report.Rows))

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
	if _, err := runConformance(filepath.Join(t.TempDir(), "absent")); err == nil {
		t.Error("an absent pack ran")
	}
	empty := t.TempDir()
	if err := os.WriteFile(filepath.Join(empty, "stamp.json"), []byte("{}"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := runConformance(empty); err == nil || !strings.Contains(err.Error(), "zero block cases") {
		t.Errorf("a pack with zero cases ran: %v", err)
	}
}

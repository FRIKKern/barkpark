package pdrender

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/charmbracelet/x/ansi"
)

// renderM6Fixture renders the M6 task-family fixture (task-list + task-detail +
// task-board + roadmap, plus one unresolved task-list) with NoColor pinned so the
// goldens are byte-stable. These blocks arrive PRE-RESOLVED — literal snapshot /
// task data lives in Attrs — so no RefResolver is needed.
func renderM6Fixture(t *testing.T, name string, width int) string {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("testdata", name))
	if err != nil {
		t.Fatalf("read fixture %s: %v", name, err)
	}
	blocks, err := Decode(raw)
	if err != nil {
		t.Fatalf("decode %s: %v", name, err)
	}
	reg := testRegistry() // pins lipgloss to Ascii (NoColor)
	ctx := RenderCtx{
		Width:   width,
		Theme:   DarkTheme(),
		Profile: NoColor,
	}
	out := reg.RenderDoc(blocks, ctx)
	stripped := ansi.Strip(out)
	// Shared blind-spot guard (unknown_block_guard_test.go): a golden diffed
	// against Go's OWN render cannot see a fallback box that appears on BOTH
	// sides. This is the one call that can.
	assertNoUnknownBlock(t, name, stripped)
	return stripped
}

// TestGoldenM6 renders the M6 task-family fixture (task-list as momentum header +
// phase bands + stacked rows, task-detail as a bordered card with ✓/○ criteria,
// task-board as stacked ready/progress/blocked/done lanes, roadmap as positioned
// │…▓▓…│ bars, and the unresolved task-list degrade line) at every golden width
// and diffs it against the checked-in golden (regenerate with -update).
func TestGoldenM6(t *testing.T) {
	const fx = "sample_m6.json"
	for _, w := range goldenWidths {
		w := w
		name := strings.TrimSuffix(fx, ".json")
		t.Run(name+"_w"+itoa(w), func(t *testing.T) {
			got := renderM6Fixture(t, fx, w)
			goldenPath := filepath.Join("testdata", "golden", name+"_w"+itoa(w)+".txt")
			if *update {
				if err := os.MkdirAll(filepath.Dir(goldenPath), 0o755); err != nil {
					t.Fatal(err)
				}
				if err := os.WriteFile(goldenPath, []byte(got), 0o644); err != nil {
					t.Fatal(err)
				}
				return
			}
			want, err := os.ReadFile(goldenPath)
			if err != nil {
				t.Fatalf("read golden (run with -update to create): %v", err)
			}
			if got != string(want) {
				t.Errorf("M6 render mismatch at width %d\n--- got ---\n%s\n--- want ---\n%s",
					w, got, string(want))
			}
		})
	}
}

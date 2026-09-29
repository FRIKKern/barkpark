package pdrender

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"testing"
)

// colContractFixtureRel is the ONE cross-runtime record of the table `cols`
// contract, relative TO THE REPO ROOT (not to this test's working directory).
const colContractFixtureRel = "api/test/support/fixtures/table-col-types.json"

// repoRoot walks up from the test's working directory until it finds the
// directory carrying go.mod (the module root == the repo root). It never counts
// "../" hops: a relative path that happens to resolve to nothing would otherwise
// leave every assertion below comparing two empty sets, i.e. passing forever
// while measuring nothing.
func repoRoot(t *testing.T) string {
	t.Helper()
	dir, err := os.Getwd()
	if err != nil {
		t.Fatalf("os.Getwd: %v", err)
	}
	for {
		if _, err := os.Stat(filepath.Join(dir, "go.mod")); err == nil {
			return dir
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			t.Fatalf("repo root not found: walked up from working dir to %q without seeing go.mod", dir)
		}
		dir = parent
	}
}

type colTypeContract struct {
	Types        []string          `json:"types"`
	RightAligned []string          `json:"right_aligned"`
	DeltaGlyphs  map[string]string `json:"delta_glyphs"`
}

// loadColTypeContract reads the fixture and REFUSES on an empty read — an
// unreadable path, a zero-byte file, or a decode that yields no terms is a
// failure, never a vacuous pass.
func loadColTypeContract(t *testing.T) colTypeContract {
	t.Helper()
	path := filepath.Join(repoRoot(t), colContractFixtureRel)
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read fixture %s: %v", path, err)
	}
	if len(raw) == 0 {
		t.Fatalf("fixture %s is empty (0 bytes) — refusing to compare against nothing", path)
	}
	var keyed map[string]json.RawMessage
	if err := json.Unmarshal(raw, &keyed); err != nil {
		t.Fatalf("fixture %s is not a JSON object: %v", path, err)
	}
	var keys []string
	for k := range keyed {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	var fx colTypeContract
	if err := json.Unmarshal(raw, &fx); err != nil {
		t.Fatalf("decode fixture %s: %v (keys present: %v)", path, err, keys)
	}
	if len(fx.Types) == 0 || len(fx.RightAligned) == 0 || len(fx.DeltaGlyphs) == 0 {
		t.Fatalf("fixture %s parsed EMPTY (types=%v right_aligned=%v delta_glyphs=%v); keys present: %v",
			path, fx.Types, fx.RightAligned, fx.DeltaGlyphs, keys)
	}
	return fx
}

func sortedCopy(in []string) []string {
	out := append([]string(nil), in...)
	sort.Strings(out)
	return out
}

// TestColTypeContractMatchesFixture holds the Go engine's `cols` literals
// term-identical to the cross-runtime fixture. It reds in BOTH directions: edit
// a term in the fixture, or edit a Go literal in richblocks.go, and this fails.
func TestColTypeContractMatchesFixture(t *testing.T) {
	fx := loadColTypeContract(t)

	if got, want := sortedCopy(colTypeNames), sortedCopy(fx.Types); !reflect.DeepEqual(got, want) {
		t.Errorf("col type set drifted: Go colTypeNames=%v, fixture %s types=%v", got, colContractFixtureRel, want)
	}
	if got, want := sortedCopy(colRightAlignNames), sortedCopy(fx.RightAligned); !reflect.DeepEqual(got, want) {
		t.Errorf("right-align set drifted: Go colRightAlignNames=%v, fixture %s right_aligned=%v", got, colContractFixtureRel, want)
	}
	if !reflect.DeepEqual(deltaGlyphs, fx.DeltaGlyphs) {
		t.Errorf("delta glyphs drifted: Go deltaGlyphs=%v, fixture %s delta_glyphs=%v", deltaGlyphs, colContractFixtureRel, fx.DeltaGlyphs)
	}

	// right_aligned must be a SUBSET of types — a fixture that right-aligns a
	// type the engine cannot produce is itself drift.
	for _, ra := range fx.RightAligned {
		if !hasColName(fx.Types, ra) {
			t.Errorf("fixture right_aligned %q is not in fixture types %v", ra, fx.Types)
		}
	}
}

// TestColTypeContractFixtureIsWiredToBehaviour proves the terms above are the
// ones the renderer actually emits: the fixture's glyphs come out of deltaCell,
// and the fixture's right_aligned entries are the ones colRightAlign accepts.
func TestColTypeContractFixtureIsWiredToBehaviour(t *testing.T) {
	fx := loadColTypeContract(t)
	tr := tableRenderer{ir: InlineRenderer{}}
	ctx := RenderCtx{}

	for _, c := range []struct {
		key  string
		cell any
	}{{"up", 3.0}, {"down", -3.0}, {"flat", 0.0}} {
		got := tr.deltaCell(c.cell, ctx)
		want := fx.DeltaGlyphs[c.key]
		if want == "" {
			t.Fatalf("fixture delta_glyphs missing %q (have %v)", c.key, fx.DeltaGlyphs)
		}
		if len(got) < len(want) || got[:len(want)] != want {
			t.Errorf("deltaCell(%v) = %q, want prefix %q (fixture delta_glyphs.%s)", c.cell, got, want, c.key)
		}
	}

	for _, typ := range fx.Types {
		want := hasColName(fx.RightAligned, typ)
		if got := colRightAlign([]string{typ}, 0); got != want {
			t.Errorf("colRightAlign(%q) = %v, fixture right_aligned=%v says %v", typ, got, fx.RightAligned, want)
		}
	}
}

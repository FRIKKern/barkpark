package pdrender

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"testing"

	"github.com/charmbracelet/x/ansi"
)

// ── the shared unknown-block guard ────────────────────────────────────────────
//
// blocks.go's fallbackRenderer degrades an unhandled block type to a labeled
// "unknown block: <type>" box instead of crashing. That degrade is DELIBERATE
// and stays — a reader must survive a forward-compatible document.
//
// The blind spot is in the TESTS, not the renderer. Every sample_m* harness
// diffs Go's render against Go's OWN committed golden, so when the Elixir
// producer adds or renames a block type BOTH sides say "unknown block", they
// match byte for byte, the suite stays green — and a real paper shows a grey box
// in the TUI and CLI. That has already shipped twice: see the file headers of
// composeblocks.go and gridblocks.go, each of which fixed ONE block family and
// left the blind spot intact for the next one.
//
// This file is the ONE assertion every fixture-loading harness calls, so the
// next drift reds a test instead of shipping. It is deliberately shared rather
// than pasted: a single place to widen when the fallback's label changes.

// unknownBlockReporter is the slice of *testing.T the guard needs. Taking an
// interface (not *testing.T) is what makes the guard's own NON-VACUITY
// testable — TestUnknownBlockGuardCanFail hands it a recorder and reads the
// message back. A guard that silently never evaluates looks identical to a
// guard that passes.
type unknownBlockReporter interface {
	Helper()
	Errorf(format string, args ...any)
}

// boxDrawing is the border/padding furniture lipgloss wraps around the fallback
// label. Stripping it before matching means the guard reads the same whether the
// caller passes a bare label or a full bordered box.
var boxDrawing = strings.NewReplacer(
	"│", " ", "┃", " ", "|", " ",
	"─", " ", "━", " ",
	"╭", " ", "╮", " ", "╰", " ", "╯", " ",
	"┌", " ", "┐", " ", "└", " ", "┘", " ",
)

// unknownBlockRe matches the fallback label emitted by fallbackRenderer.Render
// and captures the offending block type, so a failure NAMES the drifted type
// rather than just saying "something is wrong".
var unknownBlockRe = regexp.MustCompile(`(?i)unknown block:\s*(\S*)`)

// unknownBlockTypes returns every block type that rendered as the fallback box
// in out, de-duplicated and sorted. Empty means the render is clean.
func unknownBlockTypes(out string) []string {
	flat := strings.Join(strings.Fields(boxDrawing.Replace(ansi.Strip(out))), " ")
	seen := map[string]bool{}
	for _, m := range unknownBlockRe.FindAllStringSubmatch(flat, -1) {
		typ := m[1]
		if typ == "" {
			typ = "(unnamed)"
		}
		seen[typ] = true
	}
	types := make([]string, 0, len(seen))
	for typ := range seen {
		types = append(types, typ)
	}
	sort.Strings(types)
	return types
}

// assertNoUnknownBlock is THE guard. Every harness that renders a portable-doc
// fixture calls it; a rendered fallback box fails the test and names the block
// type the Go decoder does not know.
func assertNoUnknownBlock(t unknownBlockReporter, label, out string) {
	t.Helper()
	types := unknownBlockTypes(out)
	if len(types) == 0 {
		return
	}
	t.Errorf("%s: pdrender drew the unknown-block fallback box for %d block type(s): %s\n"+
		"The Go decoder does not know these types, so the TUI and CLI show a grey box "+
		"where the web reader renders content. Add a renderer (see composeblocks.go / "+
		"gridblocks.go for prior fixes) — do NOT regenerate the golden.\n--- render ---\n%s",
		label, len(types), strings.Join(types, ", "), out)
}

// ── blast-radius sweep ────────────────────────────────────────────────────────

// decodeFixtureBlocks turns a testdata file into a renderable block list. Two
// shapes exist in this corpus: a bare block ARRAY (the sample_m* documents), and
// the component goldens' object wrapper carrying one authored block under
// "input" (the shape renderComponent already renders). Anything else — the chat
// transcript / stable-frames / sheet-parity fixtures, whose own harnesses carry
// the guard directly — is reported as a skip rather than guessed at.
func decodeFixtureBlocks(raw []byte) ([]Block, error) {
	if blocks, err := Decode(raw); err == nil {
		return blocks, nil
	}
	var wrapper struct {
		Input json.RawMessage `json:"input"`
	}
	if err := json.Unmarshal(raw, &wrapper); err != nil || len(wrapper.Input) == 0 {
		return nil, fmt.Errorf("not a block array and no \"input\" block")
	}
	return Decode([]byte("[" + string(wrapper.Input) + "]"))
}

// TestNoFixtureRendersAnUnknownBlock is the corpus-wide measurement the per-
// harness calls cannot make: it walks EVERY testdata/*.json fixture, renders it
// at every golden width, and runs the shared guard. A fixture added tomorrow is
// covered the moment it lands, with no harness edit — the per-harness calls
// still matter because they fence the exact render CONFIGURATION (resolvers,
// profiles, widths) each harness exercises.
func TestNoFixtureRendersAnUnknownBlock(t *testing.T) {
	paths, err := filepath.Glob(filepath.Join("testdata", "*.json"))
	if err != nil {
		t.Fatal(err)
	}
	if len(paths) == 0 {
		t.Fatal("no fixtures found under testdata/ — the sweep would pass vacuously")
	}

	reg := testRegistry()
	rendered := 0
	var skipped []string
	for _, path := range paths {
		name := filepath.Base(path)
		raw, err := os.ReadFile(path)
		if err != nil {
			t.Fatalf("read %s: %v", name, err)
		}
		blocks, err := decodeFixtureBlocks(raw)
		if err != nil || len(blocks) == 0 {
			// Report every skip loudly so the sweep can never go quietly vacuous.
			// These fixtures are harness-specific shapes; their own harnesses call
			// assertNoUnknownBlock directly.
			t.Logf("SKIP %s: %v (covered by its own harness's guard call)", name, err)
			skipped = append(skipped, name)
			continue
		}
		rendered++
		for _, w := range goldenWidths {
			out := ansi.Strip(reg.RenderDoc(blocks, RenderCtx{Width: w, Theme: DarkTheme(), Profile: NoColor}))
			assertNoUnknownBlock(t, fmt.Sprintf("%s@w%d", name, w), out)
		}
	}
	t.Logf("unknown-block sweep: %d fixtures rendered at %d widths, %d skipped (%s)",
		rendered, len(goldenWidths), len(skipped), strings.Join(skipped, ", "))
	if rendered == 0 {
		t.Fatal("every fixture was skipped — the sweep proved nothing")
	}
}

// ── non-vacuity ───────────────────────────────────────────────────────────────

// recordingReporter captures what the guard would have told *testing.T.
type recordingReporter struct {
	helperCalls int
	messages    []string
}

func (r *recordingReporter) Helper() { r.helperCalls++ }
func (r *recordingReporter) Errorf(format string, args ...any) {
	r.messages = append(r.messages, fmt.Sprintf(format, args...))
}

// TestUnknownBlockGuardCanFail is the NON-VACUITY proof: feed the renderer a
// block type the decoder does not know, and the shared guard must red with a
// message naming the offending type. Without this, a guard that never evaluates
// is indistinguishable from one that passes.
func TestUnknownBlockGuardCanFail(t *testing.T) {
	reg := testRegistry()
	ctx := RenderCtx{Width: 80, Theme: DarkTheme(), Profile: NoColor}
	out := ansi.Strip(reg.RenderDoc([]Block{
		{Type: "paragraph", Attrs: map[string]any{"type": "paragraph",
			"content": []any{map[string]any{"type": "text", "value": "real content"}}}},
		{Type: "producer-added-me", Attrs: map[string]any{"type": "producer-added-me"}},
	}, ctx))

	// The runtime behaviour is UNCHANGED: the reader still degrades to a labeled
	// box rather than crashing (blocks.go keeps its fallback).
	if !strings.Contains(out, "producer-added-me") {
		t.Fatalf("expected the labeled fallback box to still render, got:\n%s", out)
	}

	rec := &recordingReporter{}
	assertNoUnknownBlock(rec, "synthetic", out)

	if len(rec.messages) != 1 {
		t.Fatalf("guard did not fire on an unknown block — it is vacuous; messages=%v", rec.messages)
	}
	if !strings.Contains(rec.messages[0], "producer-added-me") {
		t.Errorf("guard fired but did not NAME the offending block type:\n%s", rec.messages[0])
	}
	if rec.helperCalls != 1 {
		t.Errorf("expected the guard to mark itself a helper once, got %d", rec.helperCalls)
	}

	// …and it stays silent on a clean render, so it is not simply always-red.
	clean := ansi.Strip(reg.RenderDoc([]Block{
		{Type: "paragraph", Attrs: map[string]any{"type": "paragraph",
			"content": []any{map[string]any{"type": "text", "value": "real content"}}}},
	}, ctx))
	quiet := &recordingReporter{}
	assertNoUnknownBlock(quiet, "clean", clean)
	if len(quiet.messages) != 0 {
		t.Errorf("guard is always-red — it fired on a clean render:\n%v", quiet.messages)
	}
}

// TestUnknownBlockTypesNamesEveryType pins the extractor itself: it survives the
// lipgloss border furniture and reports each distinct type once.
func TestUnknownBlockTypesNamesEveryType(t *testing.T) {
	reg := testRegistry()
	out := reg.RenderDoc([]Block{
		{Type: "alpha-widget", Attrs: map[string]any{"type": "alpha-widget"}},
		{Type: "beta-widget", Attrs: map[string]any{"type": "beta-widget"}},
		{Type: "alpha-widget", Attrs: map[string]any{"type": "alpha-widget"}},
	}, RenderCtx{Width: 80, Theme: DarkTheme(), Profile: NoColor})

	got := unknownBlockTypes(out)
	want := []string{"alpha-widget", "beta-widget"}
	if strings.Join(got, ",") != strings.Join(want, ",") {
		t.Errorf("unknownBlockTypes = %v, want %v\n--- render ---\n%s", got, want, ansi.Strip(out))
	}
	if len(unknownBlockTypes("a perfectly ordinary paragraph")) != 0 {
		t.Error("unknownBlockTypes matched text that carries no fallback box")
	}
}

package pdrender

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// The two MALFORMED `notes` item shapes the wave-6 corpus census found, kept
// here verbatim because the live corpus no longer holds either: re-reading
// heggemsnes-act `hga-remedies` and epic-paper-beauty-reference-wave-2026-07-31
// `local-suite-note` on 2026-09-17 returned {"text": …} DICTS on both, where the
// 2026-08-17 dossier measured 5 bare strings and 2 inline-node lists. Nothing
// in the block grammar forbids a client from posting either shape, so the
// renderer still receives them — and this fixture is now the ONLY committed
// record of what they look like.
const (
	// heggemsnes-act `hga-remedies`, item 2 of 5, as the dossier measured it.
	heggemsnesBareStringItem = "PR #11556: his deleted testing disclosure stands again, word for word."
	// epic-paper-beauty-reference-wave-2026-07-31 `local-suite-note`, the
	// ProseMirror inline-node-LIST shape (dossier: the corpus's only one).
	beautyInlineListLead = "The isolated CI suite is the merge authority."
)

func notesTestdataPath(t *testing.T, name string) string {
	t.Helper()
	return filepath.Join("testdata", name)
}

// loadNotesFixture reads the committed malformed-shapes fixture. A missing or
// unparseable file FAILS rather than yielding an empty block — an absent
// fixture must never read as a passing empty case.
func loadNotesFixture(t *testing.T) map[string]any {
	t.Helper()
	raw, err := os.ReadFile(notesTestdataPath(t, "notes_malformed_items.json"))
	if err != nil {
		t.Fatalf("fixture unreadable: %v", err)
	}
	var block map[string]any
	if err := json.Unmarshal(raw, &block); err != nil {
		t.Fatalf("fixture unparseable: %v", err)
	}
	items, ok := block["items"].([]any)
	if !ok || len(items) != 3 {
		t.Fatalf("fixture must carry exactly 3 items (dict, bare string, inline list); got %#v", block["items"])
	}
	// CONTROL on the fixture's own shapes — if a future serializer round-trip
	// canonicalizes the file the way the live corpus was canonicalized, this
	// test must fail loudly instead of quietly measuring three dicts.
	if _, isStr := items[1].(string); !isStr {
		t.Fatalf("fixture item 1 must be a BARE STRING, got %T", items[1])
	}
	if _, isList := items[2].([]any); !isList {
		t.Fatalf("fixture item 2 must be an INLINE-NODE LIST, got %T", items[2])
	}
	return block
}

func renderNotes(t *testing.T, block map[string]any) string {
	t.Helper()
	lines := notesRenderer{}.Render(Block{Type: "notes", Attrs: block}, RenderCtx{Width: 80, Profile: NoColor})
	trimmed := make([]string, len(lines))
	for i, l := range lines {
		// notesRenderer right-pads the whole GROUP; a group-level comparison
		// would hide a wrong cell behind trailing spaces, so strip the padding
		// before asserting on the cells themselves.
		trimmed[i] = strings.TrimRight(l, " ")
	}
	return strings.Join(trimmed, "\n")
}

// TestNotesMalformedItemsRenderTheirProse is the RED arm: reverting
// noteItemMaps back to itemMaps in notesRenderer drops both malformed items and
// this fails on the two Contains assertions.
func TestNotesMalformedItemsRenderTheirProse(t *testing.T) {
	got := renderNotes(t, loadNotesFixture(t))

	if !strings.Contains(got, "well-formed") {
		t.Fatalf("dict item lost — control for the other two assertions failed:\n%s", got)
	}
	if !strings.Contains(got, "word for word") {
		t.Errorf("BARE STRING item dropped; its prose never reached the reader:\n%s", got)
	}
	if !strings.Contains(got, "merge authority") {
		t.Errorf("INLINE-NODE LIST item dropped; its prose never reached the reader:\n%s", got)
	}
}

// TestNotesMalformedDiffersFromEmptyAndAbsent proves the three states are not
// collapsed: malformed-with-prose must render DIFFERENTLY from both an
// all-empty measured row and an absent items list. Without the normalizer all
// three render the identical single blank line.
func TestNotesMalformedDiffersFromEmptyAndAbsent(t *testing.T) {
	malformed := renderNotes(t, map[string]any{
		"items": []any{heggemsnesBareStringItem},
	})
	measuredEmpty := renderNotes(t, map[string]any{
		"items": []any{map[string]any{"label": "", "lead": "", "text": ""}},
	})
	absent := renderNotes(t, map[string]any{})

	if malformed == measuredEmpty {
		t.Errorf("malformed item renders IDENTICALLY to a measured-empty row — a false %q is manufactured from a shape mismatch:\n%q", "the author wrote nothing", malformed)
	}
	if malformed == absent {
		t.Errorf("malformed item renders IDENTICALLY to an absent items list:\n%q", malformed)
	}
	// The deliberate SAMENESS, pinned so it is a decision and not an accident:
	// an author who wrote an all-empty row said nothing, exactly as absence does.
	if measuredEmpty != absent {
		t.Errorf("measured-empty and absent diverged; the doctrine pins them equal:\n empty=%q\nabsent=%q", measuredEmpty, absent)
	}
}

// TestNotesUnreadableMalformedStaysSilent is the QUIET arm: shapes that carry
// no prose at all (number, bool, nil, empty list, empty string) must NOT grow
// chrome — tolerance is for content, never for noise.
func TestNotesUnreadableMalformedStaysSilent(t *testing.T) {
	absent := renderNotes(t, map[string]any{})
	for _, junk := range []any{float64(42), true, nil, []any{}, ""} {
		got := renderNotes(t, map[string]any{"items": []any{junk}})
		if got != absent {
			t.Errorf("item %#v grew visible chrome; want the absent rendering %q, got %q", junk, absent, got)
		}
	}
}

// TestNotesWellFormedItemsUnchanged is the second QUIET arm: the dict path the
// whole corpus uses is byte-identical through the new normalizer.
func TestNotesWellFormedItemsUnchanged(t *testing.T) {
	attrs := map[string]any{"items": []any{
		map[string]any{"label": "Kernel", "lead": "16 types", "text": "the printable floor."},
		map[string]any{"label": "Notes", "text": "the grid this row is about."},
	}}
	viaNew := renderNotes(t, attrs)

	// Re-render through the OLD path (plain itemMaps) — for all-dict items the
	// two normalizers must agree exactly.
	if len(noteItemMaps(attrs, "items")) != len(itemMaps(attrs, "items")) {
		t.Fatalf("normalizers disagree on item count for an all-dict block")
	}
	if !strings.Contains(viaNew, "the printable floor.") || !strings.Contains(viaNew, "the grid this row is about.") {
		t.Errorf("well-formed dict rendering regressed:\n%s", viaNew)
	}
}

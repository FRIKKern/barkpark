package pdrender

import (
	"encoding/json"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	"github.com/charmbracelet/x/ansi"
)

// The Go leg of the cross-surface CHAT GOLDEN-TRANSCRIPT parity spine (charter
// D8 + D13, Mechanism A). ONE fixture of assistant-REPLY-BODY variants is
// synthesised by Elixir (`mix barkpark.chat.gen_golden_transcript`) — each
// variant carries the reply `markdown`, the EXACT `FromMarkdown.blocks/1` output
// (`blocks`, the shared JSON both surfaces consume — D8), and a structural
// `projection` (top-level type sequence + the key text each block must realize).
// It is mirrored byte-for-byte into api/test/support/fixtures. The Elixir
// freshness lock (chat_golden_transcript_parity_test.exs) proves the fixture
// still equals the generator; THIS test proves the TUI's render path
// (`Decode` → `DefaultRegistry(...).RenderDoc`) realizes that same projection —
// the same blocks Studio renders, drawn faithfully in the terminal with zero
// `unknown block:` fallback.
//
// REPLY-BODY-ONLY scope (charter D13): this covers ONLY the settled assistant
// reply body. Tool / todo / approval / thinking rows are bespoke HEEx with no
// pdrender twin — their TUI renderers + parity mechanism are the named backlog
// slice `ct-bl-toolrow-renderers`, NOT silently covered here.
//
// Mechanism A: field/structural projection, never a cross-engine byte-diff (a
// HEEx string and an ANSI terminal string can never be byte-equal). The shared
// truth is the block JSON + the projection; this leg asserts its NATIVE
// realization — stripped-ANSI, whitespace-collapsed, case-insensitive presence
// of every significant word (uppercased h1 / uppercased table heads are folded
// by the case-insensitivity; wrap boundaries are folded by the whitespace strip).

type chatGoldenFixture struct {
	Scope    string              `json:"scope"`
	Comment  string              `json:"_comment"`
	Variants []chatGoldenVariant `json:"variants"`
}

type chatGoldenVariant struct {
	Name       string          `json:"name"`
	Markdown   string          `json:"markdown"`
	Blocks     json.RawMessage `json:"blocks"`
	Projection []chatProjEntry `json:"projection"`
}

type chatProjEntry struct {
	Type  string `json:"type"`
	Level int    `json:"level"`
	Text  string `json:"text"`
}

func loadChatGolden(t *testing.T) chatGoldenFixture {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("testdata", "chat_golden_transcript.json"))
	if err != nil {
		t.Fatalf("read chat golden-transcript fixture: %v", err)
	}
	var fx chatGoldenFixture
	if err := json.Unmarshal(raw, &fx); err != nil {
		t.Fatalf("decode chat golden-transcript fixture: %v", err)
	}
	// Floor guards: the fixture is generated; a gutted or truncated regen must
	// RED here instead of silently shrinking what the asserts below cover.
	if fx.Scope != "assistant-reply-body-only" {
		t.Fatalf("fixture floor: scope = %q, want assistant-reply-body-only (D13)", fx.Scope)
	}
	if !strings.Contains(fx.Comment, "ct-bl-toolrow-renderers") {
		t.Fatalf("fixture floor: comment must state the reply-body-only scope boundary (D13)")
	}
	if len(fx.Variants) < 3 {
		t.Fatalf("fixture floor: %d variants, want >= 3", len(fx.Variants))
	}
	return fx
}

// wordRe matches a significant word: an alphanumeric run of length >= 4. Words
// this length never wrap-split at the widths below, so each must appear as a
// contiguous run in the whitespace-collapsed render.
var wordRe = regexp.MustCompile(`[A-Za-z0-9]{4,}`)

// significantWords returns the >=4-char alphanumeric tokens of a projection
// text — the words whose presence in the render proves the block realized.
func significantWords(text string) []string {
	return wordRe.FindAllString(text, -1)
}

// collapse strips ANSI, removes ALL whitespace, and lowercases — the haystack a
// projection word is looked up in. Whitespace removal folds render-time wrapping
// and box padding; lowercasing folds the h1 / table-head uppercasing.
func collapse(s string) string {
	return strings.ToLower(strings.Join(strings.Fields(ansi.Strip(s)), ""))
}

// TestChatGoldenTranscriptParity is the reply-body render-parity proof: every
// variant's blocks decode to exactly the projected type sequence, render through
// the real Decode -> RenderDoc seam with zero unknown-block fallback, and every
// block's key projection text is realized in the terminal output.
func TestChatGoldenTranscriptParity(t *testing.T) {
	fx := loadChatGolden(t)
	reg := DefaultRegistry(DarkTheme())
	// A realistic chat viewport width — narrow enough to exercise wrapping/degrade
	// paths, which the whitespace-collapsed realization check tolerates.
	ctx := RenderCtx{Width: 80, Theme: DarkTheme(), Profile: NoColor}

	seenTypes := map[string]bool{}
	seenLevels := map[int]bool{}

	for _, v := range fx.Variants {
		v := v
		t.Run(v.Name, func(t *testing.T) {
			if len(v.Projection) == 0 {
				t.Fatalf("variant %q has an empty projection", v.Name)
			}

			blocks, err := Decode(v.Blocks)
			if err != nil {
				t.Fatalf("decode blocks: %v", err)
			}

			// (1) Structural parity: the decoded top-level type sequence equals the
			// projection's — the shared JSON (D8) decodes to exactly the projected
			// shape, no drift.
			if len(blocks) != len(v.Projection) {
				t.Fatalf("decoded %d blocks, projection has %d entries", len(blocks), len(v.Projection))
			}
			for i, entry := range v.Projection {
				if blocks[i].Type != entry.Type {
					t.Fatalf("block %d: decoded type %q, projection type %q", i, blocks[i].Type, entry.Type)
				}
				seenTypes[entry.Type] = true
				// Heading level survives the round-trip too.
				if entry.Type == "heading" {
					lvl := attrInt(blocks[i].Attrs, "level", 0)
					if lvl != entry.Level {
						t.Fatalf("block %d heading: decoded level %d, projection level %d", i, lvl, entry.Level)
					}
					seenLevels[entry.Level] = true
				}
			}

			// (2) No fallback: every block type has a real renderer.
			out := reg.RenderDoc(blocks, ctx)
			stripped := ansi.Strip(out)
			assertNoUnknownBlock(t, "chat transcript variant "+v.Name, stripped)

			// (3) Realization: every block's key projection text appears in the
			// render (whitespace-collapsed, case-insensitive per-word presence).
			hay := collapse(out)
			for _, entry := range v.Projection {
				words := significantWords(entry.Text)
				if len(words) == 0 {
					t.Fatalf("projection %q/%q carries no significant (>=4-char) word", v.Name, entry.Type)
				}
				for _, w := range words {
					if !strings.Contains(hay, strings.ToLower(w)) {
						t.Fatalf(
							"variant %q %q block: projection word %q not realized in render:\n%s",
							v.Name, entry.Type, w, stripped,
						)
					}
				}
			}
		})
	}

	// (4) Coverage floor across the whole fixture: every required block type and
	// all three heading levels realized somewhere — a gutted regen reds here.
	for _, want := range []string{"heading", "paragraph", "list", "table", "code", "diagram", "callout", "stats"} {
		if !seenTypes[want] {
			t.Fatalf("coverage floor: block type %q never appeared — regen dropped coverage", want)
		}
	}
	for _, lvl := range []int{1, 2, 3} {
		if !seenLevels[lvl] {
			t.Fatalf("coverage floor: heading level %d never appeared", lvl)
		}
	}
}

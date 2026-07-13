package pdrender

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/charmbracelet/x/ansi"
)

// The Go leg of the cross-surface CHAT TOOLROWS parity spine (charter D25,
// Law 1 — Mechanism A, the sibling of chat_golden_parity_test.go). Where that
// test covers the settled assistant REPLY BODY, this one covers the three
// structural chat rows that used to be GUI-only bespoke HEEx: chat-tool-diff,
// chat-todo, chat-thinking. The shared truth is the typed block maps — the
// Elixir generator (`mix barkpark.chat.gen_golden_toolrows`) writes them from
// the SAME derivations Studio renders (TextDiff.diff_lines/2, the todo
// glyph/progress logic, the thinking token count) and mirrors them byte-for-byte
// into api/test/support/fixtures + this testdata dir. THIS leg proves the TUI's
// render path (Decode -> DefaultRegistry(...).RenderDoc) realizes that same
// projection with ZERO unknown-block fallback — the Law-1 promise that every
// chat affordance renders on BOTH surfaces made a CI fact.
//
// Technique mirrors chat_golden_parity_test.go exactly: decode the shared JSON,
// render through the real seam, strip ANSI, and assert every projection
// significant word appears (whitespace-collapsed, case-insensitive). The struct
// types, wordRe, significantWords, and collapse helpers are REUSED from that
// sibling test (same package) — one projection technique, not a fork.

// loadChatToolrowsGolden reads the toolrows fixture and floor-guards it: a gutted
// or truncated regen must RED here instead of silently shrinking coverage.
func loadChatToolrowsGolden(t *testing.T) chatGoldenFixture {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("testdata", "chat_golden_toolrows.json"))
	if err != nil {
		t.Fatalf("read chat toolrows golden fixture: %v", err)
	}
	var fx chatGoldenFixture
	if err := json.Unmarshal(raw, &fx); err != nil {
		t.Fatalf("decode chat toolrows golden fixture: %v", err)
	}
	if fx.Scope != "chat-toolrows-only" {
		t.Fatalf("fixture floor: scope = %q, want chat-toolrows-only (D25)", fx.Scope)
	}
	if !strings.Contains(fx.Comment, "gen_golden_toolrows") {
		t.Fatalf("fixture floor: comment must name the sibling generator so a hand-edit is caught")
	}
	if len(fx.Variants) < 3 {
		t.Fatalf("fixture floor: %d variants, want >= 3 (one per structural block type)", len(fx.Variants))
	}
	return fx
}

// TestChatGoldenToolrowsParity is the toolrows render-parity proof: every variant
// decodes to exactly the projected type sequence, renders through the real
// Decode -> RenderDoc seam with zero unknown-block fallback, and every block's
// key projection text is realized in the terminal output — the same rows Studio
// draws, now drawn in the terminal.
func TestChatGoldenToolrowsParity(t *testing.T) {
	fx := loadChatToolrowsGolden(t)
	reg := DefaultRegistry(DarkTheme())
	// A realistic chat viewport width, wide enough that the crafted fixture lines
	// never cell-truncate (truncation would drop projection words legitimately).
	ctx := RenderCtx{Width: 80, Theme: DarkTheme(), Profile: NoColor}

	seenTypes := map[string]bool{}

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
			// projection's — the shared JSON decodes to exactly the projected shape.
			if len(blocks) != len(v.Projection) {
				t.Fatalf("decoded %d blocks, projection has %d entries", len(blocks), len(v.Projection))
			}
			for i, entry := range v.Projection {
				if blocks[i].Type != entry.Type {
					t.Fatalf("block %d: decoded type %q, projection type %q", i, blocks[i].Type, entry.Type)
				}
				seenTypes[entry.Type] = true
			}

			// (2) No fallback: every structural block type has a real renderer — the
			// whole point of promoting these rows to block types (Law 1).
			out := reg.RenderDoc(blocks, ctx)
			stripped := ansi.Strip(out)
			if strings.Contains(stripped, "unknown block") {
				t.Fatalf("variant %q fell through to the unknown-block box:\n%s", v.Name, stripped)
			}

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

	// (4) Coverage floor: all three promoted block types realized somewhere — a
	// regen that drops one reds here.
	for _, want := range []string{"chat-tool-diff", "chat-todo", "chat-thinking"} {
		if !seenTypes[want] {
			t.Fatalf("coverage floor: block type %q never appeared — regen dropped coverage", want)
		}
	}
}

// TestChatToolDiffPathFromInput pins the tolerant file-path read: the LIVE
// Elixir controller (chat_tool_diff_block) nests the tool call under `input`,
// so the mutated path arrives as `input.file_path`, NOT a flat `path` like the
// golden fixture carries. Without the nested fallback the diff card header is
// path-less on real /v1/chat data — a silent Law-1 parity break the fixture
// (flat-path only) cannot catch. This renders the real server shape and asserts
// the path is drawn.
func TestChatToolDiffPathFromInput(t *testing.T) {
	reg := DefaultRegistry(DarkTheme())
	ctx := RenderCtx{Width: 80, Theme: DarkTheme(), Profile: NoColor}

	// The exact shape ChatController.message_json emits for a file-mutating tool
	// row: whole tool input under "input", derived lines/added/removed flat.
	raw := []byte(`[{"type":"chat-tool-diff","input":{"file_path":"lib/barkpark/chat.ex","old_string":"a","new_string":"b"},"lines":[{"op":"=","text":"keep"},{"op":"-","text":"a"},{"op":"+","text":"b"}],"added":1,"removed":1}]`)
	blocks, err := Decode(raw)
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	out := ansi.Strip(reg.RenderDoc(blocks, ctx))
	if !strings.Contains(out, "lib/barkpark/chat.ex") {
		t.Fatalf("nested input.file_path not rendered in diff header:\n%s", out)
	}
}

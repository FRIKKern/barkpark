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
// chat-todo, chat-thinking.
//
// ONE fixture, ONE schema: the Elixir generator (`mix
// barkpark.chat.gen_golden_toolrows`) is the sole authoritative writer of the
// fixture and mirrors it BYTE-FOR-BYTE into api/test/support/fixtures + this
// testdata dir (the Elixir freshness test asserts both mirrors decode
// term-identical). This Go leg therefore consumes THAT schema verbatim — a
// variant is `{kind, name, source, block, projection:{type,text}}` with a
// SINGLE typed block per variant — so the two halves lock one fixture and the
// golden gate spans both surfaces on merge (charter's two-halves-one-deliverable
// contract). We do NOT keep a second, divergent Go-authored fixture: that would
// conflict with the generator's mirror and split the "one truth."
//
// The proof: each variant's block decodes through the real Decode -> RenderDoc
// seam with ZERO unknown-block fallback, and every significant word of the
// Elixir-derived projection text is realized in the terminal render — the
// Law-1 promise that every chat affordance renders on BOTH surfaces, made a CI
// fact. Technique (significantWords / collapse / ANSI strip) is REUSED from the
// reply-body sibling; chatProjEntry is shared. Only the top-level variant shape
// differs (single block + single projection object), so it gets its own struct.

// chatToolrowsFixture mirrors the generator's toolrows schema (distinct from the
// reply-body chatGoldenFixture: one block + one projection object per variant).
type chatToolrowsFixture struct {
	Scope    string                `json:"scope"`
	Comment  string                `json:"_comment"`
	Variants []chatToolrowsVariant `json:"variants"`
}

type chatToolrowsVariant struct {
	Kind       string          `json:"kind"`
	Name       string          `json:"name"`
	Block      json.RawMessage `json:"block"`
	Projection chatProjEntry   `json:"projection"`
}

// loadChatToolrowsGolden reads the toolrows fixture and floor-guards it: a gutted
// or truncated regen must RED here instead of silently shrinking coverage. The
// scope + generator-name guards also make a schema DRIFT (a hand-swap to some
// other fixture) red loudly rather than parse to zero variants.
func loadChatToolrowsGolden(t *testing.T) chatToolrowsFixture {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("testdata", "chat_golden_toolrows.json"))
	if err != nil {
		t.Fatalf("read chat toolrows golden fixture: %v", err)
	}
	var fx chatToolrowsFixture
	if err := json.Unmarshal(raw, &fx); err != nil {
		t.Fatalf("decode chat toolrows golden fixture: %v", err)
	}
	// The generator stamps this scope on BOTH mirrors; a mismatch means the Go
	// leg is reading a different/older fixture than Studio locked.
	if fx.Scope != "chat-tool-todo-thinking-rows" {
		t.Fatalf("fixture floor: scope = %q, want chat-tool-todo-thinking-rows (D25)", fx.Scope)
	}
	if !strings.Contains(fx.Comment, "gen_golden_toolrows") {
		t.Fatalf("fixture floor: comment must name the generator so a hand-edit is caught")
	}
	if len(fx.Variants) < 3 {
		t.Fatalf("fixture floor: %d variants, want >= 3 (one per structural block type)", len(fx.Variants))
	}
	return fx
}

// TestChatGoldenToolrowsParity is the toolrows render-parity proof: every
// variant's single typed block decodes to exactly the projected type, renders
// through the real Decode -> RenderDoc seam with zero unknown-block fallback,
// and every significant word of the projection text is realized in the terminal
// output — the same rows Studio draws, now drawn in the terminal.
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
			if strings.TrimSpace(v.Projection.Text) == "" {
				t.Fatalf("variant %q has an empty projection text", v.Name)
			}

			// A variant carries ONE block; wrap it in an array for the shared
			// Decode seam (which accepts a bare block array).
			blocks, err := Decode([]byte("[" + string(v.Block) + "]"))
			if err != nil {
				t.Fatalf("decode block: %v", err)
			}

			// (1) Structural parity: the block decodes to exactly one block whose
			// type equals the projection's type.
			if len(blocks) != 1 {
				t.Fatalf("variant %q decoded %d blocks, want exactly 1", v.Name, len(blocks))
			}
			if blocks[0].Type != v.Projection.Type {
				t.Fatalf("variant %q: decoded type %q, projection type %q", v.Name, blocks[0].Type, v.Projection.Type)
			}
			seenTypes[v.Projection.Type] = true

			// (2) No fallback: every structural block type has a real renderer — the
			// whole point of promoting these rows to block types (Law 1).
			out := reg.RenderDoc(blocks, ctx)
			stripped := ansi.Strip(out)
			if strings.Contains(stripped, "unknown block") {
				t.Fatalf("variant %q fell through to the unknown-block box:\n%s", v.Name, stripped)
			}

			// (3) Realization: every significant projection word appears in the
			// render (whitespace-collapsed, case-insensitive per-word presence).
			hay := collapse(out)
			words := significantWords(v.Projection.Text)
			if len(words) == 0 {
				t.Fatalf("projection %q/%q carries no significant (>=4-char) word", v.Name, v.Projection.Type)
			}
			for _, w := range words {
				if !strings.Contains(hay, strings.ToLower(w)) {
					t.Fatalf(
						"variant %q %q block: projection word %q not realized in render:\n%s",
						v.Name, v.Projection.Type, w, stripped,
					)
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
// so the mutated path arrives as `input.file_path`, NOT a flat `path`. Without
// the nested fallback the diff card header is path-less on real /v1/chat data —
// a silent Law-1 parity break the projection-text asserts do not cover (the
// generator's projection omits the path). This renders the real server shape and
// asserts the path is drawn.
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

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
	Kind       string           `json:"kind"`
	Name       string           `json:"name"`
	Block      json.RawMessage  `json:"block"`
	Projection chatToolrowsProj `json:"projection"`
}

// chatToolrowsProj is the toolrows projection entry: the reply-body
// chatProjEntry's {type,text} plus the budget-aware `overflow` field the
// generator stamps on chat-tool-diff variants (charter D40) — the literal
// number of DRAWABLE rows the fold discards, asserted verbatim so a
// raw-element budget (which would count folded gap separators too) reds on
// the number, not just on word presence.
type chatToolrowsProj struct {
	Type     string `json:"type"`
	Text     string `json:"text"`
	Overflow int    `json:"overflow"`
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
	if len(fx.Variants) < 6 {
		t.Fatalf("fixture floor: %d variants, want >= 6 (>=1 per promoted block type: 3 inert + 3 cards)", len(fx.Variants))
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
			assertNoUnknownBlock(t, "chat toolrow variant "+v.Name, stripped)

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

			// (4) The fold NUMBER (charter D40): a chat-tool-diff variant's
			// overflow footnote must show the generator's drawable-only count
			// VERBATIM. Word presence is blind to the number — under a
			// raw-element budget the adjudicating variant (24 drawable + 2
			// folded-region gaps) would honestly render "+6 more lines" and
			// still realize every projected word; asserting the literal "+4"
			// is what makes the non-ratified reading red.
			if v.Projection.Type == "chat-tool-diff" {
				if v.Projection.Overflow > 0 {
					want := "… +" + itoa(v.Projection.Overflow) + " more lines"
					if !strings.Contains(stripped, want) {
						t.Fatalf(
							"variant %q: overflow footnote %q not rendered (drawable-only budget, D40):\n%s",
							v.Name, want, stripped,
						)
					}
				} else if strings.Contains(stripped, "more lines") {
					t.Fatalf(
						"variant %q: projection says overflow 0, but the render claims a fold:\n%s",
						v.Name, stripped,
					)
				}
			}
		})
	}

	// The adjudicating budget variant must EXIST: at least one chat-tool-diff
	// variant folds (overflow > 0), else the fold-number assertion above is
	// vacuously green and a regen that drops it silently sheds the D40 lock.
	folded := false
	for _, v := range fx.Variants {
		if v.Projection.Type == "chat-tool-diff" && v.Projection.Overflow > 0 {
			folded = true
		}
	}
	if !folded {
		t.Fatalf("fixture floor: no folding chat-tool-diff variant — the D40 budget lock is unexercised")
	}

	// (5) Coverage floor: all six promoted block types realized somewhere — the
	// three inert rows (D25) plus the three interactive cards (D35). A regen that
	// drops one reds here.
	for _, want := range []string{
		"chat-tool-diff", "chat-todo", "chat-thinking",
		"chat-approval", "chat-question", "chat-plan",
	} {
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

// TestChatToolDiffGapAfterBudget pins the D40 third clause on the terminal
// surface: a gap hunk separator never SPENDS budget (it draws free between
// drawn hunks) and never DRAWS once the budget is spent — the rule of a fully
// folded hunk would be chrome introducing rows the fold already discarded.
func TestChatToolDiffGapAfterBudget(t *testing.T) {
	reg := DefaultRegistry(DarkTheme())
	ctx := RenderCtx{Width: 80, Theme: DarkTheme(), Profile: NoColor}

	render := func(lines []any) string {
		block := map[string]any{"type": "chat-tool-diff", "lines": lines}
		raw, err := json.Marshal([]any{block})
		if err != nil {
			t.Fatalf("marshal: %v", err)
		}
		blocks, err := Decode(raw)
		if err != nil {
			t.Fatalf("decode: %v", err)
		}
		return ansi.Strip(reg.RenderDoc(blocks, ctx))
	}

	row := func(text string) any { return map[string]any{"op": "+", "text": text} }
	gap := map[string]any{"op": "gap", "text": ""}

	// A gap BETWEEN drawn hunks draws its rule and spends nothing.
	var mid []any
	for i := 0; i < 10; i++ {
		mid = append(mid, row("aa"+itoa(i)))
	}
	mid = append(mid, gap)
	for i := 0; i < 10; i++ {
		mid = append(mid, row("bb"+itoa(i)))
	}
	out := render(mid)
	if !strings.Contains(out, "─") {
		t.Fatalf("a gap between drawn hunks must draw its separator rule:\n%s", out)
	}
	if !strings.Contains(out, "bb9") {
		t.Fatalf("the 20th DRAWABLE row must draw (the gap spent budget):\n%s", out)
	}
	if strings.Contains(out, "more lines") {
		t.Fatalf("20 drawable rows + 1 gap is NOT an overflow:\n%s", out)
	}

	// A gap AFTER the budget is spent belongs to the folded tail: no rule.
	var late []any
	for i := 0; i < 20; i++ {
		late = append(late, row("cc"+itoa(i)))
	}
	late = append(late, gap)
	for i := 0; i < 4; i++ {
		late = append(late, row("dd"+itoa(i)))
	}
	out = render(late)
	if strings.Contains(out, "─") {
		t.Fatalf("a gap of a fully folded hunk must NOT draw once the budget is spent (D40):\n%s", out)
	}
	if !strings.Contains(out, "… +4 more lines") {
		t.Fatalf("the footnote must count the 4 folded DRAWABLE rows only:\n%s", out)
	}
}

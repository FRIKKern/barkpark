package pdrender

import (
	"encoding/json"
	"fmt"
	"math"
	"reflect"
	"strings"
	"testing"

	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"
	"github.com/muesli/termenv"
)

// TestComposeBlocksNeverPanic asserts note/stage/card degrade gracefully on
// empty attrs, empty slots, deeply-typed slot values, and a sub-MinWidth column
// — a document-controlled block must never crash the whole RenderDoc (the same
// contract TestPdTableNeverPanic enforces for the grid).
func TestComposeBlocksNeverPanic(t *testing.T) {
	reg := testRegistry()
	cases := []Block{
		// note: empty, partial, control-byte laden.
		{Type: "note", Attrs: map[string]any{}},
		{Type: "note", Attrs: map[string]any{"text": "body only"}},
		{Type: "note", Attrs: map[string]any{"label": "L", "lead": "lead", "text": "\x1b[2Jhijack"}},
		// stage: empty, partial, all fields.
		{Type: "stage", Attrs: map[string]any{}},
		{Type: "stage", Attrs: map[string]any{"kind": "todo", "title": "t"}},
		{Type: "stage", Attrs: map[string]any{"kind": "k", "title": "t", "detail": "d", "files": "f", "source": "s"}},
		// card: no slots, empty slots map, slots as a single map, slots as []any,
		// a slot holding a bare scalar (skipped), and a wrong-typed slots value.
		{Type: "card", Attrs: map[string]any{}},
		{Type: "card", Attrs: map[string]any{"slots": map[string]any{}}},
		{Type: "card", Attrs: map[string]any{"slots": map[string]any{
			"title": map[string]any{"type": "heading", "level": 2, "text": "hi"},
		}}},
		{Type: "card", Attrs: map[string]any{"slots": map[string]any{
			"body": []any{map[string]any{"type": "paragraph", "content": []any{
				map[string]any{"type": "text", "value": "x"}}}},
		}}},
		{Type: "card", Attrs: map[string]any{"slots": map[string]any{"title": "bare scalar"}}},
		{Type: "card", Attrs: map[string]any{"slots": "not-a-map"}},
	}
	// Exercise a normal width AND a sub-MinWidth column (the flat-degrade path).
	for _, width := range []int{40, 10} {
		for _, b := range cases {
			b := b
			func() {
				defer func() {
					if r := recover(); r != nil {
						t.Fatalf("compose block %q panicked on %v at width %d: %v", b.Type, b.Attrs, width, r)
					}
				}()
				out := reg.Render(b, RenderCtx{Width: width, Theme: DarkTheme(), Profile: NoColor})
				if len(out) == 0 {
					t.Fatalf("compose block %q returned zero lines on %v at width %d", b.Type, b.Attrs, width)
				}
			}()
		}
	}
}

// TestCardMediaImageFastPath checks the model-B image fast-path: a typed
// `type:"image"` media child renders imageRenderer's box, a typeless `{src,alt}`
// media element is coerced to an image (so it fast-paths instead of degrading),
// and the coercion is scoped to the MEDIA slot only (a typeless `{src,alt}` in a
// non-media slot is NOT coerced).
func TestCardMediaImageFastPath(t *testing.T) {
	reg := testRegistry()
	ctx := RenderCtx{Width: 60, Theme: DarkTheme(), Profile: NoColor}

	// Typed image in the media slot → 🖼 box.
	typed := Block{Type: "card", Attrs: map[string]any{"slots": map[string]any{
		"media": map[string]any{"type": "image", "src": "u.png", "alt": "typed alt"},
	}}}
	gotTyped := ansi.Strip(strings.Join(reg.Render(typed, ctx), "\n"))
	if !strings.Contains(gotTyped, "🖼") || !strings.Contains(gotTyped, "typed alt") {
		t.Fatalf("typed image media should fast-path to the image box, got:\n%s", gotTyped)
	}

	// Typeless {src,alt} in the media slot → coerced to an image box.
	bare := Block{Type: "card", Attrs: map[string]any{"slots": map[string]any{
		"media": map[string]any{"src": "u.png", "alt": "bare alt"},
	}}}
	gotBare := ansi.Strip(strings.Join(reg.Render(bare, ctx), "\n"))
	if !strings.Contains(gotBare, "🖼") || !strings.Contains(gotBare, "bare alt") {
		t.Fatalf("typeless {src,alt} media should be coerced to the image box, got:\n%s", gotBare)
	}

	// Scope: a typeless {src,alt} in a NON-media slot is NOT coerced (no 🖼 box).
	nonMedia := Block{Type: "card", Attrs: map[string]any{"slots": map[string]any{
		"body": map[string]any{"src": "u.png", "alt": "body alt"},
	}}}
	gotNon := ansi.Strip(strings.Join(reg.Render(nonMedia, ctx), "\n"))
	if strings.Contains(gotNon, "🖼") {
		t.Errorf("typeless {src,alt} outside the media slot must NOT be coerced, got:\n%s", gotNon)
	}
}

// TestNoteRendersNormally checks the definition row carries its label, bold lead
// and body text, and that control bytes in the body are stripped (not spliced
// into the terminal stream).
func TestNoteRendersNormally(t *testing.T) {
	reg := testRegistry()
	b := Block{Type: "note", Attrs: map[string]any{
		"label": "NB", "lead": "Lead in", "text": "the wrapped body of the note.",
	}}
	got := ansi.Strip(strings.Join(reg.Render(b, RenderCtx{Width: 40, Theme: DarkTheme(), Profile: NoColor}), "\n"))
	for _, want := range []string{"▌", "NB", "Lead in", "the wrapped body"} {
		if !strings.Contains(got, want) {
			t.Fatalf("note missing %q, got:\n%s", want, got)
		}
	}

	// Below MinWidth the bar is dropped (flat degrade).
	flat := ansi.Strip(strings.Join(reg.Render(b, RenderCtx{Width: 10, Theme: DarkTheme(), Profile: NoColor}), "\n"))
	if strings.Contains(flat, "▌") {
		t.Errorf("note should drop the bar below MinWidth, got:\n%s", flat)
	}
}

// TestStageRendersNormally checks the stacked cell UPPER-cases the kind kicker,
// keeps the title, and emits labelled files:/source: provenance lines.
func TestStageRendersNormally(t *testing.T) {
	reg := testRegistry()
	b := Block{Type: "stage", Attrs: map[string]any{
		"kind": "milestone", "title": "Renderers land", "detail": "shipped",
		"files": "composeblocks.go", "source": "pbp",
	}}
	got := ansi.Strip(strings.Join(reg.Render(b, RenderCtx{Width: 60, Theme: DarkTheme(), Profile: NoColor}), "\n"))
	for _, want := range []string{"MILESTONE", "Renderers land", "shipped", "files: composeblocks.go", "source: pbp"} {
		if !strings.Contains(got, want) {
			t.Fatalf("stage missing %q, got:\n%s", want, got)
		}
	}

	// Omitted optionals: no detail/files/source lines when absent.
	partial := ansi.Strip(strings.Join(reg.Render(
		Block{Type: "stage", Attrs: map[string]any{"kind": "todo", "title": "just a title"}},
		RenderCtx{Width: 60, Theme: DarkTheme(), Profile: NoColor}), "\n"))
	if strings.Contains(partial, "files:") || strings.Contains(partial, "source:") {
		t.Errorf("stage should omit absent provenance lines, got:\n%s", partial)
	}
}

func TestStageUsesSlotTextBeforeScalarShadows(t *testing.T) {
	attrs := map[string]any{"title": "stale shadow", "source": "queue.ex:42", "slots": map[string]any{
		"title": []any{map[string]any{"type": "paragraph", "content": []any{
			map[string]any{"type": "strong", "children": []any{map[string]any{"type": "text", "value": "Authored title"}}},
		}}},
	}}
	got := ansi.Strip(strings.Join(testRegistry().Render(Block{Type: "stage", Attrs: attrs}, RenderCtx{Width: 60, Theme: DarkTheme(), Profile: NoColor}), "\n"))
	if !strings.Contains(got, "Authored title") || strings.Contains(got, "stale shadow") || !strings.Contains(got, "queue.ex:42") {
		t.Fatalf("Stage must use authoritative slots without changing provenance:\n%s", got)
	}
	for _, slot := range []any{[]any{}, []any{map[string]any{"type": "paragraph", "content": []any{}}}} {
		attrs["slots"].(map[string]any)["title"] = slot
		if got := stageFieldText(attrs, "title"); got != "" {
			t.Fatalf("empty materialized slot must suppress scalar shadow, got %q", got)
		}
	}
}

// TestCardRendersNormally checks the model-B box: a rounded border, the slots
// in media→title→body→action order, all four slots' recursed content present,
// and NO per-slot label chrome (the `media`/`action` caption lines model B
// dropped, #1529).
func TestCardRendersNormally(t *testing.T) {
	reg := testRegistry()
	b := Block{Type: "card", Attrs: map[string]any{"slots": map[string]any{
		"title":  map[string]any{"type": "heading", "level": 2, "text": "The Title"},
		"body":   map[string]any{"type": "paragraph", "content": []any{map[string]any{"type": "text", "value": "the body prose"}}},
		"media":  map[string]any{"type": "paragraph", "content": []any{map[string]any{"type": "text", "value": "media prose"}}},
		"action": map[string]any{"type": "action", "label": "Go", "href": "https://x.example", "priority": "primary"},
	}}}
	got := ansi.Strip(strings.Join(reg.Render(b, RenderCtx{Width: 60, Theme: DarkTheme(), Profile: NoColor}), "\n"))
	for _, want := range []string{"╭", "╰", "The Title", "the body prose", "media prose", "Go"} {
		if !strings.Contains(got, want) {
			t.Fatalf("card missing %q, got:\n%s", want, got)
		}
	}
	// Model-B slot order: media renders before the title.
	if strings.Index(got, "media prose") > strings.Index(got, "The Title") {
		t.Errorf("card should render media before title (model-B order), got:\n%s", got)
	}
	// No per-slot label chrome: the muted `media`/`action` caption lines are gone.
	// (The media/action *content* still shows; the standalone label lines do not.)
	for _, line := range strings.Split(got, "\n") {
		trimmed := strings.TrimSpace(strings.Trim(line, "│ "))
		if trimmed == "media" || trimmed == "action" {
			t.Errorf("card must drop the %q label caption (model B), got:\n%s", trimmed, got)
		}
	}

	// Below MinWidth the border is dropped but the slot content survives.
	flat := ansi.Strip(strings.Join(reg.Render(b, RenderCtx{Width: 12, Theme: DarkTheme(), Profile: NoColor}), "\n"))
	if strings.Contains(flat, "╭") {
		t.Errorf("card should drop the border below MinWidth, got:\n%s", flat)
	}
	if !strings.Contains(flat, "The Title") {
		t.Errorf("card flat-degrade should keep slot content, got:\n%s", flat)
	}
}

// The three carrier shapes from the private browser proof, with opaque vendor
// data retained to guard against render-time normalization of authored source.
func noteReaderCarrierFixtures(t *testing.T) []Block {
	t.Helper()
	blocks, err := Decode([]byte(`
[
	{
		"id": "note-chain-shadow",
		"lead": null,
		"text": 47,
		"type": "note",
		"label": "Divergent flat label: never overwrite",
		"slots": {
			"body": [
				{
					"id": "note-chain-shadow-body",
					"type": "paragraph",
					"vendor": {
						"paragraph": [
							"keep",
							2
						]
					},
					"content": [
						{
							"type": "strong",
							"vendor": {
								"wrapper": {
									"keep": true
								}
							},
							"children": [
								{
									"type": "code",
									"value": "Shadow carrier body edited.",
									"vendor": {
										"leaf": [
											1,
											{
												"keep": "exact"
											}
										]
									}
								}
							]
						}
					]
				}
			],
			"lead": [
				{
					"id": "note-chain-shadow-lead",
					"type": "paragraph",
					"vendor": {
						"paragraph": [
							"keep",
							2
						]
					},
					"content": [
						{
							"type": "strong",
							"vendor": {
								"wrapper": {
									"keep": true
								}
							},
							"children": [
								{
									"type": "code",
									"value": "Chain lead",
									"vendor": {
										"leaf": [
											1,
											{
												"keep": "exact"
											}
										]
									}
								}
							]
						}
					]
				}
			],
			"label": [
				{
					"id": "note-chain-shadow-label",
					"type": "paragraph",
					"vendor": {
						"paragraph": [
							"keep",
							2
						]
					},
					"content": [
						{
							"type": "strong",
							"vendor": {
								"wrapper": {
									"keep": true
								}
							},
							"children": [
								{
									"type": "code",
									"value": "Shadow carrier label edited",
									"vendor": {
										"leaf": [
											1,
											{
												"keep": "exact"
											}
										]
									}
								}
							]
						}
					]
				}
			],
			"vendor-extra": {
				"opaque": {
					"keep": [
						1,
						2,
						{
							"untouched": true
						}
					]
				}
			}
		},
		"vendor": {
			"note": [
				"keep",
				{
					"version": 1
				}
			]
		}
	},
	{
		"id": "note-content-body",
		"text": "",
		"type": "note",
		"label": "Content",
		"vendor": {
			"keep": "content-only-edit"
		},
		"content": [
			{
				"type": "em",
				"vendor": {
					"wrapper": "preserve"
				},
				"children": [
					{
						"type": "text",
						"value": "Direct content carrier edited.",
						"vendor": {
							"leaf": "preserve"
						}
					}
				]
			}
		]
	},
	{
		"id": "note-unsafe-multirun",
		"type": "note",
		"label": "Read only",
		"slots": {
			"body": [
				{
					"id": "note-unsafe-body",
					"type": "paragraph",
					"vendor": {
						"paragraph": "retain"
					},
					"content": [
						{
							"type": "text",
							"value": "First authored run. ",
							"vendor": {
								"run": 1
							}
						},
						{
							"type": "code",
							"value": "Second authored run stays separate.",
							"vendor": {
								"run": 2
							}
						}
					]
				}
			],
			"vendor-extra": {
				"opaque": [
					"keep"
				]
			}
		},
		"vendor": {
			"keep": "no-writable-note-controls"
		}
	}
]
`))
	if err != nil {
		t.Fatal(err)
	}
	return blocks
}

func TestNoteReaderBrowserCarriers(t *testing.T) {
	expected := []map[string]any{
		{"label": "Shadow carrier label edited", "lead": "Chain lead", "text": "Shadow carrier body edited."},
		{"label": "Content", "text": "Direct content carrier edited."},
		{"label": "Read only", "text": "First authored run. Second authored run stays separate."},
	}
	blocks := noteReaderCarrierFixtures(t)
	if len(blocks) != len(expected) {
		t.Fatalf("got %d fixtures", len(blocks))
	}
	for i, block := range blocks {
		t.Run(block.ID, func(t *testing.T) {
			assertNoteReaderMatchesFlat(t, block, expected[i])
			assertStripComplete(t, block.ID, func(width int, profile Profile) string {
				return strings.Join(testRegistry().Render(block, RenderCtx{Width: width, Theme: DarkTheme(), Profile: profile}), "\n")
			})
		})
	}
}

func assertNoteReaderMatchesFlat(t *testing.T, block Block, flat map[string]any) {
	t.Helper()
	before, err := json.Marshal(block.Attrs)
	if err != nil {
		t.Fatal(err)
	}
	reg := testRegistry()
	for _, width := range []int{1, 10, 20, 40, 80, 120} {
		ctx := RenderCtx{Width: width, Theme: DarkTheme(), Profile: NoColor}
		got := reg.Render(block, ctx)
		want := reg.Render(Block{Type: "note", Attrs: flat}, ctx)
		if !reflect.DeepEqual(got, want) {
			t.Errorf("width %d: got %q; want %q", width, got, want)
		}
		for _, line := range got {
			if ansi.StringWidth(line) > width {
				t.Errorf("width %d overflow: %q", width, line)
			}
		}
	}
	after, err := json.Marshal(block.Attrs)
	if err != nil {
		t.Fatal(err)
	}
	if string(before) != string(after) {
		t.Fatal("reader mutated source carriers or metadata")
	}
}

func TestNoteReaderSlotSemantics(t *testing.T) {
	paragraph := func(content any) any { return map[string]any{"type": "paragraph", "content": content} }
	cases := []struct {
		name string
		slot any
		want string
	}{
		{"null slot", nil, "shadow"},
		{"nonlist", "bad", "shadow"},
		{"empty list", []any{}, "shadow"},
		{"null first", []any{nil, paragraph("ignored")}, "shadow"},
		{"scalar first", []any{"bad", paragraph("ignored")}, "shadow"},
		{"empty map", []any{map[string]any{}}, ""},
		{"empty paragraph", []any{paragraph([]any{})}, ""},
		{"bad content", []any{paragraph(47)}, ""},
		{"first paragraph only", []any{paragraph("primary"), paragraph("ignored")}, "primary"},
		{"whitespace primary", []any{paragraph("   ")}, "   "},
	}
	for _, field := range []string{"label", "lead", "body"} {
		flatKey := field
		if field == "body" {
			flatKey = "text"
		}
		for _, tc := range cases {
			t.Run(field+"/"+tc.name, func(t *testing.T) {
				attrs := map[string]any{flatKey: "shadow", "slots": map[string]any{field: tc.slot}, "content": []any{"fallback"}}
				want := tc.want
				if field == "body" && want == "" {
					want = "fallback"
				}
				expected := map[string]any{flatKey: want}
				if field != "body" {
					expected["text"] = "fallback"
				}
				assertNoteReaderMatchesFlat(t, Block{Type: "note", Attrs: attrs}, expected)
			})
		}
	}
	for _, slots := range []any{nil, "bad", []any{}, map[string]any{}} {
		t.Run(fmt.Sprintf("slots/%v", slots), func(t *testing.T) {
			attrs := map[string]any{"slots": slots, "label": "label", "lead": "lead", "text": "body", "content": []any{"ignored"}}
			assertNoteReaderMatchesFlat(t, Block{Type: "note", Attrs: attrs}, map[string]any{"label": "label", "lead": "lead", "text": "body"})
		})
	}
	for _, content := range []any{nil, "stranded scalar", 47, []any{}, map[string]any{"value": "stranded"}, []any{"body"}} {
		t.Run(fmt.Sprintf("content/%v", content), func(t *testing.T) {
			want := ""
			if list, ok := content.([]any); ok && len(list) > 0 {
				want = "body"
			}
			assertNoteReaderMatchesFlat(t, Block{Type: "note", Attrs: map[string]any{"content": content}}, map[string]any{"text": want})
		})
	}
}

// Integral float64 is the existing Go decoded-number convention, not full
// Elixir numeric parity: Decode erases lexical 47 versus 47.0 before rendering.
func TestNoteReaderScalarsAndInlineNodes(t *testing.T) {
	// Nonfinite values cannot pass through the JSON-based nonmutation helper.
	// Exercise the Go scalar path directly instead.
	for _, number := range []float64{math.NaN(), math.Inf(1), math.Inf(-1)} {
		t.Run(fmt.Sprint(number), func(t *testing.T) {
			attrs := map[string]any{"label": number, "lead": number, "text": number}
			got := noteRenderer{}.Render(Block{Type: "note", Attrs: attrs}, RenderCtx{Width: 80, Profile: NoColor})
			if !reflect.DeepEqual(got, []string{""}) {
				t.Fatalf("nonfinite scalar rendered as %q", got)
			}
		})
	}

	for _, tc := range []struct {
		value any
		want  string
	}{
		{nil, ""}, {true, ""}, {false, ""}, {47, "47"}, {int64(-47), "-47"},
		{float64(47), "47"}, {47.5, ""}, {"text", "text"}, {[]any{"bad"}, ""}, {map[string]any{"bad": true}, ""},
	} {
		t.Run(fmt.Sprintf("%T/%v", tc.value, tc.value), func(t *testing.T) {
			assertNoteReaderMatchesFlat(t, Block{Type: "note", Attrs: map[string]any{"label": tc.value, "lead": tc.value, "text": tc.value}}, map[string]any{"label": tc.want, "lead": tc.want, "text": tc.want})
			inline := []any{map[string]any{"type": "text", "value": tc.value, "children": []any{"ignored"}}, map[string]any{"type": "code", "value": tc.value}}
			attrs := map[string]any{"slots": map[string]any{"body": []any{map[string]any{"content": inline}}}}
			assertNoteReaderMatchesFlat(t, Block{Type: "note", Attrs: attrs}, map[string]any{"text": tc.want + tc.want})
		})
	}
	attrs := map[string]any{"content": []any{"bare ", map[string]any{"type": "strong", "children": []any{map[string]any{"type": "link", "children": []any{map[string]any{"type": "code", "value": "nested"}}}}}, nil, 47, []any{"ignored"}, map[string]any{"children": "ignored"}, map[string]any{"type": "text", "value": true, "children": []any{"ignored"}}}}
	assertNoteReaderMatchesFlat(t, Block{Type: "note", Attrs: attrs}, map[string]any{"text": "bare nested"})
}

// The shared sanitizer contract covers C0 and DEL. C1 hardening is a separate
// shared-sanitizer follow-up, not part of this Note carrier regression.
func TestNoteReaderSanitizesSlotAndContentCarriers(t *testing.T) {
	hostile := "safe\x1b[31m red\x1b[0m\x1b]52;c;YXR0YWNr\a\r\x00\x7f end"
	// Use a literal oracle, not sanitizeText or a second renderer invocation.
	const safe = "safe[31m red[0m]52;c;YXR0YWNr end"
	savedProfile := lipgloss.ColorProfile()
	lipgloss.SetColorProfile(termenv.Ascii)
	t.Cleanup(func() { lipgloss.SetColorProfile(savedProfile) })
	for _, carrier := range []string{"slots", "content"} {
		t.Run(carrier, func(t *testing.T) {
			attrs := map[string]any{"content": []any{hostile}}
			want := "▌ " + safe
			if carrier == "slots" {
				slots := map[string]any{}
				for _, field := range []string{"label", "lead", "body"} {
					slots[field] = []any{map[string]any{"content": []any{map[string]any{"type": "strong", "children": []any{map[string]any{"type": "text", "value": hostile}}}}}}
				}
				attrs = map[string]any{"slots": slots}
				want += "  " + safe + " " + safe
			}
			// Plain styles and Ascii profile keep theme escapes out of the raw output.
			got := strings.Join(noteRenderer{}.Render(Block{Type: "note", Attrs: attrs}, RenderCtx{Width: 512, Profile: NoColor}), "\n")
			if got != want {
				t.Errorf("sanitized text = %q; want %q", got, want)
			}
			for _, r := range got {
				if r < 0x20 || r == 0x7f {
					t.Errorf("terminal control U+%04X survived in %q", r, got)
				}
			}
		})
	}
}

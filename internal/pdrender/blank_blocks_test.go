package pdrender

import "testing"

// TestBlankBlocksRenderNothing pins the EMPTY-CHROME INVARIANT across every
// block type the Elixir composer guards, so the Go TUI and the web reader agree
// on what a blank block is (task-bc3cfbb08cfd0533; the code precedent is #15028
// / code_blank_test.go).
//
// THE MIRRORED PREDICATES, from api/lib/barkpark/portable_doc/render/compose.ex:
//
//	blank_field?(b, key)  -> Map.get(key, "") |> stringish() |> String.trim() == ""
//	blank_diagram?(b)     -> blank_field?("source") and blank_field?("caption")
//	blank_asciicast?(b)   -> blank_field?("src")    and blank_field?("caption")
//	blank_action?(b)      -> blank_field?("label")  and blank_field?("href")
//	blank_filetree?(b)    -> blank_field?("text")   and blank_field?("legend")
//	figure_html/3         -> String.trim(stringish(child_html)) == "" and
//	                         String.trim(caption) == ""
//
// `blank_field?/2` was extracted (verbatim) from `blank_code_source?/1` in
// #14806; the four type predicates and the figure branch landed in #14991.
//
// THE WHITESPACE RULE, quoted from `blank_field?/2`'s own comment: "String.trim/1
// strips the whole Unicode White_Space set (NBSP U+00A0, the U+2000-200A quads,
// IDEOGRAPHIC SPACE U+3000, LINE/PARAGRAPH SEPARATOR U+2028/9), not just ASCII.
// Zero-width characters (U+200B, U+FEFF) are NOT White_Space and stay CONTENT —
// the guard must not over-reach." Go's strings.TrimSpace strips unicode.IsSpace,
// which is that same set; the zero-width rows below prove both halves.
//
// EVERY PREDICATE IS AN AND, NEVER AN OR. The "one field only" rows are the
// load-bearing controls: they prove the guard cannot delete an authored caption
// (or legend, or label) just because its media is missing.
func TestBlankBlocksRenderNothing(t *testing.T) {
	reg := testRegistry()
	ctx := RenderCtx{Width: 60, Theme: DarkTheme(), Profile: NoColor}

	// The Unicode White_Space sampler both languages trim: NBSP, EM SPACE,
	// IDEOGRAPHIC SPACE, LINE SEPARATOR — none of them ASCII.
	const uniWS = "  　 "
	// ZWSP: NOT White_Space in either language, so it is content.
	const zwsp = "​"

	textPara := func(s string) *Block {
		return &Block{Type: "paragraph", Attrs: map[string]any{
			"content": []any{map[string]any{"type": "text", "value": s}},
		}}
	}

	cases := []struct {
		typ   string
		name  string
		block Block
		blank bool
	}{
		// ── diagram: source AND caption ─────────────────────────────────────
		{"diagram", "empty/no attrs at all", Block{Type: "diagram"}, true},
		{"diagram", "empty/both keys empty strings",
			Block{Type: "diagram", Attrs: map[string]any{"source": "", "caption": ""}}, true},
		{"diagram", "empty/explicit nils",
			Block{Type: "diagram", Attrs: map[string]any{"source": nil, "caption": nil}}, true},
		{"diagram", "whitespace/ascii only",
			Block{Type: "diagram", Attrs: map[string]any{"source": "  \n\t \n", "caption": " "}}, true},
		{"diagram", "whitespace/unicode only",
			Block{Type: "diagram", Attrs: map[string]any{"source": uniWS, "caption": uniWS}}, true},
		{"diagram", "whitespace/non-stringish map source",
			Block{Type: "diagram", Attrs: map[string]any{"source": map[string]any{}}}, true},
		{"diagram", "nonblank/source only", // AND-control: no caption, still renders
			Block{Type: "diagram", Attrs: map[string]any{"source": "flowchart TD\n  A --> B"}}, false},
		{"diagram", "nonblank/caption only", // AND-control: prose is never deleted
			Block{Type: "diagram", Attrs: map[string]any{"source": "   ", "caption": "Figure 2. The bus."}}, false},
		{"diagram", "nonblank/zero-width source is content",
			Block{Type: "diagram", Attrs: map[string]any{"source": zwsp}}, false},
		{"diagram", "nonblank/both",
			Block{Type: "diagram", Attrs: map[string]any{"source": "graph LR\n  A --> B", "caption": "Flow."}}, false},

		// ── asciicast: src AND caption ──────────────────────────────────────
		{"asciicast", "empty/no attrs at all", Block{Type: "asciicast"}, true},
		{"asciicast", "empty/both keys empty strings",
			Block{Type: "asciicast", Attrs: map[string]any{"src": "", "caption": ""}}, true},
		{"asciicast", "whitespace/ascii only",
			Block{Type: "asciicast", Attrs: map[string]any{"src": " \t ", "caption": "\n"}}, true},
		{"asciicast", "whitespace/unicode only",
			Block{Type: "asciicast", Attrs: map[string]any{"src": uniWS, "caption": uniWS}}, true},
		{"asciicast", "whitespace/player options only are still blank",
			// poster/rows/cols/duration are CHROME: asciicastMeta could spell a
			// "0:42 · 80x24" suffix out of these, and the block is blank anyway
			// — a poster names a frame of a recording that is not there.
			Block{Type: "asciicast", Attrs: map[string]any{
				"poster": "npt:1:23", "rows": 24.0, "cols": 80.0, "duration": 42.0,
			}}, true},
		{"asciicast", "nonblank/src only",
			Block{Type: "asciicast", Attrs: map[string]any{"src": "https://barkpark.cloud/casts/a.cast"}}, false},
		{"asciicast", "nonblank/caption only",
			Block{Type: "asciicast", Attrs: map[string]any{"src": " ", "caption": "A recorded session."}}, false},
		{"asciicast", "nonblank/zero-width src is content",
			Block{Type: "asciicast", Attrs: map[string]any{"src": zwsp}}, false},

		// ── action: label AND href ──────────────────────────────────────────
		{"action", "empty/no attrs at all", Block{Type: "action"}, true},
		{"action", "empty/the Studio canvas seed",
			// Blocks.default_block("action", id) == %{"href" => "", "label" => ""}
			Block{Type: "action", Attrs: map[string]any{"href": "", "label": ""}}, true},
		{"action", "whitespace/ascii only",
			Block{Type: "action", Attrs: map[string]any{"label": "   ", "href": "\t\n"}}, true},
		{"action", "whitespace/unicode only",
			Block{Type: "action", Attrs: map[string]any{"label": uniWS, "href": uniWS}}, true},
		{"action", "whitespace/priority only is still blank",
			Block{Type: "action", Attrs: map[string]any{"priority": "primary"}}, true},
		{"action", "nonblank/label only", // the sample_m8 shape: label, href ""
			Block{Type: "action", Attrs: map[string]any{"label": "Open the board", "href": ""}}, false},
		{"action", "nonblank/href only",
			Block{Type: "action", Attrs: map[string]any{"label": " ", "href": "https://barkpark.cloud"}}, false},
		{"action", "nonblank/href the sanitizer refuses is still authored",
			// Keyed on the RAW field like the Elixir clause, not on sanitizeURL's
			// verdict: the surfaces agree the block EXISTS before they disagree
			// about its safety.
			Block{Type: "action", Attrs: map[string]any{"label": "", "href": "javascript:alert(1)"}}, false},

		// ── filetree: text AND legend ───────────────────────────────────────
		{"filetree", "empty/no attrs at all", Block{Type: "filetree"}, true},
		{"filetree", "empty/both keys empty strings",
			Block{Type: "filetree", Attrs: map[string]any{"text": "", "legend": ""}}, true},
		{"filetree", "whitespace/ascii only",
			Block{Type: "filetree", Attrs: map[string]any{"text": "  \n \n", "legend": " "}}, true},
		{"filetree", "whitespace/unicode only",
			Block{Type: "filetree", Attrs: map[string]any{"text": uniWS, "legend": uniWS}}, true},
		{"filetree", "nonblank/text only",
			Block{Type: "filetree", Attrs: map[string]any{"text": "src/\n└── main.go ● created"}}, false},
		{"filetree", "nonblank/legend only", // the WIDENING this change makes
			Block{Type: "filetree", Attrs: map[string]any{"text": "  ", "legend": "● created · ○ injected"}}, false},

		// ── figure: composed child bytes AND caption ────────────────────────
		{"figure", "empty/no child, no caption", Block{Type: "figure"}, true},
		{"figure", "empty/nil child, empty caption",
			Block{Type: "figure", Attrs: map[string]any{"caption": ""}, Child: nil}, true},
		{"figure", "whitespace/ascii caption, no child",
			Block{Type: "figure", Attrs: map[string]any{"caption": "  \n "}}, true},
		{"figure", "whitespace/unicode caption, no child",
			Block{Type: "figure", Attrs: map[string]any{"caption": uniWS}}, true},
		{"figure", "whitespace/child that is itself scaffolding",
			// STRONGER THAN A KEY CHECK: the child KEY is present, but a
			// sourceless code block composes to nothing (#14806), so the figure
			// wrapping it is blank too — the case a key check would miss.
			Block{Type: "figure", Attrs: map[string]any{"caption": " "},
				Child: &Block{Type: "code", Attrs: map[string]any{"code": "  \n"}}}, true},
		{"figure", "nonblank/caption only", // AND-control: prose keeps the frame
			Block{Type: "figure", Attrs: map[string]any{"caption": "Figure 1. A caption with no art."}}, false},
		{"figure", "nonblank/child only",
			Block{Type: "figure", Attrs: map[string]any{"caption": ""}, Child: textPara("Body.")}, false},
		{"figure", "nonblank/both",
			Block{Type: "figure", Attrs: map[string]any{"caption": "Figure 1. Both."}, Child: textPara("Body.")}, false},
	}

	for _, tc := range cases {
		t.Run(tc.typ+"/"+tc.name, func(t *testing.T) {
			lines := reg.Render(tc.block, ctx)
			if tc.blank && len(lines) != 0 {
				t.Fatalf("blank %s rendered %d line(s), want 0: %q", tc.typ, len(lines), lines)
			}
			if !tc.blank && len(lines) == 0 {
				t.Fatalf("non-blank %s rendered nothing — the guard is too wide", tc.typ)
			}
		})
	}
}

// TestBlankBlocksSkipDoesNotBreakTheWalker mirrors compose_test's "a skipped
// block does not break the walker — neighbours still render": a blank block
// contributing zero lines must not swallow, shift, or blank-line-pad the blocks
// around it in a document render.
func TestBlankBlocksSkipDoesNotBreakTheWalker(t *testing.T) {
	reg := testRegistry()
	ctx := RenderCtx{Width: 60, Theme: DarkTheme(), Profile: NoColor}

	before := reg.RenderDoc([]Block{
		{Type: "heading", Attrs: map[string]any{"level": 2.0, "text": "A"}},
		{Type: "paragraph", Attrs: map[string]any{
			"content": []any{map[string]any{"type": "text", "value": "B"}},
		}},
	}, ctx)

	after := reg.RenderDoc([]Block{
		{Type: "heading", Attrs: map[string]any{"level": 2.0, "text": "A"}},
		{Type: "diagram"},
		{Type: "asciicast"},
		{Type: "action"},
		{Type: "filetree"},
		{Type: "figure"},
		{Type: "paragraph", Attrs: map[string]any{
			"content": []any{map[string]any{"type": "text", "value": "B"}},
		}},
	}, ctx)

	if before != after {
		t.Fatalf("five blank blocks changed the document render.\n--- without ---\n%s\n--- with ---\n%s", before, after)
	}
}

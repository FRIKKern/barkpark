package pdrender

import (
	"strings"
	"testing"

	"github.com/charmbracelet/x/ansi"
)

// TestParseSequenceMessages covers actor declaration (participant/actor + as
// alias) and the arrow-style decode the ladder depends on — including the
// greedy-dash trap (`DB-->>API` must split as DB → API, not DB- → API).
func TestParseSequenceMessages(t *testing.T) {
	src := "sequenceDiagram\n" +
		"  actor User\n" +
		"  participant App as Frontend\n" +
		"  User->>App: click\n" +
		"  App-->>User: 200\n" +
		"  DB--xApp: fail"
	doc := parseMermaid(src)
	if doc.kind != "sequence" {
		t.Fatalf("kind = %q, want sequence", doc.kind)
	}
	s := doc.seq
	// Actors in declared/first-seen order; DB is lazily added by its message.
	want := []string{"User", "App", "DB"}
	if strings.Join(s.actors, ",") != strings.Join(want, ",") {
		t.Errorf("actors = %v, want %v", s.actors, want)
	}
	if !s.isActor["User"] {
		t.Errorf("User should be an actor")
	}
	if s.label["App"] != "Frontend" {
		t.Errorf("App alias = %q, want Frontend", s.label["App"])
	}
	// Message decode: solid, dashed, cross — and no phantom `DB-` actor.
	if len(s.messages) != 3 {
		t.Fatalf("messages = %d, want 3: %+v", len(s.messages), s.messages)
	}
	if s.messages[0].style != msgSolid || s.messages[0].to != "App" {
		t.Errorf("msg0 = %+v, want solid ->App", s.messages[0])
	}
	if s.messages[1].style != msgDashed {
		t.Errorf("msg1 should be dashed: %+v", s.messages[1])
	}
	if s.messages[2].style != msgCross || s.messages[2].from != "DB" || s.messages[2].to != "App" {
		t.Errorf("msg2 = %+v, want cross DB->App (dash not swallowed)", s.messages[2])
	}
}

// TestSequenceRectangular is the structural guarantee: the lifeline ladder is a
// perfect rectangle at every width it can draw. Non-vacuous — it also asserts a
// participant box and a message arrow were drawn.
func TestSequenceRectangular(t *testing.T) {
	src := "sequenceDiagram\n Client->>API: GET /user\n API->>DB: SELECT\n DB-->>API: rows\n API-->>Client: 200"
	s := parseMermaid(src).seq
	for _, w := range []int{40, 60, 80, 120} {
		ctx := RenderCtx{Width: w, Theme: DarkTheme(), Profile: NoColor}
		out := renderSequence(s, ctx)
		if len(out) == 0 {
			t.Fatalf("w=%d: empty render (should fit)", w)
		}
		var box, arrow bool
		for i, ln := range out {
			if got := ansi.StringWidth(ln); got != w {
				t.Errorf("w=%d line %d width = %d, want %d: %q", w, i, got, w, ansi.Strip(ln))
			}
			plain := ansi.Strip(ln)
			if strings.Contains(plain, "┌") {
				box = true
			}
			if strings.ContainsAny(plain, "▶◀") {
				arrow = true
			}
		}
		if !box || !arrow {
			t.Errorf("w=%d: vacuous render (box=%v arrow=%v)", w, box, arrow)
		}
	}
}

// TestSequenceFallback confirms the honest degradation: a single participant, or
// a width too narrow for the boxes, returns nil so the caller folds the source.
func TestSequenceFallback(t *testing.T) {
	one := parseMermaid("sequenceDiagram\n A->>A: solo").seq
	if out := renderSequence(one, RenderCtx{Width: 80, Theme: DarkTheme(), Profile: NoColor}); out != nil {
		t.Errorf("single participant should fall back to folded source, got %d lines", len(out))
	}
	// Many participants at a tiny width → columns collide → fall back.
	many := parseMermaid("sequenceDiagram\n A->>B: x\n B->>C: y\n C->>D: z\n D->>E: w").seq
	if out := renderSequence(many, RenderCtx{Width: 24, Theme: DarkTheme(), Profile: NoColor}); out != nil {
		t.Errorf("5 columns at w=24 should fall back, got %d lines", len(out))
	}
}

// TestSequenceDispatch confirms a sequence source now DRAWS a ladder (no folded
// header) at a comfortable width.
func TestSequenceDispatch(t *testing.T) {
	ctx := RenderCtx{Width: 80, Theme: DarkTheme(), Profile: NoColor}
	seq := Block{Type: "diagram", Attrs: map[string]any{
		"source": "sequenceDiagram\n Client->>API: GET\n API-->>Client: 200", "caption": "Seq."}}
	got := ansi.Strip(strings.Join(diagramRenderer{}.Render(seq, ctx), "\n"))
	if strings.Contains(got, "◇ Mermaid diagram") {
		t.Errorf("sequence should draw, not fold:\n%s", got)
	}
	if !strings.Contains(got, "Client") || !strings.ContainsAny(got, "▶◀") || !strings.Contains(got, "Figure") {
		t.Errorf("sequence render missing lifelines/arrow/caption:\n%s", got)
	}
}

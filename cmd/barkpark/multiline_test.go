package main

import (
	"encoding/json"
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"

	"github.com/FRIKKern/barkpark/internal/apiclient"
)

// Multi-line editing pins (2026-06-12): FieldText and legacy-string
// FieldRichText edit in a bubbles textarea — enter inserts a newline, ctrl+s
// commits, esc cancels. FieldRichText is value-aware: a legacy plain-string
// body renders + edits as multi-line text; a blocks-doc projection map
// ({"blocks":…,"html":…}, absent from Doc.Values, present in Doc.Extra)
// renders a read-only stripped-html preview and REFUSES to open an editor —
// patching a string over the projection map is the data-corruption hazard.

func multilineModel(fields []Field, values map[string]string, extra map[string]json.RawMessage) model {
	return model{
		selectedDoc: &Doc{
			ID:     "drafts.p1",
			Title:  "Doc",
			Values: values,
			Extra:  extra,
		},
		editorSchema: &apiclient.Schema{Name: "post", Fields: fields},
		focus:        focusState{Target: FocusEditor},
		showEditor:   true,
		width:        100,
		height:       40,
	}
}

func textBodyField(rows int) Field {
	return Field{Name: "body", Title: "Body", Type: FieldText, Rows: rows}
}

func richBodyField() Field {
	return Field{Name: "body", Title: "Body", Type: FieldRichText}
}

const blocksProjection = `{"blocks":[{"content":[{"type":"text","value":"Hello"}],"id":"synth-body-p-3","type":"paragraph"}],"html":"<span>Hello there</span>"}`

// ── Value-aware richText render ──────────────────────────────────────────────

func TestRichTextRenderShowsLegacyStringValue(t *testing.T) {
	// Shape A (legacy plain string): the value itself must render — the old
	// fake "B I U H1…" toolbar + static "Start writing..." never showed it.
	m := multilineModel([]Field{richBodyField()},
		map[string]string{"body": "First line\nSecond line"}, nil)
	out := strings.Join(m.renderField(m.editorSchema.Fields[0], 60, false, false), "\n")
	if !strings.Contains(out, "First line") || !strings.Contains(out, "Second line") {
		t.Errorf("legacy-string richText should render its value, got:\n%s", out)
	}
	if strings.Contains(out, "Start writing") {
		t.Errorf("set richText field must not show the empty placeholder, got:\n%s", out)
	}
}

func TestRichTextRenderEmptyShowsPlaceholder(t *testing.T) {
	m := multilineModel([]Field{richBodyField()}, nil, nil)
	out := strings.Join(m.renderField(m.editorSchema.Fields[0], 60, false, false), "\n")
	if !strings.Contains(out, "Start writing") {
		t.Errorf("empty richText field should show the placeholder, got:\n%s", out)
	}
}

func TestRichTextRenderBlocksProjectionPreview(t *testing.T) {
	// Shape B (blocks-doc projection): non-scalar, so absent from Doc.Values
	// (getFieldValue returns "") — the preview comes from Extra's html key,
	// stripped of tags, with the read-only pointer beneath the box.
	m := multilineModel([]Field{richBodyField()}, nil,
		map[string]json.RawMessage{"body": json.RawMessage(blocksProjection)})
	out := strings.Join(m.renderField(m.editorSchema.Fields[0], 60, false, false), "\n")
	if !strings.Contains(out, "Hello there") {
		t.Errorf("blocks doc should preview the stripped html text, got:\n%s", out)
	}
	if strings.Contains(out, "<span>") {
		t.Errorf("preview must strip tags, got:\n%s", out)
	}
	if !strings.Contains(out, "blocks doc") || !strings.Contains(out, "Studio") {
		t.Errorf("blocks doc should carry the edit-in-Studio note, got:\n%s", out)
	}
	if strings.Contains(out, "Start writing") {
		t.Errorf("blocks doc must not show the empty placeholder, got:\n%s", out)
	}
}

func TestRichTextBlocksDocDetection(t *testing.T) {
	// Scalar string in Extra (Shape A's raw form) → NOT a blocks doc.
	m := multilineModel([]Field{richBodyField()},
		map[string]string{"body": "plain"},
		map[string]json.RawMessage{"body": json.RawMessage(`"plain"`)})
	if _, blocks := m.richTextBlocksDoc("body"); blocks {
		t.Error("scalar string raw value must stay text-editable")
	}

	// Projection map → blocks doc, preview from html.
	m = multilineModel([]Field{richBodyField()}, nil,
		map[string]json.RawMessage{"body": json.RawMessage(blocksProjection)})
	preview, blocks := m.richTextBlocksDoc("body")
	if !blocks {
		t.Fatal("projection map must be detected as a blocks doc")
	}
	if preview != "Hello there" {
		t.Errorf("preview = %q, want stripped html text", preview)
	}

	// Non-scalar WITHOUT an html key still refuses editing (refusal keys on
	// non-scalar, never on the exact shape).
	m = multilineModel([]Field{richBodyField()}, nil,
		map[string]json.RawMessage{"body": json.RawMessage(`{"blocks":[]}`)})
	if _, blocks := m.richTextBlocksDoc("body"); !blocks {
		t.Error("html-less object must still refuse text editing")
	}

	// Absent field → editable (empty).
	m = multilineModel([]Field{richBodyField()}, nil, nil)
	if _, blocks := m.richTextBlocksDoc("body"); blocks {
		t.Error("absent field must not be a blocks doc")
	}
}

// ── Editor open / refusal ────────────────────────────────────────────────────

func TestRichTextProjectionRefusesEdit(t *testing.T) {
	m := multilineModel([]Field{richBodyField()}, nil,
		map[string]json.RawMessage{"body": json.RawMessage(blocksProjection)})
	cmd := m.startFieldEdit()
	if m.editing || m.editingMultiline {
		t.Fatal("blocks doc must NEVER open a text editor")
	}
	if cmd != nil {
		t.Error("refusal should return no focus cmd")
	}
	if !strings.Contains(m.status, "blocks doc") {
		t.Errorf("refusal should explain via the status line, got %q", m.status)
	}
}

func TestRichTextLegacyStringEditsAsMultiline(t *testing.T) {
	m := multilineModel([]Field{richBodyField()},
		map[string]string{"body": "one\ntwo"}, nil)
	cmd := m.startFieldEdit()
	if !m.editing || !m.editingMultiline {
		t.Fatal("legacy-string richText should open the multi-line editor")
	}
	if cmd == nil {
		t.Error("textarea focus should return its cursor cmd")
	}
	if got := m.textArea.Value(); got != "one\ntwo" {
		t.Errorf("edit prefill = %q, want the multi-line value", got)
	}
}

func TestTextFieldEditsAsMultiline(t *testing.T) {
	m := multilineModel([]Field{textBodyField(4)},
		map[string]string{"body": "alpha\nbeta"}, nil)
	m.startFieldEdit()
	if !m.editing || !m.editingMultiline {
		t.Fatal("FieldText should open the multi-line editor")
	}
	if got := m.textArea.Value(); got != "alpha\nbeta" {
		t.Errorf("edit prefill = %q, want the multi-line value", got)
	}
}

// ── Key routing: enter = newline, ctrl+s = commit, esc = cancel ──────────────

func TestMultilineEnterInsertsNewlineNotCommit(t *testing.T) {
	m := multilineModel([]Field{textBodyField(3)},
		map[string]string{"body": "hello"}, nil)
	m.startFieldEdit()

	mm, _ := m.handleKey(tea.KeyMsg{Type: tea.KeyEnter})
	m2 := mm.(model)
	if !m2.editing || !m2.editingMultiline {
		t.Fatal("enter inside the textarea must NOT commit the edit")
	}
	mm, _ = m2.handleKey(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("x")})
	m3 := mm.(model)
	if got := m3.textArea.Value(); got != "hello\nx" {
		t.Errorf("textarea value = %q, want %q", got, "hello\nx")
	}
	if len(m3.dirtyValues) != 0 {
		t.Errorf("nothing committed yet, dirtyValues = %v", m3.dirtyValues)
	}
}

func TestMultilineCtrlSCommitsWithEmbeddedNewlines(t *testing.T) {
	m := multilineModel([]Field{textBodyField(3)},
		map[string]string{"body": ""}, nil)
	m.startFieldEdit()
	m.textArea.SetValue("line one\nline two\nline three")

	mm, _ := m.handleKey(tea.KeyMsg{Type: tea.KeyCtrlS})
	m2 := mm.(model)
	if m2.editing || m2.editingMultiline {
		t.Fatal("ctrl+s must commit and leave editing mode")
	}
	if got := m2.dirtyValues["body"]; got != "line one\nline two\nline three" {
		t.Errorf("dirtyValues[body] = %q, want the newlines verbatim", got)
	}
	if !m2.dirty {
		t.Error("commit must mark the doc dirty")
	}
	// The NEXT ctrl+s (no longer editing) is the document save — pin that the
	// editing branch no longer swallows it (it falls through to the outer
	// handler; here, with no live DataStore, just pin the mode flags).
	if m2.editing {
		t.Error("second ctrl+s must reach the outer save handler")
	}
}

func TestMultilineEscCancelsWithoutDirty(t *testing.T) {
	m := multilineModel([]Field{textBodyField(3)},
		map[string]string{"body": "keep me"}, nil)
	m.startFieldEdit()
	m.textArea.SetValue("discarded\ndraft")

	mm, _ := m.handleKey(tea.KeyMsg{Type: tea.KeyEsc})
	m2 := mm.(model)
	if m2.editing || m2.editingMultiline {
		t.Fatal("esc must cancel the edit")
	}
	if len(m2.dirtyValues) != 0 || m2.dirty {
		t.Errorf("esc must discard input, dirtyValues = %v", m2.dirtyValues)
	}
	if got := m2.getFieldValue("body"); got != "keep me" {
		t.Errorf("value after cancel = %q, want original", got)
	}
}

// ── Scroll-follow: rendered heights stay stable while editing ────────────────

// scrollToField sums len(renderField(...)) for every preceding field with
// isEditing=false. The textarea View() is FIXED at the height startFieldEdit
// set (it scrolls internally), so the editing render of a field occupies the
// same line span as its static render — the probe can never drift mid-edit.
// The 12-row cap edge (review finding): a value LONGER than the editing
// textarea's 12-row pin must render the SAME height statically — the static
// path caps via capValueLines, with an explicit "+N more lines" summary.
func TestOverlongValueHeightParityAndSummary(t *testing.T) {
	long := strings.Repeat("line\n", 14) + "tail" // 15 logical lines
	for _, f := range []Field{textBodyField(4), richBodyField()} {
		m := multilineModel([]Field{f}, map[string]string{"body": long}, nil)
		staticLines := m.renderField(f, 60, true, false)
		static := renderedLineCount(staticLines)
		m.startFieldEdit()
		editing := renderedLineCount(m.renderField(f, 60, true, true))
		if static != editing {
			t.Errorf("%v: 15-line value renders %d static vs %d editing lines",
				f.Type, static, editing)
		}
		if !strings.Contains(strings.Join(staticLines, "\n"), "more lines") {
			t.Errorf("%v: capped static render should disclose the truncation", f.Type)
		}
	}
}

func TestEditingRenderHeightMatchesStaticRender(t *testing.T) {
	for _, f := range []Field{textBodyField(4), richBodyField()} {
		m := multilineModel([]Field{f},
			map[string]string{"body": "one\ntwo"}, nil)
		static := renderedLineCount(m.renderField(f, 60, true, false))
		m.startFieldEdit()
		editing := renderedLineCount(m.renderField(f, 60, true, true))
		if static != editing {
			t.Errorf("%v: editing render is %d lines, static is %d — scrollToField would drift",
				f.Type, editing, static)
		}
	}
}

// Pin the scrollToField formula against buildEditorContent's real assembly:
// the field after a textarea-edited field must START at the same line whether
// or not the edit is live, and that line is 4 + Σ(height+1) — exactly what
// scrollToField computes.
func TestScrollAccountingStableWhileEditing(t *testing.T) {
	fields := []Field{
		{Name: "title", Title: "Title", Type: FieldString},
		textBodyField(4),
		{Name: "footer", Title: "Footer", Type: FieldString},
	}
	m := multilineModel(fields, map[string]string{"body": "a\nb\nc"}, nil)
	m.fieldCursor = 1

	ew := m.calcEditorWidth()
	fieldWidth := ew - 4

	findFooter := func(content string) int {
		for i, line := range strings.Split(content, "\n") {
			if strings.Contains(line, "FOOTER") {
				return i
			}
		}
		return -1
	}

	before := findFooter(m.buildEditorContent(ew))
	m.startFieldEdit() // textarea live on the body field
	after := findFooter(m.buildEditorContent(ew))
	if before == -1 || before != after {
		t.Errorf("FOOTER start line moved while editing: %d → %d", before, after)
	}

	// And the scrollToField probe (static PHYSICAL heights, +1 separator,
	// 4 header rows) lands exactly on that line. renderField returns boxes
	// as single elements with embedded newlines, so the probe must count
	// physical lines (renderedLineCount), never slice length.
	want := 4
	for i := 0; i < 2; i++ {
		want += renderedLineCount(m.renderField(fields[i], fieldWidth, false, false)) + 1
	}
	if want != after {
		t.Errorf("scrollToField formula says line %d, buildEditorContent puts FOOTER at %d", want, after)
	}
}

// ── Help bar ─────────────────────────────────────────────────────────────────

func TestHelpBarMultilineHints(t *testing.T) {
	m := multilineModel([]Field{textBodyField(3)}, nil, nil)
	m.startFieldEdit()
	bar := m.renderHelpBar()
	for _, hint := range []string{"enter newline", "ctrl+s confirm", "esc cancel"} {
		if !strings.Contains(bar, hint) {
			t.Errorf("multi-line help bar missing %q, got:\n%s", hint, bar)
		}
	}
}

// ── Tag stripping / preview clamp ────────────────────────────────────────────

func TestStripHTMLTags(t *testing.T) {
	cases := []struct{ in, want string }{
		{"<span>Hello</span>", "Hello"},
		{"<p>a</p><p>b</p>", "ab"},
		{"no tags", "no tags"},
		{"a &amp; b &lt;c&gt;", "a & b <c>"},
		{"", ""},
	}
	for _, c := range cases {
		if got := stripHTMLTags(c.in); got != c.want {
			t.Errorf("stripHTMLTags(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

func TestClampLinesClipsWithEllipsis(t *testing.T) {
	long := strings.Repeat("word ", 200)
	out := clampLines(long, 40, 6)
	if n := len(strings.Split(out, "\n")); n > 7 { // 6 + ellipsis row
		t.Errorf("clamped preview is %d lines, want ≤ 7", n)
	}
	if !strings.HasSuffix(out, "…") {
		t.Error("clipped preview should end with an ellipsis row")
	}
}

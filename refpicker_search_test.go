package main

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"

	"github.com/FRIKKern/barkpark/internal/apiclient"
)

// TUI parity pins for gaps 5+6:
//   - reference picker: enter on a focused reference field opens the modal;
//     enter on a row stores the BARE published id (drafts. prefix stripped —
//     the Studio select-ref wire format, Content.published_id) in dirtyValues;
//     the "(clear)" row stores "" (the Studio clear-ref); ctrl+s patches that
//     exact value. The field renders the referenced doc's TITLE + dim id.
//   - search: `/` on a focused pane opens the help-bar query prompt; enter
//     hits GET /w/…/p/…/v1/data/search/<dataset>?q=…&limit=20 (top-level
//     "documents" response); hits render in a transient modal; enter drills
//     into the hit's editor (type from _type); esc dismisses untouched; empty
//     results → status "no matches".
//   - pure-render: pane help bars hint "/ search"; the reference field shows
//     the resolved title.

const (
	postWithRefJSON = `{"_id":"drafts.post-9","_type":"post","_draft":true,
		"title":"Refer","author":"author-1","_updatedAt":"2026-06-09T10:00:00Z"}`
	authorDocsJSON = `[{"_id":"drafts.author-1","_type":"author","_draft":true,
		"title":"Alice","_updatedAt":"2026-06-09T09:00:00Z"},
		{"_id":"author-2","_type":"author","_draft":false,
		"title":"Bob","_updatedAt":"2026-06-08T09:00:00Z"}]`
	searchHitJSON = `{"_id":"post-7","_type":"post","_draft":false,
		"title":"Hello World","_updatedAt":"2026-06-09T10:00:00Z"}`
)

// refServer serves the post doc-list, the author candidates, and captures
// mutate bodies — the three endpoints the reference-picker path touches.
func refServer(mutates *[][]byte) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		switch {
		case strings.Contains(r.URL.Path, "/v1/data/mutate/"):
			b, _ := io.ReadAll(r.Body)
			*mutates = append(*mutates, b)
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write([]byte(`{"transactionId":"t1","results":[]}`))
		case strings.Contains(r.URL.Path, "/v1/data/query/production/post"):
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write([]byte(`{"result":{"documents":[` + postWithRefJSON + `]}}`))
		case strings.Contains(r.URL.Path, "/v1/data/query/production/author"):
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write([]byte(`{"result":{"documents":` + authorDocsJSON + `}}`))
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}
}

// refModel builds a model whose post schema carries a reference field
// (refType author) as field 0, focused on the post doc-list pane.
func refModel(t *testing.T, srvURL string) model {
	t.Helper()
	prevSchemas, prevRoot := schemas, rootStructure
	t.Cleanup(func() { schemas, rootStructure = prevSchemas, prevRoot })
	schemas = []Schema{
		{Name: "post", Title: "Posts", Icon: "📄", Fields: []Field{
			{Name: "author", Title: "Author", Type: FieldReference, RefType: "author"},
		}},
		{Name: "author", Title: "Authors", Icon: "👤"},
	}
	initRootStructure()

	m := model{
		ds:     apiclient.New(apiclient.Config{BaseURL: srvURL, Token: "t"}),
		width:  120,
		height: 40,
		path:   []string{"post"},
	}
	m.rebuildPanes()
	if len(m.panes) != 2 || !m.panes[1].IsDocList {
		t.Fatalf("setup: want a doc-list pane at index 1, got %d panes", len(m.panes))
	}
	m.focus = focusState{Target: FocusPane, PaneIndex: 1}
	return m
}

func parsePatchBody(t *testing.T, captured []byte) (id, typeName string, set map[string]any) {
	t.Helper()
	var body struct {
		Mutations []struct {
			Patch struct {
				ID   string         `json:"id"`
				Type string         `json:"type"`
				Set  map[string]any `json:"set"`
			} `json:"patch"`
		} `json:"mutations"`
	}
	if err := json.Unmarshal(captured, &body); err != nil {
		t.Fatalf("parse captured mutate body: %v", err)
	}
	if len(body.Mutations) != 1 {
		t.Fatalf("want 1 mutation, got %d", len(body.Mutations))
	}
	p := body.Mutations[0].Patch
	return p.ID, p.Type, p.Set
}

// ─── Reference picker ────────────────────────────────────────────────────────

func TestRefPickerStoresBarePublishedID(t *testing.T) {
	var mutates [][]byte
	srv := httptest.NewServer(refServer(&mutates))
	defer srv.Close()

	m := refModel(t, srv.URL)
	m = press(t, m, "enter") // drill into the doc's editor (fieldCursor 0 = author)
	if !m.showEditor || m.focus.Target != FocusEditor {
		t.Fatalf("setup: want editor focus, got showEditor=%v focus=%v", m.showEditor, m.focus.Target)
	}

	// Enter on the focused reference field opens the picker, NOT a text input.
	m = press(t, m, "enter")
	if !m.refPicker.active || m.editing {
		t.Fatalf("enter on a reference field must open the picker: active=%v editing=%v",
			m.refPicker.active, m.editing)
	}
	if len(m.refPicker.items) != 2 {
		t.Fatalf("picker must list the 2 author docs, got %d", len(m.refPicker.items))
	}
	// Cursor starts on the CURRENT value's row (author-1 → row 1, after "(clear)").
	if m.refPicker.cursor != 1 {
		t.Errorf("cursor = %d, want 1 (the row of the current value author-1)", m.refPicker.cursor)
	}

	// j → Bob (author-2, listed as the bare published id), enter selects.
	m = press(t, m, "j")
	m = press(t, m, "enter")
	if m.refPicker.active {
		t.Error("picker must close on select")
	}
	if !m.dirty || m.dirtyValues["author"] != "author-2" {
		t.Fatalf("dirtyValues[author] = %q (dirty=%v), want the BARE published id author-2",
			m.dirtyValues["author"], m.dirty)
	}

	// ctrl+s patches EXACTLY that value — the Studio select-ref wire format.
	mm, _ := m.handleKey(tea.KeyMsg{Type: tea.KeyCtrlS})
	m = mm.(model)
	if len(mutates) != 1 {
		t.Fatalf("want 1 mutate, got %d", len(mutates))
	}
	id, typeName, set := parsePatchBody(t, mutates[0])
	if id != "drafts.post-9" || typeName != "post" {
		t.Errorf("patch target = {%q %q}, want drafts.post-9/post", id, typeName)
	}
	if set["author"] != "author-2" {
		t.Errorf("patch set.author = %v, want author-2", set["author"])
	}
	if m.statusErr || m.status != "saved" {
		t.Errorf("status = (%q, err=%v), want saved", m.status, m.statusErr)
	}
}

func TestRefPickerClearRowClearsValue(t *testing.T) {
	var mutates [][]byte
	srv := httptest.NewServer(refServer(&mutates))
	defer srv.Close()

	m := refModel(t, srv.URL)
	m = press(t, m, "enter") // editor
	m = press(t, m, "enter") // picker, cursor on row 1 (current value)
	m = press(t, m, "k")     // up to the "(clear)" row
	if m.refPicker.cursor != 0 {
		t.Fatalf("cursor = %d, want 0 (the clear row)", m.refPicker.cursor)
	}
	m = press(t, m, "enter")

	if val, ok := m.dirtyValues["author"]; !ok || val != "" {
		t.Fatalf("clear must store the empty string (Studio clear-ref), got %q ok=%v", val, ok)
	}
	mm, _ := m.handleKey(tea.KeyMsg{Type: tea.KeyCtrlS})
	m = mm.(model)
	_, _, set := parsePatchBody(t, mutates[0])
	if set["author"] != "" {
		t.Errorf("patch set.author = %v, want the empty string", set["author"])
	}
}

func TestRefPickerEscCancelsUntouched(t *testing.T) {
	var mutates [][]byte
	srv := httptest.NewServer(refServer(&mutates))
	defer srv.Close()

	m := refModel(t, srv.URL)
	m = press(t, m, "enter")
	m = press(t, m, "enter")
	m = press(t, m, "j")
	m = press(t, m, "esc")

	if m.refPicker.active {
		t.Error("esc must close the picker")
	}
	if m.dirty || len(m.dirtyValues) != 0 {
		t.Errorf("esc must not touch the doc: dirty=%v values=%v", m.dirty, m.dirtyValues)
	}
	if len(mutates) != 0 {
		t.Errorf("esc must send nothing, got %d mutate(s)", len(mutates))
	}
}

// Pure-render pin: the reference field resolves the stored id to the
// referenced doc's TITLE (cached on editor open) with the id dim beside it.
func TestReferenceFieldRendersResolvedTitle(t *testing.T) {
	var mutates [][]byte
	srv := httptest.NewServer(refServer(&mutates))
	defer srv.Close()

	m := refModel(t, srv.URL)
	m = press(t, m, "enter") // drill in — cacheRefTitlesFor resolves author-1 → Alice

	out := m.buildEditorContent(80)
	if !strings.Contains(out, "Alice") {
		t.Errorf("reference field must render the resolved TITLE:\n%s", out)
	}
	if !strings.Contains(out, "author-1") {
		t.Errorf("reference field must keep the id beside the title:\n%s", out)
	}
}

// ─── Search ──────────────────────────────────────────────────────────────────

// searchServer captures the search request and serves the given documents
// payload; the post query endpoint backs the doc-list pane.
func searchServer(docsJSON string, gotPath *string, gotQuery *url.Values) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		switch {
		case strings.Contains(r.URL.Path, "/v1/data/search/"):
			*gotPath = r.URL.Path
			*gotQuery = r.URL.Query()
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write([]byte(`{"documents":` + docsJSON + `,"count":1,"query":"hello","ms":1}`))
		case strings.Contains(r.URL.Path, "/v1/data/query/"):
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write([]byte(`{"result":{"documents":[]}}`))
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}
}

// searchModel builds a model on the root structure pane with a post schema,
// drafts perspective (the TUI default) pinned so the param is assertable.
func searchModel(t *testing.T, srvURL string) model {
	t.Helper()
	prevSchemas, prevRoot := schemas, rootStructure
	t.Cleanup(func() { schemas, rootStructure = prevSchemas, prevRoot })
	schemas = []Schema{{Name: "post", Title: "Posts", Icon: "📄"}}
	initRootStructure()

	m := model{
		ds: apiclient.New(apiclient.Config{
			BaseURL: srvURL, Token: "t", Perspective: "drafts",
		}),
		width:  120,
		height: 40,
	}
	m.rebuildPanes()
	m.focus = focusState{Target: FocusPane, PaneIndex: 0}
	return m
}

func TestSearchHitsScopedPathWithParams(t *testing.T) {
	var gotPath string
	var gotQuery url.Values
	srv := httptest.NewServer(searchServer("["+searchHitJSON+"]", &gotPath, &gotQuery))
	defer srv.Close()

	m := searchModel(t, srv.URL)
	m = press(t, m, "/")
	if !m.searching {
		t.Fatal("/ on a focused pane must open the search prompt")
	}
	if bar := m.renderHelpBar(); !strings.Contains(bar, "Search:") {
		t.Errorf("help bar must show the search prompt:\n%s", bar)
	}

	m.textInput.SetValue("hello")
	m = press(t, m, "enter")

	if gotPath != "/w/default/p/default/v1/data/search/production" {
		t.Errorf("search path = %q, want the scoped /w/default/p/default/v1/data/search/production", gotPath)
	}
	if gotQuery.Get("q") != "hello" || gotQuery.Get("limit") != "20" {
		t.Errorf("search params = %v, want q=hello limit=20", gotQuery)
	}
	if gotQuery.Get("perspective") != "drafts" {
		t.Errorf("perspective = %q, want drafts (the TUI's client perspective)", gotQuery.Get("perspective"))
	}
	if !m.searchOpen || len(m.searchHits) != 1 {
		t.Fatalf("results modal must open with 1 hit, got open=%v hits=%d", m.searchOpen, len(m.searchHits))
	}

	// Results render: title + type badge.
	out := m.renderSearchResults(120, 36)
	if !strings.Contains(out, "Hello World") || !strings.Contains(out, "[post]") {
		t.Errorf("results must render title + type:\n%s", out)
	}
}

func TestSearchDrillOpensHitEditor(t *testing.T) {
	var gotPath string
	var gotQuery url.Values
	srv := httptest.NewServer(searchServer("["+searchHitJSON+"]", &gotPath, &gotQuery))
	defer srv.Close()

	m := searchModel(t, srv.URL)
	m = press(t, m, "/")
	m.textInput.SetValue("hello")
	m = press(t, m, "enter")
	m = press(t, m, "enter") // drill into the highlighted hit

	if m.searchOpen {
		t.Error("modal must dismiss on drill")
	}
	if !m.showEditor || m.focus.Target != FocusEditor {
		t.Errorf("drill must open the editor: showEditor=%v focus=%v", m.showEditor, m.focus.Target)
	}
	if m.selectedDoc == nil || m.selectedDoc.ID != "post-7" {
		t.Fatalf("selectedDoc = %+v, want the hit post-7", m.selectedDoc)
	}
	// Type resolved from the hit's _type, not from any pane context.
	if m.editorSchema == nil || m.editorSchema.Name != "post" {
		t.Errorf("editorSchema = %+v, want post (resolved from _type)", m.editorSchema)
	}
}

func TestSearchEscDismissesBackToPaneState(t *testing.T) {
	var gotPath string
	var gotQuery url.Values
	srv := httptest.NewServer(searchServer("["+searchHitJSON+"]", &gotPath, &gotQuery))
	defer srv.Close()

	m := searchModel(t, srv.URL)
	prevFocus := m.focus
	m = press(t, m, "/")
	m.textInput.SetValue("hello")
	m = press(t, m, "enter")
	m = press(t, m, "esc")

	if m.searchOpen {
		t.Error("esc must dismiss the results modal")
	}
	if m.focus != prevFocus || m.showEditor {
		t.Errorf("esc must restore the previous pane state: focus=%v showEditor=%v", m.focus, m.showEditor)
	}
}

func TestSearchNoMatchesStatusOnly(t *testing.T) {
	var gotPath string
	var gotQuery url.Values
	srv := httptest.NewServer(searchServer("[]", &gotPath, &gotQuery))
	defer srv.Close()

	m := searchModel(t, srv.URL)
	m = press(t, m, "/")
	m.textInput.SetValue("zzz")
	m = press(t, m, "enter")

	if m.searchOpen {
		t.Error("empty results must NOT open the modal")
	}
	if m.status != "no matches" {
		t.Errorf("status = %q, want the no-matches notice", m.status)
	}
}

// ─── Help-bar hints ──────────────────────────────────────────────────────────

func TestHelpBarSearchHintOnPanes(t *testing.T) {
	var gotPath string
	var gotQuery url.Values
	srv := httptest.NewServer(searchServer("[]", &gotPath, &gotQuery))
	defer srv.Close()

	// Structure pane.
	m := searchModel(t, srv.URL)
	if bar := m.renderHelpBar(); !strings.Contains(bar, "/ search") {
		t.Errorf("structure-pane help bar must hint / search:\n%s", bar)
	}

	// Doc-list pane.
	var mutates [][]byte
	docSrv := httptest.NewServer(docServer(postDocJSON, &mutates))
	defer docSrv.Close()
	dm := listModel(t, docSrv.URL, "post")
	if bar := dm.renderHelpBar(); !strings.Contains(bar, "/ search") {
		t.Errorf("doc-list help bar must hint / search:\n%s", bar)
	}
}

// Type-to-filter (Sanity's search-driven reference field, 2026-06-12): `/`
// enters filter typing, printables narrow over title + bare id, enter picks
// from the FILTERED rows, and esc layers — typing → filter kept → cleared →
// closed.
func TestRefPickerTypeToFilter(t *testing.T) {
	m := model{refPicker: refPickerState{
		active:    true,
		fieldName: "author",
		refType:   "author",
		items: []Doc{
			{ID: "knut", Title: "Knut Hamsun", Status: "published"},
			{ID: "drafts.ibsen", Title: "Henrik Ibsen", Status: "draft"},
			{ID: "undset", Title: "Sigrid Undset", Status: "published"},
		},
		cursor: 1,
	}}

	press := func(mm model, k string) model {
		var msg tea.KeyMsg
		switch k {
		case "esc":
			msg = tea.KeyMsg{Type: tea.KeyEsc}
		case "enter":
			msg = tea.KeyMsg{Type: tea.KeyEnter}
		case "backspace":
			msg = tea.KeyMsg{Type: tea.KeyBackspace}
		default:
			msg = tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune(k)}
		}
		next, _ := mm.handleRefPickerKey(msg)
		return next.(model)
	}

	// `/` then type — the filter narrows over title AND bare id.
	m = press(m, "/")
	if !m.refPicker.filtering {
		t.Fatal("/ should enter filter typing")
	}
	for _, r := range "ibsen" {
		m = press(m, string(r))
	}
	if got := m.refPicker.filteredRefItems(); len(got) != 1 || got[0].Title != "Henrik Ibsen" {
		t.Fatalf("filter 'ibsen' = %+v, want just Ibsen (matches the bare id too)", got)
	}

	// Render shows the filter line and only the matching row.
	m.width, m.height = 100, 40
	out := m.renderRefPicker(100, 30)
	if !strings.Contains(out, "ibsen") || strings.Contains(out, "Undset") {
		t.Errorf("filtered render wrong:\n%s", out)
	}

	// Cursor was clamped into the narrowed span; enter picks from FILTERED rows.
	m.refPicker.cursor = 1
	m = press(m, "enter")
	if m.refPicker.active {
		t.Fatal("enter should commit and close")
	}
	if m.dirtyValues["author"] != "ibsen" {
		t.Errorf("picked %q, want the bare id ibsen", m.dirtyValues["author"])
	}
}

func TestRefPickerEscLayers(t *testing.T) {
	m := model{refPicker: refPickerState{
		active: true, fieldName: "author", refType: "author",
		items:  []Doc{{ID: "knut", Title: "Knut Hamsun"}},
		cursor: 1, filter: "kn", filtering: true,
	}}
	esc := tea.KeyMsg{Type: tea.KeyEsc}

	next, _ := m.handleRefPickerKey(esc) // 1: stop typing, keep filter
	m = next.(model)
	if m.refPicker.filtering || m.refPicker.filter != "kn" {
		t.Fatalf("first esc should keep the filter, got %+v", m.refPicker)
	}

	next, _ = m.handleRefPickerKey(esc) // 2: clear filter, stay open
	m = next.(model)
	if !m.refPicker.active || m.refPicker.filter != "" {
		t.Fatalf("second esc should clear the filter and stay open, got %+v", m.refPicker)
	}

	next, _ = m.handleRefPickerKey(esc) // 3: close
	m = next.(model)
	if m.refPicker.active {
		t.Fatal("third esc should close the picker")
	}
}

func TestRefPickerNoMatchesAndBackspace(t *testing.T) {
	m := model{refPicker: refPickerState{
		active: true, fieldName: "author", refType: "author",
		items:  []Doc{{ID: "knut", Title: "Knut Hamsun"}},
		cursor: 1, filtering: true, filter: "zzz",
	}}
	m.clampRefCursor()
	if m.refPicker.cursor != 0 {
		t.Errorf("cursor should clamp to the (clear) row on no matches, got %d", m.refPicker.cursor)
	}
	out := m.renderRefPicker(100, 30)
	if !strings.Contains(out, "no matches") {
		t.Errorf("empty filter result should say so:\n%s", out)
	}

	next, _ := m.handleRefPickerKey(tea.KeyMsg{Type: tea.KeyBackspace})
	m = next.(model)
	if m.refPicker.filter != "zz" {
		t.Errorf("backspace should trim the filter, got %q", m.refPicker.filter)
	}
}

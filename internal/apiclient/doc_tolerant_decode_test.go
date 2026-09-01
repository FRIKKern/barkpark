package apiclient

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
	"time"
)

// ─────────────────────────────────────────────────────────────────────────────
// Why this file exists.
//
// Go's encoding/json fails the ENTIRE Unmarshal when ONE field's shape does not
// match the struct — you do not lose that field, you lose the whole value. Doc
// is decoded as []Doc (QueryResult, Search) and as a single Doc
// (GetPerspectiveResult), so ONE reference-shaped "author" used to cost the
// caller EVERY document on the page: QueryResult returned (nil,
// DocReadUnreachable) and Query() discards the outcome, so the TUI pane
// rendered an empty list that is indistinguishable from "this type holds
// nothing".
//
// The producer really can vary these. api/lib/barkpark/content/envelope.ex
// flattens EVERY unreserved content field to the envelope top level under its
// own name, and expand.ex documents that a reference value is "either a plain
// id string or a Sanity-style %{"_ref" => id} object" — same field, same
// schema, two shapes. tooling/jarl-schema-backup/schema-ls-all.json captures a
// live deployment whose `post` schema declares a reference field literally
// named "author".
//
// The tests below are a table over the reachable collision set with a CONTROL
// arm: the control proves the instrument reports PRESENCE (a well-shaped doc
// really does land its Author/Category/Status/UpdatedAt), not merely the
// absence of a complaint.
// ─────────────────────────────────────────────────────────────────────────────

// wellShapedDocJSON is a document every field of which has the shape the typed
// decode expects, carrying BOTH the legacy keys ("id"/"updatedAt"/"values")
// and the live v1 envelope keys ("_id"/"_updatedAt"/flattened content) so the
// baseline below pins the legacy-wins branch of normalizeEnvelope.
const wellShapedDocJSON = `{
	"id": "legacy-id",
	"_id": "envelope-id",
	"_type": "post",
	"_rev": "r1",
	"_draft": true,
	"_publishedId": "pub-1",
	"_createdAt": "2026-01-01T00:00:00Z",
	"_updatedAt": "2026-06-05T10:19:18.901132Z",
	"title": "Hello",
	"status": "published",
	"category": "news",
	"author": "Ada",
	"updatedAt": "2025-01-02T03:04:05Z",
	"values": {"a": "b"},
	"featured": true,
	"priority": 2,
	"tags": ["a", "b"],
	"meta": {"x": 1},
	"blocks": [{"type": "paragraph"}],
	"body_html": "<p>hi</p>"
}`

// liveShapedDocJSON is the live v1 envelope with NO legacy keys, so the
// baseline also pins the gap-fill branches (_id → ID, _updatedAt → UpdatedAt,
// _draft → Status, flattened scalars → Values).
const liveShapedDocJSON = `{
	"_createdAt": "2026-06-05T10:19:18.901132Z",
	"_draft": true,
	"_id": "drafts.playground-unpublish-1",
	"_publishedId": "playground-unpublish-1",
	"_rev": "a49ab6f8b38b957cfa3d3a165aabce0f",
	"_type": "post",
	"_updatedAt": "2026-06-05T10:19:18.901132Z",
	"title": "Unpublish me",
	"status": "draft",
	"category": "Tech",
	"author": "Knut",
	"featured": true,
	"priority": 2,
	"tags": ["a", "b"],
	"meta": {"x": 1}
}`

// snapshotDoc renders EVERY exported field of a decoded Doc (plus the Extra
// key set) in a stable order. It is the instrument behind the "provably not a
// rewrite" claim: the baseline file it feeds was captured from the PREVIOUS
// decode and must keep matching field-for-field.
func snapshotDoc(d Doc) string {
	var b strings.Builder
	fmt.Fprintf(&b, "ID=%q\n", d.ID)
	fmt.Fprintf(&b, "Type=%q\n", d.Type)
	fmt.Fprintf(&b, "Title=%q\n", d.Title)
	fmt.Fprintf(&b, "Status=%q\n", d.Status)
	fmt.Fprintf(&b, "Category=%q\n", d.Category)
	fmt.Fprintf(&b, "Author=%q\n", d.Author)
	fmt.Fprintf(&b, "UpdatedAt=%s\n", d.UpdatedAt.UTC().Format(time.RFC3339Nano))
	fmt.Fprintf(&b, "UpdatedAt.IsZero=%v\n", d.UpdatedAt.IsZero())
	fmt.Fprintf(&b, "Values==nil:%v len=%d\n", d.Values == nil, len(d.Values))
	for _, k := range sortedStringKeys(d.Values) {
		fmt.Fprintf(&b, "  Values[%q]=%q\n", k, d.Values[k])
	}
	fmt.Fprintf(&b, "Blocks=%s\n", rawOrNil(d.Blocks))
	fmt.Fprintf(&b, "Content=%s\n", rawOrNil(d.Content))
	fmt.Fprintf(&b, "Body=%s\n", rawOrNil(d.Body))
	fmt.Fprintf(&b, "BodyHTML=%q\n", d.BodyHTML)
	fmt.Fprintf(&b, "Extra==nil:%v len=%d\n", d.Extra == nil, len(d.Extra))
	for _, k := range sortedRawKeys(d.Extra) {
		fmt.Fprintf(&b, "  Extra[%q]=%s\n", k, string(d.Extra[k]))
	}
	return b.String()
}

func sortedStringKeys(m map[string]string) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

func sortedRawKeys(m map[string]json.RawMessage) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

func rawOrNil(raw json.RawMessage) string {
	if raw == nil {
		return "<nil>"
	}
	return string(raw)
}

// TestWellShapedDocDecodeMatchesCapturedBaseline is acceptance criterion 3:
// a well-shaped payload must decode field-for-field the way it decoded before
// the tolerant-decode change. The baseline in testdata/ was CAPTURED from the
// pre-change decode (regenerate deliberately with
// BP_UPDATE_DOC_DECODE_BASELINE=1 — a diff to that file is a behaviour change
// and must be justified, not waved through).
func TestWellShapedDocDecodeMatchesCapturedBaseline(t *testing.T) {
	var wellShaped, liveShaped Doc
	if err := json.Unmarshal([]byte(wellShapedDocJSON), &wellShaped); err != nil {
		t.Fatalf("well-shaped doc must decode: %v", err)
	}
	if err := json.Unmarshal([]byte(liveShapedDocJSON), &liveShaped); err != nil {
		t.Fatalf("live-shaped doc must decode: %v", err)
	}
	got := "# well-shaped (legacy + envelope keys)\n" + snapshotDoc(wellShaped) +
		"\n# live v1 envelope (gap-fill branches)\n" + snapshotDoc(liveShaped)

	path := filepath.Join("testdata", "doc_decode_baseline.txt")
	if os.Getenv("BP_UPDATE_DOC_DECODE_BASELINE") == "1" {
		if err := os.WriteFile(path, []byte(got), 0o644); err != nil {
			t.Fatalf("write baseline: %v", err)
		}
		t.Logf("baseline rewritten: %s", path)
		return
	}
	want, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read baseline: %v", err)
	}
	if got != string(want) {
		t.Fatalf("well-shaped decode DRIFTED from the captured baseline.\n--- want (%s) ---\n%s\n--- got ---\n%s", path, want, got)
	}
	// Guard the guard: the baseline must be a PRESENCE record, not an empty
	// file that any decode would match.
	for _, needle := range []string{`Author="Ada"`, `Category="news"`, `Status="published"`, `Author="Knut"`} {
		if !strings.Contains(got, needle) {
			t.Fatalf("baseline instrument is vacuous: snapshot lacks %s", needle)
		}
	}
}

// ─── the collision table ─────────────────────────────────────────────────────

// pageDoc renders one document of a five-document page. override is appended
// AFTER the well-shaped fields, so it is the value encoding/json decodes (for a
// duplicate key, the last one wins).
func pageDoc(id string, override string) string {
	fields := []string{
		fmt.Sprintf(`"_id": %q`, id),
		`"_type": "post"`,
		fmt.Sprintf(`"title": "Title of %s"`, id),
		`"_updatedAt": "2026-06-05T10:19:18.901132Z"`,
		`"status": "published"`,
		`"category": "news"`,
		`"author": "Ada"`,
		`"updatedAt": "2025-01-02T03:04:05Z"`,
		`"values": {"a": "b"}`,
		`"body_html": "<p>ok</p>"`,
		`"priority": 2`,
	}
	if override != "" {
		fields = append(fields, override)
	}
	return "{" + strings.Join(fields, ",") + "}"
}

// collisionCases is the reachable collision set plus a CONTROL arm. Every case
// builds the SAME five-document page; only doc-3 differs.
var collisionCases = []struct {
	name string
	// override is spliced into doc-3 AFTER the well-shaped field of the same
	// name, so it is the value encoding/json actually decodes.
	override string
	// check asserts what doc-3 must still carry once the page survives.
	check func(t *testing.T, d Doc)
}{
	{
		name:     "CONTROL/every field well shaped",
		override: "",
		check: func(t *testing.T, d Doc) {
			// PRESENCE proof: this arm fails if the decode quietly stops
			// landing these fields, so a green table can never mean
			// "nothing was checked".
			if d.Author != "Ada" {
				t.Errorf("CONTROL Author = %q, want \"Ada\"", d.Author)
			}
			if d.Category != "news" {
				t.Errorf("CONTROL Category = %q, want \"news\"", d.Category)
			}
			if d.Status != "published" {
				t.Errorf("CONTROL Status = %q, want \"published\"", d.Status)
			}
			if want := time.Date(2025, 1, 2, 3, 4, 5, 0, time.UTC); !d.UpdatedAt.Equal(want) {
				t.Errorf("CONTROL UpdatedAt = %v, want %v", d.UpdatedAt, want)
			}
			if len(d.Values) != 1 || d.Values["a"] != "b" {
				t.Errorf("CONTROL Values = %v, want {\"a\":\"b\"}", d.Values)
			}
			if d.BodyHTML != "<p>ok</p>" {
				t.Errorf("CONTROL BodyHTML = %q, want the well-shaped body_html", d.BodyHTML)
			}
			if d.ID != "post-3" {
				t.Errorf("CONTROL ID = %q, want \"post-3\" (from _id)", d.ID)
			}
			// Title joins the presence proof: a well-shaped string title must
			// still decode to exactly the value it decoded to before it was
			// moved off the typed struct decode.
			if d.Title != "Title of post-3" {
				t.Errorf("CONTROL Title = %q, want \"Title of post-3\"", d.Title)
			}
		},
	},
	{
		name:     "author is an expanded reference object",
		override: `"author": {"_ref": "author-ada", "_type": "author", "name": "Ada Lovelace"}`,
		check: func(t *testing.T, d Doc) {
			if d.Author != "" {
				t.Errorf("Author = %q, want \"\" (an object has no flat rendering)", d.Author)
			}
			// The point of the row: only THAT field degrades.
			if d.Category != "news" || d.Status != "published" || d.Title != "Title of post-3" {
				t.Errorf("colliding doc lost sibling fields: category=%q status=%q title=%q", d.Category, d.Status, d.Title)
			}
			if _, ok := d.Extra["author"]; !ok {
				t.Errorf("Extra must still carry the raw author value for a caller that can read it")
			}
		},
	},
	{
		name:     "author is a bare reference id string (the other half of the union)",
		override: `"author": "author-ada"`,
		check: func(t *testing.T, d Doc) {
			if d.Author != "author-ada" {
				t.Errorf("Author = %q, want the reference id verbatim", d.Author)
			}
		},
	},
	{
		name:     "category is an array",
		override: `"category": ["news", "tech"]`,
		check: func(t *testing.T, d Doc) {
			if d.Category != "" {
				t.Errorf("Category = %q, want \"\" (an array has no flat rendering)", d.Category)
			}
			if d.Author != "Ada" || d.Status != "published" {
				t.Errorf("colliding doc lost sibling fields: author=%q status=%q", d.Author, d.Status)
			}
		},
	},
	{
		name:     "values is a non-string map",
		override: `"values": {"count": 3, "nested": {"k": "v"}}`,
		check: func(t *testing.T, d Doc) {
			// The typed map[string]string cannot hold it; the tolerant path
			// falls through to the Extra-derived Values, which keeps the
			// document's flattened scalars.
			if d.Values["author"] != "Ada" || d.Values["priority"] != "2" {
				t.Errorf("Values = %v, want the Extra-derived scalars", d.Values)
			}
			if d.Author != "Ada" || d.Category != "news" {
				t.Errorf("colliding doc lost sibling fields: author=%q category=%q", d.Author, d.Category)
			}
		},
	},
	{
		name:     "updatedAt is not a timestamp",
		override: `"updatedAt": "yesterday"`,
		check: func(t *testing.T, d Doc) {
			// Degrades to the envelope's _updatedAt rather than killing the doc.
			want := time.Date(2026, 6, 5, 10, 19, 18, 901132000, time.UTC)
			if !d.UpdatedAt.Equal(want) {
				t.Errorf("UpdatedAt = %v, want the _updatedAt fallback %v", d.UpdatedAt, want)
			}
			if d.Author != "Ada" {
				t.Errorf("colliding doc lost sibling fields: author=%q", d.Author)
			}
		},
	},
	{
		name:     "updatedAt is an object",
		override: `"updatedAt": {"at": "2025-01-02T03:04:05Z"}`,
		check: func(t *testing.T, d Doc) {
			want := time.Date(2026, 6, 5, 10, 19, 18, 901132000, time.UTC)
			if !d.UpdatedAt.Equal(want) {
				t.Errorf("UpdatedAt = %v, want the _updatedAt fallback %v", d.UpdatedAt, want)
			}
		},
	},
	{
		name:     "body_html is a reference object",
		override: `"body_html": {"_ref": "html-blob-1", "_type": "asset"}`,
		check: func(t *testing.T, d Doc) {
			if d.BodyHTML != "" {
				t.Errorf("BodyHTML = %q, want empty (an object has no flat rendering)", d.BodyHTML)
			}
			if d.Author != "Ada" || d.Category != "news" || d.ID != "post-3" {
				t.Errorf("colliding doc lost sibling fields: author=%q category=%q id=%q", d.Author, d.Category, d.ID)
			}
		},
	},
	{
		// The identity case, and the worst of the seven. A content field named
		// plain "id" is NOT in Barkpark.Content.Envelope's @reserved list, so it
		// flattens onto Doc.ID; a reference-shaped one used to kill the whole
		// page. It must now degrade to the envelope's "_id", which leaves the
		// document ADDRESSABLE rather than merely present.
		name:     "id is a reference object",
		override: `"id": {"_ref": "post-3", "_type": "post"}`,
		check: func(t *testing.T, d Doc) {
			if d.ID != "post-3" {
				t.Errorf("ID = %q, want the _id fallback \"post-3\" — the document must stay addressable", d.ID)
			}
			if d.Author != "Ada" || d.Title != "Title of post-3" {
				t.Errorf("colliding doc lost sibling fields: author=%q title=%q", d.Author, d.Title)
			}
		},
	},
	{
		name:     "status is a reference object",
		override: `"status": {"_ref": "status-published"}`,
		check: func(t *testing.T, d Doc) {
			// _draft is absent on this page, so Status simply degrades to "".
			if d.Status != "" {
				t.Errorf("Status = %q, want \"\"", d.Status)
			}
			if d.Author != "Ada" || d.Category != "news" {
				t.Errorf("colliding doc lost sibling fields: author=%q category=%q", d.Author, d.Category)
			}
		},
	},
	{
		// The EIGHTH field, and the one #14487 deliberately left typed. Through
		// /v1/data/query it cannot collide: envelope.ex does Map.put("title",
		// doc.title) from the typed DB column AFTER the content merge, so the
		// producer overwrites a content field named "title" before it reaches
		// the wire. But Doc is decoded from bodies that producer never shaped —
		// paper.go's PaperDoc callers decode raw envelopes and RevisionDoc
		// builds a Doc from a revision body — and on those paths a
		// reference-shaped title used to abort the WHOLE slice. A client
		// hardened against ONE producer's invariant is hardened against nothing.
		name:     "title is a reference object",
		override: `"title": {"_ref": "title-block-1", "_type": "title"}`,
		check: func(t *testing.T, d Doc) {
			if d.Title != "" {
				t.Errorf("Title = %q, want \"\" (an object has no flat rendering)", d.Title)
			}
			if d.Author != "Ada" || d.Category != "news" || d.Status != "published" || d.ID != "post-3" {
				t.Errorf("colliding doc lost sibling fields: author=%q category=%q status=%q id=%q", d.Author, d.Category, d.Status, d.ID)
			}
			if _, ok := d.Extra["title"]; !ok {
				t.Errorf("Extra must still carry the raw title value for a caller that can read it")
			}
		},
	},
	{
		name:     "title is an array",
		override: `"title": ["Hello", "World"]`,
		check: func(t *testing.T, d Doc) {
			if d.Title != "" {
				t.Errorf("Title = %q, want \"\" (an array has no flat rendering)", d.Title)
			}
			if d.Author != "Ada" || d.Status != "published" {
				t.Errorf("colliding doc lost sibling fields: author=%q status=%q", d.Author, d.Status)
			}
		},
	},
	{
		name:     "title is a number",
		override: `"title": 2026`,
		check: func(t *testing.T, d Doc) {
			// scalarString renders a JSON number via its literal representation,
			// exactly as it does for every other coerced field.
			if d.Title != "2026" {
				t.Errorf("Title = %q, want \"2026\" (a number renders via its literal)", d.Title)
			}
			if d.Author != "Ada" || d.Category != "news" {
				t.Errorf("colliding doc lost sibling fields: author=%q category=%q", d.Author, d.Category)
			}
		},
	},
}

const collidingIndex = 2 // doc-3, i.e. pageIDs[2]

var pageIDs = []string{"post-1", "post-2", "post-3", "post-4", "post-5"}

// collisionPage builds the five-document page for a case.
func collisionPage(override string) []string {
	docs := make([]string, len(pageIDs))
	for i, id := range pageIDs {
		if i == collidingIndex {
			docs[i] = pageDoc(id, override)
		} else {
			docs[i] = pageDoc(id, "")
		}
	}
	return docs
}

// assertWholePage is the honest failure message: it NAMES the documents that
// went missing rather than reporting a bare count.
func assertWholePage(t *testing.T, got []Doc) {
	t.Helper()
	seen := make(map[string]bool, len(got))
	for _, d := range got {
		seen[d.ID] = true
	}
	var lost []string
	for _, id := range pageIDs {
		if !seen[id] {
			lost = append(lost, id)
		}
	}
	if len(lost) > 0 {
		t.Fatalf("ONE reference-shaped field on %s blanked the page: %d of %d documents LOST — %s",
			pageIDs[collidingIndex], len(lost), len(pageIDs), strings.Join(lost, ", "))
	}
	if len(got) != len(pageIDs) {
		t.Fatalf("page length = %d, want %d", len(got), len(pageIDs))
	}
}

func docAt(t *testing.T, got []Doc, id string) Doc {
	t.Helper()
	for _, d := range got {
		if d.ID == id {
			return d
		}
	}
	t.Fatalf("document %s absent from the page", id)
	return Doc{}
}

func newDocDecodeClient(srv *httptest.Server) *Client {
	return New(Config{BaseURL: srv.URL, Token: "t", Workspace: "default", Project: "default", Dataset: "production"})
}

func serveJSON(t *testing.T, body string) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(body))
	}))
	t.Cleanup(srv.Close)
	return srv
}

// TestQueryResultSurvivesReferenceShapedField is acceptance criteria 1, 2 and
// 5: one mis-shaped field on one document must cost that FIELD, never the page.
func TestQueryResultSurvivesReferenceShapedField(t *testing.T) {
	for _, tc := range collisionCases {
		t.Run(tc.name, func(t *testing.T) {
			body := `{"result":{"count":5,"documents":[` + strings.Join(collisionPage(tc.override), ",") + `]}}`
			got, outcome := newDocDecodeClient(serveJSON(t, body)).QueryResult("post", "")
			// Errorf, not Fatalf: assertWholePage below is the message that
			// NAMES the documents that went missing, and a mutation must
			// surface that, not merely an outcome code.
			if outcome != DocReadOK {
				t.Errorf("outcome = %v, want DocReadOK — a decodable page reported as a failed read", outcome)
			}
			assertWholePage(t, got)
			tc.check(t, docAt(t, got, pageIDs[collidingIndex]))

			// The other four documents must be untouched.
			for i, id := range pageIDs {
				if i == collidingIndex {
					continue
				}
				d := docAt(t, got, id)
				if d.Author != "Ada" || d.Category != "news" || d.Title != "Title of "+id {
					t.Errorf("bystander %s corrupted: author=%q category=%q title=%q", id, d.Author, d.Category, d.Title)
				}
			}
		})
	}
}

// TestSearchSurvivesReferenceShapedField — Search decodes the same []Doc and is
// LOUD about a decode failure, so the operator was at least told; it still lost
// every row. Same radius, same fix.
func TestSearchSurvivesReferenceShapedField(t *testing.T) {
	body := `{"count":5,"documents":[` + strings.Join(collisionPage(`"author": {"_ref": "author-ada"}`), ",") + `]}`
	got, err := newDocDecodeClient(serveJSON(t, body)).Search("ada", 0)
	if err != nil {
		t.Fatalf("Search returned %v — one reference-shaped author killed the whole result set", err)
	}
	assertWholePage(t, got)

	// CONTROL: a well-shaped page must still land its fields.
	ctrlBody := `{"count":5,"documents":[` + strings.Join(collisionPage(""), ",") + `]}`
	ctrlDocs, err := newDocDecodeClient(serveJSON(t, ctrlBody)).Search("ada", 0)
	if err != nil {
		t.Fatalf("CONTROL Search: %v", err)
	}
	assertWholePage(t, ctrlDocs)
	if d := docAt(t, ctrlDocs, "post-3"); d.Author != "Ada" {
		t.Fatalf("CONTROL Search: author = %q, want \"Ada\"", d.Author)
	}
}

// TestGetPerspectiveSurvivesReferenceShapedField — GetPerspectiveResult decodes
// ONE Doc and collapses a decode failure to (Doc{}, false), so a document that
// EXISTS and is READABLE reported as ABSENT. That feeds `bp cmux status`'s
// acceptance gate on perspective=drafts, which would then see nothing before an
// auto-close decision.
func TestGetPerspectiveSurvivesReferenceShapedField(t *testing.T) {
	body := `{"result":` + pageDoc("post-3", `"author": {"_ref": "author-ada", "_type": "author"}`) + `}`
	c := newDocDecodeClient(serveJSON(t, body))

	doc, outcome := c.GetPerspectiveResult("post", "post-3", "drafts")
	if outcome != DocReadOK {
		t.Fatalf("outcome = %v, want DocReadOK — a document that EXISTS reported as unreadable", outcome)
	}
	if doc.ID != "post-3" || doc.Title != "Title of post-3" {
		t.Fatalf("doc = {ID:%q Title:%q}, want the real document", doc.ID, doc.Title)
	}

	// And the bool-collapsing wrapper `bp cmux status` actually calls.
	if _, ok := c.GetPerspective("post", "post-3", "drafts"); !ok {
		t.Fatalf("GetPerspective reported ABSENT for a document that exists and is readable")
	}

	// CONTROL: the same read of a well-shaped document must land its author,
	// so this test proves presence, not merely the absence of a complaint.
	ctrl := newDocDecodeClient(serveJSON(t, `{"result":`+pageDoc("post-4", "")+`}`))
	ctrlDoc, ctrlOutcome := ctrl.GetPerspectiveResult("post", "post-4", "drafts")
	if ctrlOutcome != DocReadOK || ctrlDoc.Author != "Ada" {
		t.Fatalf("CONTROL: outcome=%v author=%q, want DocReadOK / \"Ada\"", ctrlOutcome, ctrlDoc.Author)
	}
}

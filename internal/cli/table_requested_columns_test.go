package cli

import (
	"bytes"
	"net/url"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// sparseCatalogPayload is the live shape that produced this row: a projected
// catalog page (`--fields title,concept,variant,domain,description`) on which
// NO row carries a description. The API projects a document's own content, so a
// field the document does not set is not an empty string in the payload — the
// key is absent entirely, which is precisely why a renderer that derives
// columns from the keys PRESENT could not tell "unset on this page" from "not a
// field". Every other requested column has values, so nothing but the sparse
// column distinguishes the two renders below.
const sparseCatalogPayload = `{"documents":[
  {"_id":"cmd-a","title":"Add a LiveView","concept":"liveview","variant":"basic","domain":"web"},
  {"_id":"cmd-b","title":"Add a context","concept":"context","variant":"basic","domain":"core"},
  {"_id":"cmd-c","title":"Add a migration","concept":"migration","variant":"basic","domain":"db"}
]}`

// A column the caller NAMED renders even when every value on the page is empty.
// The two states this separates are not interchangeable: an absent column says
// "there is no such field", an empty one says "no row here has a value", and
// before this the renderer printed the first while meaning the second — at exit
// 0, on a projection the query asked for by name.
//
// MUTATION PROOF: pass nil instead of out.requestedColumns in renderRows (or
// drop the withRequestedColumns call in pickColumns) and this reds — the golden
// loses its `description` column, becoming byte-identical to the inferred
// golden the quiet arm below pins.
func TestRenderTableRendersRequestedButEmptyColumn(t *testing.T) {
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	w.requestedColumns = splitFieldsProjection("title,concept,variant,domain,description")
	renderTable(w, []byte(sparseCatalogPayload))

	assertGolden(t, "table_requested_sparse_columns", stdout.String())

	header := strings.SplitN(stdout.String(), "\n", 2)[0]
	if !strings.Contains(header, "description") {
		t.Fatalf("a requested column must survive an all-empty page; header was %q", header)
	}
	// Requested order is the caller's order, and the identity column the caller
	// did NOT name keeps its front seat rather than being shuffled to the back.
	if got, want := strings.Fields(header), []string{"_id", "title", "concept", "variant", "domain", "description"}; !equalStrings(got, want) {
		t.Errorf("column order = %v, want %v", got, want)
	}
}

// THE QUIET ARM. The same page with NO projection keeps today's behaviour: an
// inferred all-empty column is still dropped. This is the half a careless fix
// breaks — rendering every key present would make the projection meaningless
// and fill inferred tables with blank columns.
func TestRenderTableInferredColumnsStillDropWhenAllEmpty(t *testing.T) {
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	renderTable(w, []byte(sparseCatalogPayload))

	assertGolden(t, "table_inferred_sparse_columns", stdout.String())

	header := strings.SplitN(stdout.String(), "\n", 2)[0]
	if strings.Contains(header, "description") {
		t.Fatalf("an INFERRED all-empty column must keep being dropped; header was %q", header)
	}
	for _, want := range []string{"_id", "title", "concept", "variant", "domain"} {
		if !strings.Contains(header, want) {
			t.Errorf("inferred header lost %q: %q", want, header)
		}
	}
}

// A projection never DELETES a column the payload carries — the requested names
// lead, in order, and anything else the row holds still follows. (Absent-and-
// unrequested stays absent: there is nothing to render and nothing asked for.)
func TestRenderTableRequestedColumnsKeepUnrequestedOnes(t *testing.T) {
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	w.requestedColumns = []string{"domain", "description"}
	renderTable(w, []byte(sparseCatalogPayload))

	header := strings.Fields(strings.SplitN(stdout.String(), "\n", 2)[0])
	want := []string{"_id", "title", "domain", "description", "concept", "variant"}
	if !equalStrings(header, want) {
		t.Errorf("column order = %v, want %v", header, want)
	}
	if strings.Contains(strings.Join(header, " "), "nosuchcolumn") {
		t.Errorf("renderer invented a column nobody asked for: %v", header)
	}
}

// A bare scalar array has no keys at all; a stray projection must not print a
// header of empty columns over data that has none. The synthetic "value" column
// still wins.
func TestRenderTableScalarArrayIgnoresProjection(t *testing.T) {
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	w.requestedColumns = []string{"title", "description"}
	renderTable(w, []byte(`["production","staging"]`))
	out := stdout.String()
	if !strings.Contains(out, "value") || !strings.Contains(out, "production") {
		t.Fatalf("scalar array lost its synthetic column:\n%s", out)
	}
	if strings.Contains(out, "description") {
		t.Errorf("a projection must not columnize a keyless array:\n%s", out)
	}
}

// The projection is read off the RESOLVED url, so it can only ever claim what
// the request actually carried — and only for a command whose manifest declares
// the flag, so a route that grows an unrelated `?fields=` cannot reshape its
// table.
func TestRequestedColumnsFromURL(t *testing.T) {
	withFields := manifest.Command{Noun: "doc", Verb: "query", Flags: []manifest.Flag{{Name: "fields", Type: "string"}}}
	without := manifest.Command{Noun: "task", Verb: "ready"}

	cases := []struct {
		name string
		cmd  manifest.Command
		url  string
		want []string
	}{
		{"declared flag, projection present", withFields,
			"https://x/v1/data/query/production/post?fields=title%2Cdescription&limit=10",
			[]string{"title", "description"}},
		{"whitespace trimmed, empties dropped", withFields,
			"https://x/v1/data/query/production/post?fields=" + url.QueryEscape("title, ,description "),
			[]string{"title", "description"}},
		{"no projection in url", withFields, "https://x/v1/data/query/production/post?limit=10", nil},
		{"empty projection value", withFields, "https://x/v1/data/query/production/post?fields=", nil},
		{"no query string at all", withFields, "https://x/v1/data/query/production/post", nil},
		// The manifest gate: same url, a command that does not declare --fields.
		{"flag not declared", without, "https://x/v1/tasks/ready?fields=title,description", nil},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := requestedColumnsFromURL(c.cmd, c.url); !equalStrings(got, c.want) {
				t.Errorf("requestedColumnsFromURL = %v, want %v", got, c.want)
			}
		})
	}
}

// `scaffy ls --remote` projects on the caller's behalf, and the rendered header
// is derived from the SAME constant the request sends — the request and the
// table cannot drift into disagreeing about which columns were asked for. This
// is the verb the row was filed against: its `description` column is empty on a
// fresh catalog page and used to disappear.
func TestScaffyRemoteProjectionRendersEveryColumn(t *testing.T) {
	cols := splitFieldsProjection(scaffyRemoteFields)
	want := []string{"title", "concept", "variant", "domain", "description"}
	if !equalStrings(cols, want) {
		t.Fatalf("scaffyRemoteFields splits to %v, want %v", cols, want)
	}
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	w.requestedColumns = cols
	renderTable(w, []byte(sparseCatalogPayload))
	header := strings.SplitN(stdout.String(), "\n", 2)[0]
	for _, c := range want {
		if !strings.Contains(header, c) {
			t.Errorf("scaffy catalog header lost %q: %q", c, header)
		}
	}
}

// The repeatability METADATA and the runtime behaviour are one decision, so the
// flag's declaration is what decides both doors: a `repeatable: true` flag
// composes as the bracket list form (AND-composed server-side), and a flag
// without it is REFUSED by name when repeated rather than silently keeping one
// of the two values. The one-filter and two-filter url shapes themselves are
// pinned by TestApplyQueryRepeatableFilterEmitsListForm.
func TestFlagRepeatabilityMetadataMatchesBehavior(t *testing.T) {
	cmd := manifest.Command{
		Noun: "doc", Verb: "query",
		Flags: []manifest.Flag{
			{Name: "filter", Type: "string", Repeatable: true},
			{Name: "fields", Type: "string"},
		},
	}
	repeatable := cmd.Flags[0]
	scalar := cmd.Flags[1]

	if !flagAcceptsRepeat(repeatable) {
		t.Error("a flag declared repeatable must accept a repeat")
	}
	if err := refuseRepeatedFlag(cmd, repeatable, []string{"status=published"}, "title=Alpha"); err != nil {
		t.Errorf("a repeatable flag must not be refused: %v", err)
	}
	// One --filter: the plain scalar spelling. Two: the list form.
	one := applyQuery("https://x/v1/data/query/production/post", globals{}, cmd,
		map[string][]string{"filter": {"status=published"}}, map[string]string{})
	if q := mustQuery(t, one); q.Get("filter") != "status=published" || q.Has("filter[]") {
		t.Errorf("one --filter must ride as the scalar key; got %q", one)
	}
	two := applyQuery("https://x/v1/data/query/production/post", globals{}, cmd,
		map[string][]string{"filter": {"status=published", "title=Alpha"}}, map[string]string{})
	q := mustQuery(t, two)
	if list := q["filter[]"]; len(list) != 2 || q.Has("filter") {
		t.Errorf("two --filter clauses must ride as filter[] (both preserved); got %q", two)
	}

	// The un-declared side: repeating it is a NAMED refusal, never last-wins.
	if flagAcceptsRepeat(scalar) {
		t.Error("a flag without repeatable:true must not accept a repeat")
	}
	err := refuseRepeatedFlag(cmd, scalar, []string{"title"}, "description")
	if err == nil {
		t.Fatal("repeating a non-repeatable flag must refuse before the request")
	}
	for _, want := range []string{"--fields", "not repeatable", `"title"`, `"description"`} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("the refusal must name %s; got %q", want, err.Error())
		}
	}
}

func mustQuery(t *testing.T, raw string) url.Values {
	t.Helper()
	u, err := url.Parse(raw)
	if err != nil {
		t.Fatalf("bad url %q: %v", raw, err)
	}
	return u.Query()
}

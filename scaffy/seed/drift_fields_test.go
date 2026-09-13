package main

// drift_fields_test.go is the regression for task-7c037e523ccac6ee: the
// scaffy-catalog-drift gate compared sha256(source) and nothing else, so a
// change under internal/scaffy/** that altered what the SAME corpus bytes
// DERIVE TO — header extraction, cmd.Direction(), weightedTags' 90/80/70
// ladder — moved the served metadata out from under the check while `source`
// still matched and the table printed `22/22 MATCH — catalog in sync`.
// internal/scaffy/** is one of that workflow's own `on: push: paths:` entries,
// so the gate fired on exactly the class it could not see.
//
// The arms here are hermetic: an httptest server stands in for guerrilla, so
// nothing in this file reaches the network.

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"sort"
	"strings"
	"testing"
)

// serveCatalog stands up a fixture catalog server returning the given documents
// in the real envelope shape, and returns its base URL.
func serveCatalog(t *testing.T, docs []servedDoc) string {
	t.Helper()
	body, err := json.Marshal(map[string]any{
		"result": map[string]any{"documents": docs},
	})
	if err != nil {
		t.Fatal(err)
	}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write(body)
	}))
	t.Cleanup(srv.Close)
	return srv.URL
}

// servedFromPayloads mirrors each derived payload into the served document the
// catalog would hold if seeding had just run — every field, not two.
func servedFromPayloads(payloads []*payload) []servedDoc {
	out := make([]servedDoc, 0, len(payloads))
	for _, p := range payloads {
		out = append(out, servedDoc{
			ID: p.ID, Title: p.Title, Description: p.Description,
			Concept: p.Concept, Variant: p.Variant, Domain: p.Domain,
			Direction: p.Direction, Tags: p.Tags, Source: p.Source,
		})
	}
	return out
}

// TestFetchServedDecodesEveryDerivedField is c0's first half: the envelope no
// longer stops at {_id, source}. It asserts all eight compared fields survive
// the wire, which the two-field struct could not have done.
func TestFetchServedDecodesEveryDerivedField(t *testing.T) {
	want := servedDoc{
		ID: "a--b--c", Title: "T", Description: "D", Concept: "b",
		Variant: "c", Domain: "a", Direction: "add",
		Tags:   []weightedTag{{Tag: "x", Strength: 90, Rationale: "R"}},
		Source: "SRC",
	}
	got, err := fetchServed(serveCatalog(t, []servedDoc{want}))
	if err != nil {
		t.Fatal(err)
	}
	d, ok := got["a--b--c"]
	if !ok {
		t.Fatalf("id not decoded: %v", got)
	}
	// Field by field, by NAME — a struct-equality check would pass on a struct
	// that had lost a json tag and silently zeroed the field.
	for _, c := range []struct{ name, got, want string }{
		{"title", d.Title, "T"}, {"description", d.Description, "D"},
		{"concept", d.Concept, "b"}, {"variant", d.Variant, "c"},
		{"domain", d.Domain, "a"}, {"direction", d.Direction, "add"},
		{"source", d.Source, "SRC"},
	} {
		if c.got != c.want {
			t.Errorf("%s decoded as %q, want %q", c.name, c.got, c.want)
		}
	}
	if len(d.Tags) != 1 || d.Tags[0].Tag != "x" || d.Tags[0].Strength != 90 {
		t.Errorf("tags decoded as %+v, want one x@90", d.Tags)
	}
}

// TestServedDocMirrorsThePayloadFieldSet is the structural guard c0 asks for:
// the check can only compare what it decodes, so a field added to `derive`'s
// payload and NOT to servedDoc becomes invisible to the gate the moment it is
// seeded. This compares the two structs' json tag sets directly, so that
// omission fails a test instead of quietly widening the blind spot again.
func TestServedDocMirrorsThePayloadFieldSet(t *testing.T) {
	payloadTags := jsonTagSet(t, payload{})
	servedTags := jsonTagSet(t, servedDoc{})
	if strings.Join(payloadTags, ",") != strings.Join(servedTags, ",") {
		t.Fatalf("payload and servedDoc field sets diverged:\n payload:  %v\n servedDoc: %v\nadd the new field to servedDoc, comparedFields, localFields and servedFields, or the gate will not see it",
			payloadTags, servedTags)
	}
	// comparedFields must be exactly that set minus the join key `_id`.
	want := make([]string, 0, len(payloadTags))
	for _, f := range payloadTags {
		if f != "_id" {
			want = append(want, f)
		}
	}
	got := append([]string(nil), comparedFields...)
	sort.Strings(want)
	sort.Strings(got)
	if strings.Join(want, ",") != strings.Join(got, ",") {
		t.Fatalf("comparedFields = %v, want every seeded field but _id: %v", got, want)
	}
}

// TestTheRealCorpusAuditsCleanAgainstAFaithfulCatalog is arm (1) of the
// mutation proof the row demands: the unmodified corpus against a catalog that
// holds exactly what seeding wrote → every row MATCH, exit 0. Without this arm
// the red arm below would prove only that the check can fail.
func TestTheRealCorpusAuditsCleanAgainstAFaithfulCatalog(t *testing.T) {
	payloads, err := deriveAll(corpusCommandsDir)
	if err != nil {
		t.Fatal(err)
	}
	if len(payloads) == 0 {
		t.Fatal("derived ZERO payloads — every arm below would pass vacuously")
	}
	served := map[string]servedDoc{}
	for _, d := range servedFromPayloads(payloads) {
		served[d.ID] = d
	}

	var sb strings.Builder
	if n := printCheckTable(&sb, "http://fixture", payloads, served); n != 0 {
		t.Fatalf("a faithful catalog must audit clean, got %d non-MATCH:\n%s", n, sb.String())
	}
	if !strings.Contains(sb.String(), "MATCH — catalog in sync") {
		t.Fatalf("the in-sync line the workflow greps for is missing:\n%s", sb.String())
	}
}

// TestAParserOnlyChangeRedsTheGate is c1, the criterion this row exists for.
// It simulates precisely what a change under internal/scaffy/** does: the
// .scaffy bytes are untouched (`source` is byte-identical on both sides) while
// what they DERIVE TO moves. Under the old sha256(source)-only comparison every
// one of these rows printed MATCH.
func TestAParserOnlyChangeRedsTheGate(t *testing.T) {
	payloads, err := deriveAll(corpusCommandsDir)
	if err != nil {
		t.Fatal(err)
	}

	// Each case mutates ONE derived field on the served side, leaving source
	// alone — one per trigger path the row names.
	cases := []struct {
		field string
		// mutate edits the served document to hold the pre-change derivation.
		mutate func(d *servedDoc)
	}{
		{"direction", func(d *servedDoc) { d.Direction = "remove" }},       // cmd.Direction()
		{"title", func(d *servedDoc) { d.Title = "a stale header value" }}, // header extraction
		{"domain", func(d *servedDoc) { d.Domain = "stale-domain" }},       // header extraction
		{"tags", func(d *servedDoc) { d.Tags[0].Strength = 95 }},           // weightedTags' ladder
	}
	for _, tc := range cases {
		t.Run(tc.field, func(t *testing.T) {
			served := map[string]servedDoc{}
			for _, d := range servedFromPayloads(payloads) {
				// deep-copy tags so a mutation does not leak across subtests
				d.Tags = append([]weightedTag(nil), d.Tags...)
				served[d.ID] = d
			}
			target := payloads[0].ID
			d := served[target]
			tc.mutate(&d)
			served[target] = d

			// THE PRECONDITION, ASSERTED NOT ASSUMED: source must be identical,
			// or this proves nothing about a parser-only change.
			if served[target].Source != payloads[0].Source {
				t.Fatalf("fixture bug: the mutation changed source; this arm must hold source byte-identical")
			}

			var sb strings.Builder
			n := printCheckTable(&sb, "http://fixture", payloads, served)
			out := sb.String()
			if n != 1 {
				t.Fatalf("expected exactly 1 non-MATCH row, got %d:\n%s", n, out)
			}
			// The status token the workflow greps for, last field on the line.
			if !strings.Contains(out, "DRIFT") {
				t.Fatalf("a parser-only divergence must report DRIFT:\n%s", out)
			}
			if strings.Contains(out, "MATCH — catalog in sync") {
				t.Fatalf("a drifted catalog must not print the in-sync line:\n%s", out)
			}
			// c1: the divergent field is NAMED, not merely counted.
			if !rowLineNames(out, target, tc.field) {
				t.Fatalf("the %s row must name %q as the divergent field:\n%s", target, tc.field, out)
			}
			// The breakdown must route the operator at the deriver, not at a re-seed alone.
			if !strings.Contains(out, "source is UNCHANGED") {
				t.Fatalf("a metadata-only drift must say the source did not move:\n%s", out)
			}
		})
	}
}

// TestSourceDriftStillRedsAndIsDistinguished is the CONTROL for the arm above:
// widening must not have cost the original detection, and the two causes must
// read differently — a moved source is a re-seed, a moved derivation is a
// parser investigation.
func TestSourceDriftStillRedsAndIsDistinguished(t *testing.T) {
	payloads := []*payload{{ID: "a--b--c", Title: "T", Source: "LOCAL"}}
	served := map[string]servedDoc{"a--b--c": {ID: "a--b--c", Title: "T", Source: "SERVED"}}

	var sb strings.Builder
	if n := printCheckTable(&sb, "http://fixture", payloads, served); n != 1 {
		t.Fatalf("expected 1 non-MATCH row, got %d:\n%s", n, sb.String())
	}
	out := sb.String()
	if !rowLineNames(out, "a--b--c", "source") {
		t.Fatalf("a source drift must name source:\n%s", out)
	}
	if !strings.Contains(out, "changed source — re-seed") {
		t.Fatalf("a source drift must route at a re-seed:\n%s", out)
	}
	if strings.Contains(out, "source is UNCHANGED") {
		t.Fatalf("a source drift must NOT be reported as metadata-only:\n%s", out)
	}
	// The LOCAL/SERVED digest columns still carry sha256(source), unchanged.
	if !strings.Contains(out, sha256hex("LOCAL")[:8]) || !strings.Contains(out, sha256hex("SERVED")[:8]) {
		t.Fatalf("the digest columns must still show sha8(source) on both sides:\n%s", out)
	}
}

// TestTheStatusTokenStaysWorkflowGreppable pins the contract the gate's shell
// depends on: .github/workflows/scaffy-catalog-drift.yml greps
// `[[:space:]](DRIFT|MISSING|EXTRA)$` and awk-extracts $1 from those lines. A
// finer status token such as "METADATA-DRIFT" would not match that grep and
// would route a real drift into the workflow's UNREACHABLE branch — so the
// finer verdict lives in the DIVERGENT FIELDS column, and this test is why.
func TestTheStatusTokenStaysWorkflowGreppable(t *testing.T) {
	payloads := []*payload{
		{ID: "drift--x--y", Source: "LOCAL"},
		{ID: "meta--x--y", Source: "SAME", Title: "NEW"},
		{ID: "missing--x--y", Source: "ONLY-LOCAL"},
	}
	served := map[string]servedDoc{
		"drift--x--y": {ID: "drift--x--y", Source: "SERVED"},
		"meta--x--y":  {ID: "meta--x--y", Source: "SAME", Title: "OLD"},
		"extra--x--y": {ID: "extra--x--y", Source: "ONLY-SERVED"},
	}
	var sb strings.Builder
	printCheckTable(&sb, "http://fixture", payloads, served)

	// Emulate the workflow's own two greps against the rendered table.
	var greppable, ids []string
	for _, ln := range strings.Split(sb.String(), "\n") {
		f := strings.Fields(ln)
		if len(f) == 0 {
			continue
		}
		switch f[len(f)-1] {
		case "DRIFT", "MISSING", "EXTRA":
			greppable = append(greppable, f[len(f)-1])
			ids = append(ids, f[0])
		}
	}
	if len(greppable) != 4 {
		t.Fatalf("the workflow grep must see 4 verdict rows (2 DRIFT, 1 MISSING, 1 EXTRA), saw %v\n%s", greppable, sb.String())
	}
	for _, want := range []string{"drift--x--y", "meta--x--y", "missing--x--y", "extra--x--y"} {
		if !containsStr(ids, want) {
			t.Errorf("awk '$1' over the verdict rows must yield %s; got %v", want, ids)
		}
	}
}

// TestTheVerdictLineStatesItsScope is c2: the summary must say what it
// compared and name what it does not, rather than letting "catalog in sync" be
// read as broader than the comparison behind it.
func TestTheVerdictLineStatesItsScope(t *testing.T) {
	payloads := []*payload{{ID: "a--b--c", Source: "SRC"}}
	served := map[string]servedDoc{"a--b--c": {ID: "a--b--c", Source: "SRC"}}
	var sb strings.Builder
	printCheckTable(&sb, "http://fixture", payloads, served)
	out := sb.String()

	for _, f := range comparedFields {
		if !strings.Contains(out, f) {
			t.Errorf("the scope line must name the compared field %q:\n%s", f, out)
		}
	}
	if !strings.Contains(out, "not compared (seeding does not write them)") {
		t.Errorf("the uncompared served keys must be NAMED, not silently excluded:\n%s", out)
	}
	for _, k := range uncomparedServedKeys {
		if !strings.Contains(out, k) {
			t.Errorf("the scope line must name the uncompared key %q:\n%s", k, out)
		}
	}
	// main_tag is the one that is easy to miss: the server derives it from the
	// weighted tags rather than reading it off the payload, so seeding does not
	// write it and the check must say so instead of appearing to check it.
	if !strings.Contains(out, "main_tag") {
		t.Errorf("main_tag is served but never seeded — it must be named as uncompared:\n%s", out)
	}
}

// rowLineNames reports whether the table line for id names field in its
// DIVERGENT FIELDS cell.
func rowLineNames(table, id, field string) bool {
	for _, ln := range strings.Split(table, "\n") {
		f := strings.Fields(ln)
		if len(f) == 0 || f[0] != id {
			continue
		}
		// the cell sits immediately before the trailing status token
		if len(f) < 2 {
			return false
		}
		for _, name := range strings.Split(f[len(f)-2], ",") {
			if name == field {
				return true
			}
		}
	}
	return false
}

func containsStr(hay []string, needle string) bool {
	for _, h := range hay {
		if h == needle {
			return true
		}
	}
	return false
}

// jsonTagSet returns the sorted json tag names of a struct's exported fields,
// skipping `json:"-"` (payload.File is audit-only and never part of the body).
func jsonTagSet(t *testing.T, v any) []string {
	t.Helper()
	raw, err := json.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	var m map[string]any
	if err := json.Unmarshal(raw, &m); err != nil {
		t.Fatal(err)
	}
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	if len(out) == 0 {
		t.Fatalf("%T marshalled to no fields — the comparison below would be vacuous", v)
	}
	_ = fmt.Sprint(out)
	return out
}

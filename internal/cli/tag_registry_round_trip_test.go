package cli

// tag_registry_round_trip_test.go — task-11f69d777d9d8e87, criterion 0.
//
// THE ROUND TRIP, MECHANICALLY. Take the FIRST row of `bp doc ls tag --all -o
// json`, read the id key off it, feed that value straight into a `tags` entry,
// and run the real `bp task create --publish`. It must be ACCEPTED, not refused
// `unknown_tag`.
//
// Both halves talk to ONE fake instance, which is what makes this a round trip
// rather than two assertions sharing a constant: the listing and the publish
// wall's registry read hit the SAME handler (`/v1/data/query/:dataset/tag`), so
// the tag the test carries between them is a value the server produced, never a
// literal the test wrote down.
//
// NO PRODUCTION LEDGER IS TOUCHED. Every request is served by httptest, and the
// mutate handler records what it received — a create that never reached the
// wire would fail the assertion, so a green here cannot come from a run that
// wrote nothing.

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// tagRegistryFixture is the registry the fake instance serves, and it is the
// live one in miniature. `epic-wave-paper` is carried on purpose: its title is
// prose ("Epic Wave Paper"), which is not a legal tag name — 52 of the 208
// published type:tag docs on guerrilla are shaped like that, and `identity`
// carries NO title at all (2 of 208). A row's `_id` is the accepted string on
// all of them, which is why the mirror is keyed off `_id` and not off `title`.
var tagRegistryRows = []string{
	`{"_createdAt":"2026-09-05T13:39:29.508024Z","_draft":false,"_id":"epic-wave-paper","_publishedId":"epic-wave-paper","_rev":"r1","_type":"tag","title":"Epic Wave Paper"}`,
	`{"_createdAt":"2026-09-05T13:39:29.508024Z","_draft":false,"_id":"cli","_publishedId":"cli","_rev":"r2","_type":"tag","title":"cli"}`,
	`{"_createdAt":"2026-09-05T13:39:29.508024Z","_draft":false,"_id":"identity","_publishedId":"identity","_rev":"r3","_type":"tag","title":null}`,
}

// tagRegistryPagedRows is the SAME vocabulary past the walk's page size, so the
// `--all` STITCH runs instead of the single-page passthrough. That distinction
// is load-bearing: the server sends `count` on every page, and it is the stitch
// — which re-wraps the walked rows as `{key: rows}` and drops every sibling —
// that used to lose it. A count test that only ever saw one page would pass
// against the unfixed code, which is exactly what the first draft of this file
// did.
func tagRegistryPagedRows() []string {
	rows := append([]string(nil), tagRegistryRows...)
	for i := len(rows); i < 150; i++ {
		id := fmt.Sprintf("paged-tag-%03d", i)
		rows = append(rows, `{"_draft":false,"_id":"`+id+`","_publishedId":"`+id+`","_rev":"r","_type":"tag","title":"`+id+`"}`)
	}
	return rows
}

// queryInt reads one integer query parameter, or def when it is absent or
// unreadable.
func queryInt(r *http.Request, name string, def int) int {
	raw := r.URL.Query().Get(name)
	if raw == "" {
		return def
	}
	n, err := strconv.Atoi(raw)
	if err != nil {
		return def
	}
	return n
}

// tagRoundTripManifest declares the one paginated read this test drives. `bp
// doc ls` as the api serves it: GET /v1/data/query/:dataset/:type, paginated,
// which is what makes `--all` available.
const tagRoundTripManifest = `{
  "manifest_version": "1",
  "etag": "test",
  "server": {"name": "test", "base_url": "http://replaced"},
  "nouns": [{"name": "doc", "summary": "Documents."}],
  "commands": [
    {"id":"doc.ls","noun":"doc","verb":"ls","summary":"List documents.",
     "http":{"method":"GET","path_template":"/v1/data/query/:dataset/:type"},
     "auth_tier":"none",
     "args":[{"name":"type","required":true,"type":"string","summary":"Document type."}],
     "flags":[{"name":"limit","type":"int","summary":"Rows per page."},
              {"name":"offset","type":"int","summary":"Rows to skip."},
              {"name":"all","type":"bool","summary":"Fetch every page."}],
     "writes":false,"batch":false,"paginated":true,"dry_run":false,
     "default_output":"table","scoped_prefix":"/w/:workspace_slug/p/:project_slug"}
  ]
}`

// tagRoundTripHarness is one fake instance answering BOTH doors.
type tagRoundTripHarness struct {
	t        *testing.T
	m        *manifest.Manifest
	ctx      manifest.Context
	mutation []string
}

func newTagRoundTripHarness(t *testing.T) *tagRoundTripHarness {
	return newTagRoundTripHarnessRows(t, tagRegistryRows)
}

// newTagRoundTripHarnessRows serves `rows` as the tag registry, honouring
// offset/limit so a registry larger than one page drives the REAL `--all`
// stitch rather than the single-page passthrough.
func newTagRoundTripHarnessRows(t *testing.T, rows []string) *tagRoundTripHarness {
	t.Helper()
	h := &tagRoundTripHarness{t: t}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch {
		case strings.Contains(r.URL.Path, "/v1/data/query/"):
			offset := queryInt(r, "offset", 0)
			limit := queryInt(r, "limit", 100)
			page := rows
			if offset >= len(page) {
				page = nil
			} else {
				page = page[offset:]
			}
			if limit >= 0 && limit < len(page) {
				page = page[:limit]
			}
			// The server's own single-page envelope, count and all.
			_, _ = fmt.Fprintf(w, `{"count":%d,"documents":[%s],"hasMore":%t,"limit":%d,"offset":%d}`,
				len(page), strings.Join(page, ","), offset+len(page) < len(rows), limit, offset)
		case strings.Contains(r.URL.Path, "/v1/data/mutate/"):
			raw, _ := io.ReadAll(r.Body)
			h.mutation = append(h.mutation, string(raw))
			_, _ = w.Write([]byte(`{"transactionId":"tx1","results":[{"id":"task-round-trip","operation":"create",` +
				`"document":{"_id":"task-round-trip","_draft":false,"lifecycle_status":"open"}}]}`))
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	t.Cleanup(srv.Close)

	m, err := manifest.Parse([]byte(strings.Replace(tagRoundTripManifest, "http://replaced", srv.URL, 1)))
	if err != nil {
		t.Fatalf("parse fixture manifest: %v", err)
	}
	h.m = m
	h.ctx = manifest.Context{Server: srv.URL, Token: "tok", Dataset: "production"}
	return h
}

// listTags runs the REAL `bp doc ls tag --all -o json` against the fake
// instance and returns its stdout.
func (h *tagRoundTripHarness) listTags() string {
	h.t.Helper()
	cmd, ok := h.m.Tree().Lookup("doc", "ls")
	if !ok {
		h.t.Fatal("fixture manifest has no doc ls")
	}
	var so, se bytes.Buffer
	w := newWriter(&so, &se)
	w.output = "json"
	// `--all` is a GLOBAL, not a per-command flag: run.go gates the offset walk
	// on `g.all`. Passing it in the tail instead would be parsed as the
	// manifest's own `all` flag and sent to the server as a query param, and the
	// command would quietly read ONE page — which is how the first draft of this
	// file measured the single-page passthrough while believing it measured the
	// stitch.
	if code := runCommand(w, globals{output: "json", all: true}, h.ctx, h.m, *cmd, []string{"tag"}); code != exitOK {
		h.t.Fatalf("doc ls tag --all exited %d\nstdout=%s\nstderr=%s", code, so.String(), se.String())
	}
	return so.String()
}

// createWithTag runs the REAL `bp task create --publish` carrying one weighted
// tag named `tag`.
func (h *tagRoundTripHarness) createWithTag(tag string) (int, string, string) {
	h.t.Helper()
	var so, se bytes.Buffer
	w := &writer{stdout: &so, stderr: &se, output: "json"}
	entry := map[string]any{
		"tag":       tag,
		"strength":  80,
		"rationale": "the round trip: this name came straight off the listing's id key",
	}
	raw, err := json.Marshal([]any{entry})
	if err != nil {
		h.t.Fatalf("marshal tags: %v", err)
	}
	code := runTaskCreate(w, globals{yes: true, output: "json"}, h.ctx, []string{
		"a row whose only tag came off the tag listing",
		"--description", "the round trip from the listing's id key into a weighted tags entry",
		"--set", "tags:=" + string(raw),
		"--publish",
	})
	return code, so.String(), se.String()
}

// firstRowKey reads .documents[0].<key> out of a listing's stdout. The second
// return is false when the key is absent or null — which is EXACTLY the state
// this row was filed about, so the test must be able to see it rather than
// crash on it.
func firstRowKey(t *testing.T, listing, key string) (string, bool) {
	t.Helper()
	var env struct {
		Documents []map[string]json.RawMessage `json:"documents"`
	}
	if err := json.Unmarshal([]byte(listing), &env); err != nil {
		t.Fatalf("listing is not JSON: %v\n%s", err, listing)
	}
	if len(env.Documents) == 0 {
		t.Fatalf("listing carried no rows — nothing to round-trip:\n%s", listing)
	}
	raw, present := env.Documents[0][key]
	if !present {
		return "", false
	}
	var s string
	if err := json.Unmarshal(raw, &s); err != nil || s == "" {
		return "", false
	}
	return s, true
}

// TestTagListingIDKeyRoundTripsIntoPublish is the criterion's own sentence as a
// test: FIRST row → its id key → a tags entry → an ACCEPTED create.
//
// RED WITHOUT THE FIX: `.documents[0].doc_id` is absent, firstRowKey returns
// false and the test fails at the first assertion, naming the keys the row
// actually carried.
func TestTagListingIDKeyRoundTripsIntoPublish(t *testing.T) {
	h := newTagRoundTripHarness(t)
	listing := h.listTags()

	tag, ok := firstRowKey(t, listing, docListingRowIDKey)
	if !ok {
		t.Fatalf("the FIRST row of `bp doc ls tag --all -o json` carries no usable .%s — "+
			"a jq path keyed on it resolves to null on every row, which reads exactly like an EMPTY REGISTRY.\nlisting=%s",
			docListingRowIDKey, listing)
	}

	// The mirror must carry the SAME string the row's `_id` does — not a
	// re-derived, re-cased or re-slugged one. A key that answers with a
	// DIFFERENT string would be a new way to be refused.
	if id, idOK := firstRowKey(t, listing, "_id"); !idOK || id != tag {
		t.Fatalf(".%s = %q but ._id = %q (ok=%v) — the mirror must be verbatim", docListingRowIDKey, tag, id, idOK)
	}

	code, stdout, stderr := h.createWithTag(tag)
	t.Logf("tag=%q exit=%d stdout=%s stderr=%s", tag, code, stdout, stderr)
	if code != exitOK {
		t.Fatalf("`bp task create --publish` with the tag read off the listing exited %d, want %d — "+
			"the listing's own id key must be a value this command ACCEPTS.\nstdout=%s\nstderr=%s",
			code, exitOK, stdout, stderr)
	}
	if strings.Contains(stdout, "unknown_tag") || strings.Contains(stderr, "unknown_tag") {
		t.Fatalf("refused unknown_tag on a tag taken from the registry listing itself:\nstdout=%s\nstderr=%s", stdout, stderr)
	}
	// A create that never reached the wire would pass every assertion above.
	if len(h.mutation) == 0 {
		t.Fatal("no mutation reached the fake instance — the accepted path was never exercised")
	}
	if !strings.Contains(h.mutation[0], `"`+tag+`"`) {
		t.Fatalf("the create body does not carry the tag read off the listing (%q): %s", tag, h.mutation[0])
	}
}

// TestTagListingRoundTripPositiveControl is the POSITIVE CONTROL for the test
// above: the same harness, the same command, one deliberately bogus tag. If
// this does NOT refuse `unknown_tag`, the green above is a test that never
// reached its subject — the wall would be accepting everything.
func TestTagListingRoundTripPositiveControl(t *testing.T) {
	h := newTagRoundTripHarness(t)

	code, stdout, stderr := h.createWithTag("no-such-tag-zz")
	t.Logf("exit=%d stdout=%s stderr=%s", code, stdout, stderr)
	if code == exitOK {
		t.Fatal("a tag that is NOT in the served registry was ACCEPTED — the wall is inert and the round-trip green means nothing")
	}
	if !strings.Contains(stdout, "unknown_tag") && !strings.Contains(stderr, "unknown_tag") {
		t.Fatalf("a bogus tag was refused, but not as unknown_tag:\nstdout=%s\nstderr=%s", stdout, stderr)
	}
	if len(h.mutation) != 0 {
		t.Fatalf("the wall wrote %d mutation(s) before refusing — it must refuse BEFORE writing anything", len(h.mutation))
	}
}

// TestTagListingTitleIsNotTheAcceptedString is the other half of the filing's
// own claim, tested rather than assumed. The row that filed this defect
// prescribed `.title` as the usable key. On the fixture — which mirrors the
// live shape — the first row's title is "Epic Wave Paper", and feeding THAT
// into a tags entry is refused. So `title` cannot be the key the refusal points
// a caller at, and `_id`/`doc_id` is.
func TestTagListingTitleIsNotTheAcceptedString(t *testing.T) {
	h := newTagRoundTripHarness(t)
	listing := h.listTags()

	title, ok := firstRowKey(t, listing, "title")
	if !ok {
		t.Fatalf("fixture's first row has no title — this control needs one:\n%s", listing)
	}
	code, stdout, stderr := h.createWithTag(title)
	t.Logf("title=%q exit=%d stdout=%s stderr=%s", title, code, stdout, stderr)
	if code == exitOK {
		t.Fatalf("`.title` = %q was ACCEPTED — if that ever becomes true, this test and the refusal's wording both need revisiting", title)
	}
	if len(h.mutation) != 0 {
		t.Fatalf("refusing on a prose title still wrote %d mutation(s)", len(h.mutation))
	}
}

// TestTagListingDeclaresItsRowCount pins criterion 1's SECOND half: a listing
// whose rows a caller's jq path missed entirely must still say how many rows it
// held, so "I read the wrong key" is distinguishable from "the registry is
// empty".
func TestTagListingDeclaresItsRowCount(t *testing.T) {
	// The PAGED registry on purpose — see tagRegistryPagedRows. On a
	// single-page read the server's own `count` rides through verbatim and this
	// test would measure nothing.
	rows := tagRegistryPagedRows()
	h := newTagRoundTripHarnessRows(t, rows)
	listing := h.listTags()

	var env struct {
		Count     *int              `json:"count"`
		Documents []json.RawMessage `json:"documents"`
	}
	if err := json.Unmarshal([]byte(listing), &env); err != nil {
		t.Fatalf("listing is not JSON: %v", err)
	}
	if env.Count == nil {
		t.Fatalf("the listing declares no row count — a jq path that answers nothing is then indistinguishable from an empty registry:\n%s", listing)
	}
	if *env.Count != len(env.Documents) {
		t.Fatalf("count = %d but the listing carried %d rows", *env.Count, len(env.Documents))
	}
	// The stitch must have walked the WHOLE registry, not one page of it —
	// otherwise the count is honest about a listing that is itself short.
	if *env.Count != len(rows) {
		t.Fatalf("count = %d but the served registry holds %d tags — the --all walk did not stitch every page", *env.Count, len(rows))
	}
	// And the mirror must survive the stitch: the re-wrap is a DIFFERENT render
	// path from the single-page passthrough.
	if tag, ok := firstRowKey(t, listing, docListingRowIDKey); !ok {
		t.Fatalf("the stitched --all listing carries no .%s on its first row", docListingRowIDKey)
	} else if tag != "epic-wave-paper" {
		t.Fatalf("stitched first row .%s = %q, want the registry's first row", docListingRowIDKey, tag)
	}
}

// TestUnknownTagRefusalNamesTheListingAndTheKey pins criterion 1's chosen half.
// The refusal a caller actually hits must name BOTH the command that lists the
// vocabulary AND the key to read off it — naming the command alone is what sent
// the filing agent to `.doc_id`, read null on every row, and concluded the
// registry was empty.
func TestUnknownTagRefusalNamesTheListingAndTheKey(t *testing.T) {
	h := newTagRoundTripHarness(t)
	code, stdout, stderr := h.createWithTag("no-such-tag-zz")
	if code == exitOK {
		t.Fatal("the bogus tag was accepted — no refusal to inspect")
	}
	all := stdout + "\n" + stderr
	for _, want := range []string{tagRegistryCommand, docListingRowIDKey, ".title"} {
		if !strings.Contains(all, want) {
			t.Errorf("the unknown_tag refusal never mentions %q — a caller cannot act on it:\n%s", want, all)
		}
	}
}

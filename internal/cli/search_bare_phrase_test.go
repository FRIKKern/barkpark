package cli

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// liveSearchVerbs is `search` EXACTLY as the live server declares it — all
// thirteen verbs, with each one's real writes/args shape (read off
// GET /v1/capabilities on 2026-09-03). The fixtures the previous wave used
// declared one or three verbs, which is why the defect stayed invisible.
const liveSearchVerbs = `
    {"id":"search.query","noun":"search","verb":"query","summary":"Full-text search documents in a dataset.","http":{"method":"GET","path_template":"/v1/search"},"auth_tier":"none","args":[{"name":"q","required":true,"type":"string","summary":"q"}],"flags":[{"name":"type","type":"string","summary":"one type"}],"writes":false,"batch":false,"paginated":true,"dry_run":false,"default_output":"table"},
    {"id":"search.suggestions","noun":"search","verb":"suggestions","summary":"s","http":{"method":"GET","path_template":"/v1/search/suggestions"},"auth_tier":"none","args":[{"name":"q","required":false,"type":"string","summary":"q"}],"flags":[],"writes":false,"batch":false,"paginated":false,"dry_run":false,"default_output":"table"},
    {"id":"search.interaction","noun":"search","verb":"interaction","summary":"i","http":{"method":"POST","path_template":"/v1/search/interaction"},"auth_tier":"none","args":[{"name":"queryEventId","required":true,"type":"string","summary":"a"},{"name":"objectId","required":true,"type":"string","summary":"b"}],"flags":[],"writes":true,"batch":false,"paginated":false,"dry_run":false,"default_output":"table"},
    {"id":"search.correction","noun":"search","verb":"correction","summary":"c","http":{"method":"POST","path_template":"/v1/search/correction"},"auth_tier":"none","args":[{"name":"from","required":true,"type":"string","summary":"a"},{"name":"to","required":true,"type":"string","summary":"b"}],"flags":[],"writes":true,"batch":false,"paginated":false,"dry_run":false,"default_output":"table"},
    {"id":"search.reindex","noun":"search","verb":"reindex","summary":"r","http":{"method":"POST","path_template":"/v1/search/reindex"},"auth_tier":"none","args":[],"flags":[],"writes":true,"batch":false,"paginated":false,"dry_run":false,"default_output":"table"},
    {"id":"search.settings","noun":"search","verb":"settings","summary":"st","http":{"method":"GET","path_template":"/v1/search/settings"},"auth_tier":"none","args":[],"flags":[],"writes":false,"batch":false,"paginated":false,"dry_run":false,"default_output":"table"},
    {"id":"search.update-settings","noun":"search","verb":"update-settings","summary":"us","http":{"method":"PATCH","path_template":"/v1/search/settings"},"auth_tier":"none","args":[],"flags":[],"writes":true,"batch":false,"paginated":false,"dry_run":false,"default_output":"table"},
    {"id":"search.insights","noun":"search","verb":"insights","summary":"in","http":{"method":"GET","path_template":"/v1/search/insights"},"auth_tier":"none","args":[],"flags":[],"writes":false,"batch":false,"paginated":false,"dry_run":false,"default_output":"table"},
    {"id":"search.synonyms","noun":"search","verb":"synonyms","summary":"sy","http":{"method":"GET","path_template":"/v1/search/synonyms"},"auth_tier":"none","args":[],"flags":[],"writes":false,"batch":false,"paginated":false,"dry_run":false,"default_output":"table"},
    {"id":"search.synonym-preview","noun":"search","verb":"synonym-preview","summary":"sp","http":{"method":"GET","path_template":"/v1/search/synonym-preview"},"auth_tier":"none","args":[{"name":"q","required":true,"type":"string","summary":"q"}],"flags":[],"writes":false,"batch":false,"paginated":false,"dry_run":false,"default_output":"table"},
    {"id":"search.create-synonym","noun":"search","verb":"create-synonym","summary":"cs","http":{"method":"POST","path_template":"/v1/search/synonyms"},"auth_tier":"none","args":[{"name":"from","required":true,"type":"string","summary":"a"},{"name":"to","required":true,"type":"string","summary":"b"}],"flags":[],"writes":true,"batch":false,"paginated":false,"dry_run":false,"default_output":"table"},
    {"id":"search.promote-synonym","noun":"search","verb":"promote-synonym","summary":"ps","http":{"method":"POST","path_template":"/v1/search/synonyms/promote"},"auth_tier":"none","args":[{"name":"from","required":true,"type":"string","summary":"a"},{"name":"to","required":true,"type":"string","summary":"b"}],"flags":[],"writes":true,"batch":false,"paginated":false,"dry_run":false,"default_output":"table"},
    {"id":"search.delete-synonym","noun":"search","verb":"delete-synonym","summary":"ds","http":{"method":"DELETE","path_template":"/v1/search/synonyms/:id"},"auth_tier":"none","args":[{"name":"id","required":true,"type":"string","summary":"id"}],"flags":[],"writes":true,"batch":false,"paginated":false,"dry_run":false,"default_output":"table"}`

// liveSearchVerbNames is the same list as bare names — the "every real verb
// still dispatches" half of the contract is asserted against it.
var liveSearchVerbNames = []string{
	"query", "suggestions", "interaction", "correction", "reindex", "settings",
	"update-settings", "insights", "synonyms", "synonym-preview",
	"create-synonym", "promote-synonym", "delete-synonym",
}

func liveSearchManifest(base string) string {
	return `{
  "manifest_version": "1",
  "server": {"name": "t", "version": "0", "base_url": "` + base + `"},
  "auth_tier": "none",
  "generated_at": "now",
  "etag": "e",
  "nouns": [{"name": "search", "summary": "Full-text search over documents."}],
  "commands": [` + liveSearchVerbs + `
  ]
}`
}

// writeLiveSearchManifest points the CLI at the thirteen-verb `search` noun and
// at base (a closed port, or an httptest server when the round trip matters).
func writeLiveSearchManifest(t *testing.T, base string) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "live-search-manifest.json")
	if err := os.WriteFile(p, []byte(liveSearchManifest(base)), 0o600); err != nil {
		t.Fatalf("write fixture: %v", err)
	}
	return p
}

// searchStub is a Barkpark-shaped server that answers any GET with one hit, so
// the re-dispatched `query` can be observed EXITING 0 with results — the half a
// closed port cannot show. It records the query string it was asked for.
func searchStub(t *testing.T) (*httptest.Server, *string) {
	t.Helper()
	last := new(string)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		*last = r.URL.RequestURI()
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{
			"ok":        true,
			"total":     1,
			"documents": []map[string]any{{"_id": "doc-1", "_type": "task", "title": "a hit"}},
		})
	}))
	t.Cleanup(srv.Close)
	return srv, last
}

// --- criterion 1: the reproduction ------------------------------------------

// TestSearchBarePhraseNoLongerNamesThePhraseAsABadVerb pins the EXACT defect
// shape the row reports, in the negative: `bp search "fork" --type task` must
// not come back as a usage refusal that quotes the user's phrase as a verb.
//
// MUTATION PROOF: revert the searchPhraseVerb arm in cli.go and this test reds
// with the literal reported line — `no verb "fork" under `+"`barkpark search`"+`
// — at exit 2 (exitUsage), which is precisely the envelope that carried no
// `documents` key and read as NOTHING FOUND.
func TestSearchBarePhraseNoLongerNamesThePhraseAsABadVerb(t *testing.T) {
	srv, _ := searchStub(t)
	t.Setenv("BARKPARK_MANIFEST", writeLiveSearchManifest(t, srv.URL))
	t.Setenv("BARKPARK_API_URL", srv.URL)

	out, code := captureExecuteCode(t, []string{"search", "fork", "--type", "task", "-o", "json"})

	if strings.Contains(out, `no verb "fork"`) || strings.Contains(out, `no verb \"fork\"`) {
		t.Errorf("the user's PHRASE is still reported as a bad verb; got:\n%s", out)
	}
	if strings.Contains(out, `"code":"usage"`) || strings.Contains(out, `"code": "usage"`) {
		t.Errorf("bare search phrase still returns a usage error envelope; got:\n%s", out)
	}
	if code != exitOK {
		t.Errorf("exit = %d, want %d (exitOK) — a non-zero exit is the shape callers read as nothing found; got:\n%s", code, exitOK, out)
	}
}

// --- criterion 2: the fix, both halves --------------------------------------

// TestSearchBarePhraseRunsTheQueryVerb is the first half: the phrase is
// searched for, and the request that reaches the server is the `query` one
// carrying the phrase (not an empty search, and not a different verb's path).
func TestSearchBarePhraseRunsTheQueryVerb(t *testing.T) {
	srv, last := searchStub(t)
	t.Setenv("BARKPARK_MANIFEST", writeLiveSearchManifest(t, srv.URL))
	t.Setenv("BARKPARK_API_URL", srv.URL)

	out, code := captureExecuteCode(t, []string{"search", "PDS crown proof", "-o", "json"})

	if code != exitOK {
		t.Fatalf("exit = %d, want %d; got:\n%s", code, exitOK, out)
	}
	if !strings.HasPrefix(*last, "/v1/search") {
		t.Errorf("re-dispatched to %q, want the `query` verb's /v1/search path", *last)
	}
	if !strings.Contains(*last, "PDS") || !strings.Contains(*last, "proof") {
		t.Errorf("the phrase never reached the server; request was %q", *last)
	}
	if !strings.Contains(out, "doc-1") {
		t.Errorf("search results not rendered; got:\n%s", out)
	}
	// The rewrite is never silent.
	if !strings.Contains(out, "note:") || !strings.Contains(out, "search query") {
		t.Errorf("stderr note missing — the rewrite must say what it ran; got:\n%s", out)
	}
}

// TestEveryRealSearchVerbStillDispatches is the second half, and the one that
// makes the fix narrow: NONE of the thirteen declared verb names may be
// swallowed as a search phrase. Each is driven through Execute; the proof is
// that no invocation takes the phrase path (no re-dispatch note, no "searched
// … for the phrase" line). Verbs missing required args still fail on THEIR OWN
// usage — that is the verb dispatching, which is what is under test.
func TestEveryRealSearchVerbStillDispatches(t *testing.T) {
	srv, last := searchStub(t)
	for _, verb := range liveSearchVerbNames {
		t.Run(verb, func(t *testing.T) {
			t.Setenv("BARKPARK_MANIFEST", writeLiveSearchManifest(t, srv.URL))
			t.Setenv("BARKPARK_API_URL", srv.URL)
			*last = ""

			out, _ := captureExecuteCode(t, []string{"search", verb})

			if strings.Contains(out, "as a search phrase") || strings.Contains(out, "for the phrase") {
				t.Errorf("verb %q was swallowed as a search phrase; got:\n%s", verb, out)
			}
			if strings.Contains(out, "no verb") {
				t.Errorf("verb %q was rejected as an unknown verb; got:\n%s", verb, out)
			}
		})
	}
}

// --- criterion 3: ambiguity is not silent -----------------------------------

// TestSearchNearTypoVerbSearchesAndNamesTheVerb pins the ambiguous case the row
// names by example. `sugestions` is one bareword AND one edit away from the real
// verb `suggestions`: refusing manufactured the false "nothing found", so the
// CLI searches — and says so, naming the verb the caller may have meant, on
// stderr, while still exiting 0 with the result.
func TestSearchNearTypoVerbSearchesAndNamesTheVerb(t *testing.T) {
	srv, last := searchStub(t)
	t.Setenv("BARKPARK_MANIFEST", writeLiveSearchManifest(t, srv.URL))
	t.Setenv("BARKPARK_API_URL", srv.URL)

	out, code := captureExecuteCode(t, []string{"search", "sugestions"})

	if code != exitOK {
		t.Errorf("exit = %d, want %d (the search still runs); got:\n%s", code, exitOK, out)
	}
	if !strings.Contains(*last, "sugestions") {
		t.Errorf("the bareword was not searched for; request was %q", *last)
	}
	if !strings.Contains(out, `searched `+"`search query`"+` for the phrase "sugestions"`) {
		t.Errorf("stderr does not say WHAT it searched for; got:\n%s", out)
	}
	if !strings.Contains(out, "barkpark search suggestions") {
		t.Errorf("stderr does not name the verb the caller may have meant; got:\n%s", out)
	}
}

// TestSearchPhraseWithSpacesGetsNoTypoNote is the negative control for the note
// above: a multi-word phrase cannot be a mistyped verb, so it must NOT be told
// it may have meant one.
func TestSearchPhraseWithSpacesGetsNoTypoNote(t *testing.T) {
	srv, _ := searchStub(t)
	t.Setenv("BARKPARK_MANIFEST", writeLiveSearchManifest(t, srv.URL))
	t.Setenv("BARKPARK_API_URL", srv.URL)

	out, _ := captureExecuteCode(t, []string{"search", "PDS crown proof"})
	if strings.Contains(out, "if you meant the VERB") {
		t.Errorf("a multi-word phrase was offered a verb correction; got:\n%s", out)
	}
}

// --- the predicate itself ---------------------------------------------------

// TestSearchPhraseVerbIsSearchOnlyAndManifestChecked keeps the inference from
// widening. It is the unit guard behind the design note in usage.go: the rule
// fires for `search` only, and only while the manifest still declares a
// non-writing `query` taking exactly one required string arg.
func TestSearchPhraseVerbIsSearchOnlyAndManifestChecked(t *testing.T) {
	_, tree := loadTreeFrom(t, writeLiveSearchManifest(t, "http://127.0.0.1:1"))
	search, ok := lookupNoun(tree, "search")
	if !ok {
		t.Fatal("fixture has no `search` noun")
	}
	if q, fired := searchPhraseVerb(search, "search", "fork"); !fired || q.Verb != "query" {
		t.Errorf("searchPhraseVerb(search, fork) = %v,%v; want query,true", q, fired)
	}
	// Flag-shaped and empty tokens are never phrases.
	for _, typed := range []string{"-o", "--json", ""} {
		if _, fired := searchPhraseVerb(search, "search", typed); fired {
			t.Errorf("searchPhraseVerb fired on %q", typed)
		}
	}
	// ANY other noun — even one shaped exactly like search — is refused. This is
	// the guard that keeps `bp doc "text"` and `bp task "text"` on the precise
	// error path instead of silently reading through some verb.
	if _, fired := searchPhraseVerb(search, "doc", "fork"); fired {
		t.Error("the phrase inference fired for a noun other than `search`")
	}
	// A manifest that stops declaring the free-text `query` loses the inference.
	noQuery := &manifest.TreeNoun{Name: "search", Verbs: []*manifest.Command{
		{Noun: "search", Verb: "insights"},
	}}
	if _, fired := searchPhraseVerb(noQuery, "search", "fork"); fired {
		t.Error("inference fired with no `query` verb declared")
	}
	writingQuery := &manifest.TreeNoun{Name: "search", Verbs: []*manifest.Command{
		{Noun: "search", Verb: "query", Writes: true, Args: []manifest.Arg{{Name: "q", Required: true, Type: "string"}}},
	}}
	if _, fired := searchPhraseVerb(writingQuery, "search", "fork"); fired {
		t.Error("inference fired for a WRITING query verb")
	}
	twoArgs := &manifest.TreeNoun{Name: "search", Verbs: []*manifest.Command{
		{Noun: "search", Verb: "query", Args: []manifest.Arg{
			{Name: "q", Required: true, Type: "string"},
			{Name: "b", Required: true, Type: "string"},
		}},
	}}
	if _, fired := searchPhraseVerb(twoArgs, "search", "fork"); fired {
		t.Error("inference fired for a query verb taking two required args")
	}
}

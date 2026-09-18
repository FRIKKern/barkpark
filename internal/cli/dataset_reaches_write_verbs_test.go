package cli

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// bp-task-verbs-500-on-cross-dataset-duplicate-slugs — the remedy must reach the
// wire on the WRITE verbs, not only on `task get`.
//
// THE GAP THIS CLOSES, and it is the row's own title. The row is filed on
// "`bp task get/claim/close` 500 on any doc_id that exists in two datasets", and
// its description is explicit that the eleven twins are "unreachable through the
// entire `bp task` verb surface — not just `get`, but `claim`, `close` and
// `stage` too". The server now answers those ids with a 409 `ambiguous_dataset`
// whose remedy is to name the dataset, and `-d` is the CLI dialect of that
// remedy. So for each of these verbs the remedy is the ONLY way to address a
// twin, and a verb whose `-d` does not reach the wire leaves its twins exactly
// as unwritable as the original 500 did.
//
// dataset_reaches_path_routed_route_test.go proved this for ONE command,
// `task.get`, on GET /v1/tasks/:doc_id. Its harness hard-codes that single
// manifest entry, so it measures nothing about the ten sibling verbs that
// address a row by the same placeholder and then WRITE to it. Measured
// 2026-09-17 against guerrilla with bp built from origin/main 174f97664:
//
//	bp task claim akbr-feedback-2026-08-epic w --dry-run
//	  -> POST /v1/tasks/akbr-feedback-2026-08-epic/claim
//	bp task claim akbr-feedback-2026-08-epic w -d production --dry-run
//	  -> POST /v1/tasks/akbr-feedback-2026-08-epic/claim?dataset=production
//
// That is the behaviour the eleven twins depend on, and nothing pinned it.
//
// WHY THE EXISTING ARM CANNOT CATCH THIS. The forward lives in applyQuery, which
// is shared, so a mutation that drops it wholesale reds the get test too. The
// mutation this file exists for is the one that SPLITS reads from writes:
//
//	if cmd.Writes { continue }   // in applyQuery's globalQueryForwards loop
//
// That compiles, leaves `bp task get -d` working, leaves the get arm GREEN, and
// silently strips `-d` from claim/close/stamp/stage/pulse/release — re-breaking
// every twin for every verb that changes them. Verified: with that mutation in
// place the tests below fail and
// TestDeclaredGlobalRidesAPathTemplatedRoute passes.
//
// The arg schemas below are deliberately trimmed to `doc_id` alone. The
// mechanism under test is the query forward and the placeholder fill on a
// path-templated WRITE command; a faithful copy of each verb's full arg list
// would couple this file to schema churn it is not measuring.

// writeVerbManifestJSON is one :doc_id-routed WRITE command with a
// %DATASETFLAG% hole, so the declared and undeclared arms differ in EXACTLY one
// thing. %ID% / %VERB% / %PATH% carry the real command id and route.
const writeVerbManifestJSON = `{
  "manifest_version": "1",
  "etag": "test",
  "server": {"name": "test", "base_url": "http://replaced"},
  "nouns": [{"name": "task", "summary": "Tasks."}],
  "commands": [
    {"id":"%ID%","noun":"task","verb":"%VERB%","summary":"Write to one task.",
     "http":{"method":"POST","path_template":"%PATH%"},
     "auth_tier":"write",
     "args":[{"name":"doc_id","type":"string","required":true,"summary":"Task id."}],
     "flags":[%DATASETFLAG%],
     "writes":true,"batch":false,"paginated":false,"dry_run":true,
     "default_output":"json"}
  ]
}`

// writeVerbs are the :doc_id-addressing task verbs that MUTATE a row. Each one
// is a door the eleven twins can only be reached through by naming the dataset.
var writeVerbs = []struct {
	verb string
	path string
}{
	{"claim", "/v1/tasks/:doc_id/claim"},
	{"close", "/v1/tasks/:doc_id/close"},
	{"release", "/v1/tasks/:doc_id/release"},
	{"stamp", "/v1/tasks/:doc_id/stamp"},
	{"stage", "/v1/tasks/:doc_id/stage"},
	{"pulse", "/v1/tasks/:doc_id/pulse"},
	{"renew", "/v1/tasks/:doc_id/renew"},
	{"landed", "/v1/tasks/:doc_id/landed"},
	{"move", "/v1/tasks/:doc_id/move"},
}

type writeVerbHarness struct {
	t       *testing.T
	srv     *httptest.Server
	m       *manifest.Manifest
	ctx     manifest.Context
	verb    string
	queries []url.Values
	paths   []string
}

func newWriteVerbHarness(t *testing.T, verb, path string, declaresDataset bool) *writeVerbHarness {
	t.Helper()
	h := &writeVerbHarness{t: t, verb: verb}
	h.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h.queries = append(h.queries, r.URL.Query())
		h.paths = append(h.paths, r.URL.Path)
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"ok":true,"doc":{"doc_id":"twin-id"}}`))
	}))
	t.Cleanup(h.srv.Close)

	flag := ""
	if declaresDataset {
		flag = getDatasetFlagJSON
	}
	body := strings.Replace(writeVerbManifestJSON, "%DATASETFLAG%", flag, 1)
	body = strings.Replace(body, "%ID%", "task."+verb, 1)
	body = strings.Replace(body, "%VERB%", verb, 1)
	body = strings.Replace(body, "%PATH%", path, 1)
	body = strings.Replace(body, "http://replaced", h.srv.URL, 1)
	m, err := manifest.Parse([]byte(body))
	if err != nil {
		t.Fatalf("parse fixture manifest for task.%s: %v", verb, err)
	}
	h.m = m
	h.ctx = manifest.Context{
		Server:    h.srv.URL,
		Token:     "tok",
		Workspace: "acme",
		Project:   "site",
		Dataset:   "production",
	}
	return h
}

// run drives the real runCommand, so an edit that moves or bypasses the forward
// reds this rather than a hand-rolled call to applyQuery.
func (h *writeVerbHarness) run(g globals, tail ...string) (code int, stdout, stderr string) {
	h.t.Helper()
	cmd, ok := h.m.Tree().Lookup("task", h.verb)
	if !ok {
		h.t.Fatalf("fixture manifest has no task %s", h.verb)
	}
	var so, se bytes.Buffer
	w := newWriter(&so, &se)
	w.applyGlobals(g)
	code = runCommand(w, g, h.ctx, h.m, *cmd, tail)
	return code, so.String(), se.String()
}

func (h *writeVerbHarness) last() (url.Values, string) {
	h.t.Helper()
	if len(h.queries) == 0 {
		h.t.Fatalf("task %s sent no request at all (paths seen: %v)", h.verb, h.paths)
	}
	return h.queries[len(h.queries)-1], h.paths[len(h.paths)-1]
}

// ARM (a). THE REMEDY ON A WRITE DOOR: the manifest declares `dataset` on a
// :doc_id-routed WRITE command, the operator types -d production, and the stub
// must SEE dataset=production — with the placeholder still carrying the id.
//
// This is the arm that reds on `if cmd.Writes { continue }`.
func TestDatasetReachesTheWireOnEveryDocIDWriteVerb(t *testing.T) {
	for _, wv := range writeVerbs {
		t.Run(wv.verb, func(t *testing.T) {
			h := newWriteVerbHarness(t, wv.verb, wv.path, true)
			code, _, stderr := h.run(
				globals{dataset: "production", datasetSet: true, output: "json", yes: true},
				"twin-id",
			)
			if code != 0 {
				t.Fatalf("task %s exited %d, stderr=%q", wv.verb, code, stderr)
			}
			q, path := h.last()
			if got := q.Get("dataset"); got != "production" {
				t.Fatalf("task %s: stub received dataset=%q on %s, want %q (whole query: %q) — "+
					"the remedy the ambiguous_dataset refusal names does not reach the wire on a WRITE verb, "+
					"so the eleven cross-dataset twins stay unwritable through this door",
					wv.verb, got, wv.path, "production", q.Encode())
			}
			// The other half: the placeholder is still filled from the positional
			// arg, so the forward did not land in the PATH and the fill did not
			// consume it.
			wantPath := strings.Replace(wv.path, ":doc_id", "twin-id", 1)
			if path != wantPath {
				t.Fatalf("task %s: stub saw path %q, want %q — the dataset reached the query "+
					"but the :doc_id placeholder no longer carries the id", wv.verb, path, wantPath)
			}
		})
	}
}

// THE PAIRED ARM — the one that must stay QUIET. Same routes, same typed flag,
// the manifest simply does not declare `dataset` on these commands. Without it
// the arm above passes just as well against a blanket "always forward on a
// path-templated write", which would narrow every :doc_id write by whatever
// dataset happened to be ambient — the silent-wrong-row family this row's
// server-side fix deliberately replaced with a refusal.
func TestUndeclaredDatasetStaysHomeOnEveryDocIDWriteVerb(t *testing.T) {
	for _, wv := range writeVerbs {
		t.Run(wv.verb, func(t *testing.T) {
			h := newWriteVerbHarness(t, wv.verb, wv.path, false)
			code, _, stderr := h.run(
				globals{dataset: "production", datasetSet: true, output: "json", yes: true},
				"twin-id",
			)
			if code != 0 {
				t.Fatalf("task %s exited %d, stderr=%q", wv.verb, code, stderr)
			}
			q, _ := h.last()
			if got := q.Get("dataset"); got != "" {
				t.Fatalf("task %s: stub received dataset=%q on %s though the command declares no "+
					"dataset flag (whole query: %q) — an undeclared global rode anyway, narrowing a "+
					"write the caller never asked to narrow", wv.verb, got, wv.path, q.Encode())
			}
		})
	}
}

// THE FIXTURE CONTROL. Every assertion above rests on the fixture actually being
// a path-templated WRITE command that declares the flag; if manifest.Parse ever
// stopped carrying `writes` or the dataset flag, both arms above would still
// pass — the declared arm by forwarding for some other reason, the undeclared
// arm vacuously. This pins the fixture itself, so a green above means the thing
// it claims to mean.
func TestWriteVerbFixtureIsAWritingPathRoutedCommandThatDeclaresDataset(t *testing.T) {
	for _, wv := range writeVerbs {
		t.Run(wv.verb, func(t *testing.T) {
			h := newWriteVerbHarness(t, wv.verb, wv.path, true)
			cmd, ok := h.m.Tree().Lookup("task", wv.verb)
			if !ok {
				t.Fatalf("fixture manifest has no task %s", wv.verb)
			}
			if !cmd.Writes {
				t.Fatalf("task %s fixture is not a WRITE command — the reads/writes split this "+
					"file exists to catch cannot be exercised by it", wv.verb)
			}
			if got := cmd.HTTP.PathTemplate; got != wv.path {
				t.Fatalf("task %s fixture route = %q, want %q", wv.verb, got, wv.path)
			}
			names := manifest.PlaceholderNames(cmd.HTTP.PathTemplate)
			if !names["doc_id"] {
				t.Fatalf("task %s fixture route %q has no :doc_id placeholder (placeholders: %v) — "+
					"this file is about the :doc_id family", wv.verb, wv.path, names)
			}
			if manifest.DatasetFateFor(*cmd) != manifest.DatasetCarried {
				t.Fatalf("task %s fixture does not CARRY dataset (fate=%v) though it declares the "+
					"flag — the declared arm would be measuring nothing",
					wv.verb, manifest.DatasetFateFor(*cmd))
			}

			// And the paired control's fixture must genuinely NOT carry it,
			// or TestUndeclaredDatasetStaysHomeOnEveryDocIDWriteVerb is vacuous.
			hu := newWriteVerbHarness(t, wv.verb, wv.path, false)
			ucmd, _ := hu.m.Tree().Lookup("task", wv.verb)
			if manifest.DatasetFateFor(*ucmd) == manifest.DatasetCarried {
				t.Fatalf("task %s undeclared fixture CARRIES dataset — the paired control is vacuous", wv.verb)
			}
		})
	}
}

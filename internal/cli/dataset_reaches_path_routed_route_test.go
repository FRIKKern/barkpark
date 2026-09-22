package cli

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// task-7cba0e62c3813fac — a declared global rides a route whose path carries a
// PLACEHOLDER, not only a flat one.
//
// THE GAP THIS CLOSES, measured rather than assumed. `bp task get <id>` on an id
// that lives in two datasets refuses with `ambiguous_dataset` and names the
// remedy; the remedy only works because `-d production` reaches
// GET /v1/tasks/:doc_id as `?dataset=`. The forward that puts it there
// (globalQueryForwards + the loop in applyQuery) was proven by
// global_flag_forward_test.go against /v1/tasks/ready — a route with NO
// placeholder. So the whole :doc_id family, which is exactly the family that
// can answer `ambiguous_dataset`, had no arm at all.
//
// It was not a theoretical hole. A mutation that skips the forward for any
// command with a path-located arg:
//
//	for _, a := range cmd.Args { if cmd.ArgLocation(a) == "path" { pathRouted = true } }
//	if pathRouted { continue }
//
// compiles, silently kills `-d` on every :doc_id route, and `go test
// ./internal/...` stayed GREEN. These tests red on it.
//
// Two things must hold at once on such a route, and only asserting both
// separates them: the dataset lands in the QUERY, and the placeholder is still
// filled from the positional arg. A forward that put `dataset` in the path, or
// a fill that consumed it, would each satisfy one assertion alone.

// getManifestJSON is task.get's slice of the live manifest with a %DATASETFLAG%
// hole, so the declared and undeclared arms differ in EXACTLY one thing. The
// route is the real one: /v1/tasks/:doc_id, placeholder included.
const getManifestJSON = `{
  "manifest_version": "1",
  "etag": "test",
  "server": {"name": "test", "base_url": "http://replaced"},
  "nouns": [{"name": "task", "summary": "Tasks."}],
  "commands": [
    {"id":"task.get","noun":"task","verb":"get","summary":"Fetch one task.",
     "http":{"method":"GET","path_template":"/v1/tasks/:doc_id"},
     "auth_tier":"read",
     "args":[{"name":"doc_id","type":"string","required":true,"summary":"Task id."}],
     "flags":[%DATASETFLAG%],
     "writes":false,"batch":false,"paginated":false,"dry_run":false,
     "default_output":"json"}
  ]
}`

const getDatasetFlagJSON = `{"name":"dataset","type":"string","summary":"Name the dataset holding this id."}`

// ambiguousBody is the shape the live door answers with when an id exists in
// two datasets — the refusal whose remedy this row is about.
const ambiguousBody = `{"ok":false,"error":{"code":"ambiguous_dataset",` +
	`"message":"task twin-id exists in more than one dataset in this workspace/project (aker-brygge, production); name one with ?dataset= — this door will not pick for you",` +
	`"details":{"datasets":["aker-brygge","production"],"doc_id":"twin-id"}}}`

type getHarness struct {
	t       *testing.T
	srv     *httptest.Server
	m       *manifest.Manifest
	ctx     manifest.Context
	queries []url.Values
	paths   []string
}

// newGetHarness stands up a fake instance on the :doc_id route. When refuse is
// true it answers the honest ambiguous_dataset refusal, so the control arm
// exercises the real refusal path and not a happy-path stand-in.
func newGetHarness(t *testing.T, declaresDataset, refuse bool) *getHarness {
	t.Helper()
	h := &getHarness{t: t}
	h.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h.queries = append(h.queries, r.URL.Query())
		h.paths = append(h.paths, r.URL.Path)
		w.Header().Set("Content-Type", "application/json")
		if refuse {
			w.WriteHeader(http.StatusConflict)
			_, _ = w.Write([]byte(ambiguousBody))
			return
		}
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"ok":true,"doc":{"doc_id":"twin-id"}}`))
	}))
	t.Cleanup(h.srv.Close)

	flag := ""
	if declaresDataset {
		flag = getDatasetFlagJSON
	}
	body := strings.Replace(getManifestJSON, "%DATASETFLAG%", flag, 1)
	body = strings.Replace(body, "http://replaced", h.srv.URL, 1)
	m, err := manifest.Parse([]byte(body))
	if err != nil {
		t.Fatalf("parse fixture manifest: %v", err)
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

// runGet drives the real runCommand, so an edit that moves or bypasses the
// forward reds this rather than a hand-rolled call to applyQuery.
func (h *getHarness) runGet(g globals, tail ...string) (code int, stdout, stderr string) {
	h.t.Helper()
	cmd, ok := h.m.Tree().Lookup("task", "get")
	if !ok {
		h.t.Fatal("fixture manifest has no task get")
	}
	var so, se bytes.Buffer
	w := newWriter(&so, &se)
	w.applyGlobals(g)
	code = runCommand(w, g, h.ctx, h.m, *cmd, tail)
	return code, so.String(), se.String()
}

func (h *getHarness) last() (url.Values, string) {
	h.t.Helper()
	if len(h.queries) == 0 {
		h.t.Fatalf("the CLI sent no request at all (paths seen: %v)", h.paths)
	}
	return h.queries[len(h.queries)-1], h.paths[len(h.paths)-1]
}

// ARM (a). THE REMEDY, end to end: the manifest declares `dataset` on a
// :doc_id-routed command, the operator types -d production, and the stub must
// SEE dataset=production — on the same route the refusal came from.
func TestDeclaredGlobalRidesAPathTemplatedRoute(t *testing.T) {
	h := newGetHarness(t, true, false)
	code, _, stderr := h.runGet(globals{dataset: "production", datasetSet: true, output: "json"}, "twin-id")
	if code != 0 {
		t.Fatalf("exit %d, stderr=%q", code, stderr)
	}
	q, path := h.last()
	if got := q.Get("dataset"); got != "production" {
		t.Fatalf("stub received dataset=%q on /v1/tasks/:doc_id, want %q (whole query: %q) — "+
			"the remedy the ambiguous_dataset refusal names does not reach the wire", got, "production", q.Encode())
	}
	// The other half: the placeholder is still filled from the positional arg,
	// so the forward did not land in the PATH and the fill did not eat it.
	if path != "/v1/tasks/twin-id" {
		t.Fatalf("stub saw path %q, want %q — the dataset reached the query but the :doc_id placeholder no longer carries the id", path, "/v1/tasks/twin-id")
	}
}

// THE PAIRED ARM. Same route, same typed flag — the manifest simply does not
// declare `dataset` here. Without it the test above passes just as well against
// a blanket "always forward on a path-templated route", which would narrow every
// :doc_id read by whatever dataset happened to be set.
func TestUndeclaredGlobalStaysHomeOnAPathTemplatedRoute(t *testing.T) {
	h := newGetHarness(t, false, false)
	code, _, stderr := h.runGet(globals{dataset: "production", datasetSet: true, output: "json"}, "twin-id")
	if code != 0 {
		t.Fatalf("exit %d, stderr=%q", code, stderr)
	}
	q, path := h.last()
	if q.Has("dataset") {
		t.Fatalf("stub received dataset=%q on a :doc_id command that does not declare it (whole query: %q)", q.Get("dataset"), q.Encode())
	}
	if path != "/v1/tasks/twin-id" {
		t.Fatalf("stub saw path %q, want %q", path, "/v1/tasks/twin-id")
	}
}

// ARM (b), THE POSITIVE CONTROL. A call with NO dataset typed must behave
// exactly as before: nothing on the wire, and the door's honest refusal comes
// back. A change that ALWAYS sent a dataset would pass arm (a) while silently
// re-introducing the picking behaviour the refusal deliberately replaced — this
// is the only arm that can tell those apart.
func TestPathTemplatedRouteWithoutATypedDatasetStillRefusesHonestly(t *testing.T) {
	h := newGetHarness(t, true, true)
	// ctx.Dataset is "production": an ambient dataset must not be forwarded
	// either, or the caller who typed nothing silently gets one dataset's answer.
	code, stdout, stderr := h.runGet(globals{output: "json"}, "twin-id")
	q, path := h.last()
	if q.Has("dataset") {
		t.Fatalf("a dataset rode a call that typed none: dataset=%q (whole query: %q) — "+
			"the CLI is picking for the caller, which is what the refusal replaced", q.Get("dataset"), q.Encode())
	}
	if path != "/v1/tasks/twin-id" {
		t.Fatalf("stub saw path %q, want %q", path, "/v1/tasks/twin-id")
	}
	if code == 0 {
		t.Fatalf("an ambiguous_dataset refusal exited 0 — stdout=%q stderr=%q", stdout, stderr)
	}
	if !strings.Contains(stdout+stderr, "ambiguous_dataset") {
		t.Fatalf("the honest refusal did not reach the operator; stdout=%q stderr=%q", stdout, stderr)
	}
}

// THE SAME CONTROL FOR AN UNAMBIGUOUS ID: a plain read on a :doc_id route with
// no dataset typed still succeeds. Without this the control above is satisfied
// by a build that broke the route outright.
func TestUnambiguousPathTemplatedReadNeedsNoDataset(t *testing.T) {
	h := newGetHarness(t, true, false)
	code, _, stderr := h.runGet(globals{output: "json"}, "twin-id")
	if code != 0 {
		t.Fatalf("a plain read on a :doc_id route exited %d, stderr=%q", code, stderr)
	}
	if q, _ := h.last(); q.Has("dataset") {
		t.Fatalf("dataset=%q rode an unambiguous read that typed none", q.Get("dataset"))
	}
}

// THE RULE, NOT THE VERB. Enumerated over the served roster rather than over a
// hand-written list of commands: for EVERY command in the checked-in live
// manifest whose path carries a placeholder and which DECLARES one of the
// globals in globalQueryForwards, the typed value must reach the query. A
// per-verb arm would leave the next placeholder-routed command silent, which is
// the same shape as the defect.
func TestEveryPlaceholderRoutedCommandForwardsItsDeclaredGlobals(t *testing.T) {
	const fixture = "../manifest/testdata/capabilities-guerrilla-2026-09-04.json"
	body, err := os.ReadFile(fixture)
	if err != nil {
		t.Fatalf("read %s: %v", fixture, err)
	}
	m, err := manifest.Parse(body)
	if err != nil {
		t.Fatalf("parse %s: %v", fixture, err)
	}

	typed := map[string]struct {
		g    globals
		want string
	}{
		"limit":   {globals{limit: 25, limitSet: true}, "25"},
		"offset":  {globals{offset: 200, offsetSet: true}, "200"},
		"dataset": {globals{dataset: "staging", datasetSet: true}, "staging"},
	}

	checked := 0
	for _, cmd := range m.Commands {
		// Placeholder-routed is read off the DECLARATION — a command has a
		// path-located arg — not off the spelling of the template.
		placeholderRouted := false
		for _, a := range cmd.Args {
			if cmd.ArgLocation(a) == "path" {
				placeholderRouted = true
			}
		}
		if !placeholderRouted {
			continue
		}
		for _, gf := range globalQueryForwards(globals{}) {
			if !commandDeclaresFlag(cmd, gf.name) {
				continue
			}
			tc, ok := typed[gf.name]
			if !ok {
				t.Fatalf("globalQueryForwards grew %q with no case here — add one, or the new global is untested on placeholder routes", gf.name)
			}
			checked++
			got := applyQuery("https://x.test"+cmd.HTTP.PathTemplate, tc.g, cmd, map[string][]string{}, map[string]string{})
			if q := queryOf(t, got); q.Get(gf.name) != tc.want {
				t.Errorf("%s.%s (%s) declares --%s but sent %q, want %q (url %q)",
					cmd.Noun, cmd.Verb, cmd.HTTP.PathTemplate, gf.name, q.Get(gf.name), tc.want, got)
			}
		}
	}

	// THE FLOOR. Without it this guard passes by enumerating nothing — the exact
	// vacuity a roster-driven test invites when the fixture drifts behind the
	// server. Measured on this fixture: 8 placeholder-routed commands declare
	// `dataset` and 11 declare `limit`, so the floor is comfortably clear of 0.
	if checked == 0 {
		t.Fatal("no placeholder-routed command in the fixture declares a forwarded global — this guard measured nothing; refresh the fixture")
	}
	t.Logf("checked %d (command, global) pairs on placeholder-routed commands", checked)
}

// A shape check on the refusal fixture itself: if the envelope this file feeds
// the control arm ever stops being an ambiguous_dataset refusal, the control
// stops measuring the thing it names.
func TestAmbiguousFixtureIsAnAmbiguousDatasetRefusal(t *testing.T) {
	var env struct {
		OK    bool `json:"ok"`
		Error struct {
			Code    string `json:"code"`
			Details struct {
				Datasets []string `json:"datasets"`
			} `json:"details"`
		} `json:"error"`
	}
	if err := json.Unmarshal([]byte(ambiguousBody), &env); err != nil {
		t.Fatalf("the control's refusal fixture is not JSON: %v", err)
	}
	if env.OK || env.Error.Code != "ambiguous_dataset" || len(env.Error.Details.Datasets) != 2 {
		t.Fatalf("the control's refusal fixture is no longer an ambiguous_dataset refusal naming two datasets: %+v", env)
	}
}

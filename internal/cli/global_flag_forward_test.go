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

// task-00ccc80aed2a6d49 — a GLOBAL value flag the command DECLARES is forwarded
// to the query; one the command does not declare is not.
//
// THE DEFECT, in its third instance in a day. -d/--dataset is a global flag:
// parseGlobals consumes it wherever it appears in argv, so `flags["dataset"]`
// is never populated and the manifest-driven flag loop in applyQuery cannot see
// it. Security taught /v1/tasks/ready to honour `?dataset=` and declared the
// flag on task.ready — and `bp task ready --dataset x` still sent nothing. The
// server answered across every dataset, at 200/rc=0, with no notice: the caller
// read an UNFILTERED page believing it was filtered, which is the worst shape a
// wrong answer can take. limit and offset had already walked into the identical
// trap on six commands.
//
// The fix is the table in globals.go (globalQueryForwards) plus one loop in
// applyQuery, so the rule is declaration-driven for EVERY global value flag
// rather than one hand-written pair of ifs per flag written after each incident.
//
// RED-before: with the loop in applyQuery unwired, TestGlobalDatasetForwarded*
// and the dataset rows of TestGlobalValueFlagsForwardOnlyWhereDeclared fail
// ("no dataset= in query"), and so do every limit/offset row — which is what
// makes those rows the control rather than decoration.

// readyManifestJSON is the task.ready slice of the live manifest, with a
// %DATASETFLAG% hole so the two arms differ in EXACTLY one thing: whether the
// command declares `dataset`. Route, args, auth tier and the other flags are
// identical, so a difference in what the stub receives can only come from the
// declaration.
const readyManifestJSON = `{
  "manifest_version": "1",
  "etag": "test",
  "server": {"name": "test", "base_url": "http://replaced"},
  "nouns": [{"name": "task", "summary": "Tasks."}],
  "commands": [
    {"id":"task.ready","noun":"task","verb":"ready","summary":"List claimable tasks.",
     "http":{"method":"GET","path_template":"/v1/tasks/ready"},
     "auth_tier":"read",
     "args":[],
     "flags":[{"name":"limit","type":"int","summary":"Max tasks to return.","default":50},
              {"name":"offset","type":"int","summary":"Ready-queue row offset.","default":0},
              {"name":"order","type":"string","summary":"Ordering."}%DATASETFLAG%],
     "writes":false,"batch":false,"paginated":false,"dry_run":false,
     "default_output":"table"}
  ]
}`

const readyDatasetFlagJSON = `,{"name":"dataset","type":"string","summary":"Narrow the ready queue to one dataset."}`

// readyHarness stands up a fake instance serving /v1/tasks/ready and records the
// query string of every request the CLI actually sends — the only way to tell
// "filtered" from "the server chose to answer that way".
type readyHarness struct {
	t     *testing.T
	srv   *httptest.Server
	m     *manifest.Manifest
	ctx   manifest.Context
	seen  []url.Values
	paths []string
}

func newReadyHarness(t *testing.T, declaresDataset bool) *readyHarness {
	t.Helper()
	h := &readyHarness{t: t}
	h.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h.seen = append(h.seen, r.URL.Query())
		h.paths = append(h.paths, r.URL.Path)
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"ok":true,"docs":[]}`))
	}))
	t.Cleanup(h.srv.Close)

	datasetFlag := ""
	if declaresDataset {
		datasetFlag = readyDatasetFlagJSON
	}
	body := strings.Replace(readyManifestJSON, "%DATASETFLAG%", datasetFlag, 1)
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

// runReady drives the real runCommand — the whole path, not applyQuery in
// isolation — so an edit that moves or bypasses the forward reds these tests.
func (h *readyHarness) runReady(g globals, tail ...string) (code int, stdout, stderr string) {
	h.t.Helper()
	cmd, ok := h.m.Tree().Lookup("task", "ready")
	if !ok {
		h.t.Fatal("fixture manifest has no task ready")
	}
	var so, se bytes.Buffer
	w := newWriter(&so, &se)
	w.applyGlobals(g)
	code = runCommand(w, g, h.ctx, h.m, *cmd, tail)
	return code, so.String(), se.String()
}

func (h *readyHarness) lastQuery() url.Values {
	h.t.Helper()
	if len(h.seen) == 0 {
		h.t.Fatalf("the CLI sent no request at all (paths seen: %v)", h.paths)
	}
	return h.seen[len(h.seen)-1]
}

// THE BUG, end to end: the manifest declares `dataset` on task.ready, the
// operator types --dataset x, and the stub must SEE dataset=x.
func TestGlobalDatasetForwardedWhenDeclared(t *testing.T) {
	h := newReadyHarness(t, true)
	code, _, stderr := h.runReady(globals{dataset: "x", datasetSet: true, output: "json"})
	if code != 0 {
		t.Fatalf("exit %d, stderr=%q", code, stderr)
	}
	q := h.lastQuery()
	if got := q.Get("dataset"); got != "x" {
		t.Fatalf("stub received dataset=%q, want %q (whole query: %q) — an unfiltered page read as a filtered one", got, "x", q.Encode())
	}
}

// THE PAIRED ARM. Same flag, same value, same route — the manifest simply does
// not declare `dataset` on this command, so nothing is sent. Without it the test
// above passes just as well against a blanket "always forward g.dataset", which
// would narrow every request by the AMBIENT dataset from config.json.
func TestGlobalDatasetNotForwardedWhenUndeclared(t *testing.T) {
	h := newReadyHarness(t, false)
	code, _, stderr := h.runReady(globals{dataset: "x", datasetSet: true, output: "json"})
	if code != 0 {
		t.Fatalf("exit %d, stderr=%q", code, stderr)
	}
	q := h.lastQuery()
	if q.Has("dataset") {
		t.Fatalf("stub received dataset=%q on a command that does not declare it (whole query: %q)", q.Get("dataset"), q.Encode())
	}
}

// An UNTYPED --dataset must send nothing even where the flag IS declared:
// g.dataset also carries the ambient dataset from ~/.config/barkpark/config.json
// / BARKPARK_DATASET, and forwarding that would silently narrow a request the
// caller never asked to narrow. datasetSet is the discriminator; this pins that
// the forward reads it and not the value.
func TestAmbientDatasetIsNotForwarded(t *testing.T) {
	h := newReadyHarness(t, true)
	code, _, stderr := h.runReady(globals{dataset: "production", output: "json"})
	if code != 0 {
		t.Fatalf("exit %d, stderr=%q", code, stderr)
	}
	if q := h.lastQuery(); q.Has("dataset") {
		t.Fatalf("ambient dataset leaked to the wire as dataset=%q (whole query: %q)", q.Get("dataset"), q.Encode())
	}
}

// TestGlobalValueFlagsForwardOnlyWhereDeclared is the general rule, enumerated
// over the globals table itself rather than over a list written out here: for
// EVERY entry of globalQueryForwards, the knob rides when the command declares
// the flag and stays home when it does not. A new global added to the table is
// covered the moment it is added; a global added to applyQuery WITHOUT the
// table is not — which is the point, because the table is now the only place a
// forward may be declared.
func TestGlobalValueFlagsForwardOnlyWhereDeclared(t *testing.T) {
	const base = "https://x.test/v1/tasks/ready"

	// One populated globals struct per flag name: the value the caller typed,
	// and the string it must appear as on the wire.
	typed := map[string]struct {
		g    globals
		want string
	}{
		"limit":   {globals{limit: 25, limitSet: true}, "25"},
		"offset":  {globals{offset: 200, offsetSet: true}, "200"},
		"dataset": {globals{dataset: "staging", datasetSet: true}, "staging"},
	}

	table := globalQueryForwards(globals{})
	if len(table) == 0 {
		t.Fatal("globalQueryForwards is empty — this guard measures nothing")
	}
	for _, gf := range table {
		tc, ok := typed[gf.name]
		if !ok {
			t.Fatalf("globalQueryForwards grew %q with no case here — add one, or the new global is forwarded untested", gf.name)
		}
		t.Run(gf.name+"/declared", func(t *testing.T) {
			cmd := manifest.Command{Noun: "task", Verb: "ready", Flags: []manifest.Flag{{Name: gf.name, Type: "string"}}}
			got := applyQuery(base, tc.g, cmd, map[string][]string{}, map[string]string{})
			q := queryOf(t, got)
			if q.Get(gf.name) != tc.want {
				t.Fatalf("--%s declared but sent %q, want %q (url %q)", gf.name, q.Get(gf.name), tc.want, got)
			}
		})
		t.Run(gf.name+"/undeclared", func(t *testing.T) {
			// A command declaring only the OTHER flags: proves the refusal is
			// per-name, not "this command forwards nothing".
			var others []manifest.Flag
			for _, o := range table {
				if o.name != gf.name {
					others = append(others, manifest.Flag{Name: o.name, Type: "string"})
				}
			}
			cmd := manifest.Command{Noun: "task", Verb: "ready", Flags: others}
			got := applyQuery(base, tc.g, cmd, map[string][]string{}, map[string]string{})
			if q := queryOf(t, got); q.Has(gf.name) {
				t.Fatalf("--%s undeclared but sent %q (url %q)", gf.name, q.Get(gf.name), got)
			}
		})
		t.Run(gf.name+"/unset", func(t *testing.T) {
			cmd := manifest.Command{Noun: "task", Verb: "ready", Flags: []manifest.Flag{{Name: gf.name, Type: "string"}}}
			got := applyQuery(base, globals{}, cmd, map[string][]string{}, map[string]string{})
			if q := queryOf(t, got); q.Has(gf.name) {
				t.Fatalf("--%s never typed but sent %q (url %q)", gf.name, q.Get(gf.name), got)
			}
		})
		t.Run(gf.name+"/paginated-without-declaration", func(t *testing.T) {
			// limit/offset ride a `paginated: true` command as protocol even
			// when it enumerates no flags; dataset does not — a route reads a
			// dataset only where it says it does.
			cmd := manifest.Command{Noun: "task", Verb: "ready", Paginated: true}
			got := applyQuery(base, tc.g, cmd, map[string][]string{}, map[string]string{})
			q := queryOf(t, got)
			if gf.paginatedProtocol {
				if q.Get(gf.name) != tc.want {
					t.Fatalf("paginated command dropped --%s: %q", gf.name, got)
				}
				return
			}
			if q.Has(gf.name) {
				t.Fatalf("--%s rode a paginated command that never declared it: %q", gf.name, got)
			}
		})
	}
}

// TestForwardedGlobalNeverDuplicatesTheQueryKey extends the limit/offset seam
// guard to every table entry. parseGlobals provably eats these flags before
// splitArgs runs, so `flags[name]` is unreachable from argv — but an MCP handler
// builds `flags` itself, and a duplicate scalar key hands Plug a decode-order
// coin-flip. The globals value wins and the declared-flag loop stands down.
func TestForwardedGlobalNeverDuplicatesTheQueryKey(t *testing.T) {
	cmd := manifest.Command{
		Noun: "task", Verb: "ready",
		Flags: []manifest.Flag{
			{Name: "limit", Type: "int"},
			{Name: "offset", Type: "int"},
			{Name: "dataset", Type: "string"},
		},
	}
	got := applyQuery(
		"https://x.test/v1/tasks/ready",
		globals{limit: 25, limitSet: true, offset: 5, offsetSet: true, dataset: "staging", datasetSet: true},
		cmd,
		map[string][]string{"limit": {"9"}, "offset": {"1"}, "dataset": {"other"}},
		map[string]string{},
	)
	q := queryOf(t, got)
	for name, want := range map[string]string{"limit": "25", "offset": "5", "dataset": "staging"} {
		if len(q[name]) != 1 {
			t.Fatalf("%s appears %d times in %q, want exactly 1", name, len(q[name]), got)
		}
		if q.Get(name) != want {
			t.Fatalf("%s=%q in %q, want %q (the globals value must win)", name, q.Get(name), got, want)
		}
	}
}

func queryOf(t *testing.T, rawURL string) url.Values {
	t.Helper()
	u, err := url.Parse(rawURL)
	if err != nil {
		t.Fatalf("parse %q: %v", rawURL, err)
	}
	return u.Query()
}

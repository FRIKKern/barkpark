package cli

// publish_cites_guard_test.go — RED WITHOUT publish_cites_guard.go, green with.
// Every test here drives the real runCommand against an httptest instance, so a
// future edit that moves or drops the two call sites in run.go reds these
// instead of passing on a bypassed helper (discard_draft_guard_test.go's rule).

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// publishManifestJSON is the three-verb slice of the LIVE manifest this
// advisory needs, copied field-for-field from what the server declares:
// doc.get + doc.publish (api/lib/barkpark/plugins/capabilities.ex) and task.get
// (api/lib/barkpark/plugins/tasks.ex — GET /v1/tasks/:doc_id, NO scoped
// prefix, which is why the lookups below land on a flat route while the
// document reads land under /w/acme/p/site).
const publishManifestJSON = `{
  "manifest_version": "1",
  "etag": "test",
  "server": {"name": "test", "base_url": "http://replaced"},
  "nouns": [{"name": "doc", "summary": "Documents."}, {"name": "task", "summary": "Tasks."}],
  "commands": [
    {"id":"doc.get","noun":"doc","verb":"get","summary":"Fetch one document by type and id.",
     "http":{"method":"GET","path_template":"/v1/data/doc/:dataset/:type/:doc_id"},
     "auth_tier":"none",
     "args":[{"name":"type","required":true,"type":"string","summary":"Document type."},
             {"name":"doc_id","required":true,"type":"string","summary":"Document id."}],
     "flags":[{"name":"perspective","type":"string","default":"published","summary":"published | drafts | raw."}],
     "writes":false,"batch":false,"paginated":false,"dry_run":false,
     "default_output":"table","scoped_prefix":"/w/:workspace_slug/p/:project_slug"},
    {"id":"doc.publish","noun":"doc","verb":"publish","summary":"Publish a document's draft.",
     "http":{"method":"POST","path_template":"/v1/data/mutate/:dataset"},
     "auth_tier":"write",
     "args":[{"name":"type","required":true,"type":"string","summary":"Document type."},
             {"name":"id","required":true,"type":"string","summary":"Document id."}],
     "flags":[],"writes":true,"batch":false,"paginated":false,"dry_run":false,
     "default_output":"minimal","scoped_prefix":"/w/:workspace_slug/p/:project_slug",
     "mutation_op":"publish"},
    {"id":"task.get","noun":"task","verb":"get","summary":"Fetch one task by id.",
     "http":{"method":"GET","path_template":"/v1/tasks/:doc_id"},
     "auth_tier":"read",
     "args":[{"name":"doc_id","required":true,"type":"string","summary":"Task document id."}],
     "flags":[],"writes":false,"batch":false,"paginated":false,"dry_run":false,
     "default_output":"table","scoped_prefix":null}
  ]
}`

// theStaleDraft and theDoneSibling are the real pair from the row's purpose
// (task-f80f6eaebe2b4264): a draft authored 2026-07-28 whose description names
// its sibling in the FIRST sentence, and the sibling whose work merged
// 2026-08-23 as PR #13309 — ten days before the draft was published as fresh.
const (
	theStaleDraft  = "mob-lm-s6-island-offline"
	theDoneSibling = "mob-zb-bl-island-churn-offline"
	theOpenSibling = "mob-zb-bl-island-churn-hydrate"
	theCanonicalID = "task-f80f6eaebe2b4264"
)

// publishHarness stands up a fake instance plus the parsed manifest pointed at
// it, and records every request path+method the CLI actually sends — the only
// way to distinguish "the advisory looked" from "the advisory guessed".
type publishHarness struct {
	t      *testing.T
	server *httptest.Server
	m      *manifest.Manifest
	ctx    manifest.Context
	seen   []string

	// draftBody is the doc.get --perspective drafts response.
	draftBody string
	// taskStatus maps a cited id to its lifecycle_status; an id absent from the
	// map answers 404, which is how a prose token behaves.
	taskStatus map[string]string
	// taskClosedAt maps a cited id to claim.closed_at.
	taskClosedAt map[string]string
	// taskLookupStatus overrides the HTTP status a task lookup answers (0 ->
	// the ordinary 200/404 behaviour).
	taskLookupStatus int
	// published records whether the publish mutation was actually sent, and is
	// what the post-condition read below answers from.
	published bool
}

func newPublishHarness(t *testing.T) *publishHarness {
	t.Helper()
	h := &publishHarness{
		t:            t,
		taskStatus:   map[string]string{},
		taskClosedAt: map[string]string{},
	}
	h.server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h.seen = append(h.seen, r.Method+" "+r.URL.Path)
		w.Header().Set("Content-Type", "application/json")
		switch {
		case r.Method == http.MethodGet && strings.HasPrefix(r.URL.Path, "/v1/tasks/"):
			id := strings.TrimPrefix(r.URL.Path, "/v1/tasks/")
			if h.taskLookupStatus != 0 {
				w.WriteHeader(h.taskLookupStatus)
				_, _ = w.Write([]byte(`{"error":{"code":"boom","message":"lookup failed"}}`))
				return
			}
			status, ok := h.taskStatus[id]
			if !ok {
				w.WriteHeader(http.StatusNotFound)
				_, _ = w.Write([]byte(`{"error":{"code":"not_found","message":"no such task"}}`))
				return
			}
			closed := ""
			if c := h.taskClosedAt[id]; c != "" {
				closed = `,"claim":{"closed_at":"` + c + `"}`
			}
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write([]byte(`{"ok":true,"doc":{"doc_id":"` + id + `","lifecycle_status":"` + status + `"` + closed + `}}`))

		case r.Method == http.MethodGet && strings.Contains(r.URL.Path, "/v1/data/doc/"):
			// The post-condition read (`--perspective published`) must answer
			// only once the publish has landed; the pre-write draft read is the
			// `drafts` perspective.
			if r.URL.Query().Get("perspective") == "published" {
				if !h.published {
					w.WriteHeader(http.StatusNotFound)
					_, _ = w.Write([]byte(`{"error":{"code":"not_found","message":"no published version"}}`))
					return
				}
				w.WriteHeader(http.StatusOK)
				_, _ = w.Write([]byte(`{"result":{"_id":"` + theStaleDraft + `","_type":"task","status":"published"}}`))
				return
			}
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write([]byte(h.draftBody))

		default:
			h.published = true
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write([]byte(`{"transactionId":"tx1","results":[{"id":"` + theStaleDraft + `","operation":"publish"}]}`))
		}
	}))
	t.Cleanup(h.server.Close)

	body := strings.Replace(publishManifestJSON, "http://replaced", h.server.URL, 1)
	m, err := manifest.Parse([]byte(body))
	if err != nil {
		t.Fatalf("parse fixture manifest: %v", err)
	}
	h.m = m
	h.ctx = manifest.Context{
		Server:            h.server.URL,
		Token:             "tok",
		Workspace:         "acme",
		Project:           "site",
		Dataset:           "production",
		WorkspaceExplicit: true,
		ProjectExplicit:   true,
	}
	h.draftBody = draftWithDescription("A follow-up with no citations at all.")
	return h
}

// draftWithDescription builds the drafts.<id> read body: the document as
// QueryController returns it under a {"result": …} envelope, with the prose in
// `description` and a PortableDoc `brief` beside it.
func draftWithDescription(desc string) string {
	doc := map[string]any{
		"_id":         "drafts." + theStaleDraft,
		"_type":       "task",
		"title":       "Island offline: six sub-claims still true on main",
		"description": desc,
		"brief": map[string]any{
			"blocks": []any{
				map[string]any{"type": "paragraph", "content": []any{
					map[string]any{"type": "text", "value": "Authored 2026-07-28."},
				}},
			},
		},
		// Machine fields the extractor must NOT read: a slug-shaped label here
		// is not the author citing a measurement.
		"labels": []any{"proj-mobile-lane-two"},
	}
	b, err := json.Marshal(map[string]any{"result": doc})
	if err != nil {
		panic(err)
	}
	return string(b)
}

func (h *publishHarness) sent(want string) bool {
	for _, got := range h.seen {
		if got == want {
			return true
		}
	}
	return false
}

const (
	publishScopePrefix = "/w/acme/p/site"
	publishMutatePath  = publishScopePrefix + "/v1/data/mutate/production"
	publishDraftPath   = publishScopePrefix + "/v1/data/doc/production/task/" + theStaleDraft
)

// runPublish drives the real runCommand — the whole path, not the advisory in
// isolation.
func (h *publishHarness) runPublish(g globals, tail ...string) (code int, stdout, stderr string) {
	h.t.Helper()
	cmd, ok := h.m.Tree().Lookup("doc", "publish")
	if !ok {
		h.t.Fatal("fixture manifest has no doc publish")
	}
	var so, se bytes.Buffer
	w := newWriter(&so, &se)
	w.applyGlobals(g)
	code = runCommand(w, g, h.ctx, h.m, *cmd, tail)
	return code, so.String(), se.String()
}

// readPublishedStatus is the POST-CONDITION read criterion c2 demands: after
// the publish, ask the server for the PUBLISHED perspective and report the
// document's status. It goes through the same manifest dispatch the operator's
// own `bp doc get` would.
func (h *publishHarness) readPublishedStatus() string {
	h.t.Helper()
	get, ok := h.m.Tree().Lookup("doc", "get")
	if !ok {
		h.t.Fatal("fixture manifest has no doc get")
	}
	status, body, err := execManifestCommand(globals{yes: true}, h.ctx, h.m, *get,
		[]string{"task", theStaleDraft, "--perspective", "published"})
	if err != nil || status/100 != 2 {
		h.t.Fatalf("post-condition read failed: status=%d err=%v body=%s", status, err, body)
	}
	var env struct {
		Result struct {
			Status string `json:"status"`
		} `json:"result"`
	}
	if json.Unmarshal(body, &env) != nil {
		h.t.Fatalf("post-condition body unparseable: %s", body)
	}
	return env.Result.Status
}

// ---------------------------------------------------------------------------
// c0 — a draft citing a DONE row warns, naming the id and its CURRENT status.
// ---------------------------------------------------------------------------

// THE DEFECT VERBATIM: drafts.mob-lm-s6-island-offline asserted its own
// freshness in the present tense while naming, in its first sentence, the
// sibling whose work had merged ten days earlier as PR #13309. Publishing it
// laundered a stale measurement into a row every board read as fresh, and
// nothing said a word.
func TestPublishWarnsWhenDraftCitesADoneRow(t *testing.T) {
	h := newPublishHarness(t)
	h.draftBody = draftWithDescription(
		"Sibling row " + theDoneSibling + " covers the churn half; all six sub-claims still true on main.")
	h.taskStatus[theDoneSibling] = "done"
	h.taskClosedAt[theDoneSibling] = "2026-08-23"

	code, _, stderr := h.runPublish(globals{}, "task", theStaleDraft)

	if code != exitOK {
		t.Fatalf("exit = %d — the advisory must not change the publish's outcome; stderr:\n%s", code, stderr)
	}
	if !h.sent("GET " + publishDraftPath) {
		t.Errorf("the advisory never read the draft; requests seen: %v", h.seen)
	}
	if !h.sent("GET /v1/tasks/" + theDoneSibling) {
		t.Errorf("the advisory never looked the cited id up; requests seen: %v", h.seen)
	}
	for _, want := range []string{"advisory:", theDoneSibling, "DONE", "2026-08-23", "re-verify"} {
		if !strings.Contains(stderr, want) {
			t.Errorf("advisory omits %q — it must name the id, its CURRENT status and the remedy:\n%s", want, stderr)
		}
	}
	t.Logf("CAPTURED (cites a DONE row), stderr:\n%s", stderr)
}

// The canonical `task-<16 hex>` id form must work as well as the slug form —
// it is the id shape every `bp task create` receipt hands back.
func TestPublishWarnsOnCanonicalTaskID(t *testing.T) {
	h := newPublishHarness(t)
	h.draftBody = draftWithDescription("Follows on from " + theCanonicalID + ", which measured the publish path.")
	h.taskStatus[theCanonicalID] = "done"

	code, _, stderr := h.runPublish(globals{}, "task", theStaleDraft)

	if code != exitOK {
		t.Fatalf("exit = %d; stderr:\n%s", code, stderr)
	}
	if !strings.Contains(stderr, theCanonicalID) || !strings.Contains(stderr, "DONE") {
		t.Errorf("canonical id form was not reported:\n%s", stderr)
	}
}

// ---------------------------------------------------------------------------
// c1 — non-vacuous in BOTH directions.
// ---------------------------------------------------------------------------

// Direction one: a draft citing NO task id publishes with NO advisory at all —
// byte-identical output to before this file existed, on both channels.
func TestPublishOfADraftCitingNothingIsByteIdentical(t *testing.T) {
	h := newPublishHarness(t)
	h.draftBody = draftWithDescription(
		"A plain follow-up. Nothing cited here: we re-verify before acting, read-before-write, and move on.")

	code, stdout, stderr := h.runPublish(globals{}, "task", theStaleDraft)

	if code != exitOK {
		t.Fatalf("exit = %d; stderr:\n%s", code, stderr)
	}
	if strings.Contains(stderr, "advisory:") {
		t.Errorf("an advisory fired on a draft citing nothing — the check is a false positive:\n%s", stderr)
	}
	// The prose here contains three slug-SHAPED tokens ("re-verify" is two
	// segments, but "read-before-write" is three and matches slugTaskIDRe).
	// None resolves, so none may be named: RESOLUTION, not shape, is the test.
	if strings.Contains(stderr, "read-before-write") {
		t.Errorf("a prose token was reported as a citation:\n%s", stderr)
	}
	t.Logf("CAPTURED (cites nothing), stdout:%q stderr:%q", stdout, stderr)
}

// Direction two: an OPEN row must not read like a DONE row. If both printed the
// same sentence the check would be worthless — the whole point is that a
// terminal row makes a present-tense claim suspect and an open one does not.
func TestPublishReportsAnOpenCiteDifferentlyFromADoneCite(t *testing.T) {
	done := newPublishHarness(t)
	done.draftBody = draftWithDescription("Sibling " + theDoneSibling + " has the other half.")
	done.taskStatus[theDoneSibling] = "done"
	done.taskClosedAt[theDoneSibling] = "2026-08-23"
	_, _, doneErr := done.runPublish(globals{}, "task", theStaleDraft)

	open := newPublishHarness(t)
	open.draftBody = draftWithDescription("Sibling " + theOpenSibling + " has the other half.")
	open.taskStatus[theOpenSibling] = "open"
	_, _, openErr := open.runPublish(globals{}, "task", theStaleDraft)

	if !strings.Contains(doneErr, "which is DONE") {
		t.Errorf("the DONE arm did not say DONE:\n%s", doneErr)
	}
	if !strings.Contains(openErr, "which is OPEN") {
		t.Errorf("the OPEN arm did not say OPEN:\n%s", openErr)
	}
	if strings.Contains(openErr, "stale measurement") {
		t.Errorf("an OPEN cite carried the DONE wording — the two arms are indistinguishable:\n%s", openErr)
	}
	if !strings.Contains(doneErr, "stale measurement") {
		t.Errorf("the DONE arm lost its staleness wording:\n%s", doneErr)
	}
	t.Logf("CAPTURED (DONE), stderr:\n%s\nCAPTURED (OPEN), stderr:\n%s", doneErr, openErr)
}

// ---------------------------------------------------------------------------
// c2 — the check NEVER blocks.
// ---------------------------------------------------------------------------

// A publish that WARNS still publishes: the mutation is sent, the exit code is
// 0, and a post-condition read of the PUBLISHED perspective answers
// status=published. This is the criterion that separates an advisory from a
// gate, so it is asserted against the server's own state, not against output.
func TestPublishThatWarnsStillPublishes(t *testing.T) {
	h := newPublishHarness(t)
	h.draftBody = draftWithDescription("Sibling " + theDoneSibling + " already shipped as PR #13309.")
	h.taskStatus[theDoneSibling] = "done"

	code, _, stderr := h.runPublish(globals{}, "task", theStaleDraft)

	if code != exitOK {
		t.Fatalf("exit = %d — a warning must never become a refusal; stderr:\n%s", code, stderr)
	}
	if !strings.Contains(stderr, "advisory:") {
		t.Fatalf("this fixture must warn, or the post-condition proves nothing:\n%s", stderr)
	}
	if !h.sent("POST " + publishMutatePath) {
		t.Fatalf("the publish mutation was withheld; requests seen: %v", h.seen)
	}
	if got := h.readPublishedStatus(); got != "published" {
		t.Errorf("post-condition read: status = %q, want %q — the warned publish did not land", got, "published")
	}
}

// A status lookup that fails is a one-line "could not check", never a refusal
// and never a non-zero exit on its own.
func TestPublishSurvivesAFailedStatusLookup(t *testing.T) {
	h := newPublishHarness(t)
	h.draftBody = draftWithDescription("Follows on from " + theCanonicalID + ".")
	h.taskLookupStatus = http.StatusInternalServerError

	code, _, stderr := h.runPublish(globals{}, "task", theStaleDraft)

	if code != exitOK {
		t.Fatalf("exit = %d — a failed lookup must not fail the publish; stderr:\n%s", code, stderr)
	}
	if !h.sent("POST " + publishMutatePath) {
		t.Errorf("the publish was withheld on a failed lookup; requests seen: %v", h.seen)
	}
	if !strings.Contains(stderr, "could not check") {
		t.Errorf("a failed lookup on a canonical id must say so in one line:\n%s", stderr)
	}
	if strings.Contains(stderr, "refus") {
		t.Errorf("a failed lookup produced a refusal:\n%s", stderr)
	}
}

// A draft read that fails costs nothing and says nothing: the pre-write half
// must never look like a publish problem.
func TestPublishIsSilentWhenTheDraftReadFails(t *testing.T) {
	h := newPublishHarness(t)
	h.draftBody = `not json at all`

	code, _, stderr := h.runPublish(globals{}, "task", theStaleDraft)

	if code != exitOK {
		t.Fatalf("exit = %d; stderr:\n%s", code, stderr)
	}
	if strings.Contains(stderr, "advisory:") {
		t.Errorf("an unreadable draft produced an advisory:\n%s", stderr)
	}
}

// -o json: the advisory rides stderr, so stdout stays ONE byte-identical
// parseable document. Proven by comparing the warned run's stdout against a run
// of the same command whose draft cites nothing.
func TestPublishAdvisoryLeavesJSONStdoutByteIdentical(t *testing.T) {
	warned := newPublishHarness(t)
	warned.draftBody = draftWithDescription("Sibling " + theDoneSibling + " already shipped.")
	warned.taskStatus[theDoneSibling] = "done"
	_, warnedOut, warnedErr := warned.runPublish(globals{output: "json", outputSet: true}, "task", theStaleDraft)

	quiet := newPublishHarness(t)
	quiet.draftBody = draftWithDescription("Nothing cited here.")
	_, quietOut, _ := quiet.runPublish(globals{output: "json", outputSet: true}, "task", theStaleDraft)

	if !strings.Contains(warnedErr, "advisory:") {
		t.Fatalf("the warned run did not warn, so this test proves nothing:\n%s", warnedErr)
	}
	if warnedOut != quietOut {
		t.Errorf("-o json stdout drifted when the advisory fired:\nwarned: %q\nquiet:  %q", warnedOut, quietOut)
	}
	var probe any
	if err := json.Unmarshal([]byte(warnedOut), &probe); err != nil {
		t.Errorf("-o json stdout is not one parseable document: %v\n%s", err, warnedOut)
	}
	t.Logf("CAPTURED (-o json, warned) stdout:%s stderr:%s", warnedOut, warnedErr)
}

// ---------------------------------------------------------------------------
// Scope: the advisory does no network work at all outside `doc publish` on a
// task, so no other verb's receipt or request count changes.
// ---------------------------------------------------------------------------

func TestPublishAdvisorySkipsNonTaskTypes(t *testing.T) {
	h := newPublishHarness(t)
	h.draftBody = draftWithDescription("Cites " + theDoneSibling + ".")
	h.taskStatus[theDoneSibling] = "done"

	code, _, stderr := h.runPublish(globals{}, "paper", theStaleDraft)

	if code != exitOK {
		t.Fatalf("exit = %d; stderr:\n%s", code, stderr)
	}
	if strings.Contains(stderr, "advisory:") {
		t.Errorf("the advisory fired on a non-task publish:\n%s", stderr)
	}
	for _, got := range h.seen {
		if strings.HasPrefix(got, "GET /v1/data/doc/") || strings.HasPrefix(got, "GET /w/acme/p/site/v1/data/doc/") {
			t.Errorf("a non-task publish paid for a draft read: %v", h.seen)
			break
		}
	}
}

// The extractor itself: the cap, the self-cite exclusion, and canonical-first
// ordering, asserted without a server.
func TestExtractTaskCitesRuleAndOrdering(t *testing.T) {
	text := "self " + theStaleDraft + " sibling " + theDoneSibling +
		" canonical " + theCanonicalID + " prose read-before-write again " + theDoneSibling

	got := extractTaskCites(text, theStaleDraft)

	if len(got) == 0 || got[0].ID != theCanonicalID || !got[0].Canonical {
		t.Fatalf("canonical ids must be ordered first (cap protection); got %+v", got)
	}
	for _, c := range got {
		if c.ID == theStaleDraft {
			t.Errorf("the row cited itself: %+v", got)
		}
	}
	seen := 0
	for _, c := range got {
		if c.ID == theDoneSibling {
			seen++
		}
	}
	if seen != 1 {
		t.Errorf("duplicate citation not collapsed: %+v", got)
	}
}

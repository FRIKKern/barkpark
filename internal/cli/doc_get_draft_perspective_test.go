package cli

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// theDraftOnlyTaskRow is the live shape this advisory exists for: a task whose
// only row is `drafts.<id>`. Measured on guerrilla.barkpark.cloud 2026-09-11 —
// `bp doc get task gh-6292` 404s while `--perspective drafts` returns the row,
// and 761 of the ledger's 9,079 task rows are in that state.
const theDraftOnlyTaskRow = "gh-6292"

// docGetHarness stands up a fake instance whose `doc get` behaves EXACTLY like
// the live one: the published perspective keeps an exact-id lookup and 404s a
// draft-only id (with the server's own hint, which is the misleading sentence),
// while `--perspective drafts` prefers the draft twin and answers 200.
type docGetHarness struct {
	t             *testing.T
	server        *httptest.Server
	m             *manifest.Manifest
	ctx           manifest.Context
	seen          []string
	draftExists   bool
	draftsStatus  int // override for the drafts-lens answer (0 -> derived)
	publishedOK   bool
	requestsCount int
}

func newDocGetHarness(t *testing.T) *docGetHarness {
	t.Helper()
	h := &docGetHarness{t: t}
	h.server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		persp := r.URL.Query().Get("perspective")
		h.seen = append(h.seen, r.Method+" "+r.URL.Path+"?perspective="+persp)
		h.requestsCount++
		w.Header().Set("Content-Type", "application/json")

		answerOK := func(id string) {
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write([]byte(`{"result":{"_id":"` + id + `","_type":"task","_rev":"r1"}}`))
		}
		// The LIVE server's own annotated 404 — reproduced verbatim, because the
		// whole point of the advisory is that this hint outranks any derived one
		// and says the resource does not exist when it does.
		answer404 := func() {
			w.WriteHeader(http.StatusNotFound)
			_, _ = w.Write([]byte(`{"ok":false,"error":{"code":"not_found","message":"not found: document not found","hint":"Check the document _id, type, and dataset in the URL — the resource does not exist in this scope.","request_id":"rq1"}}`))
		}

		switch persp {
		case "drafts":
			if h.draftsStatus != 0 {
				w.WriteHeader(h.draftsStatus)
				_, _ = w.Write([]byte(`{"ok":false,"error":{"code":"not_found"}}`))
				return
			}
			if h.draftExists {
				answerOK("drafts." + theDraftOnlyTaskRow)
				return
			}
			answer404()
		default: // published (the CLI's default) and raw
			if h.publishedOK {
				answerOK(theDraftOnlyTaskRow)
				return
			}
			answer404()
		}
	}))
	t.Cleanup(h.server.Close)

	body := strings.Replace(discardManifestJSON, "http://replaced", h.server.URL, 1)
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
	return h
}

// runDocGet drives the real runCommand — the whole dispatch path, not the
// advisory in isolation — so an edit that drops the call site reds these tests
// rather than passing against a helper nobody calls.
func (h *docGetHarness) runDocGet(tail ...string) (code int, stdout, stderr string) {
	h.t.Helper()
	cmd, ok := h.m.Tree().Lookup("doc", "get")
	if !ok {
		h.t.Fatal("fixture manifest has no doc get")
	}
	var so, se bytes.Buffer
	w := newWriter(&so, &se)
	g := globals{}
	w.applyGlobals(g)
	code = runCommand(w, g, h.ctx, h.m, *cmd, tail)
	return code, so.String(), se.String()
}

func (h *docGetHarness) sentPerspective(want string) bool {
	for _, got := range h.seen {
		if strings.HasSuffix(got, "?perspective="+want) {
			return true
		}
	}
	return false
}

// TestDocGetOnDraftOnlyIDNamesThePerspective is THE DETECTOR for the row's
// second acceptance criterion. Without emitDocGetDraftPerspective the 404 is
// rendered with the server's hint alone — "the resource does not exist in this
// scope" — which is indistinguishable from absence, and this test reds on the
// missing advisory.
func TestDocGetOnDraftOnlyIDNamesThePerspective(t *testing.T) {
	h := newDocGetHarness(t)
	h.draftExists = true

	code, stdout, stderr := h.runDocGet("task", theDraftOnlyTaskRow)

	if code == exitOK {
		t.Fatalf("exit = %d, want the 404's own exit — the advisory must not change it", code)
	}
	if !h.sentPerspective("drafts") {
		t.Errorf("the drafts lens was never probed; requests seen: %v", h.seen)
	}
	// The criterion in the row's own words: a hint NAMING THE PERSPECTIVE.
	for _, want := range []string{"perspective", "draft", "published", theDraftOnlyTaskRow} {
		if !strings.Contains(stderr, want) {
			t.Errorf("advisory omits %q — it must name the lens, not just repeat not_found:\n%s", want, stderr)
		}
	}
	// It is an ADVISORY: stdout stays the rendered refusal, byte-untouched.
	if strings.Contains(stdout, "perspective") {
		t.Errorf("the advisory leaked into stdout, which must stay the renderer's own bytes:\n%s", stdout)
	}
}

// NEGATIVE ARM ONE. A genuinely absent id must stay a bare not_found: the probe
// runs, finds nothing, and says nothing. A fix that prints the advisory
// unconditionally — the "helpful" version that would teach readers a draft
// always exists — fails here.
func TestDocGetOnTrulyAbsentIDSaysNothingAboutDrafts(t *testing.T) {
	h := newDocGetHarness(t)
	h.draftExists = false

	_, _, stderr := h.runDocGet("task", "zzz-no-such-row-anywhere")

	if strings.Contains(strings.ToLower(stderr), "exists as a draft") {
		t.Errorf("claimed a draft exists after a 404 on the drafts lens:\n%s", stderr)
	}
}

// NEGATIVE ARM TWO. A caller who already typed `--perspective drafts` and got a
// 404 has an ANSWER, not a lens problem — and re-probing the lens they named
// would cost a request to tell them what they just asked. No probe at all.
func TestDocGetWithExplicitPerspectiveDoesNotProbe(t *testing.T) {
	h := newDocGetHarness(t)
	h.draftExists = false

	_, _, stderr := h.runDocGet("task", theDraftOnlyTaskRow, "--perspective", "drafts")

	if h.requestsCount != 1 {
		t.Errorf("requests = %d, want exactly 1 — an explicit --perspective must pay no probe: %v",
			h.requestsCount, h.seen)
	}
	if strings.Contains(strings.ToLower(stderr), "exists as a draft") {
		t.Errorf("advisory fired under an explicit --perspective:\n%s", stderr)
	}
}

// NEGATIVE ARM THREE. A SUCCESSFUL read pays nothing: one request, no advisory.
// This is what keeps the cost bounded to the refusal it explains.
func TestDocGetSuccessPaysNoProbe(t *testing.T) {
	h := newDocGetHarness(t)
	h.publishedOK = true

	code, _, stderr := h.runDocGet("task", theDraftOnlyTaskRow)

	if code != exitOK {
		t.Fatalf("exit = %d, want ok", code)
	}
	if h.requestsCount != 1 {
		t.Errorf("requests = %d, want exactly 1 on a 2xx: %v", h.requestsCount, h.seen)
	}
	if strings.Contains(strings.ToLower(stderr), "draft") {
		t.Errorf("advisory fired on a successful read:\n%s", stderr)
	}
}

// NEGATIVE ARM FOUR. A probe that errors or answers a non-2xx establishes
// NOTHING, so it must print nothing — silence here is "not established", never
// "no draft exists". A 500 on the drafts lens is the case.
func TestDocGetDraftProbeNonSuccessStaysSilent(t *testing.T) {
	h := newDocGetHarness(t)
	h.draftsStatus = http.StatusInternalServerError

	_, _, stderr := h.runDocGet("task", theDraftOnlyTaskRow)

	if strings.Contains(strings.ToLower(stderr), "exists as a draft") {
		t.Errorf("a 500 on the probe was read as proof of a draft:\n%s", stderr)
	}
}

// A `drafts.`-addressed id is refused by the cheap gate: that caller already
// reached for the draft lens by hand, so the published default is not what
// surprised them.
func TestDocGetArgsRefusesADraftsAddressedID(t *testing.T) {
	h := newDocGetHarness(t)
	cmd, ok := h.m.Tree().Lookup("doc", "get")
	if !ok {
		t.Fatal("fixture manifest has no doc get")
	}
	if _, _, ok := docGetArgs(*cmd, []string{"task", "drafts." + theDraftOnlyTaskRow}); ok {
		t.Error("docGetArgs accepted a drafts.-addressed id")
	}
	if _, _, ok := docGetArgs(*cmd, []string{"task", theDraftOnlyTaskRow}); !ok {
		t.Error("docGetArgs refused a plain id — the control arm")
	}
}

// The cheap gate's own arms, pinned without a server: a non-404 status and a
// command that is not doc.get both refuse before any request is built.
func TestDocGetDraftProbeAppliesGate(t *testing.T) {
	h := newDocGetHarness(t)
	cmd, ok := h.m.Tree().Lookup("doc", "get")
	if !ok {
		t.Fatal("fixture manifest has no doc get")
	}
	tail := []string{"task", theDraftOnlyTaskRow}

	if !docGetDraftProbeApplies(*cmd, tail, http.StatusNotFound) {
		t.Error("the 404 arm must apply — the control")
	}
	if docGetDraftProbeApplies(*cmd, tail, http.StatusForbidden) {
		t.Error("a 403 is not a perspective problem")
	}
	other := *cmd
	other.ID = "doc.ls"
	if docGetDraftProbeApplies(other, tail, http.StatusNotFound) {
		t.Error("the gate fired for a command that is not doc.get")
	}
}

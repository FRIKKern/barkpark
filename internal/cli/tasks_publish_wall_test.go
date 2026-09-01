package cli

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// wallStub is a mutate+query endpoint that COUNTS the create mutations it
// receives and answers the publish mutation with the real publish-wall refusal
// (the exact envelope api/lib/barkpark/content/errors.ex builds for
// {:error, {:label_spine, …}} / {:error, {:unknown_tag, …}}).
//
// The create count is the whole point of these tests. "Did the refusal leave a
// draft on the server?" is not a question about stderr wording — it is a
// question about whether the CREATE mutation was ever sent, and that is the only
// thing a stub can answer without a real database.
type wallStub struct {
	*httptest.Server
	mu           sync.Mutex
	creates      int
	publishes    int
	registryHits int
}

// newWallStub serves:
//
//	POST …/v1/data/mutate/…  → create: 200 with drafts.task-77; publish: `refusal`,
//	                           or a published twin when `refusal` is empty
//	GET  …/v1/data/query/…/tag → the registry page, from `registered`
func newWallStub(t *testing.T, refusal string, registered []string) *wallStub {
	t.Helper()
	s := &wallStub{}
	s.Server = httptest.NewServer(http.HandlerFunc(func(rw http.ResponseWriter, req *http.Request) {
		switch {
		case strings.Contains(req.URL.Path, "/v1/data/query/") && strings.HasSuffix(req.URL.Path, "/tag"):
			s.mu.Lock()
			s.registryHits++
			s.mu.Unlock()
			docs := make([]map[string]any, 0, len(registered))
			for _, name := range registered {
				docs = append(docs, map[string]any{"_id": name, "_type": "tag"})
			}
			_ = json.NewEncoder(rw).Encode(map[string]any{
				"result": map[string]any{"documents": docs, "hasMore": false, "count": len(docs)},
			})

		case strings.Contains(req.URL.Path, "/v1/data/mutate"):
			var body struct {
				Mutations []map[string]json.RawMessage `json:"mutations"`
			}
			if err := json.NewDecoder(req.Body).Decode(&body); err != nil || len(body.Mutations) == 0 {
				rw.WriteHeader(http.StatusBadRequest)
				return
			}
			if _, isPublish := body.Mutations[0]["publish"]; isPublish {
				s.mu.Lock()
				s.publishes++
				s.mu.Unlock()
				if refusal == "" {
					// An empty refusal means "this server's wall accepts the row".
					_ = json.NewEncoder(rw).Encode(map[string]any{"results": []any{
						map[string]any{"id": "task-77", "document": map[string]any{"_id": "task-77", "_draft": false, "lifecycle_status": "open"}},
					}})
					return
				}
				rw.Header().Set("Content-Type", "application/json")
				rw.WriteHeader(http.StatusUnprocessableEntity)
				_, _ = rw.Write([]byte(refusal))
				return
			}
			s.mu.Lock()
			s.creates++
			s.mu.Unlock()
			_ = json.NewEncoder(rw).Encode(map[string]any{"results": []any{
				map[string]any{"id": "drafts.task-77", "document": map[string]any{"_id": "drafts.task-77", "_draft": true}},
			}})

		default:
			rw.WriteHeader(http.StatusNotFound)
		}
	}))
	t.Cleanup(s.Close)
	return s
}

func (s *wallStub) counts() (creates, publishes, registryHits int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.creates, s.publishes, s.registryHits
}

const labelSpineRefusal = `{"error":{"code":"label_spine","message":"the document cannot be published",` +
	`"details":{"field":"tags","rule":"A published document requires a ` + "`tags`" + ` array.",` +
	`"fix":"Add 1-12 weighted tags."}}}`

const unknownTagRefusal = `{"error":{"code":"unknown_tag","message":"publish references unregistered tag(s): phantom-rowz",` +
	`"details":{"unknown":["phantom-rowz"],"suggestions":{"phantom-rowz":["phantom-rows"]}}}}`

// wallPassingTags is a weighted label that clears E1/E2 — two entries, distinct
// strengths, rationales over the 20-char floor.
const wallPassingTags = `tags:=[` +
	`{"tag":"cli","strength":80,"rationale":"the defect and its fix both live in the bp CLI binary"},` +
	`{"tag":"tasks","strength":40,"rationale":"it is the task ledger's create-and-publish door"}]`

const wallPassingDescription = "A description long enough to clear the twenty-character label-spine floor."

// ── THE DEFECT ───────────────────────────────────────────────────────────────
//
// `bp task create --publish` is create-then-publish, and the publish wall runs
// on the SECOND mutation. A row that cannot clear the wall therefore lands the
// DRAFT and then exits non-zero — leaving an unclaimable `drafts.task-N` that
// `bp task claim` 404s, while telling the caller a task was "created".
//
// RED BEFORE: the create mutation reaches the server and the assertion below
// fires with creates=1. GREEN AFTER: the wall runs client-side, before anything
// is written, and creates=0.
func TestTaskCreatePublishLeavesNoDraftWhenTheLabelSpineRefuses(t *testing.T) {
	stub := newWallStub(t, labelSpineRefusal, []string{"cli", "tasks"})
	ctx := manifest.Context{Server: stub.URL, Dataset: "production", Token: "tok"}

	var so, se bytes.Buffer
	w := &writer{stdout: &so, stderr: &se}
	// No --description and no tags: exactly the shape an agent told to "file a
	// row" produces when it does not know the wall exists.
	code := runTaskCreate(w, globals{yes: true}, ctx, []string{"a task", "--publish"})

	if code == exitOK {
		t.Fatalf("a row that cannot clear the publish wall exited OK\nstdout: %s\nstderr: %s", so.String(), se.String())
	}
	creates, _, _ := stub.counts()
	if creates != 0 {
		t.Fatalf("--publish sent %d create mutation(s) for a row it could not publish — the refusal left a phantom drafts.* row on the server; a command that half-succeeds and leaves debris is worse than one that refuses.\nstderr: %s", creates, se.String())
	}
	if got := se.String(); !strings.Contains(got, "nothing was created") {
		t.Errorf("the refusal does not tell the caller that no draft was left behind:\n%s", got)
	}
	if got := se.String(); !strings.Contains(got, "description") {
		t.Errorf("the refusal does not name the field that broke the wall:\n%s", got)
	}
}

// The SECOND phantom: the caller reacts to `label_spine` by adding
// plausible-sounding tags, and the retry refuses `unknown_tag` — leaving another
// draft. Every tag must ALREADY be a published type:tag document, so the client
// can resolve them before writing, and the refusal must NAME the vocabulary
// rather than making the caller guess a third time.
func TestTaskCreatePublishLeavesNoDraftForUnregisteredTags(t *testing.T) {
	stub := newWallStub(t, unknownTagRefusal, []string{"phantom-rows", "cli", "tasks", "ledger"})
	ctx := manifest.Context{Server: stub.URL, Dataset: "production", Token: "tok"}

	var so, se bytes.Buffer
	w := &writer{stdout: &so, stderr: &se}
	code := runTaskCreate(w, globals{yes: true}, ctx, []string{
		"a task", "--publish",
		"--description", wallPassingDescription,
		"--set", `tags:=[{"tag":"phantom-rowz","strength":70,"rationale":"an invented name that is not in the registry"}]`,
	})

	if code == exitOK {
		t.Fatalf("an unregistered tag exited OK\nstdout: %s\nstderr: %s", so.String(), se.String())
	}
	creates, _, _ := stub.counts()
	if creates != 0 {
		t.Fatalf("--publish sent %d create mutation(s) for an unregistered tag — the refusal left a phantom drafts.* row behind.\nstderr: %s", creates, se.String())
	}
	got := se.String()
	if !strings.Contains(got, "phantom-rowz") {
		t.Errorf("the refusal does not name the offending tag:\n%s", got)
	}
	if !strings.Contains(got, "phantom-rows") {
		t.Errorf("the refusal does not name the nearest REGISTERED tag — the caller is left to guess again:\n%s", got)
	}
	if !strings.Contains(got, "bp doc ls tag") {
		t.Errorf("the refusal does not name the command that lists the registered vocabulary:\n%s", got)
	}
	if !strings.Contains(got, "nothing was created") {
		t.Errorf("the refusal does not tell the caller that no draft was left behind:\n%s", got)
	}
}

// A row that DOES clear the wall still publishes in one call — the pre-flight
// must not have turned `--publish` into a refusal machine.
func TestTaskCreatePublishStillPublishesAWallPassingRow(t *testing.T) {
	stub := newWallStub(t, "", []string{"cli", "tasks"})
	ctx := manifest.Context{Server: stub.URL, Dataset: "production", Token: "tok"}

	var so, se bytes.Buffer
	w := &writer{stdout: &so, stderr: &se, output: "json"}
	code := runTaskCreate(w, globals{yes: true}, ctx, []string{
		"a task", "--publish",
		"--description", wallPassingDescription,
		"--set", wallPassingTags,
	})
	if code != exitOK {
		t.Fatalf("a wall-passing row was refused (exit %d)\nstdout: %s\nstderr: %s", code, so.String(), se.String())
	}
	creates, publishes, _ := stub.counts()
	if creates != 1 || publishes != 1 {
		t.Fatalf("creates=%d publishes=%d, want 1 and 1", creates, publishes)
	}
}

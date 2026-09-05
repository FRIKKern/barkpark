package cli

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// goodTags is the in-memory twin of wallPassingTags.
func goodTags() []any {
	return []any{
		map[string]any{"tag": "cli", "strength": float64(80), "rationale": "the defect and its fix both live in the bp CLI binary"},
		map[string]any{"tag": "tasks", "strength": float64(40), "rationale": "it is the task ledger's create-and-publish door"},
	}
}

func goodBody() map[string]any {
	return map[string]any{"title": "t", "description": wallPassingDescription, "tags": goodTags()}
}

// Every rule the server's label_spine.ex enforces, checked client-side against
// the SAME field name — a client that named a different field would send the
// caller to fix something the server was not going to complain about.
func TestCheckLabelSpineLocalNamesEachBrokenRule(t *testing.T) {
	for _, tc := range []struct {
		name      string
		mutate    func(map[string]any)
		wantField string
		wantIn    string
	}{
		{"no description", func(b map[string]any) { delete(b, "description") }, "description", "requires a description"},
		{"trivial description", func(b map[string]any) { b["description"] = "too short" }, "description", "non-trivial"},
		{"no tags", func(b map[string]any) { delete(b, "tags") }, "tags", "requires a `tags` array"},
		{"empty tags", func(b map[string]any) { b["tags"] = []any{} }, "tags", "at least 1 tag"},
		{"flat legacy string tags", func(b map[string]any) { b["tags"] = []any{"cli"} }, "tags", "LEGACY flat shape"},
		{"too many tags", func(b map[string]any) {
			many := make([]any, 0, 13)
			for i := 0; i < 13; i++ {
				many = append(many, map[string]any{"tag": "cli", "strength": float64(i + 1), "rationale": strings.Repeat("x", 25)})
			}
			b["tags"] = many
		}, "tags", "at most 12 tags"},
		{"bad tag name", func(b map[string]any) {
			b["tags"] = []any{map[string]any{"tag": "Not A Tag", "strength": float64(9), "rationale": strings.Repeat("x", 25)}}
		}, "tags", "lowercase letters, digits and hyphens"},
		{"weight instead of strength", func(b map[string]any) {
			b["tags"] = []any{map[string]any{"tag": "cli", "weight": float64(80), "rationale": strings.Repeat("x", 25)}}
		}, "tags", "not `weight`"},
		{"strength out of range", func(b map[string]any) {
			b["tags"] = []any{map[string]any{"tag": "cli", "strength": float64(101), "rationale": strings.Repeat("x", 25)}}
		}, "tags", "integer 1..100"},
		{"short rationale", func(b map[string]any) {
			b["tags"] = []any{map[string]any{"tag": "cli", "strength": float64(80), "rationale": "CI wiring"}}
		}, "tags", "at least 20 characters"},
		{"duplicate strengths", func(b map[string]any) {
			b["tags"] = []any{
				map[string]any{"tag": "cli", "strength": float64(50), "rationale": strings.Repeat("x", 25)},
				map[string]any{"tag": "tasks", "strength": float64(50), "rationale": strings.Repeat("x", 25)},
			}
		}, "tags", "DISTINCT"},
		{"duplicate tag name", func(b map[string]any) {
			b["tags"] = []any{
				map[string]any{"tag": "cli", "strength": float64(50), "rationale": strings.Repeat("x", 25)},
				map[string]any{"tag": "cli", "strength": float64(40), "rationale": strings.Repeat("x", 25)},
			}
		}, "tags", "only once"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			body := goodBody()
			tc.mutate(body)
			ref := checkLabelSpineLocal(body)
			if ref == nil {
				t.Fatalf("no refusal — the client would create a draft the server refuses to publish")
			}
			if ref.Field != tc.wantField {
				t.Errorf("field = %q, want %q", ref.Field, tc.wantField)
			}
			joined := strings.Join(ref.lines(), "\n")
			if !strings.Contains(joined, tc.wantIn) {
				t.Errorf("refusal does not explain the rule (%q missing):\n%s", tc.wantIn, joined)
			}
		})
	}
}

// The happy path must NOT refuse — a pre-flight that refuses valid rows is a
// worse bug than the one it fixes.
func TestCheckLabelSpineLocalPassesAWellLabelledRow(t *testing.T) {
	if ref := checkLabelSpineLocal(goodBody()); ref != nil {
		t.Fatalf("a wall-passing row was refused: %s / %s", ref.Field, ref.Rule)
	}
}

// The three ways a strength can arrive and still be the same integer.
func TestWallIntAcceptsEveryJSONNumberShape(t *testing.T) {
	for _, tc := range []struct {
		name string
		in   any
		want int
		ok   bool
	}{
		{"float64 from encoding/json", float64(80), 80, true},
		{"native int", 80, 80, true},
		{"json.Number", json.Number("80"), 80, true},
		{"fractional float is not an integer", float64(80.5), 0, false},
		{"string is not a number", "80", 0, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got, ok := wallInt(tc.in)
			if ok != tc.ok || (ok && got != tc.want) {
				t.Fatalf("wallInt(%v) = %d,%v want %d,%v", tc.in, got, ok, tc.want, tc.ok)
			}
		})
	}
}

// THE SAFETY PROPERTY. A client that cannot read the registry must not refuse a
// publish the server would have accepted — every unreadable answer is BLIND, and
// a blind check never produces a refusal. The truncated page is the one that
// would silently do the wrong thing: it decodes fine and looks like a registry.
func TestFetchRegisteredTagsIsBlindOnEveryUnreliableAnswer(t *testing.T) {
	for _, tc := range []struct {
		name    string
		status  int
		body    string
		wantOK  bool
		wantLen int
	}{
		{"forbidden", http.StatusForbidden, `{"error":{"code":"forbidden"}}`, false, 0},
		{"server error", http.StatusInternalServerError, `{"error":{"code":"internal_error"}}`, false, 0},
		{"undecodable", http.StatusOK, `upstream connect error`, false, 0},
		{"truncated page", http.StatusOK, `{"result":{"documents":[{"_id":"cli"}],"hasMore":true}}`, false, 0},
		{"empty registry", http.StatusOK, `{"result":{"documents":[],"hasMore":false}}`, false, 0},
		{"complete page", http.StatusOK, `{"result":{"documents":[{"_id":"cli"},{"_id":"tasks"}],"hasMore":false}}`, true, 2},
	} {
		t.Run(tc.name, func(t *testing.T) {
			ts := httptest.NewServer(http.HandlerFunc(func(rw http.ResponseWriter, _ *http.Request) {
				rw.Header().Set("Content-Type", "application/json")
				rw.WriteHeader(tc.status)
				_, _ = rw.Write([]byte(tc.body))
			}))
			defer ts.Close()
			names, ok := fetchRegisteredTags(manifest.Context{Server: ts.URL, Dataset: "production", Token: "tok"})
			if ok != tc.wantOK || len(names) != tc.wantLen {
				t.Fatalf("fetchRegisteredTags = %v,%v want len %d, ok %v", names, ok, tc.wantLen, tc.wantOK)
			}
		})
	}
}

// A blind registry read is REPORTED and the create proceeds — never a silent
// clearance, never a veto.
func TestCheckTagRegistryFailsOpenAndSaysSo(t *testing.T) {
	prior := registeredTagReader
	defer func() { registeredTagReader = prior }()
	registeredTagReader = func(manifest.Context) ([]string, bool) { return nil, false }

	ref, blind := checkTagRegistry(manifest.Context{}, goodBody())
	if ref != nil {
		t.Fatalf("a blind read produced a refusal: %+v", ref)
	}
	if !blind {
		t.Fatalf("a blind read did not report itself blind — the caller would think the tags were checked")
	}
}

// The behavioural half of the same contract, INVERTED by
// task-ede6e18e8c397ee0. checkTagRegistry still reports `blind` rather than
// refusing (it is a pure classifier and the MCP path reads it too), but
// `bp task create --publish` now FAILS CLOSED on that report: it refuses before
// the create instead of writing blind. This test used to assert the opposite —
// creates=1, publishes=1, exit 0 — and that behaviour is what minted 6 of the
// 23 stranded `drafts.` rows on the rail: an unreadable registry under load is
// the same state in which the server's own unknown_tag wall then refuses, and
// the draft stays.
func TestTaskCreatePublishRefusesWhenTheRegistryIsUnreadable(t *testing.T) {
	var creates, publishes int
	ts := httptest.NewServer(http.HandlerFunc(func(rw http.ResponseWriter, req *http.Request) {
		if strings.Contains(req.URL.Path, "/v1/data/query/") {
			rw.WriteHeader(http.StatusInternalServerError)
			return
		}
		var body struct {
			Mutations []map[string]json.RawMessage `json:"mutations"`
		}
		_ = json.NewDecoder(req.Body).Decode(&body)
		if _, isPublish := body.Mutations[0]["publish"]; isPublish {
			publishes++
			_ = json.NewEncoder(rw).Encode(map[string]any{"results": []any{
				map[string]any{"id": "task-77", "document": map[string]any{"_id": "task-77", "_draft": false}},
			}})
			return
		}
		creates++
		_ = json.NewEncoder(rw).Encode(map[string]any{"results": []any{
			map[string]any{"id": "drafts.task-77", "document": map[string]any{"_id": "drafts.task-77", "_draft": true}},
		}})
	}))
	defer ts.Close()

	var so, se bytes.Buffer
	w := &writer{stdout: &so, stderr: &se}
	code := runTaskCreate(w, globals{yes: true}, manifest.Context{Server: ts.URL, Dataset: "production", Token: "tok"},
		[]string{"a task", "--publish", "--description", wallPassingDescription, "--set", wallPassingTags})
	if code == exitOK {
		t.Fatalf("a blind registry read still published: %s", so.String())
	}
	// THE LOAD-BEARING ASSERTION: nothing was written. A refusal that still
	// POSTed the create would be the defect with a nicer message on top.
	if creates != 0 || publishes != 0 {
		t.Fatalf("creates=%d publishes=%d, want 0 and 0 — the refusal must land BEFORE the create", creates, publishes)
	}
	for _, want := range []string{
		tagRegistryUnreadableCode,
		"nothing was created — no draft was left behind.",
		tagRegistryCommand,
	} {
		if !strings.Contains(se.String(), want) {
			t.Errorf("the refusal does not carry %q:\n%s", want, se.String())
		}
	}
}

// An unrelated vocabulary must yield NO suggestion. A confident wrong "did you
// mean" is how a caller invents a second unregistered tag.
func TestNearestRegisteredTagsStaysSilentOnAnUnrelatedVocabulary(t *testing.T) {
	if got := nearestRegisteredTags("zzqqxx", []string{"cli", "tasks", "ledger"}); len(got) != 0 {
		t.Fatalf("suggested %v for a name nothing resembles", got)
	}
	got := nearestRegisteredTags("phantom-rowz", []string{"phantom-rows", "cli", "tasks"})
	if len(got) == 0 || got[0] != "phantom-rows" {
		t.Fatalf("nearest = %v, want phantom-rows first", got)
	}
}

// THE RESIDUE. When a publish is refused after the draft landed, the message
// must name the row as a DRAFT (the `drafts.` id, not the bare one the old
// message printed), say what that costs, and give BOTH exits.
func TestOrphanedDraftRemedyNamesTheDraftAndBothExits(t *testing.T) {
	joined := strings.Join(orphanedDraftRemedyLines("drafts.task-77", "task-77"), "\n")
	for _, want := range []string{
		"drafts.task-77",              // the id that actually exists
		"NOT ON THE BOARD",            // the consequence, in the words a person uses
		"404",                         // what a claim against it will answer
		"bp doc publish task task-77", // exit 1: finish the job
		"bp doc delete task task-77",  // exit 2: dispose of the debris
	} {
		if !strings.Contains(joined, want) {
			t.Errorf("the remedy does not carry %q:\n%s", want, joined)
		}
	}
}

// THE SERVER-ONLY REFUSAL ARM, REWRITTEN BY task-ede6e18e8c397ee0. A 4xx from
// the publish is a refusal the server evaluated and committed nothing for, so
// the draft this run created seconds earlier is the whole row — and it is now
// DISCARDED in the same run rather than named and left. The old assertion here
// ("the caller is given no way to dispose of the draft that was left" ->
// `bp doc delete task task-77`) encoded leaving it; the remedy text still
// exists and is still printed, but only on the residue arms below, where the
// publish may actually have landed.
func TestTaskCreatePublishDiscardsTheDraftOnAServerOnlyRefusal(t *testing.T) {
	// A refusal the pre-flight CANNOT predict: the body clears the label spine and
	// every tag is registered, and the server still refuses (duplicate_of).
	var discards int
	var gotDiscardID string
	ts := httptest.NewServer(http.HandlerFunc(func(rw http.ResponseWriter, req *http.Request) {
		if strings.Contains(req.URL.Path, "/v1/data/query/") {
			_, _ = rw.Write([]byte(`{"result":{"documents":[{"_id":"cli"},{"_id":"tasks"}],"hasMore":false}}`))
			return
		}
		var body struct {
			Mutations []map[string]json.RawMessage `json:"mutations"`
		}
		_ = json.NewDecoder(req.Body).Decode(&body)
		if raw, isDiscard := body.Mutations[0]["discardDraft"]; isDiscard {
			discards++
			var op struct {
				ID   string `json:"id"`
				Type string `json:"type"`
			}
			_ = json.Unmarshal(raw, &op)
			gotDiscardID = op.ID
			if op.Type != "task" {
				t.Errorf("discardDraft type = %q, want task", op.Type)
			}
			_ = json.NewEncoder(rw).Encode(map[string]any{"results": []any{
				map[string]any{"id": "drafts.task-77"},
			}})
			return
		}
		if _, isPublish := body.Mutations[0]["publish"]; isPublish {
			rw.Header().Set("Content-Type", "application/json")
			rw.WriteHeader(http.StatusConflict)
			_, _ = rw.Write([]byte(`{"error":{"code":"duplicate_of","message":"an incumbent already covers this","details":{"duplicate_of":"task-1"}}}`))
			return
		}
		_ = json.NewEncoder(rw).Encode(map[string]any{"results": []any{
			map[string]any{"id": "drafts.task-77", "document": map[string]any{"_id": "drafts.task-77", "_draft": true}},
		}})
	}))
	defer ts.Close()

	var so, se bytes.Buffer
	w := &writer{stdout: &so, stderr: &se}
	code := runTaskCreate(w, globals{yes: true}, manifest.Context{Server: ts.URL, Dataset: "production", Token: "tok"},
		[]string{"a task", "--publish", "--description", wallPassingDescription, "--set", wallPassingTags})
	if code == exitOK {
		t.Fatalf("a refused publish exited OK: %s", so.String())
	}
	got := se.String()
	if !strings.Contains(got, "drafts.task-77") {
		t.Errorf("the failure names no draft id a re-read could resolve:\n%s", got)
	}
	if !strings.Contains(got, "duplicate_of") {
		t.Errorf("the refusal reason was not printed:\n%s", got)
	}
	if discards != 1 {
		t.Fatalf("discardDraft mutations = %d, want exactly 1 — the draft was left stranded", discards)
	}
	if gotDiscardID != "task-77" {
		t.Fatalf("discardDraft targeted %q, want the bare id task-77", gotDiscardID)
	}
	if !strings.Contains(got, "discarded drafts.task-77") {
		t.Errorf("the discard was not reported:\n%s", got)
	}
	if strings.Contains(got, "NOT ON THE BOARD") || strings.Contains(got, "bp doc delete task task-77") {
		t.Errorf("the orphaned-draft remedy was printed for a draft that no longer exists:\n%s", got)
	}
}

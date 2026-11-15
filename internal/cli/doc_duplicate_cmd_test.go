package cli

import (
	"encoding/json"
	"strings"
	"testing"
)

const docDupSchemaPath = "/v1/schemas/production/post"

// docDupSource is what the document read sends for p1 with perspective=drafts.
const docDupSource = `{"result":{"_id":"drafts.p1","_type":"post","_rev":"r2","_draft":true,"_publishedId":"p1",
	"_createdAt":"2026-01-03T00:00:00Z","_updatedAt":"2026-01-04T00:00:00Z",
	"title":"New","extra":"added","seo":{"title":"same"},
	"links":[{"_key":"c","url":"three"},{"_key":"a","url":"one"},{"_key":"b","url":"two"}]}}`

func docDupCreate(t *testing.T, body string) map[string]any {
	t.Helper()
	var req struct {
		Mutations []map[string]map[string]any `json:"mutations"`
	}
	if err := json.Unmarshal([]byte(body), &req); err != nil || len(req.Mutations) != 1 || req.Mutations[0]["create"] == nil {
		t.Fatalf("the request is not one create mutation: %v\n%s", err, body)
	}
	return req.Mutations[0]["create"]
}

// The copy is one `create` with the source's content, a " (copy)" title and
// none of the source's own keys, and the new id is the only thing on stdout.
// It reads the draft when there is one (perspective=drafts).
func TestDocDuplicateSendsACreateAndPrintsTheNewID(t *testing.T) {
	s := newDocFakeServer(t, map[string]string{
		docDiffPubPath:   docDupSource,
		docDupSchemaPath: `{"schema":{"name":"post","desk":{}}}`,
	})

	code, stdout, stderr := runDocVerb(runDocDuplicate, s.ctx(), globals{}, "post", "p1")
	if code != exitOK || strings.TrimSpace(stdout) != "drafts.post-9" {
		t.Fatalf("exit = %d, stdout=%q, stderr=%s", code, stdout, stderr)
	}
	if s.postCount() != 1 {
		t.Fatalf("writes = %d, want 1", s.postCount())
	}
	create := docDupCreate(t, s.posts[0])
	if create["title"] != "New (copy)" || create["_type"] != "post" || create["extra"] != "added" {
		t.Errorf("create = %v", create)
	}
	if rows, _ := create["links"].([]any); len(rows) != 3 {
		t.Errorf("links were not copied whole: %v", create["links"])
	}
	for _, k := range []string{"_id", "_rev", "_draft", "_publishedId", "_createdAt", "_updatedAt"} {
		if _, ok := create[k]; ok {
			t.Errorf("create carries the source's %s", k)
		}
	}

	code, stdout, _ = runDocVerb(runDocDuplicate, s.ctx(), globals{output: "json"}, "post", "p1", "--id", "p2", "--title", "Second")
	if code != exitOK || !strings.Contains(stdout, `"id":"drafts.post-9"`) {
		t.Fatalf("--id/--title: exit = %d, stdout=%s", code, stdout)
	}
	if create = docDupCreate(t, s.posts[1]); create["_id"] != "drafts.p2" || create["title"] != "Second" {
		t.Errorf("--id/--title create = %v", create)
	}

	code, stdout, _ = runDocVerb(runDocDuplicate, s.ctx(), globals{dryRun: true}, "post", "p1")
	if code != exitOK || s.postCount() != 2 || !strings.Contains(stdout, "New (copy)") {
		t.Errorf("--dry-run: exit = %d, writes = %d, stdout=%s", code, s.postCount(), stdout)
	}

	s.answer = `{"results":[]}`
	if code, stdout, _ := runDocVerb(runDocDuplicate, s.ctx(), globals{}, "post", "p1"); code == exitOK || strings.TrimSpace(stdout) != "" {
		t.Errorf("a receipt with no id: exit = %d, stdout=%q, want a refusal and no id", code, stdout)
	}
}

// What Studio's Duplicate refuses, this refuses, before any write: a type
// that says authorCreatable false, a singleton, and a document that is not
// there.
func TestDocDuplicateRefusesWhatStudioWithholds(t *testing.T) {
	for name, schema := range map[string]string{
		"authorCreatable": `{"schema":{"name":"post","desk":{"authorCreatable":false}}}`,
		"singleton":       `{"schema":{"name":"post","singleton":true}}`,
	} {
		s := newDocFakeServer(t, map[string]string{docDiffPubPath: docDupSource, docDupSchemaPath: schema})
		code, stdout, stderr := runDocVerb(runDocDuplicate, s.ctx(), globals{}, "post", "p1")
		if code != exitValidation || s.postCount() != 0 || stdout != "" || !strings.Contains(stderr, "cannot be duplicated") {
			t.Errorf("%s: exit = %d, writes = %d, stdout=%q, stderr=%s", name, code, s.postCount(), stdout, stderr)
		}
	}

	s := newDocFakeServer(t, nil)
	if code, _, _ := runDocVerb(runDocDuplicate, s.ctx(), globals{}, "post", "p1"); code != exitNotFound || s.postCount() != 0 {
		t.Errorf("no source: exit = %d, writes = %d", code, s.postCount())
	}
}

// On a server that is not local the write waits for --yes, as `bp schema
// push` and `bp seed` do.
func TestDocDuplicateNeedsYesOnProduction(t *testing.T) {
	s := newDocFakeServer(t, map[string]string{docDiffPubPath: docDupSource})
	dialAllTo(t, s)
	ctx := s.ctx()
	ctx.Server = "http://cms.example.test"

	code, stdout, stderr := runDocVerb(runDocDuplicate, ctx, globals{}, "post", "p1")
	if code != exitUsage || s.postCount() != 0 || stdout != "" || !strings.Contains(stderr, "re-run with --yes") {
		t.Fatalf("without --yes: exit = %d, writes = %d, stdout=%q, stderr=%s", code, s.postCount(), stdout, stderr)
	}
	code, stdout, stderr = runDocVerb(runDocDuplicate, ctx, globals{yes: true}, "post", "p1")
	if code != exitOK || s.postCount() != 1 || strings.TrimSpace(stdout) != "drafts.post-9" {
		t.Fatalf("with --yes: exit = %d, writes = %d, stdout=%q, stderr=%s", code, s.postCount(), stdout, stderr)
	}
}

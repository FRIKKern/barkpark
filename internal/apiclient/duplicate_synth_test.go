package apiclient

import (
	"strings"
	"testing"
)

// task-df4d07f6c88de78a: the doc-show endpoint SYNTHESIZES an in-memory block
// list (ids `synth-<prefix>-<name>-<idx>`, Barkpark.PortableDoc.Synthesis) for
// any document whose schema has a body region, and persists nothing. Treating
// that projection as a stored block tree refused EVERY post as "papers cannot
// be duplicated here" (measured in the TUI on post-ga). A synthesized list is
// a view of the content fields Duplicate already copies, so it duplicates; a
// persisted block (any id without the synth- prefix) is still refused.
func TestDuplicateCopiesAPostWhoseBlocksAreOnlySynthesized(t *testing.T) {
	post := `{"result": {
		"_id": "post-ga",
		"_type": "post",
		"_draft": false,
		"title": "Going to GA",
		"excerpt": "What changes when Barkpark hits 1.0.",
		"blocks": [
			{"id": "synth-f-title-0", "type": "field-string", "fieldName": "title", "value": "Going to GA"},
			{"id": "synth-body-p-3", "type": "paragraph", "content": []}
		]
	}}`
	var mutateBody []byte
	mutateCalls := 0
	srv := dupServer(t, post, &mutateBody, &mutateCalls)
	defer srv.Close()

	c := New(Config{BaseURL: srv.URL, Token: "t", Dataset: "production"})
	if _, err := c.Duplicate("post", "post-ga"); err != nil {
		t.Fatalf("a post with only synthesized blocks must duplicate, got: %v", err)
	}
	if mutateCalls != 1 || !strings.Contains(string(mutateBody), `"excerpt":"What changes when Barkpark hits 1.0."`) {
		t.Errorf("want one create carrying the content fields; calls=%d body=%s", mutateCalls, mutateBody)
	}
}

func TestDuplicateRefusesAMixOfSynthesizedAndPersistedBlocks(t *testing.T) {
	doc := `{"result": {"_id": "x", "_type": "post", "title": "X",
		"blocks": [{"id": "synth-f-title-0", "type": "field-string"}, {"id": "b7", "type": "paragraph"}]}}`
	var mutateBody []byte
	mutateCalls := 0
	srv := dupServer(t, doc, &mutateBody, &mutateCalls)
	defer srv.Close()

	c := New(Config{BaseURL: srv.URL, Token: "t", Dataset: "production"})
	if _, err := c.Duplicate("post", "x"); err == nil || mutateCalls != 0 {
		t.Fatalf("a persisted block must still refuse before any write; err=%v calls=%d", err, mutateCalls)
	}
}

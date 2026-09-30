package cli

import (
	"bytes"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// Stranger walk (2026-09-30): a Sanity-spelled `"type":"array","of":[{"type":
// "string"}]` field applied with exit 0 and was then read-only in Studio. The
// note names the field and the editable spelling, on stderr only.
func TestSchemaApplyNotesReadonlyFields(t *testing.T) {
	apply := manifest.Command{ID: "schema.apply", Noun: "schema", Verb: "apply", Writes: true}
	// The shape the server echoes for a 2xx apply (serialize_schema_for_sdk).
	stored := []byte(`{"name":"post","fields":[
		{"name":"title","type":"string"},
		{"name":"tags","type":"array","of":[{"type":"string"}]},
		{"name":"meta","type":"object","fields":[{"name":"x","type":"string"}]},
		{"name":"keywords","type":"arrayOf","of":{"type":"string"}},
		{"name":"seo","type":"composite","fields":[]}
	]}`)

	run := func(cmd manifest.Command, status int, body []byte) (string, string) {
		var so, se bytes.Buffer
		emitSchemaReadonlyFieldNote(&writer{stdout: &so, stderr: &se, output: "json"}, cmd, status, body)
		return so.String(), se.String()
	}

	stdout, stderr := run(apply, 200, stored)
	if stdout != "" {
		t.Fatalf("the note must never touch stdout (-o json): %q", stdout)
	}
	for _, want := range []string{
		`field "tags" is type "array"`,
		`{"type":"arrayOf","of":{"type":"string"}}`,
		`field "meta" is type "object"`,
		`{"type":"composite","fields":[…]}`,
	} {
		if !strings.Contains(stderr, want) {
			t.Errorf("stderr = %q, want it to contain %q", stderr, want)
		}
	}
	for _, quiet := range []string{`"keywords"`, `"seo"`, `"title"`} {
		if strings.Contains(stderr, quiet) {
			t.Errorf("an editable field %s must not be noted: %q", quiet, stderr)
		}
	}

	t.Run("a wrapped {result:{schema:…}} echo reads the same", func(t *testing.T) {
		_, se := run(apply, 201, []byte(`{"result":{"schema":{"fields":[{"name":"tags","type":"array","of":[{"type":"string"}]}]}}}`))
		if !strings.Contains(se, `field "tags" is type "array"`) {
			t.Fatalf("stderr = %q", se)
		}
	})

	t.Run("silent on a refusal and on any other command", func(t *testing.T) {
		if _, se := run(apply, 422, stored); se != "" {
			t.Fatalf("a refused apply must add nothing: %q", se)
		}
		if _, se := run(manifest.Command{ID: "schema.get"}, 200, stored); se != "" {
			t.Fatalf("schema get must add nothing: %q", se)
		}
	})

	t.Run("a multi-member list gets the shape with a placeholder", func(t *testing.T) {
		if got := arrayOfSpelling([]any{map[string]any{"type": "a"}, map[string]any{"type": "b"}}); !strings.Contains(got, "<member type>") {
			t.Fatalf("got %q", got)
		}
	})
}

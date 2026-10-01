package cli

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// `bp make schema` suggested an example select field named `status`. A
// document's status lives on its ROW, and the Studio's Classic save drops a
// content field of that name, so a stranger who applied the skeleton lost the
// value on the first unrelated edit (stranger walk, 2026-10-01: "draft" ->
// gone after typing one character into the title).

func TestMakeSchemaSkeletonDeclaresNoStatusField(t *testing.T) {
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	w.output = "json"
	if code := runMakeSchema(w, globals{}, []string{"schema", "recipe"}); code != exitOK {
		t.Fatalf("exit %d: %s", code, stderr.String())
	}
	var doc struct {
		Fields []struct {
			Name string `json:"name"`
			Type string `json:"type"`
		} `json:"fields"`
	}
	if err := json.Unmarshal(stdout.Bytes(), &doc); err != nil {
		t.Fatalf("skeleton is not JSON: %v", err)
	}
	sawSelect := false
	for _, f := range doc.Fields {
		if f.Name == reservedStatusField {
			t.Errorf("the skeleton still declares a content field named %q", f.Name)
		}
		if f.Type == "select" {
			sawSelect = true
		}
	}
	if !sawSelect {
		t.Error("the skeleton lost its select example")
	}
}

func TestSchemaApplyNotesAStatusField(t *testing.T) {
	apply := manifest.Command{ID: "schema.apply", Noun: "schema", Verb: "apply", Writes: true}
	run := func(body string) (string, string) {
		var so, se bytes.Buffer
		emitSchemaReadonlyFieldNote(&writer{stdout: &so, stderr: &se, output: "json"}, apply, 200, []byte(body))
		return so.String(), se.String()
	}

	stdout, stderr := run(`{"name":"recipe","fields":[{"name":"title","type":"string"},{"name":"status","type":"select","options":["a"]}]}`)
	if stdout != "" {
		t.Fatalf("the note must never touch stdout: %q", stdout)
	}
	for _, want := range []string{`field "status" shares its name with the document's own status`, "drops a content field named", `"state"`} {
		if !strings.Contains(stderr, want) {
			t.Errorf("stderr missing %q:\n%s", want, stderr)
		}
	}

	if _, stderr := run(`{"name":"recipe","fields":[{"name":"state","type":"select"}]}`); stderr != "" {
		t.Errorf("a schema without a status field must print nothing, got:\n%s", stderr)
	}
}

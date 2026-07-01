package cli

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestRunMakeSchemaValidJSON asserts `bp make schema <name>` prints valid JSON
// carrying the given name, the expected document type, and a placeholder for
// every supported field type (v1 primitives + the four v2 shapes).
func TestRunMakeSchemaValidJSON(t *testing.T) {
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	w.output = "json"

	if code := runMakeSchema(w, globals{}, []string{"schema", "post"}); code != exitOK {
		t.Fatalf("runMakeSchema exit = %d, want %d; stderr=%s", code, exitOK, stderr.String())
	}

	out := stdout.Bytes()
	var doc map[string]any
	if err := json.Unmarshal(out, &doc); err != nil {
		t.Fatalf("output is not valid JSON: %v\n%s", err, out)
	}
	if doc["name"] != "post" {
		t.Errorf("name = %v, want post", doc["name"])
	}
	if doc["type"] != "document" {
		t.Errorf("type = %v, want document", doc["type"])
	}

	// Every supported field type must appear as a placeholder.
	s := string(out)
	for _, ft := range []string{
		"string", "slug", "text", "richText", "number", "boolean", "datetime",
		"reference", "select", "image",
		"composite", "arrayOf", "codelist", "localizedText",
	} {
		if !strings.Contains(s, `"`+ft+`"`) {
			t.Errorf("skeleton missing %q field-type placeholder", ft)
		}
	}

	// The v2 codelist discriminator placeholder is present.
	if !strings.Contains(s, "<plugin>:<name>") {
		t.Errorf("skeleton missing codelistId placeholder")
	}

	// The v2 localizedText example must include the `languages` key — the server
	// validates it (schema_definition.ex) and codegen reads it, but the scaffold
	// used to omit it so a user never saw the language-slot declaration.
	if !strings.Contains(s, `"languages"`) {
		t.Errorf("skeleton missing localizedText `languages` key:\n%s", s)
	}
}

// TestRunMakeSchemaOutFile asserts `bp make schema <name> --out <file>` writes
// the skeleton to disk and exits 0 (nothing goes to stdout). Regression guard
// for the dropped `-o` alias: `-o` is a global value flag, so only `--out`
// reaches make.
func TestRunMakeSchemaOutFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "post.json")

	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)

	if code := runMakeSchema(w, globals{}, []string{"schema", "post", "--out", path}); code != exitOK {
		t.Fatalf("runMakeSchema exit = %d, want %d; stderr=%s", code, exitOK, stderr.String())
	}
	if stdout.Len() != 0 {
		t.Errorf("--out wrote to stdout: %s", stdout.String())
	}

	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("reading skeleton file: %v", err)
	}
	var doc map[string]any
	if err := json.Unmarshal(data, &doc); err != nil {
		t.Fatalf("skeleton file is not valid JSON: %v\n%s", err, data)
	}
	if doc["name"] != "post" {
		t.Errorf("name = %v, want post", doc["name"])
	}
}

// TestRunMakeSchemaHelp asserts an explicit `--help` (folded into g.help by the
// global parser) exits 0 and prints the usage to stdout, not stderr — an
// explicit help request is never an error.
func TestRunMakeSchemaHelp(t *testing.T) {
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)

	if code := runMakeSchema(w, globals{help: true}, nil); code != exitOK {
		t.Fatalf("runMakeSchema --help exit = %d, want %d", code, exitOK)
	}
	if !strings.Contains(stdout.String(), "usage: bp make schema") {
		t.Errorf("help did not go to stdout:\nstdout=%q\nstderr=%q", stdout.String(), stderr.String())
	}
	if stderr.Len() != 0 {
		t.Errorf("help wrote to stderr: %s", stderr.String())
	}
}

// TestRunMakeSchemaUsage asserts the missing-name / wrong-subnoun paths exit as
// usage errors without printing a body.
func TestRunMakeSchemaUsage(t *testing.T) {
	cases := [][]string{
		{},                 // no sub-noun
		{"schema"},         // no name
		{"widget", "post"}, // wrong sub-noun
	}
	for _, args := range cases {
		var stdout, stderr bytes.Buffer
		w := newWriter(&stdout, &stderr)
		if code := runMakeSchema(w, globals{}, args); code != exitUsage {
			t.Errorf("runMakeSchema(%v) exit = %d, want %d", args, code, exitUsage)
		}
		if stdout.Len() != 0 {
			t.Errorf("runMakeSchema(%v) wrote to stdout on usage error: %s", args, stdout.String())
		}
	}
}

// TestTitleCase pins the dependency-free title helper.
func TestTitleCase(t *testing.T) {
	cases := map[string]string{
		"post":         "Post",
		"blog_post":    "Blog Post",
		"site-setting": "Site Setting",
		"":             "",
	}
	for in, want := range cases {
		if got := titleCase(in); got != want {
			t.Errorf("titleCase(%q) = %q, want %q", in, got, want)
		}
	}
}

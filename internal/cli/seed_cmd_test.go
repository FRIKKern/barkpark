package cli

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// fixtureRawSchema is a raw /v1/schemas-shaped object exercising one field of
// every type the generator handles, including a v2 composite with subfields and
// a pattern-constrained string.
const fixtureRawSchema = `{
  "name": "post",
  "fields": [
    {"name": "title", "type": "string"},
    {"name": "code", "type": "string", "validation": {"pattern": "^[a-z-]+$"}},
    {"name": "slug", "type": "slug"},
    {"name": "body", "type": "text"},
    {"name": "rank", "type": "number"},
    {"name": "featured", "type": "boolean"},
    {"name": "publishedAt", "type": "datetime"},
    {"name": "author", "type": "reference", "refType": "author"},
    {"name": "status", "type": "select", "options": ["draft", "published"]},
    {"name": "cover", "type": "image"},
    {"name": "seo", "type": "composite", "fields": [
      {"name": "metaTitle", "type": "string"},
      {"name": "score", "type": "number"}
    ]},
    {"name": "tags", "type": "arrayOf"},
    {"name": "language", "type": "codelist", "codelistId": "onix:language"},
    {"name": "intro", "type": "localizedText", "format": "plain"}
  ]
}`

func parseFixtureSchema(t *testing.T) seedSchema {
	t.Helper()
	var s seedSchema
	if err := json.Unmarshal([]byte(fixtureRawSchema), &s); err != nil {
		t.Fatalf("parse fixture schema: %v", err)
	}
	return s
}

// TestGenerateDocDeterministicIDs asserts the _id/_type system keys and that
// the id is the deterministic seed-<type>-<n> form (so re-runs overwrite).
func TestGenerateDocDeterministicIDs(t *testing.T) {
	s := parseFixtureSchema(t)
	for n := 1; n <= 3; n++ {
		doc := generateDoc(s, n)
		wantID := "seed-post-" + string(rune('0'+n))
		if doc["_id"] != wantID {
			t.Errorf("doc %d _id = %v, want %v", n, doc["_id"], wantID)
		}
		if doc["_type"] != "post" {
			t.Errorf("doc %d _type = %v, want post", n, doc["_type"])
		}
	}

	// Same n twice yields the same id (idempotent).
	if generateDoc(s, 2)["_id"] != generateDoc(s, 2)["_id"] {
		t.Errorf("generateDoc is not deterministic for the same n")
	}
}

// TestGenerateDocFieldTypes asserts each field gets a value of the correct Go
// (JSON) type for its schema field type.
func TestGenerateDocFieldTypes(t *testing.T) {
	s := parseFixtureSchema(t)
	doc := generateDoc(s, 1)

	if _, ok := doc["title"].(string); !ok {
		t.Errorf("title = %T, want string", doc["title"])
	}
	if _, ok := doc["slug"].(string); !ok {
		t.Errorf("slug = %T, want string", doc["slug"])
	}
	if _, ok := doc["body"].(string); !ok {
		t.Errorf("body = %T, want string", doc["body"])
	}
	if _, ok := doc["rank"].(int); !ok {
		t.Errorf("rank = %T, want int", doc["rank"])
	}
	if _, ok := doc["featured"].(bool); !ok {
		t.Errorf("featured = %T, want bool", doc["featured"])
	}
	if _, ok := doc["publishedAt"].(string); !ok {
		t.Errorf("publishedAt = %T, want string", doc["publishedAt"])
	}

	// reference → {"_ref": "seed-author-1"}.
	ref, ok := doc["author"].(map[string]any)
	if !ok || ref["_ref"] != "seed-author-1" {
		t.Errorf("author = %v, want {_ref: seed-author-1}", doc["author"])
	}

	// select → one of the declared options.
	if doc["status"] != "draft" && doc["status"] != "published" {
		t.Errorf("status = %v, want a declared option", doc["status"])
	}

	// composite → nested object whose subfields carry typed values.
	seo, ok := doc["seo"].(map[string]any)
	if !ok {
		t.Fatalf("seo = %T, want composite map", doc["seo"])
	}
	if _, ok := seo["metaTitle"].(string); !ok {
		t.Errorf("seo.metaTitle = %T, want string", seo["metaTitle"])
	}
	if _, ok := seo["score"].(int); !ok {
		t.Errorf("seo.score = %T, want int (recursed number)", seo["score"])
	}

	// localizedText → language-slot map.
	if loc, ok := doc["intro"].(map[string]any); !ok || loc["nob"] == nil {
		t.Errorf("intro = %v, want localized map with nob slot", doc["intro"])
	}

	// arrayOf without an `of` element shape → empty array (a valid draft).
	if _, ok := doc["tags"].([]any); !ok {
		t.Errorf("tags = %T, want []any", doc["tags"])
	}

	// The whole doc must marshal to JSON cleanly.
	if _, err := json.Marshal(doc); err != nil {
		t.Errorf("generated doc does not marshal: %v", err)
	}
}

// TestFakeValueArrayOfPopulatesFromOf asserts arrayOf generates real elements
// from its `of` element shape (recursing through fakeValue) rather than an empty
// placeholder, falls back to empty when `of` is absent, and handles a composite
// element shape.
func TestFakeValueArrayOfPopulatesFromOf(t *testing.T) {
	withOf := seedField{Name: "tags", Type: "arrayOf", Of: &seedField{Name: "tag", Type: "string"}}
	arr, ok := fakeValue(withOf, 1).([]any)
	if !ok {
		t.Fatalf("arrayOf = %T, want []any", fakeValue(withOf, 1))
	}
	if len(arr) != 2 {
		t.Errorf("arrayOf with of: got %d elements, want 2", len(arr))
	}
	for i, el := range arr {
		if _, isStr := el.(string); !isStr {
			t.Errorf("element %d = %T, want string", i, el)
		}
	}

	// No `of` → empty array (still a valid draft).
	if a, _ := fakeValue(seedField{Name: "tags", Type: "arrayOf"}, 1).([]any); len(a) != 0 {
		t.Errorf("arrayOf without of: got %d elements, want 0", len(a))
	}

	// arrayOf of composite → element objects carrying the declared subfield.
	comp := seedField{Name: "blocks", Type: "arrayOf", Of: &seedField{Type: "composite", Fields: []seedField{{Name: "heading", Type: "string"}}}}
	carr, _ := fakeValue(comp, 1).([]any)
	if len(carr) != 2 {
		t.Fatalf("arrayOf-of-composite: got %d, want 2", len(carr))
	}
	if obj, ok := carr[0].(map[string]any); !ok || obj["heading"] == nil {
		t.Errorf("composite element = %v, want object with heading", carr[0])
	}
}

// TestFakeValueRichTextIsPortableText asserts richText fabricates a Portable
// Text block ARRAY (not a plain string), so the seeded value renders through
// @barkpark/react's PortableText and matches the shape Studio stores. `text`
// stays a plain string — the two must not be conflated.
func TestFakeValueRichTextIsPortableText(t *testing.T) {
	rt, ok := fakeValue(seedField{Name: "body", Type: "richText"}, 1).([]any)
	if !ok {
		t.Fatalf("richText = %T, want []any (Portable Text blocks)", fakeValue(seedField{Name: "body", Type: "richText"}, 1))
	}
	if len(rt) == 0 {
		t.Fatal("richText produced an empty block array")
	}
	block, ok := rt[0].(map[string]any)
	if !ok || block["_type"] != "block" {
		t.Fatalf("richText[0] = %v, want a {_type:'block'} node", rt[0])
	}
	kids, ok := block["children"].([]any)
	if !ok || len(kids) == 0 {
		t.Fatalf("block.children = %v, want a non-empty span array", block["children"])
	}
	span, ok := kids[0].(map[string]any)
	if !ok || span["_type"] != "span" {
		t.Fatalf("children[0] = %v, want a {_type:'span'} node", kids[0])
	}
	if _, ok := span["text"].(string); !ok {
		t.Errorf("span.text = %T, want string", span["text"])
	}
	// It must round-trip through JSON (the wire path seed writes on).
	if _, err := json.Marshal(rt); err != nil {
		t.Errorf("richText block does not marshal: %v", err)
	}

	// `text` must remain a plain string — the two field types are distinct.
	if _, ok := fakeValue(seedField{Name: "summary", Type: "text"}, 1).(string); !ok {
		t.Errorf("text field should stay a plain string, not Portable Text")
	}
}

// TestFakeValuePatternIsSlugSafe asserts a pattern-constrained string field gets
// a slug-safe value (no spaces), so a slug-style regex isn't violated outright.
func TestFakeValuePatternIsSlugSafe(t *testing.T) {
	s := parseFixtureSchema(t)
	doc := generateDoc(s, 1)
	code, ok := doc["code"].(string)
	if !ok {
		t.Fatalf("code = %T, want string", doc["code"])
	}
	for _, r := range code {
		if !(r == '-' || (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9')) {
			t.Errorf("pattern-constrained value %q has non-slug rune %q", code, r)
		}
	}
}

// TestParseCount pins the --count parser.
func TestParseCount(t *testing.T) {
	good := map[string]int{"1": 1, "3": 3, "25": 25}
	for in, want := range good {
		if got, err := parseCount(in); err != nil || got != want {
			t.Errorf("parseCount(%q) = %d,%v, want %d,nil", in, got, err, want)
		}
	}
	for _, bad := range []string{"0", "-1", "x", "1.5", "", "99999999999999999999", "10001"} {
		if _, err := parseCount(bad); err == nil {
			t.Errorf("parseCount(%q): expected error", bad)
		}
	}
}

func TestSeedPublishBody(t *testing.T) {
	body := seedPublishBody([]string{"seed-post-1", "seed-post-2"}, "post")
	var parsed struct {
		Mutations []map[string]map[string]string `json:"mutations"`
	}
	if err := json.Unmarshal(body, &parsed); err != nil {
		t.Fatalf("publish body is not JSON: %v\n%s", err, body)
	}
	if len(parsed.Mutations) != 2 {
		t.Fatalf("got %d publish ops, want 2", len(parsed.Mutations))
	}
	p := parsed.Mutations[0]["publish"]
	if p["id"] != "seed-post-1" || p["type"] != "post" {
		t.Errorf("first publish op = %v, want {id:seed-post-1, type:post}", p)
	}
	if parsed.Mutations[1]["publish"]["id"] != "seed-post-2" {
		t.Errorf("second publish op id = %q, want seed-post-2", parsed.Mutations[1]["publish"]["id"])
	}
}

// TestRunSeedHelp asserts an explicit `--help` (folded into g.help by the global
// parser) exits 0 and prints the usage to stdout, not stderr — it must return
// before any network is touched, so an empty ctx is fine.
func TestRunSeedHelp(t *testing.T) {
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)

	if code := runSeed(w, globals{help: true}, manifest.Context{}, nil); code != exitOK {
		t.Fatalf("runSeed --help exit = %d, want %d", code, exitOK)
	}
	if !strings.Contains(stdout.String(), "usage: bp seed") {
		t.Errorf("help did not go to stdout:\nstdout=%q\nstderr=%q", stdout.String(), stderr.String())
	}
	if stderr.Len() != 0 {
		t.Errorf("help wrote to stderr: %s", stderr.String())
	}
}

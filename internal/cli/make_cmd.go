package cli

import (
	"bytes"
	"encoding/json"
	"os"
	"strings"
)

// runMakeSchema is the `bp make schema <name> [--out <file>]` built-in. It emits
// a schema v2 JSON skeleton — name/title plus a commented placeholder field for
// every supported field type (the v1 primitives plus the four v2 shapes:
// composite / arrayOf / codelist / localizedText) — so authoring a content type
// is fill-the-blanks instead of reading docs/contracts/schema-v2.md. It is a
// PURE local builder: no network, no manifest. Output goes to stdout, or to
// --out <file> when given.
//
// args is everything after the `make` noun (rest[1:] in Execute), i.e. the
// "schema" sub-noun followed by <name> and any flags.
func runMakeSchema(out *writer, args []string) int {
	if len(args) == 0 || args[0] != "schema" {
		usageMake(out)
		return exitUsage
	}

	name := ""
	outFile := ""
	i := 1
	for i < len(args) {
		a := args[i]
		key, inlineVal, hasInline := splitFlagToken(a)
		switch key {
		case "--out":
			v, ni, err := flagValue(args, i, inlineVal, hasInline, "--out")
			if err != nil {
				out.errf("barkpark: %v", err)
				usageMake(out)
				return exitUsage
			}
			outFile = v
			i = ni
		default:
			if strings.HasPrefix(a, "-") && a != "-" {
				out.errf("barkpark: unknown make flag %q", a)
				usageMake(out)
				return exitUsage
			}
			if name == "" {
				name = a
			} else {
				out.errf("barkpark: too many arguments; usage: bp make schema <name>")
				usageMake(out)
				return exitUsage
			}
			i++
		}
	}

	if name == "" {
		out.errf("barkpark: make schema needs a <name>")
		usageMake(out)
		return exitUsage
	}

	skeleton, err := schemaSkeleton(name)
	if err != nil {
		out.errf("barkpark: build skeleton: %v", err)
		return exitGeneric
	}

	if outFile != "" {
		if werr := os.WriteFile(outFile, []byte(skeleton+"\n"), 0o644); werr != nil {
			out.errf("barkpark: write %q: %v", outFile, werr)
			return exitGeneric
		}
		out.errf("wrote %s schema skeleton to %s", name, outFile)
		return exitOK
	}

	out.outf("%s", skeleton)
	return exitOK
}

// skelField is one field in the generated skeleton. encoding/json marshals
// struct fields in declaration order, so the key order below is the order the
// user sees — `_comment` first as the inline guidance, then the field shape.
// Every non-core key is omitempty so each placeholder shows only the keys that
// type actually uses.
type skelField struct {
	Comment    string         `json:"_comment,omitempty"`
	Name       string         `json:"name"`
	Title      string         `json:"title"`
	Type       string         `json:"type"`
	Options    []string       `json:"options,omitempty"`
	RefType    string         `json:"refType,omitempty"`
	Of         *skelField     `json:"of,omitempty"`
	Ordered    *bool          `json:"ordered,omitempty"`
	CodelistID string         `json:"codelistId,omitempty"`
	Languages  []string       `json:"languages,omitempty"`
	Format     string         `json:"format,omitempty"`
	Fallback   []string       `json:"fallbackChain,omitempty"`
	Fields     []skelField    `json:"fields,omitempty"`
	Validation map[string]any `json:"validation,omitempty"`
}

// skel is the top-level skeleton document.
type skel struct {
	Comment string      `json:"_comment"`
	Name    string      `json:"name"`
	Title   string      `json:"title"`
	Type    string      `json:"type"`
	Fields  []skelField `json:"fields"`
}

// schemaSkeleton renders a schema v2 JSON skeleton for the named content type.
// The output is ALWAYS valid JSON (the `_comment` keys carry the human guidance
// that JSON itself cannot) — `bp make schema post | python3 -m json.tool`
// round-trips. Field types covered: string / slug / text / number / boolean /
// datetime / reference / select / image (v1 primitives) plus composite /
// arrayOf / codelist / localizedText (the four v2 shapes, with their
// discriminator keys per docs/contracts/schema-v2.md).
func schemaSkeleton(name string) (string, error) {
	ordered := true
	doc := skel{
		Comment: "schema v2 skeleton — fill the blanks, delete fields/types you don't need, then strip the _comment keys before POSTing to /v1/schemas.",
		Name:    name,
		Title:   titleCase(name),
		Type:    "document",
		Fields: []skelField{
			{
				Comment:    "single-line string; add validation.required / validation.pattern as needed.",
				Name:       "title",
				Title:      "Title",
				Type:       "string",
				Validation: map[string]any{"required": true},
			},
			{
				Comment:    "url-safe identifier; the server validates the slug pattern.",
				Name:       "slug",
				Title:      "Slug",
				Type:       "slug",
				Validation: map[string]any{"required": true},
			},
			{
				Comment: "multi-line plain text; rows hints the editor height.",
				Name:    "body",
				Title:   "Body",
				Type:    "text",
			},
			{
				Comment: "numeric scalar — stored as a real JSON number (not a string).",
				Name:    "rank",
				Title:   "Rank",
				Type:    "number",
			},
			{
				Comment: "true/false toggle.",
				Name:    "featured",
				Title:   "Featured",
				Type:    "boolean",
			},
			{
				Comment: "ISO-8601 timestamp, e.g. 2026-01-31T12:00:00Z.",
				Name:    "publishedAt",
				Title:   "Published At",
				Type:    "datetime",
			},
			{
				Comment: "reference to another document; refType is the target schema name.",
				Name:    "author",
				Title:   "Author",
				Type:    "reference",
				RefType: "author",
			},
			{
				Comment: "single-choice enum; list the allowed values in options.",
				Name:    "status",
				Title:   "Status",
				Type:    "select",
				Options: []string{"draft", "published", "archived"},
			},
			{
				Comment: "media reference (asset id); upload via `bp media upload`.",
				Name:    "cover",
				Title:   "Cover",
				Type:    "image",
			},
			{
				Comment: "v2 composite — a nested object with its own subfields (recurses).",
				Name:    "seo",
				Title:   "SEO",
				Type:    "composite",
				Fields: []skelField{
					{Name: "metaTitle", Title: "Meta Title", Type: "string"},
					{Name: "metaDescription", Title: "Meta Description", Type: "text"},
				},
			},
			{
				Comment: "v2 arrayOf — homogeneous list; `of` is the element shape, `ordered` toggles reorder controls.",
				Name:    "tags",
				Title:   "Tags",
				Type:    "arrayOf",
				Ordered: &ordered,
				Of:      &skelField{Name: "tag", Title: "Tag", Type: "string"},
			},
			{
				Comment:    "v2 codelist — registry-backed enum pinned to an issue; codelistId is `<plugin>:<name>`.",
				Name:       "language",
				Title:      "Language",
				Type:       "codelist",
				CodelistID: "<plugin>:<name>",
			},
			{
				Comment:   "v2 localizedText — multi-language string; `languages` declares the slots, format is plain|rich, fallbackChain orders resolution.",
				Name:      "intro",
				Title:     "Intro",
				Type:      "localizedText",
				Languages: []string{"nob", "eng"},
				Format:    "plain",
				Fallback:  []string{"nob", "eng", "first-non-empty"},
			},
		},
	}

	// SetEscapeHTML(false): keep the `<plugin>:<name>` codelist placeholder
	// readable instead of <-escaped. The output stays valid JSON.
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	enc.SetIndent("", "  ")
	if err := enc.Encode(doc); err != nil {
		return "", err
	}
	return strings.TrimRight(buf.String(), "\n"), nil
}

// titleCase upper-cases the first rune of each space/underscore/dash separated
// word — a tiny, dependency-free Title for the skeleton's display titles.
func titleCase(s string) string {
	repl := strings.NewReplacer("_", " ", "-", " ")
	words := strings.Fields(repl.Replace(s))
	for i, w := range words {
		if w == "" {
			continue
		}
		words[i] = strings.ToUpper(w[:1]) + w[1:]
	}
	if len(words) == 0 {
		return s
	}
	return strings.Join(words, " ")
}

// usageMake prints the make command signature.
func usageMake(out *writer) {
	out.errf("usage: barkpark make schema <name> [--out <file>]")
	out.errf("  emit a schema v2 JSON skeleton (fill-the-blanks) to stdout or a file")
	out.errf("")
	out.errf("flags:")
	out.errf("  --out <file>   write the skeleton to <file> instead of stdout")
	out.errf("")
	out.errf("example: barkpark make schema post > post.schema.json")
}

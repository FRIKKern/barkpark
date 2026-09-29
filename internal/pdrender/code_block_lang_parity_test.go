package pdrender

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/charmbracelet/x/ansi"
)

// The Go leg of the code-block LANGUAGE-FIELD parity lock (task-6e6b2661d201ccc0).
//
// It reads THE SAME FILE the Elixir and JS legs read — not a mirror, the same
// file: api/test/support/fixtures/code-block-lang-parity.json. Before this the
// Go engine read `attrStrFirst(b.Attrs, "language", "lang")`, PREFERRING a
// `language` key BPML never emits, while the BPML kernel / Elixir / JS all spell
// (or ignore) the field as `lang`. The Go engine now reads `lang` only.
//
// Go is the ONE engine that consumes the code-block language at render time: an
// explicit `lang` names the chroma lexer and produces the uppercased lang header
// line. This leg asserts that end-to-end over Render — so a change to the read
// key in code.go (e.g. back to the retired `language`) reds here.
//
// MUTATION PROOF: change the read in code.go from `lang` to the retired
// `language` and TestCodeBlockLangParity reds — the "lang names the lexer" case
// loses its ELIXIR header (the block carries only `lang`), and the
// "retired language key is IGNORED" case gains one.

const codeLangFixture = "../../api/test/support/fixtures/code-block-lang-parity.json"

type codeLangCase struct {
	Name        string         `json:"name"`
	Block       map[string]any `json:"block"`
	Source      string         `json:"source"`
	Lang        string         `json:"lang"`
	LexerHeader string         `json:"lexer_header"`
}

func loadCodeLangDoc(t *testing.T) struct {
	LanguageField string         `json:"language_field"`
	RetiredAlias  string         `json:"retired_alias"`
	Cases         []codeLangCase `json:"cases"`
} {
	t.Helper()
	raw, err := os.ReadFile(filepath.FromSlash(codeLangFixture))
	if err != nil {
		t.Fatalf("shared code-lang fixture unreadable (%s): %v — "+
			"the Elixir and JS legs read the same file", codeLangFixture, err)
	}
	var doc struct {
		LanguageField string         `json:"language_field"`
		RetiredAlias  string         `json:"retired_alias"`
		Cases         []codeLangCase `json:"cases"`
	}
	if err := json.Unmarshal(raw, &doc); err != nil {
		t.Fatalf("shared code-lang fixture is not valid JSON: %v", err)
	}
	return doc
}

// The spelling contract itself, asserted directly against the shared fixture, so
// a rename of the field reds all three legs at once.
func TestCodeBlockLangContractSpelling(t *testing.T) {
	doc := loadCodeLangDoc(t)
	if doc.LanguageField != "lang" {
		t.Errorf("the code-block language field is `lang`; fixture says %q", doc.LanguageField)
	}
	if doc.RetiredAlias != "language" {
		t.Errorf("the retired alias is `language`; fixture says %q", doc.RetiredAlias)
	}
	if len(doc.Cases) < 3 {
		t.Fatalf("the shared fixture must keep covering lang / no-lang / retired-alias, got %d cases", len(doc.Cases))
	}
}

func TestCodeBlockLangParity(t *testing.T) {
	// A wide, no-color render: the lang header line is emitted independent of the
	// color profile, and ansi.Strip leaves the plain uppercased lexer name.
	ctx := RenderCtx{Width: 100, Theme: DarkTheme(), Profile: NoColor}

	for _, c := range loadCodeLangDoc(t).Cases {
		c := c
		t.Run(c.Name, func(t *testing.T) {
			cr := newCodeRenderer()
			lines := cr.Render(Block{Type: "code", Attrs: c.Block}, ctx)
			out := ansi.Strip(strings.Join(lines, "\n"))

			// Every case carries real source, so the block always renders.
			if len(lines) == 0 {
				t.Fatalf("case %q: expected content, got an EMPTY render", c.Name)
			}
			if !strings.Contains(out, c.Source) {
				t.Fatalf("case %q: expected source %q in the render, got:\n%q", c.Name, c.Source, out)
			}

			// The discriminating assertion: an explicit `lang` produces the
			// uppercased lexer header; no `lang` (whether the block is bare or
			// carries the retired `language` key) does NOT force that header.
			if c.LexerHeader != "" {
				if !strings.Contains(out, c.LexerHeader) {
					t.Fatalf("case %q: expected the %q lang header (lang=%q was read), got:\n%q",
						c.Name, c.LexerHeader, c.Lang, out)
				}
			} else {
				if strings.Contains(out, "ELIXIR") {
					t.Fatalf("case %q: the render forced an ELIXIR header from a key that is NOT `lang` "+
						"(the retired `language` alias must be ignored), got:\n%q", c.Name, out)
				}
			}
		})
	}
}

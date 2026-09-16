package taskboard

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

// The PRODUCER leg of the code-block LANGUAGE-FIELD lock (task-bff484e54b711fb2).
//
// internal/pdrender/code_block_lang_parity_test.go locks the READER: it proves
// the Go render engine consumes `lang` and ignores the retired `language`. Three
// engines share that lock. Nothing locked the WRITERS — and a writer is what
// regressed. PR #18214 repaired two defects wearing one symptom:
//
//	(1) internal/taskboard/mdlite.go's codeBlock/2 still wrote attrs["language"],
//	    so every fenced block composed through mdlite lost its language; and
//	(2) paper_test.go's inline PortableDoc fixture — the INPUT to
//	    TestComposePaperGolden and TestRenderPaperFrameGolden80 — authored
//	    "language", so the golden's expected BASH header could never render
//	    whatever the renderer did.
//
// Four golden tests went red on clean main and stayed red for a round. The
// danger in that shape is the REMEDY, not the failure: a loud byte diff on a
// .txt golden invites "regenerate the baseline", which would have laundered a
// live renderer regression into an approved snapshot. Neither golden was stale.
//
// This file makes the CAUSE red before the goldens do, and says so in the
// failure message. It reads the SAME file the three reader legs read — not a
// mirror, the same file — so the key names here are a PREDICATE against the
// contract, never a second hand-written copy that can drift with the producer it
// is supposed to guard. mdlite_test.go's "lang"/"language" literals could both
// be edited alongside a producer change and stay green; these cannot.
//
// go-tests.yml already dispatches the Go leg on an edit to this fixture, so a
// contract rename reds this leg on the PR that makes it.
//
// MUTATION PROOF (re-run it if you touch either arm):
//   - mdlite.go: write attrs[<retired alias>] instead of attrs["lang"] →
//     TestMdliteWritesTheContractLanguageField reds, naming the alias.
//   - paper_test.go fixtureBlocks: spell the code block's key "language" →
//     TestGoldenPaperFixtureUsesTheContractLanguageField reds, and it reds
//     BEFORE the golden byte-diff, which is the point.

const codeLangContractFixture = "../../api/test/support/fixtures/code-block-lang-parity.json"

type codeLangContract struct {
	LanguageField string `json:"language_field"`
	RetiredAlias  string `json:"retired_alias"`
}

func loadCodeLangContract(t *testing.T) codeLangContract {
	t.Helper()
	raw, err := os.ReadFile(filepath.FromSlash(codeLangContractFixture))
	if err != nil {
		t.Fatalf("shared code-lang contract unreadable (%s): %v — "+
			"the pdrender, Elixir and JS legs read the same file",
			codeLangContractFixture, err)
	}
	var doc codeLangContract
	if err := json.Unmarshal(raw, &doc); err != nil {
		t.Fatalf("shared code-lang contract is not valid JSON: %v", err)
	}
	if doc.LanguageField == "" || doc.RetiredAlias == "" {
		t.Fatalf("contract must declare both language_field and retired_alias, got %+v", doc)
	}
	if doc.LanguageField == doc.RetiredAlias {
		t.Fatalf("language_field and retired_alias are the same key (%q) — "+
			"the contract can no longer discriminate", doc.LanguageField)
	}
	return doc
}

// mdlite is a taskboard-side PRODUCER of pdrender code blocks. It must author
// the field the render engines actually read.
func TestMdliteWritesTheContractLanguageField(t *testing.T) {
	c := loadCodeLangContract(t)

	for _, tc := range []struct {
		name string
		src  string
		want string // expected value under the contract field; "" = key absent
	}{
		{"fenced with an info string", "```go\nfmt.Println(1)\n```", "go"},
		{"fenced with a different lexer", "```bash\necho hi\n```", "bash"},
		{"bare fence carries no language", "```\nplain\n```", ""},
	} {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			blocks := MarkdownBlocks(tc.src)
			if len(blocks) != 1 || blocks[0].Type != "code" {
				t.Fatalf("→ %#v, want exactly one code block", blocks)
			}
			attrs := blocks[0].Attrs

			// The retired alias must never appear, whatever the value.
			if v, ok := attrs[c.RetiredAlias]; ok {
				t.Errorf("mdlite wrote the RETIRED alias %q=%v. No render engine reads it "+
					"(see %s), so the language is silently lost and every fenced-code golden "+
					"drifts. Write %q instead — do NOT regenerate the goldens.",
					c.RetiredAlias, v, codeLangContractFixture, c.LanguageField)
			}

			got, present := attrs[c.LanguageField].(string)
			if tc.want == "" {
				if present {
					t.Errorf("bare fence wrote %s=%q, want the key omitted", c.LanguageField, got)
				}
				return
			}
			if !present {
				t.Fatalf("mdlite omitted the contract field %q; attrs=%#v", c.LanguageField, attrs)
			}
			if got != tc.want {
				t.Errorf("%s = %q, want %q", c.LanguageField, got, tc.want)
			}
		})
	}
}

// The paper goldens' own INPUT is a producer too. This is the half that made
// TestComposePaperGolden and TestRenderPaperFrameGolden80 unfixable by staring
// at the renderer: the fixture authored a key nothing reads, so the expected
// output could never be produced no matter what the renderer did.
func TestGoldenPaperFixtureUsesTheContractLanguageField(t *testing.T) {
	c := loadCodeLangContract(t)

	var blocks []map[string]any
	if err := json.Unmarshal([]byte(fixtureBlocks), &blocks); err != nil {
		t.Fatalf("the golden paper fixture is not valid JSON: %v", err)
	}

	codeBlocks := 0
	for i, b := range blocks {
		if b["type"] != "code" {
			continue
		}
		codeBlocks++
		if v, ok := b[c.RetiredAlias]; ok {
			t.Errorf("fixtureBlocks[%d] authors the RETIRED alias %q=%v. The render engines "+
				"read %q (see %s), so this block renders with NO language and the paper "+
				"goldens can never match their expected header. Fix the FIXTURE — "+
				"regenerating the golden would bake the loss in.",
				i, c.RetiredAlias, v, c.LanguageField, codeLangContractFixture)
		}
		if _, ok := b[c.LanguageField].(string); !ok {
			t.Errorf("fixtureBlocks[%d] carries no %q; the goldens then pin a language-less "+
				"render and stop exercising the lexer header at all", i, c.LanguageField)
		}
	}
	if codeBlocks == 0 {
		t.Fatalf("the golden paper fixture no longer contains a code block — the paper "+
			"goldens stopped covering the field this lock guards; restore one or retire this test")
	}
}

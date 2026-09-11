package pdrender

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/charmbracelet/x/ansi"
)

// The Go leg of the code-block SOURCE-FIELD parity lock (task-e9af9f95d290307d).
//
// It reads THE SAME FILE the Elixir leg reads — not a mirror, the same file:
// api/test/support/fixtures/code-source-aliases.json. A mirror pair drifts the
// moment one side is regenerated and the other is not, which is precisely the
// class of bug this task closes (this renderer read `code`||`value`, compose.ex
// read `value`, and nothing ever compared them).
//
// Each engine asserts the property in its NATIVE output: Elixir over the
// composed HTML, this leg over the stripped-ANSI lines the code renderer emits.
// The shared truth is CONTENT PRESENCE plus WHICH source the contract selects.
//
// DRIFT PROOF: reorder or shorten codeSourceKeys in code.go and the shapes below
// red here while the Elixir leg stays green — and vice versa. Neither engine can
// move alone.

const codeSourceFixture = "../../api/test/support/fixtures/code-source-aliases.json"

type codeSourceCase struct {
	Name           string         `json:"name"`
	Block          map[string]any `json:"block"`
	ContentPresent bool           `json:"content_present"`
	Source         string         `json:"source"`
}

func loadCodeSourceCases(t *testing.T) []codeSourceCase {
	t.Helper()
	raw, err := os.ReadFile(filepath.FromSlash(codeSourceFixture))
	if err != nil {
		t.Fatalf("shared code-source fixture unreadable (%s): %v — "+
			"api/test/.../code_source_alias_parity_test.exs reads the same file", codeSourceFixture, err)
	}
	var doc struct {
		AcceptedKeys []string         `json:"accepted_keys"`
		Cases        []codeSourceCase `json:"cases"`
	}
	if err := json.Unmarshal(raw, &doc); err != nil {
		t.Fatalf("shared code-source fixture is not valid JSON: %v", err)
	}
	if len(doc.Cases) < 10 {
		t.Fatalf("shared fixture must keep covering code-only / value-only / both / blank / missing, got %d cases", len(doc.Cases))
	}
	// The accepted-key list in the fixture IS the contract; this renderer must
	// read exactly it, in exactly that order.
	if strings.Join(doc.AcceptedKeys, ",") != strings.Join(codeSourceKeys, ",") {
		t.Errorf("codeSourceKeys drifted from the shared contract:\n  code.go: %v\n  fixture: %v",
			codeSourceKeys, doc.AcceptedKeys)
	}
	return doc.Cases
}

func TestCodeSourceAliasParity(t *testing.T) {
	ctx := RenderCtx{Width: 100, Theme: DarkTheme(), Profile: NoColor}

	for _, c := range loadCodeSourceCases(t) {
		c := c
		t.Run(c.Name, func(t *testing.T) {
			cr := newCodeRenderer()
			lines := cr.Render(Block{Type: "code", Attrs: c.Block}, ctx)
			out := ansi.Strip(strings.Join(lines, "\n"))

			if !c.ContentPresent {
				if len(lines) != 0 {
					t.Fatalf("expected NO content for %q, got %d line(s):\n%q", c.Name, len(lines), out)
				}
				return
			}

			if len(lines) == 0 {
				t.Fatalf("expected content for %q, got an EMPTY render — "+
					"this is the hollow-render shape the task closes", c.Name)
			}
			if !strings.Contains(out, c.Source) {
				t.Fatalf("expected source %q in the render of %q, got:\n%q", c.Source, c.Name, out)
			}
		})
	}
}

// The selector itself, asserted directly against the shared fixture, so a
// failure points at the precedence rule rather than at chroma's output.
func TestCodeSourceSelectorMatchesSharedFixture(t *testing.T) {
	for _, c := range loadCodeSourceCases(t) {
		got := codeSource(c.Block)
		want := c.Source
		if !c.ContentPresent {
			if strings.TrimSpace(got) != "" {
				t.Errorf("%s: expected no selected source, got %q", c.Name, got)
			}
			continue
		}
		if strings.TrimSpace(got) != strings.TrimSpace(want) {
			t.Errorf("%s: codeSource selected %q, contract says %q", c.Name, got, want)
		}
	}
}

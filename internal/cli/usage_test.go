package cli

import (
	"bytes"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

func TestUsageCommandShowsArgSummaries(t *testing.T) {
	cmd := manifest.Command{
		Noun:    "task",
		Verb:    "show",
		Summary: "Show a task by id.",
		Args: []manifest.Arg{
			{Name: "id", Required: true, Type: "string", Summary: "Task document id."},
			{Name: "depth", Required: false, Type: "int", Summary: "How many child levels to include."},
		},
		Flags: []manifest.Flag{
			{Name: "json", Summary: "Emit JSON."},
		},
	}

	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	usageCommand(w, cmd)
	out := stderr.String()

	// Signature still shows required/optional markers.
	for _, want := range []string{"usage: barkpark task show <id> [depth]", "Show a task by id."} {
		if !strings.Contains(out, want) {
			t.Errorf("usage missing %q:\n%s", want, out)
		}
	}
	// The new arguments block surfaces each arg's summary (the regression this
	// locks: the manifest carries them but usageCommand used to drop them).
	for _, want := range []string{"arguments:", "id", "Task document id.", "depth", "How many child levels to include."} {
		if !strings.Contains(out, want) {
			t.Errorf("usage missing arg detail %q:\n%s", want, out)
		}
	}
	// Flags block still renders.
	if !strings.Contains(out, "flags:") || !strings.Contains(out, "Emit JSON.") {
		t.Errorf("usage missing flags block:\n%s", out)
	}
}

func TestUsageCommandNoArgumentsBlockWhenNoSummaries(t *testing.T) {
	// Args with no summaries must NOT produce an empty "arguments:" header.
	cmd := manifest.Command{
		Noun: "doc",
		Verb: "get",
		Args: []manifest.Arg{{Name: "id", Required: true, Type: "string"}},
	}
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	usageCommand(w, cmd)
	if strings.Contains(stderr.String(), "arguments:") {
		t.Errorf("summary-less args should not render an arguments block:\n%s", stderr.String())
	}
}

func TestLevenshtein(t *testing.T) {
	cases := []struct {
		a, b string
		want int
	}{
		{"", "", 0},
		{"a", "", 1},
		{"", "abc", 3},
		{"kitten", "sitting", 3},
		{"doctor", "doctor", 0},
		{"doctr", "doctor", 1},
		{"scema", "schema", 1},
	}
	for _, c := range cases {
		if got := levenshtein(c.a, c.b); got != c.want {
			t.Errorf("levenshtein(%q,%q) = %d, want %d", c.a, c.b, got, c.want)
		}
	}
}

func TestNearestNoun(t *testing.T) {
	nouns := []string{"doc", "schema", "media", "doctor", "task", "workspace", "search"}

	// Close typos → a suggestion.
	for _, c := range []struct{ typed, want string }{
		{"doctr", "doctor"},
		{"scema", "schema"},
		{"workspce", "workspace"},
		{"serach", "search"},
	} {
		got, ok := nearestNoun(c.typed, nouns)
		if !ok || got != c.want {
			t.Errorf("nearestNoun(%q) = %q,%v; want %q,true", c.typed, got, ok, c.want)
		}
	}

	// Unrelated / too-distant input → no misleading hint.
	for _, typed := range []string{"xyzzy", "completelyoff", "z"} {
		if got, ok := nearestNoun(typed, nouns); ok {
			t.Errorf("nearestNoun(%q) = %q,true; want no suggestion", typed, got)
		}
	}
}

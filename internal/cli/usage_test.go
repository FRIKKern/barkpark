package cli

import "testing"

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

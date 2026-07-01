package cli

import "testing"

// The tinker REPL's unknown-command hint reuses the CLI's nearestToken matcher,
// so a mistyped command suggests the closest real one; an unrelated word gets no
// misleading hint.
func TestTinkerSuggest(t *testing.T) {
	for _, c := range []struct{ typed, want string }{
		{"quer", "query"},
		{"muate", "mutate"},
		{"scemas", "schemas"},
		{"prespective", "perspective"},
	} {
		got, ok := tinkerSuggest(c.typed)
		if !ok || got != c.want {
			t.Errorf("tinkerSuggest(%q) = %q,%v; want %q,true", c.typed, got, ok, c.want)
		}
	}

	for _, typed := range []string{"xyzzy", "completelyoff"} {
		if got, ok := tinkerSuggest(typed); ok {
			t.Errorf("tinkerSuggest(%q) = %q,true; want no suggestion", typed, got)
		}
	}
}

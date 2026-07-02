package pdrender

import "testing"

// markHref resolves a link mark's href: nested attrs.href wins, else a
// top-level href, else "". It feeds the OSC-8 hyperlink path (sanitizeURL),
// so a wrong lookup would drop or mis-target terminal links.
func TestMarkHref(t *testing.T) {
	cases := []struct {
		name string
		in   any
		want string
	}{
		{"nested attrs.href", map[string]any{"attrs": map[string]any{"href": "https://x"}}, "https://x"},
		{"top-level href (no attrs)", map[string]any{"href": "https://y"}, "https://y"},
		{"attrs present but empty href → top-level fallback", map[string]any{"attrs": map[string]any{"href": ""}, "href": "https://z"}, "https://z"},
		{"attrs present, no href key → top-level fallback", map[string]any{"attrs": map[string]any{"title": "t"}, "href": "https://w"}, "https://w"},
		{"neither → empty", map[string]any{"foo": "bar"}, ""},
		{"non-map input → empty", "not a map", ""},
		{"nil → empty", nil, ""},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := markHref(tc.in); got != tc.want {
				t.Errorf("markHref(%v) = %q, want %q", tc.in, got, tc.want)
			}
		})
	}
}

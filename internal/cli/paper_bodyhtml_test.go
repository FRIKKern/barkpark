package cli

import (
	"strings"
	"testing"
)

// htmlToPlainText renders a paper's body_html into a legible plain-text dump:
// block-level tags become line breaks, inline tags are stripped, common
// entities are decoded, and blank runs collapse. It is the fallback for
// body_html-only papers (soc2-controls-mapping et al.) — the goal is legible
// content, not HTML fidelity.
func TestHTMLToPlainText(t *testing.T) {
	cases := []struct {
		name string
		in   string
		want string
	}{
		{
			name: "empty and whitespace return empty",
			in:   "   \n\t ",
			want: "",
		},
		{
			name: "all-tag input returns empty",
			in:   "<div><span></span></div>",
			want: "",
		},
		{
			name: "heading and paragraph become separate lines",
			in:   "<h1>Title</h1>\n<p>Body text.</p>",
			want: "Title\n\nBody text.",
		},
		{
			name: "inline formatting is stripped, text kept",
			in:   "<p>A <strong>bold</strong> and <em>italic</em> word.</p>",
			want: "A bold and italic word.",
		},
		{
			name: "entities are decoded",
			in:   "<p>Barkpark&#39;s controls &amp; evidence &mdash; ready.</p>",
			want: "Barkpark's controls & evidence — ready.",
		},
		{
			name: "list items each get a line",
			in:   "<ul><li>one</li><li>two</li></ul>",
			want: "one\ntwo",
		},
		{
			name: "br is a line break",
			in:   "line one<br>line two",
			want: "line one\nline two",
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := htmlToPlainText(tc.in)
			if got != tc.want {
				t.Errorf("htmlToPlainText(%q)\n got: %q\nwant: %q", tc.in, got, tc.want)
			}
		})
	}
}

// A real-shaped body_html fragment must render without run-on lines and without
// stray tags surviving into the output.
func TestHTMLToPlainTextNoResidualTags(t *testing.T) {
	got := htmlToPlainText(`<h1>SOC 2</h1>
<p><em>Evidence-prep artifact</em> mapping controls.</p>
<table><tr><td>A</td><td>B</td></tr></table>`)
	if strings.ContainsAny(got, "<>") {
		t.Errorf("residual tag chars in output: %q", got)
	}
	if !strings.Contains(got, "SOC 2") || !strings.Contains(got, "Evidence-prep artifact") {
		t.Errorf("expected content missing: %q", got)
	}
}

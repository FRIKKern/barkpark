package cli

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/charmbracelet/x/ansi"
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
			name: "entities decode exactly once",
			in:   "<p>A &amp;amp; B &amp; C</p>",
			want: "A &amp; B & C",
		},
		{
			name: "code and pre entities remain literal",
			in:   "<p>A &amp; B</p><pre>&amp;lt;tag&amp;gt;</pre><p><code>&amp;amp;</code></p>",
			want: "A & B\n&amp;lt;tag&amp;gt;\n&amp;amp;",
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

func TestRunPaperViewWrapsLegacyHTMLAtExplicitWidth(t *testing.T) {
	var requests []string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests = append(requests, r.URL.RequestURI())
		w.Header().Set("content-type", "application/json")
		_, _ = w.Write([]byte(`{"id":"legacy-width","title":"Legacy","source":{"kind":"html","html":"<h1>Legacy &amp;amp; width</h1><p>alpha beta gamma delta epsilon zeta eta theta iota kappa lambda</p>"}}`))
	}))
	defer srv.Close()

	var stdout, stderr bytes.Buffer
	out := newWriter(&stdout, &stderr)
	code := runPaperView(out, globals{}, []string{srv.URL + "/papers/legacy-width", "--width", "20", "--profile", "none"})
	if code != exitOK {
		t.Fatalf("runPaperView exit = %d, stderr=%q", code, stderr.String())
	}
	got := strings.TrimSuffix(stdout.String(), "\n")
	for i, line := range strings.Split(got, "\n") {
		if width := ansi.StringWidth(line); width > 20 {
			t.Errorf("line %d width %d > 20: %q", i, width, line)
		}
	}
	if !strings.Contains(got, "Legacy &amp; width") {
		t.Errorf("legacy semantic entity did not decode exactly once: %q (requests=%v, stderr=%q)", got, requests, stderr.String())
	}
	if !strings.Contains(got, "alpha") || !strings.Contains(got, "lambda") {
		t.Errorf("legacy wrapping lost authored tokens: %q", got)
	}
	if len(requests) != 1 || !strings.Contains(requests[0], "/d/production/papers/legacy-width/source") {
		t.Fatalf("rendered mode did not use canonical source: requests=%v", requests)
	}
}

func TestWrapPaperPlainTextResolvedWidths(t *testing.T) {
	text := htmlToPlainText(`<h1>Width boundary</h1><p>alpha beta gamma delta epsilon zeta eta theta iota kappa lambda</p>`)
	for _, width := range []int{20, 40, 80} {
		got := wrapPaperPlainText(text, width)
		for i, line := range strings.Split(got, "\n") {
			if gotWidth := ansi.StringWidth(line); gotWidth > width {
				t.Errorf("width %d line %d = %d columns: %q", width, i, gotWidth, line)
			}
		}
		if !strings.Contains(got, "Width boundary") || !strings.Contains(got, "alpha") || !strings.Contains(got, "lambda") {
			t.Errorf("width %d lost authored tokens: %q", width, got)
		}
		if !strings.HasPrefix(got, "Width boundary\n") {
			t.Errorf("width %d lost heading/paragraph boundary: %q", width, got)
		}
	}
}

func TestWrapPaperPlainTextHardBoundsPunctuationHeavyLegacyLine(t *testing.T) {
	text := "One follow-up commit on stw6-deployrunner-reattach's -r branch: added .bp-site-deploy-runs/ to .gitignore. The DeployRunner run-state dir defaults under the repo root so init/1 re-attaches across a restart — but on a prod box the repo root IS the deploy checkout's git tree, and git pull is the deploy. Without the ignore, every run leaves untracked manifests/status/logs (and, transiently, 0600 token env files) littering that tree. Not a correctness bug; a hygiene/safety tidy on the owning slice. Slice-2 gate re-run green (42/0) after the change; the -r branch is pushed."
	got := wrapPaperPlainText(text, 80)
	for i, line := range strings.Split(got, "\n") {
		if width := ansi.StringWidth(line); width > 80 {
			t.Errorf("line %d width %d > 80: %q", i, width, line)
		}
	}
	plain := strings.ReplaceAll(got, "\n", " ")
	if !strings.Contains(plain, "Slice-2 gate re-run green (42/0)") || !strings.HasSuffix(plain, "branch is pushed.") {
		t.Errorf("legacy hard boundary lost authored text: %q", got)
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

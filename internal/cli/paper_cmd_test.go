package cli

import (
	"strings"
	"testing"
)

// A mistyped --perspective/--theme/--profile VALUE must be rejected by
// parsePaperArgs rather than captured verbatim — every resolver silently falls
// back (perspective → published, theme → auto, profile → auto), so an unchecked
// typo (e.g. singular "draft") would render the PUBLISHED paper instead of the
// caller's draft. Unknown flag NAMES already error; this covers unknown VALUES.
func TestParsePaperArgsRejectsInvalidValues(t *testing.T) {
	cases := []struct {
		name string
		args []string
		want string // substring the returned error must contain
	}{
		{"perspective typo", []string{"x", "--perspective", "draft"}, "invalid --perspective"},
		{"perspective empty", []string{"x", "--perspective", ""}, "invalid --perspective"},
		{"perspective mixed case", []string{"x", "--perspective", "Published"}, "invalid --perspective"},
		{"theme typo", []string{"x", "--theme", "solarized"}, "invalid --theme"},
		{"theme empty", []string{"x", "--theme", ""}, "invalid --theme"},
		{"profile typo", []string{"x", "--profile", "ansi9000"}, "invalid --profile"},
		{"profile empty", []string{"x", "--profile", ""}, "invalid --profile"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			_, err := parsePaperArgs(tc.args)
			if err == nil {
				t.Fatalf("parsePaperArgs(%v) = nil error, want one containing %q", tc.args, tc.want)
			}
			if !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("error = %q, want it to contain %q", err.Error(), tc.want)
			}
		})
	}
}

// Every valid alias the resolvers accept — including the numeric/short spellings
// (16, 256, 24bit), mixed case, and surrounding spaces the ToLower/TrimSpace
// normalization tolerates — must parse clean and round-trip verbatim into the
// parsed struct (the resolver re-normalizes downstream).
func TestParsePaperArgsAcceptsValidValues(t *testing.T) {
	perspectives := []string{"published", "drafts", "raw"}
	for _, v := range perspectives {
		t.Run("perspective/"+v, func(t *testing.T) {
			p, err := parsePaperArgs([]string{"x", "--perspective", v})
			if err != nil {
				t.Fatalf("parsePaperArgs(--perspective %q) = %v, want nil", v, err)
			}
			if p.perspective != v {
				t.Fatalf("perspective = %q, want %q", p.perspective, v)
			}
		})
	}

	themes := []string{"dark", "light", "auto", "Dark", "  light  "}
	for _, v := range themes {
		t.Run("theme/"+v, func(t *testing.T) {
			p, err := parsePaperArgs([]string{"x", "--theme", v})
			if err != nil {
				t.Fatalf("parsePaperArgs(--theme %q) = %v, want nil", v, err)
			}
			if p.theme != v {
				t.Fatalf("theme = %q, want %q (values round-trip verbatim)", p.theme, v)
			}
		})
	}

	profiles := []string{
		"auto", "none", "nocolor", "no-color", "plain",
		"ansi16", "16", "ansi256", "256", "truecolor", "24bit", "rgb",
		"ANSI256", "  truecolor  ",
	}
	for _, v := range profiles {
		t.Run("profile/"+v, func(t *testing.T) {
			p, err := parsePaperArgs([]string{"x", "--profile", v})
			if err != nil {
				t.Fatalf("parsePaperArgs(--profile %q) = %v, want nil", v, err)
			}
			if p.profile != v {
				t.Fatalf("profile = %q, want %q (values round-trip verbatim)", p.profile, v)
			}
		})
	}
}

// A full valid parse round-trips every flag plus the positional slug.
func TestParsePaperArgsFullRoundTrip(t *testing.T) {
	p, err := parsePaperArgs([]string{
		"my-slug",
		"--theme", "dark",
		"--perspective", "drafts",
		"--profile", "truecolor",
		"--width", "120",
		"-s", "prod",
	})
	if err != nil {
		t.Fatalf("parsePaperArgs full = %v, want nil", err)
	}
	if p.slug != "my-slug" {
		t.Fatalf("slug = %q, want %q", p.slug, "my-slug")
	}
	if p.theme != "dark" {
		t.Fatalf("theme = %q, want dark", p.theme)
	}
	if p.perspective != "drafts" {
		t.Fatalf("perspective = %q, want drafts", p.perspective)
	}
	if p.profile != "truecolor" {
		t.Fatalf("profile = %q, want truecolor", p.profile)
	}
	if !p.widthSet || p.width != 120 {
		t.Fatalf("width = %d (set=%v), want 120 (set)", p.width, p.widthSet)
	}
	if p.server != "prod" {
		t.Fatalf("server = %q, want prod", p.server)
	}
}

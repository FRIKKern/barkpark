package cli

// "--" ends the flags (task-379127ebdf341017). A task title that starts with
// "--" ("--perspective") was read as a flag by every parser it passed through,
// so the may-have-landed hint, pasted into a shell, searched for something else
// or failed, and `bp task create` could not file such a title positionally.

import (
	"net/url"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

func TestAmbiguousHintFindsATitleThatStartsWithDashes(t *testing.T) {
	for _, title := range []string{"--perspective", "--yes", "-o json", "plain title"} {
		check := ambiguousWrite{title: title}.checkCommand()
		words := shellWords(t, strings.TrimPrefix(check, "bp "))

		// The binary's own order: the global flags first, then the command's.
		_, rest, err := parseGlobals(words)
		if err != nil {
			t.Fatalf("%q: the global flags refuse the pasted hint: %v", check, err)
		}
		if len(rest) < 2 || rest[0] != "search" || rest[1] != "query" {
			t.Fatalf("%q: the globals left %q, want search query …", check, rest)
		}
		m, _ := loadFixtureTree(t)
		ctx := manifest.Context{Server: "http://example.invalid", Dataset: "production", Token: "tok"}
		req, derr := buildManifestRequest(globals{}, ctx, m, searchQueryLiveShape(), rest[2:], false)
		if derr != nil {
			t.Fatalf("%q: the pasted hint does not build: %v", check, derr)
		}
		u, _ := url.Parse(req.url)
		if got := u.Query().Get("q"); got != title {
			t.Errorf("%q searches for %q, want the title %q", check, got, title)
		}
		if got := u.Query().Get("perspective"); got != "drafts" {
			t.Errorf("%q reads perspective %q, want drafts", check, got)
		}
	}
}

func TestSplitArgsTakesEverythingAfterDashDashAsPositional(t *testing.T) {
	pos, flags, err := splitArgs(searchQueryLiveShape(), []string{"--perspective", "drafts", "--", "--limit", "-f"})
	if err != nil {
		t.Fatalf("splitArgs: %v", err)
	}
	if strings.Join(pos, "|") != "--limit|-f" {
		t.Errorf("positional = %q, want [--limit -f]", pos)
	}
	if got := flags["perspective"]; len(got) != 1 || got[0] != "drafts" {
		t.Errorf("--perspective before -- = %q, want [drafts]", got)
	}
	if _, set := flags["limit"]; set {
		t.Errorf("--limit after -- was read as a flag")
	}
}

func TestParseGlobalsLeavesEverythingAfterDashDashAlone(t *testing.T) {
	g, rest, err := parseGlobals([]string{"--yes", "task", "create", "--", "--yes", "-o", "json"})
	if err != nil {
		t.Fatalf("parseGlobals: %v", err)
	}
	if !g.yes {
		t.Errorf("--yes before -- was not read")
	}
	if g.output != "" {
		t.Errorf("-o after -- set the output to %q", g.output)
	}
	if want := "task|create|--|--yes|-o|json"; strings.Join(rest, "|") != want {
		t.Errorf("rest = %q, want %q", strings.Join(rest, "|"), want)
	}
}

func TestProseFilesLeaveEverythingAfterDashDashAlone(t *testing.T) {
	// "--title-file" after "--" is a title, not a file to read.
	got, err := resolveProseTextFiles([]string{"--", "--title-file", "x"}, nil, func(string, ...any) {})
	if err != nil {
		t.Fatalf("resolveProseTextFiles: %v", err)
	}
	if strings.Join(got, "|") != "--|--title-file|x" {
		t.Errorf("resolved tail = %q, want it unchanged", got)
	}
}

func TestTaskCreateTakesATitleAfterDashDash(t *testing.T) {
	body, publish, err := parseTaskCreateArgs([]string{"--publish", "--", "--perspective"})
	if err != nil {
		t.Fatalf("parseTaskCreateArgs: %v", err)
	}
	if body["title"] != "--perspective" || !publish {
		t.Errorf("title = %q, publish = %v; want --perspective and true", body["title"], publish)
	}
}

// A flag that takes a value takes the next argument even when it is "--", as
// parseGlobals does: "--" ends the flags only where a flag could start
// (task-27104d204de9620e).
func TestTaskCreateFlagValueMayBeDashDash(t *testing.T) {
	body, _, err := parseTaskCreateArgs([]string{"T", "--description", "--"})
	if err != nil {
		t.Fatalf("parseTaskCreateArgs: %v", err)
	}
	if body["title"] != "T" || body["description"] != "--" {
		t.Errorf("title = %q, description = %q; want T and --", body["title"], body["description"])
	}
}

func TestSplitArgsFlagValueMayBeDashDash(t *testing.T) {
	pos, flags, err := splitArgs(searchQueryLiveShape(), []string{"q", "--perspective", "--", "--", "--limit"})
	if err != nil {
		t.Fatalf("splitArgs: %v", err)
	}
	if got := flags["perspective"]; len(got) != 1 || got[0] != "--" {
		t.Errorf("--perspective = %q, want [--]", got)
	}
	if strings.Join(pos, "|") != "q|--limit" {
		t.Errorf("positional = %q, want [q --limit]: the second -- still ends the flags", pos)
	}
}

func TestProseFilesSeeAFlagValueDashDash(t *testing.T) {
	// "--" is the description, so the --title-file after it is a flag to resolve.
	p := writeSpecimen(t, "title.txt", "A title from a file")
	got, err := resolveProseTextFiles([]string{"--description", "--", "--title-file", p}, nil, func(string, ...any) {})
	if err != nil {
		t.Fatalf("resolveProseTextFiles: %v", err)
	}
	if want := "--description|--|--title=A title from a file"; strings.Join(got, "|") != want {
		t.Errorf("resolved tail = %q, want %q", strings.Join(got, "|"), want)
	}
}

// `bp task create -- --yes` still files the title "--yes": the globals leave
// it alone, and task create takes it after "--".
func TestTaskCreateTitleAfterDashDashIsNotAGlobal(t *testing.T) {
	g, rest, err := parseGlobals([]string{"task", "create", "--", "--yes"})
	if err != nil {
		t.Fatalf("parseGlobals: %v", err)
	}
	body, _, err := parseTaskCreateArgs(rest[2:])
	if err != nil {
		t.Fatalf("parseTaskCreateArgs: %v", err)
	}
	if g.yes || body["title"] != "--yes" {
		t.Errorf("yes = %v, title = %q; want false and --yes", g.yes, body["title"])
	}
}

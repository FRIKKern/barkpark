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

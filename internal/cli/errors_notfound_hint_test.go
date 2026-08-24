package cli

import (
	"bytes"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// hintManifest mirrors the shape of the live capabilities manifest closely
// enough to exercise sibling lookup: nouns that carry a plain `ls`, a noun
// whose families each carry their own list verb, a noun whose only enumeration
// is `inbox`, and a noun with no enumeration at all.
func hintManifest() *manifest.Manifest {
	cmd := func(noun, verb, path string) manifest.Command {
		return manifest.Command{
			ID:   noun + "." + verb,
			Noun: noun,
			Verb: verb,
			HTTP: manifest.HTTP{Method: "GET", PathTemplate: path},
		}
	}
	return &manifest.Manifest{Commands: []manifest.Command{
		cmd("token", "ls", "/v1/tokens"),
		cmd("token", "create", "/v1/tokens"),
		cmd("token", "revoke", "/v1/tokens/:id"),

		cmd("workspace", "ls", "/api/workspaces"),
		cmd("workspace", "member-ls", "/v1/members"),
		cmd("workspace", "member-rm", "/v1/members/:principal_ref"),
		cmd("workspace", "project-ls", "/api/workspaces/:workspace_slug/projects"),

		cmd("ticket", "inbox", "/v1/tickets"),
		cmd("ticket", "show", "/v1/tickets/:id"),

		cmd("media", "ls", "/v1/media/:dataset"),
		cmd("media", "get", "/v1/media/:dataset/:id"),
		cmd("media", "collections", "/v1/media/:dataset/collections"),
		cmd("media", "collection-assets", "/v1/media/:dataset/collections/:id/assets"),

		// A noun with no enumerating verb at all.
		cmd("auth", "whoami", "/v1/whoami"),
	}}
}

func cmdOf(t *testing.T, m *manifest.Manifest, noun, verb string) manifest.Command {
	t.Helper()
	for _, c := range m.Commands {
		if c.Noun == noun && c.Verb == verb {
			return c
		}
	}
	t.Fatalf("fixture has no %s %s", noun, verb)
	return manifest.Command{}
}

func TestNotFoundHintNamesTheEnumeratingSibling(t *testing.T) {
	m := hintManifest()
	cases := []struct {
		name       string
		noun, verb string
		want       string // must appear
		absent     string // must NOT appear
	}{
		{
			// The row that motivated this: `bp token revoke <id>` is what you
			// reach for when a credential has leaked, and its refusal used to
			// point at `bp schema ls`, which lists content schemas.
			name: "token revoke names token ls",
			noun: "token", verb: "revoke",
			want: "bp token ls", absent: "schema ls",
		},
		{
			// The noun alone is too coarse. `bp workspace ls` lists WORKSPACES
			// and can never show the seat whose id was rejected — naming it
			// would reproduce the very defect this hint removes.
			name: "member-rm names member-ls, not the noun-wide ls",
			noun: "workspace", verb: "member-rm",
			want: "bp workspace member-ls", absent: "bp workspace ls ",
		},
		{
			name: "a noun whose only enumeration is inbox",
			noun: "ticket", verb: "show",
			want: "bp ticket inbox",
		},
		{
			// collection-assets has no `collection-ls`; the plural family verb
			// `collections` is the list, and it is preferred over `media ls`.
			name: "family plural is preferred over the noun-wide ls",
			noun: "media", verb: "collection-assets",
			want: "bp media collections", absent: "bp media ls",
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := notFoundHint(m, cmdOf(t, m, c.noun, c.verb))
			if !strings.Contains(got, c.want) {
				t.Errorf("hint for `bp %s %s` = %q, want it to name %q", c.noun, c.verb, got, c.want)
			}
			if c.absent != "" && strings.Contains(got, c.absent) {
				t.Errorf("hint for `bp %s %s` = %q, must not name %q", c.noun, c.verb, got, c.absent)
			}
		})
	}
}

// The --dataset clause is earned by the route, not attached to every refusal.
// Telling someone to check --dataset on a workspace-scoped route is the same
// species of wrong answer as sending them to `bp schema ls`.
func TestNotFoundHintOnlyMentionsDatasetWhenTheRouteIsDatasetScoped(t *testing.T) {
	m := hintManifest()

	scoped := notFoundHint(m, cmdOf(t, m, "media", "get")) // /v1/media/:dataset/:id
	if !strings.Contains(scoped, "--dataset") {
		t.Errorf("a :dataset route should mention --dataset, got %q", scoped)
	}
	if !strings.Contains(scoped, "dataset-scoped") {
		t.Errorf("a :dataset route should say so, got %q", scoped)
	}

	unscoped := notFoundHint(m, cmdOf(t, m, "token", "revoke")) // /v1/tokens/:id
	if !strings.Contains(unscoped, "not dataset-scoped") {
		t.Errorf("a route with no :dataset must say --dataset cannot help, got %q", unscoped)
	}
}

// Silence beats a guess. A hint naming a command that does not exist costs the
// reader an extra failed run and teaches them to stop trusting hints, so the
// lookup refuses rather than inventing.
func TestNotFoundHintStaysSilentRatherThanGuessing(t *testing.T) {
	m := hintManifest()
	cases := []struct {
		name string
		m    *manifest.Manifest
		cmd  manifest.Command
	}{
		{"no manifest", nil, cmdOf(t, m, "token", "revoke")},
		{"noun has no enumerating verb", m, cmdOf(t, m, "auth", "whoami")},
		{"the command IS the list verb", m, cmdOf(t, m, "token", "ls")},
		{"noun absent from the manifest", m, manifest.Command{Noun: "nosuchnoun", Verb: "get"}},
		{"no noun at all", m, manifest.Command{}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := notFoundHint(c.m, c.cmd); got != "" {
				t.Errorf("want no hint, got %q", got)
			}
		})
	}
}

// Precedence: the server knows most, so its hint is never displaced. This is
// what keeps the doc/media/secret/schema/webhook refusals — which DO carry a
// server hint — byte-identical.
func TestServerHintOutranksTheDerivedHint(t *testing.T) {
	e := apiError{code: "not_found", serverHint: "the server's own words", localHint: "derived"}
	if got := e.hint(); got != "the server's own words" {
		t.Errorf("hint() = %q, want the server hint", got)
	}
}

func TestDerivedHintOutranksTheCodeTable(t *testing.T) {
	e := apiError{code: "not_found", localHint: "run `bp token ls` to see what exists"}
	got := e.hint()
	if !strings.Contains(got, "bp token ls") {
		t.Errorf("hint() = %q, want the derived hint", got)
	}
	if strings.Contains(got, "schema ls") {
		t.Errorf("hint() = %q, must not fall through to the document table", got)
	}
}

// End to end through the dispatch path: a 404 whose body carries no `hint` gets
// the derived remedy, and one that does carry a hint is left alone.
func TestHandleResponseDerivesTheRemedyForAnUnannotated404(t *testing.T) {
	m := hintManifest()
	revoke := cmdOf(t, m, "token", "revoke")

	t.Run("no server hint", func(t *testing.T) {
		var so, se bytes.Buffer
		w := newWriter(&so, &se)
		w.output = "table"
		body := []byte(`{"error":{"code":"not_found","message":"no token with that id holds a seat in this workspace"}}`)
		if rc := handleResponse(w, m, revoke, 404, body); rc != exitNotFound {
			t.Fatalf("exit = %d, want %d", rc, exitNotFound)
		}
		got := se.String()
		if !strings.Contains(got, "bp token ls") {
			t.Errorf("refusal did not carry its remedy:\n%s", got)
		}
		if strings.Contains(got, "schema ls") {
			t.Errorf("refusal still points at the document hint:\n%s", got)
		}
	})

	t.Run("server hint wins", func(t *testing.T) {
		var so, se bytes.Buffer
		w := newWriter(&so, &se)
		w.output = "table"
		body := []byte(`{"error":{"code":"not_found","message":"nope","hint":"the server's own words"}}`)
		handleResponse(w, m, revoke, 404, body)
		got := se.String()
		if !strings.Contains(got, "the server's own words") {
			t.Errorf("server hint was displaced:\n%s", got)
		}
		if strings.Contains(got, "bp token ls") {
			t.Errorf("derived hint displaced the server's:\n%s", got)
		}
	})
}

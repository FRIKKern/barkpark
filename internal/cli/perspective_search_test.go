package cli

import (
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// searchQueryLiveShape mirrors, field for field, the `search.query` command the
// LIVE server publishes at GET /v1/capabilities (verified against
// http://89.167.28.206/v1/capabilities: auth_tier "none", path_template
// "/v1/data/search/:dataset", and a declared `perspective` flag whose summary
// reads "published (default) | drafts | raw." — see the `search.query` entry in
// api/lib/barkpark/plugins/capabilities.ex).
//
// It is hand-built rather than read from docs/cli/fixtures/core-manifest.json
// because that fixture predates the flag: it still carries search.query at tier
// "read" with no perspective flag at all, so a fixture-driven test would be
// vacuous against the shape this regression is about.
func searchQueryLiveShape() manifest.Command {
	return manifest.Command{
		ID:       "search.query",
		Noun:     "search",
		Verb:     "query",
		HTTP:     manifest.HTTP{Method: "GET", PathTemplate: "/v1/data/search/:dataset"},
		AuthTier: "none",
		Args:     []manifest.Arg{{Name: "q", Required: true, Type: "string"}},
		Flags: []manifest.Flag{
			{Name: "engine", Type: "string", Default: "postgres"},
			{Name: "limit", Type: "int", Default: 50},
			{Name: "perspective", Type: "string"},
		},
		Paginated:     true,
		DefaultOutput: "table",
	}
}

// TestSearchQueryNonPublishedPerspectiveIsAuthenticated is the regression pin
// for the "a hardcoded id list stands in for a declared manifest fact" defect
// class (the same shape as task-c005183551c279c0 / PR #14115, where a "/media"
// substring in the route stood in for an arg's declared `type: "file"`).
//
// nonPublishedPerspectiveRequiresAuth used to gate on `switch cmd.ID { case
// "doc.get", "doc.ls", "doc.query" }`. That literal set stood in for the two
// facts the manifest already declares structurally: `auth_tier: "none"` and the
// command DECLARING a `perspective` flag. The live server declares FOUR such
// commands, not three — search.query is the fourth — so `bp search query x
// --perspective drafts` fell out of the switch, authHeaders sent nothing (tier
// "none"), and the server's BarkparkWeb.AnonPerspective.resolve/2 pins a
// tokenless caller to :published SILENTLY. The caller got published hits at
// exit 0 while believing they had read drafts, and a caller who DID have a
// token in config was affected identically — the bearer was never attached.
//
// The doc.* siblings, one switch case away, either attach the bearer or refuse
// loudly ("requires an API token"). Keying on the declaration instead of the id
// makes the guard reach every public read that declares the flag, including a
// plugin's — a whole class the id list could never admit.
func TestSearchQueryNonPublishedPerspectiveIsAuthenticated(t *testing.T) {
	m, _ := loadFixtureTree(t)
	cmd := searchQueryLiveShape()
	ctx := manifest.Context{
		Server:  "https://api.barkpark.cloud",
		Dataset: "production",
		Token:   "draft-reader-token",
	}

	for _, perspective := range []string{"drafts", "raw"} {
		perspective := perspective
		t.Run(perspective, func(t *testing.T) {
			req, derr := buildManifestRequest(
				globals{}, ctx, m, cmd,
				[]string{"hello", "--perspective", perspective},
				false,
			)
			if derr != nil {
				t.Fatalf("buildManifestRequest: %v", derr)
			}
			if got := req.headers["Authorization"]; got != "Bearer draft-reader-token" {
				t.Errorf(
					"search.query --perspective %s misclassified as a plain public read: "+
						"Authorization = %q, want %q. The command declares a perspective flag "+
						"at auth_tier none exactly like doc.get/ls/query, but the guard keyed "+
						"on a literal cmd.ID set, so the request goes out tokenless and the "+
						"server pins it back to published.",
					perspective, got, "Bearer draft-reader-token",
				)
			}
		})
	}

	// The public path must stay byte-for-byte public: asking for the default
	// perspective attaches nothing, so nothing that works today changes shape.
	t.Run("published_stays_public", func(t *testing.T) {
		req, derr := buildManifestRequest(
			globals{}, ctx, m, cmd,
			[]string{"hello", "--perspective", "published"},
			false,
		)
		if derr != nil {
			t.Fatalf("buildManifestRequest: %v", derr)
		}
		if got := req.headers["Authorization"]; got != "" {
			t.Errorf("published Authorization = %q, want an unchanged public request", got)
		}
	})

	// No --perspective at all: also unchanged.
	t.Run("absent_stays_public", func(t *testing.T) {
		req, derr := buildManifestRequest(globals{}, ctx, m, cmd, []string{"hello"}, false)
		if derr != nil {
			t.Fatalf("buildManifestRequest: %v", derr)
		}
		if got := req.headers["Authorization"]; got != "" {
			t.Errorf("no-perspective Authorization = %q, want an unchanged public request", got)
		}
	})
}

// TestSearchQueryNonPublishedPerspectiveWithoutTokenRefuses pins the OTHER half
// of the guard: with no credential to attach, the CLI must refuse rather than
// send a request whose answer will silently be the published corpus.
func TestSearchQueryNonPublishedPerspectiveWithoutTokenRefuses(t *testing.T) {
	m, _ := loadFixtureTree(t)
	cmd := searchQueryLiveShape()

	_, derr := buildManifestRequest(
		globals{},
		manifest.Context{Server: "https://api.barkpark.cloud", Dataset: "production"},
		m, cmd,
		[]string{"hello", "--perspective", "drafts"},
		false,
	)
	if derr == nil {
		t.Fatal("search.query --perspective drafts with no token was sent anyway; " +
			"the server pins it to published and the caller reads the wrong corpus at exit 0")
	}
	if !strings.Contains(derr.Error(), "requires an API token") {
		t.Fatalf("error = %q, want a refusal naming the missing API token", derr)
	}
}

// TestNonPublishedPerspectiveGuardIsDeclarationKeyed states the rule directly on
// the predicate: the door is the DECLARED flag plus the tier, never the id. A
// public command that declares no perspective flag is untouched (a caller could
// not have passed the flag in the first place — splitArgs refuses it), and an
// authenticated tier never routes through this path because authHeaders already
// attaches the bearer for it.
func TestNonPublishedPerspectiveGuardIsDeclarationKeyed(t *testing.T) {
	declaring := searchQueryLiveShape()
	drafts := map[string][]string{"perspective": {"drafts"}}

	if !nonPublishedPerspectiveRequiresAuth(declaring, drafts) {
		t.Error("a tier-none command DECLARING perspective must require auth for drafts")
	}

	// A plugin's own public read that declares the flag is the class the id list
	// could never admit. It must be admitted now.
	plugin := declaring
	plugin.ID = "sheets.find"
	plugin.Noun = "sheets"
	plugin.Verb = "find"
	plugin.HTTP.PathTemplate = "/v1/plugins/sheets/find/:dataset"
	if !nonPublishedPerspectiveRequiresAuth(plugin, drafts) {
		t.Error("a PLUGIN tier-none command declaring perspective must require auth for drafts too")
	}

	// No declaration -> not this guard's business.
	bare := declaring
	bare.Flags = []manifest.Flag{{Name: "limit", Type: "int"}}
	if nonPublishedPerspectiveRequiresAuth(bare, drafts) {
		t.Error("a command that declares no perspective flag must not be gated")
	}

	// An authenticated tier is already credentialed by authHeaders.
	authed := declaring
	authed.AuthTier = "read"
	if nonPublishedPerspectiveRequiresAuth(authed, drafts) {
		t.Error("an authenticated tier must not route through the tier-none guard")
	}

	// published / absent are never gated.
	if nonPublishedPerspectiveRequiresAuth(declaring, map[string][]string{"perspective": {"published"}}) {
		t.Error("published must never be gated")
	}
	if nonPublishedPerspectiveRequiresAuth(declaring, map[string][]string{}) {
		t.Error("an absent perspective must never be gated")
	}
}

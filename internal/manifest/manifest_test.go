package manifest

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/apiclient"
)

const fixtureDir = "../../docs/cli/fixtures"

func readFixture(t *testing.T, name string) []byte {
	t.Helper()
	body, err := os.ReadFile(filepath.Join(fixtureDir, name))
	if err != nil {
		t.Fatalf("read fixture %s: %v", name, err)
	}
	return body
}

func parseFixture(t *testing.T, name string) *Manifest {
	t.Helper()
	m, err := Parse(readFixture(t, name))
	if err != nil {
		t.Fatalf("parse fixture %s: %v", name, err)
	}
	return m
}

// (a) Parse both fixtures and sanity-check the typed surface.
func TestParseFixtures(t *testing.T) {
	admin := parseFixture(t, "core-manifest.json")
	if admin.ManifestVersion != "1" {
		t.Errorf("admin manifest_version = %q, want \"1\"", admin.ManifestVersion)
	}
	if admin.AuthTier != "admin" {
		t.Errorf("admin auth_tier = %q, want \"admin\"", admin.AuthTier)
	}
	if admin.Server.BaseURL != "https://api.barkpark.cloud" {
		t.Errorf("admin server.base_url = %q", admin.Server.BaseURL)
	}
	if admin.Server.APIVersion == nil || *admin.Server.APIVersion != "1" {
		t.Errorf("admin server.api_version not parsed as pointer to \"1\"")
	}
	if admin.Server.MinCLI == nil || *admin.Server.MinCLI != "1.0.0" {
		t.Errorf("admin server.min_cli not parsed as pointer to \"1.0.0\"")
	}
	if len(admin.Nouns) != 8 {
		t.Errorf("admin nouns = %d, want 8", len(admin.Nouns))
	}
	if len(admin.Commands) != 17 {
		t.Errorf("admin commands = %d, want 17", len(admin.Commands))
	}

	anon := parseFixture(t, "core-manifest-anon.json")
	if anon.AuthTier != "none" {
		t.Errorf("anon auth_tier = %q, want \"none\"", anon.AuthTier)
	}
	if len(anon.Nouns) != 4 {
		t.Errorf("anon nouns = %d, want 4", len(anon.Nouns))
	}
	if len(anon.Commands) != 6 {
		t.Errorf("anon commands = %d, want 6", len(anon.Commands))
	}

	// Optional scoped_prefix is a pointer: present on doc.get, null on
	// workspace.ls.
	tree := admin.Tree()
	if cmd, ok := tree.Lookup("doc", "get"); !ok {
		t.Fatal("admin tree missing doc get")
	} else if cmd.ScopedPrefix == nil || *cmd.ScopedPrefix != "/w/:workspace_slug/p/:project_slug" {
		t.Errorf("doc.get scoped_prefix = %v, want the workspace prefix", cmd.ScopedPrefix)
	}
	if cmd, ok := tree.Lookup("workspace", "ls"); !ok {
		t.Fatal("admin tree missing workspace ls")
	} else if cmd.ScopedPrefix != nil {
		t.Errorf("workspace.ls scoped_prefix = %v, want nil", *cmd.ScopedPrefix)
	}
}

// Parse must reject an unknown field (mirrors schema additionalProperties:false).
func TestParseRejectsUnknownField(t *testing.T) {
	bad := []byte(`{"manifest_version":"1","server":{"name":"x","version":"1","base_url":"http://x"},"auth_tier":"none","generated_at":"2026-01-01T00:00:00Z","etag":"e","nouns":[],"commands":[],"bogus":true}`)
	if _, err := Parse(bad); err == nil {
		t.Fatal("Parse accepted an unknown top-level field; want error")
	}
}

// Parse must reject trailing content after the JSON document: json.Decoder reads
// exactly one value, so a doubled body ({...}{...}) or trailing garbage would
// otherwise be silently dropped instead of failing loud.
func TestParseRejectsTrailingData(t *testing.T) {
	valid := `{"manifest_version":"1","server":{"name":"x","version":"1","base_url":"http://x"},"auth_tier":"none","generated_at":"2026-01-01T00:00:00Z","etag":"e","nouns":[],"commands":[]}`
	bad := []byte(valid + valid) // two concatenated manifests
	_, err := Parse(bad)
	if err == nil {
		t.Fatal("Parse accepted trailing data after the document; want error")
	}
	if !strings.Contains(err.Error(), "trailing data") {
		t.Errorf("error = %q, want it to mention \"trailing data\"", err)
	}
}

// The command-level `views` descriptor is a dormant additive field (AXI brief
// views, charter decision 2): a views-PRESENT manifest parses with all three
// keys typed, and a views-ABSENT manifest (every server today, and every server
// not asked with ?views=1) parses with Views nil. Ported from the wave's
// manifest-decode verify probe: DisallowUnknownFields recurses into Command, so
// modelling the field is what keeps a views-emitting server from bricking the
// strict decode.
func TestParseViewsPresentAndAbsent(t *testing.T) {
	withViews := []byte(`{"manifest_version":"1","server":{"name":"x","version":"1","base_url":"http://x"},"auth_tier":"none","generated_at":"2026-01-01T00:00:00Z","etag":"e","nouns":[],"commands":[{"id":"task.ready","noun":"task","verb":"ready","summary":"ready","http":{"method":"GET","path_template":"/v1/tasks/ready"},"auth_tier":"read","args":[],"flags":[],"writes":false,"batch":false,"paginated":true,"dry_run":false,"default_output":"table","views":{"supported":["brief","full"],"default":"full","default_for_agents":"brief"}}]}`)
	m, err := Parse(withViews)
	if err != nil {
		t.Fatalf("Parse rejected a views-present manifest: %v", err)
	}
	v := m.Commands[0].Views
	if v == nil {
		t.Fatal("views-present command decoded with Views nil")
	}
	if !reflect.DeepEqual(v.Supported, []string{"brief", "full"}) {
		t.Errorf("views.supported = %v, want [brief full]", v.Supported)
	}
	if v.Default != "full" {
		t.Errorf("views.default = %q, want full", v.Default)
	}
	if v.DefaultForAgents != "brief" {
		t.Errorf("views.default_for_agents = %q, want brief", v.DefaultForAgents)
	}

	withoutViews := []byte(`{"manifest_version":"1","server":{"name":"x","version":"1","base_url":"http://x"},"auth_tier":"none","generated_at":"2026-01-01T00:00:00Z","etag":"e","nouns":[],"commands":[{"id":"task.ready","noun":"task","verb":"ready","summary":"ready","http":{"method":"GET","path_template":"/v1/tasks/ready"},"auth_tier":"read","args":[],"flags":[],"writes":false,"batch":false,"paginated":true,"dry_run":false,"default_output":"table"}]}`)
	m2, err := Parse(withoutViews)
	if err != nil {
		t.Fatalf("Parse rejected a views-absent manifest: %v", err)
	}
	if m2.Commands[0].Views != nil {
		t.Errorf("views-absent command decoded with Views = %+v, want nil (dormant)", m2.Commands[0].Views)
	}

	// The pre-views fixtures must stay parseable untouched — the dormant field
	// changes nothing for a server that never emits it.
	for _, cmd := range parseFixture(t, "core-manifest.json").Commands {
		if cmd.Views != nil {
			t.Errorf("fixture command %s unexpectedly carries views", cmd.ID)
		}
	}
}

// Strict decode recurses into the views object itself: an unknown key inside it
// fails Parse, the same additionalProperties:false discipline as everywhere else.
func TestParseRejectsUnknownViewsKey(t *testing.T) {
	bad := []byte(`{"manifest_version":"1","server":{"name":"x","version":"1","base_url":"http://x"},"auth_tier":"none","generated_at":"2026-01-01T00:00:00Z","etag":"e","nouns":[],"commands":[{"id":"task.ready","noun":"task","verb":"ready","summary":"ready","http":{"method":"GET","path_template":"/v1/tasks/ready"},"auth_tier":"read","args":[],"flags":[],"writes":false,"batch":false,"paginated":true,"dry_run":false,"default_output":"table","views":{"supported":["brief"],"default":"full","default_for_agents":"brief","bogus":true}}]}`)
	if _, err := Parse(bad); err == nil {
		t.Fatal("Parse accepted an unknown key inside views; want error")
	}
}

// Parse must accept the root-only $comment annotation the fixtures carry.
func TestParseAcceptsComment(t *testing.T) {
	ok := []byte(`{"$comment":"hi","manifest_version":"1","server":{"name":"x","version":"1","base_url":"http://x"},"auth_tier":"none","generated_at":"2026-01-01T00:00:00Z","etag":"e","nouns":[],"commands":[]}`)
	m, err := Parse(ok)
	if err != nil {
		t.Fatalf("Parse rejected $comment: %v", err)
	}
	if m.Comment != "hi" {
		t.Errorf("Comment = %q, want \"hi\"", m.Comment)
	}
}

// The root `chat` discovery block is a dormant additive field (charter D27,
// the views/build precedent): a chat-PRESENT manifest parses with every nested
// key typed (providers → modes/models/efforts), and a chat-ABSENT manifest
// (every server today, and every server not asked with ?chat=1) parses with
// Chat nil — the honest "discover nothing, degrade" signal. codex's all-empty
// caps decode as empty slices, never an error.
func TestParseChatPresentAndAbsent(t *testing.T) {
	withChat := []byte(`{"manifest_version":"1","server":{"name":"x","version":"1","base_url":"http://x"},"auth_tier":"admin","generated_at":"2026-01-01T00:00:00Z","etag":"e","nouns":[],"commands":[],"chat":{"providers":{"claude":{"modes":["plan","auto"],"models":["sonnet","opus"],"efforts":["low","high"]},"codex":{"modes":[],"models":[],"efforts":[]}}}}`)
	m, err := Parse(withChat)
	if err != nil {
		t.Fatalf("Parse rejected a chat-present manifest: %v", err)
	}
	if m.Chat == nil {
		t.Fatal("chat-present manifest decoded with Chat nil")
	}
	claude, ok := m.Chat.Providers["claude"]
	if !ok {
		t.Fatal("chat.providers is missing claude")
	}
	if !reflect.DeepEqual(claude.Modes, []string{"plan", "auto"}) {
		t.Errorf("claude.modes = %v, want [plan auto]", claude.Modes)
	}
	if !reflect.DeepEqual(claude.Models, []string{"sonnet", "opus"}) {
		t.Errorf("claude.models = %v, want [sonnet opus]", claude.Models)
	}
	if !reflect.DeepEqual(claude.Efforts, []string{"low", "high"}) {
		t.Errorf("claude.efforts = %v, want [low high]", claude.Efforts)
	}
	codex, ok := m.Chat.Providers["codex"]
	if !ok {
		t.Fatal("chat.providers is missing codex")
	}
	if len(codex.Modes) != 0 || len(codex.Models) != 0 || len(codex.Efforts) != 0 {
		t.Errorf("codex caps = %+v, want all-empty (the degrade signal)", codex)
	}

	withoutChat := []byte(`{"manifest_version":"1","server":{"name":"x","version":"1","base_url":"http://x"},"auth_tier":"none","generated_at":"2026-01-01T00:00:00Z","etag":"e","nouns":[],"commands":[]}`)
	m2, err := Parse(withoutChat)
	if err != nil {
		t.Fatalf("Parse rejected a chat-absent manifest: %v", err)
	}
	if m2.Chat != nil {
		t.Errorf("chat-absent manifest decoded with Chat = %+v, want nil (dormant)", m2.Chat)
	}

	// The pre-chat fixtures must stay parseable untouched.
	if parseFixture(t, "core-manifest.json").Chat != nil {
		t.Error("core fixture unexpectedly carries a chat block")
	}
}

// Strict decode recurses into the chat block: an unknown key inside it (or
// inside one provider's caps) fails Parse. This is ALSO the mutation proof for
// the D27 atomicity invariant: DisallowUnknownFields means a build whose
// Manifest struct lacked the Chat field would reject a chat-bearing body
// outright — so the field and fetch's ?chat=1 opt-in must ship together, and
// this test pins the recursing strictness that makes that invariant bite.
func TestParseRejectsUnknownChatKey(t *testing.T) {
	badInChat := []byte(`{"manifest_version":"1","server":{"name":"x","version":"1","base_url":"http://x"},"auth_tier":"admin","generated_at":"2026-01-01T00:00:00Z","etag":"e","nouns":[],"commands":[],"chat":{"providers":{},"bogus":true}}`)
	if _, err := Parse(badInChat); err == nil {
		t.Fatal("Parse accepted an unknown key inside chat; want error")
	}

	badInCaps := []byte(`{"manifest_version":"1","server":{"name":"x","version":"1","base_url":"http://x"},"auth_tier":"admin","generated_at":"2026-01-01T00:00:00Z","etag":"e","nouns":[],"commands":[],"chat":{"providers":{"claude":{"modes":[],"models":[],"efforts":[],"bogus":true}}}}`)
	if _, err := Parse(badInCaps); err == nil {
		t.Fatal("Parse accepted an unknown key inside a provider's chat caps; want error")
	}
}

// Parse is a CLIENT-SIDE TRUST BOUNDARY against a remote-to-eval RCE: the
// completion emitters bake manifest noun/verb NAMES raw into a shell script the
// user is told to eval (`eval "$(bp completion bash)"`), so a hostile server
// could plant a name like `x";touch /tmp/pwn;#` that executes on eval. Parse
// must REJECT a manifest whose noun name or command verb leaves the shell-safe
// identifier charset — before any name reaches an emitter. MUTATION PROOF:
// deleting the safeName loop in manifest.Parse reds every subtest here.
func TestParseRejectsUnsafeNounVerbNames(t *testing.T) {
	// A well-formed manifest scaffold with one legit noun+command; each case
	// swaps in a hostile noun name or verb and asserts Parse errors.
	manifest := func(nounName, verb string) []byte {
		return []byte(`{"manifest_version":"1","server":{"name":"x","version":"1","base_url":"http://x"},"auth_tier":"none","generated_at":"2026-01-01T00:00:00Z","etag":"e","nouns":[{"name":` +
			jsonStr(nounName) + `,"summary":"s"}],"commands":[{"id":"c","noun":` + jsonStr(nounName) +
			`,"verb":` + jsonStr(verb) + `,"summary":"s","http":{"method":"GET","path_template":"/x"},"auth_tier":"read","args":[],"flags":[],"writes":false,"batch":false,"paginated":false,"dry_run":false,"default_output":"table"}]}`)
	}

	// The completion-eval RCE payload proven by verify (V3), plus a command-
	// substitution variant and a single-quote break-out (breaks the fish emitter's
	// single-quoted interpolation).
	hostileNames := []string{
		`x";touch /tmp/pwn;#`,
		`$(touch /tmp/pwn)`,
		`a'b`,
		`a b`,        // whitespace splits the shell word list
		`a;rm -rf /`, // command separator
		`a$IFS`,      // shell variable
		`Doc`,        // uppercase is outside the documented charset
		`-lead`,      // a leading hyphen would read as a flag / option
	}

	for _, name := range hostileNames {
		// Hostile NOUN name (verb kept legit) must be rejected.
		if _, err := Parse(manifest(name, "get")); err == nil {
			t.Errorf("Parse accepted hostile noun name %q; want rejection", name)
		}
		// Hostile VERB (noun kept legit) must be rejected.
		if _, err := Parse(manifest("doc", name)); err == nil {
			t.Errorf("Parse accepted hostile verb %q; want rejection", name)
		}
	}

	// The Command.Noun path is distinct from the declared Noun.Name: Tree()
	// synthesizes a node from cmd.Noun for a command whose noun was never declared
	// in nouns[], and that name flows into the same eval'd emitter. So a manifest
	// with an EMPTY nouns[] but a command carrying a hostile noun must also be
	// rejected — a Noun.Name-only check would miss it.
	cmdNounOnly := func(hostileNoun string) []byte {
		return []byte(`{"manifest_version":"1","server":{"name":"x","version":"1","base_url":"http://x"},"auth_tier":"none","generated_at":"2026-01-01T00:00:00Z","etag":"e","nouns":[],"commands":[{"id":"c","noun":` +
			jsonStr(hostileNoun) + `,"verb":"get","summary":"s","http":{"method":"GET","path_template":"/x"},"auth_tier":"read","args":[],"flags":[],"writes":false,"batch":false,"paginated":false,"dry_run":false,"default_output":"table"}]}`)
	}
	for _, name := range hostileNames {
		if _, err := Parse(cmdNounOnly(name)); err == nil {
			t.Errorf("Parse accepted hostile undeclared command noun %q; want rejection", name)
		}
	}

	// A legit hyphenated noun+verb (workspace project-create is a real command)
	// must STILL parse — the validation rejects metacharacters, not the safe
	// charset the CLI actually uses.
	if _, err := Parse(manifest("workspace", "project-create")); err != nil {
		t.Errorf("Parse rejected a legit hyphenated noun/verb: %v", err)
	}
}

// jsonStr encodes a Go string as a JSON string literal so a test payload
// carrying quotes/backslashes embeds cleanly into a manifest body.
func jsonStr(s string) string {
	b, _ := json.Marshal(s)
	return string(b)
}

// (b) Tree() from core-manifest.json yields the eight canonical core nouns plus
// the plugin-contributed `task` noun, with their commands; the anon fixture
// yields its read-only subset. The old `rail` noun is gone, and `task` carries
// source "plugin:tasks" (the Tasks plugin lift) — the Tree is a pure function of
// whatever nouns/commands the manifest carries, regardless of provenance.
func TestTreeFromCoreManifest(t *testing.T) {
	admin := parseFixture(t, "core-manifest.json")
	tree := admin.Tree()

	wantNouns := []string{"doc", "media", "plugin", "schema", "search", "task", "webhook", "workspace"}
	if got := tree.NounNames(); !reflect.DeepEqual(got, wantNouns) {
		t.Errorf("admin noun names = %v, want %v", got, wantNouns)
	}

	// Exact verb set per noun, derived from the fixture commands.
	wantVerbs := map[string][]string{
		"doc":       {"get", "ls", "query", "mutate"},
		"schema":    {"get", "apply"},
		"media":     {"ls", "upload"},
		"search":    {"query"},
		"workspace": {"ls", "project-create"},
		"task":      {"ls", "claim"},
		"webhook":   {"ls", "create"},
		"plugin":    {"ls", "settings"},
	}
	assertVerbs(t, tree, wantVerbs)

	// Every command must be reachable via Lookup at its declared (noun, verb).
	for i := range admin.Commands {
		cmd := admin.Commands[i]
		got, ok := tree.Lookup(cmd.Noun, cmd.Verb)
		if !ok {
			t.Errorf("Lookup(%q,%q) missing", cmd.Noun, cmd.Verb)
			continue
		}
		if got.ID != cmd.ID {
			t.Errorf("Lookup(%q,%q).ID = %q, want %q", cmd.Noun, cmd.Verb, got.ID, cmd.ID)
		}
	}

	// Anon read-only subset.
	anon := parseFixture(t, "core-manifest-anon.json")
	anonTree := anon.Tree()
	wantAnonNouns := []string{"doc", "media", "schema", "search"}
	if got := anonTree.NounNames(); !reflect.DeepEqual(got, wantAnonNouns) {
		t.Errorf("anon noun names = %v, want %v", got, wantAnonNouns)
	}
	// Existence-hiding: admin-only nouns/verbs must NOT appear in the anon tree.
	for _, hidden := range []struct{ noun, verb string }{
		{"doc", "mutate"}, {"schema", "apply"}, {"plugin", "settings"},
		{"task", "claim"}, {"webhook", "create"}, {"workspace", "project-create"},
	} {
		if _, ok := anonTree.Lookup(hidden.noun, hidden.verb); ok {
			t.Errorf("anon tree leaked admin command %s %s", hidden.noun, hidden.verb)
		}
	}
	assertVerbs(t, anonTree, map[string][]string{
		"doc":    {"get", "ls", "query"},
		"schema": {"get"},
		"search": {"query"},
		"media":  {"ls"},
	})
}

// TestTreeIsPureFunction proves the tree carries NO hardcoded noun list: a
// synthetic manifest with a made-up noun + command produces a tree containing
// exactly that made-up noun and verb.
func TestTreeIsPureFunction(t *testing.T) {
	syntheticPlugin := "wibble"
	m := &Manifest{
		ManifestVersion: "1",
		Server:          Server{Name: "t", Version: "0", BaseURL: "http://t"},
		AuthTier:        "admin",
		GeneratedAt:     "2026-01-01T00:00:00Z",
		ETag:            "e",
		Nouns: []Noun{
			{Name: "wibble", Summary: "a made-up noun", Plugin: &syntheticPlugin},
		},
		Commands: []Command{
			{
				ID: "wibble.frobnicate", Noun: "wibble", Verb: "frobnicate",
				Summary:  "do the thing",
				HTTP:     HTTP{Method: "POST", PathTemplate: "/v1/wibble/:dataset/frob"},
				AuthTier: "write", Args: []Arg{}, Flags: []Flag{},
				Writes: true, DefaultOutput: "minimal",
			},
		},
	}
	tree := m.Tree()
	if got := tree.NounNames(); !reflect.DeepEqual(got, []string{"wibble"}) {
		t.Fatalf("synthetic tree noun names = %v, want [wibble]", got)
	}
	cmd, ok := tree.Lookup("wibble", "frobnicate")
	if !ok {
		t.Fatal("synthetic tree missing wibble frobnicate")
	}
	if cmd.ID != "wibble.frobnicate" {
		t.Errorf("synthetic cmd ID = %q", cmd.ID)
	}
	if tree.Nouns[0].Plugin == nil || *tree.Nouns[0].Plugin != "wibble" {
		t.Errorf("synthetic noun plugin not preserved")
	}
	// A real-noun lookup that the synthetic manifest never declared must miss —
	// confirms there is no baked-in noun set.
	if _, ok := tree.Lookup("doc", "get"); ok {
		t.Error("synthetic tree returned a hardcoded doc.get")
	}
}

func assertVerbs(t *testing.T, tree *Tree, want map[string][]string) {
	t.Helper()
	for noun, verbs := range want {
		node, ok := nounNode(tree, noun)
		if !ok {
			t.Errorf("tree missing noun %q", noun)
			continue
		}
		got := make([]string, 0, len(node.Verbs))
		for _, c := range node.Verbs {
			got = append(got, c.Verb)
		}
		gotSorted := append([]string(nil), got...)
		wantSorted := append([]string(nil), verbs...)
		sort.Strings(gotSorted)
		sort.Strings(wantSorted)
		if !reflect.DeepEqual(gotSorted, wantSorted) {
			t.Errorf("noun %q verbs = %v, want %v", noun, got, verbs)
		}
	}
}

func nounNode(tree *Tree, name string) (*TreeNoun, bool) {
	for _, n := range tree.Nouns {
		if n.Name == name {
			return n, true
		}
	}
	return nil, false
}

// (c) BuildURL fills a template; scoped_prefix is INERT in v1 (flat path) and
// prepended only when ctx.ScopedMirror is true (the deferred mirror, rule #4).
func TestBuildURL(t *testing.T) {
	admin := parseFixture(t, "core-manifest.json")
	tree := admin.Tree()
	ctx := Context{
		Server:    "https://api.barkpark.cloud",
		Workspace: "acme",
		Project:   "site",
		Dataset:   "production",
	}

	docGet, _ := tree.Lookup("doc", "get")

	// v1 (ScopedMirror false): scoped_prefix is inert -> FLAT path, no prepend.
	// This is what the live flat API actually serves.
	url, err := admin.BuildURL(*docGet, ctx, map[string]string{"type": "post", "doc_id": "p1"})
	if err != nil {
		t.Fatalf("BuildURL doc.get: %v", err)
	}
	if want := "https://api.barkpark.cloud/v1/data/doc/production/post/p1"; url != want {
		t.Errorf("doc.get (flat v1) url = %q, want %q", url, want)
	}

	// Future (ScopedMirror true): the scoped_prefix hint activates and prepends.
	ctxMirror := ctx
	ctxMirror.ScopedMirror = true
	url, err = admin.BuildURL(*docGet, ctxMirror, map[string]string{"type": "post", "doc_id": "p1"})
	if err != nil {
		t.Fatalf("BuildURL doc.get (mirror): %v", err)
	}
	if want := "https://api.barkpark.cloud/w/acme/p/site/v1/data/doc/production/post/p1"; url != want {
		t.Errorf("doc.get (scoped mirror) url = %q, want %q", url, want)
	}

	// Flat command (scoped_prefix null): workspace.ls — no prefix prepended.
	wsLs, _ := tree.Lookup("workspace", "ls")
	url, err = admin.BuildURL(*wsLs, ctx, nil)
	if err != nil {
		t.Fatalf("BuildURL workspace.ls: %v", err)
	}
	if want := "https://api.barkpark.cloud/api/workspaces"; url != want {
		t.Errorf("workspace.ls url = %q, want %q", url, want)
	}

	// Flat command with an arg placeholder: workspace.project-create.
	projCreate, _ := tree.Lookup("workspace", "project-create")
	url, err = admin.BuildURL(*projCreate, ctx, map[string]string{"workspace_slug": "acme"})
	if err != nil {
		t.Fatalf("BuildURL project-create: %v", err)
	}
	if want := "https://api.barkpark.cloud/api/workspaces/acme/projects"; url != want {
		t.Errorf("project-create url = %q, want %q", url, want)
	}

	// Trailing-slash server base must not double up.
	ctxSlash := ctx
	ctxSlash.Server = "https://api.barkpark.cloud/"
	url, _ = admin.BuildURL(*wsLs, ctxSlash, nil)
	if want := "https://api.barkpark.cloud/api/workspaces"; url != want {
		t.Errorf("trailing-slash url = %q, want %q", url, want)
	}

	// A missing required placeholder is an error, not a malformed URL.
	if _, err := admin.BuildURL(*docGet, ctx, map[string]string{"type": "post"}); err == nil {
		t.Error("BuildURL accepted a missing :doc_id; want error")
	}

	// Path-placeholder values with special chars must be percent-escaped so a
	// space or '#' can't corrupt the URL (e.g. '#' truncating the rest into a
	// dropped fragment).
	url, err = admin.BuildURL(*docGet, ctx, map[string]string{"type": "post", "doc_id": "a b#c"})
	if err != nil {
		t.Fatalf("BuildURL doc.get (special chars): %v", err)
	}
	if want := "https://api.barkpark.cloud/v1/data/doc/production/post/a%20b%23c"; url != want {
		t.Errorf("doc.get (special chars) url = %q, want %q", url, want)
	}
}

// (d) Context precedence: flag beats env beats active beats default.
func TestResolvePrecedence(t *testing.T) {
	env := apiclient.Config{
		BaseURL:   "http://env-server:4000",
		Token:     "env-token",
		Workspace: "env-ws",
		Project:   "env-proj",
		Dataset:   "env-ds",
	}
	active := ActiveContext{
		Server:    "http://active-server",
		Workspace: "active-ws",
		Dataset:   "active-ds",
		Output:    "yaml",
	}
	defaults := DefaultDefaults()

	// Flag beats env (and everything below) for dataset.
	flags := map[string]string{FlagDataset: "flag-ds"}
	ctx := Resolve(flags, env, active, defaults)
	if ctx.Dataset != "flag-ds" {
		t.Errorf("dataset: flag should win, got %q", ctx.Dataset)
	}

	// Env beats active + default where no flag is set.
	if ctx.Server != "http://env-server:4000" {
		t.Errorf("server: env should beat active, got %q", ctx.Server)
	}
	if ctx.Workspace != "env-ws" {
		t.Errorf("workspace: env should win, got %q", ctx.Workspace)
	}
	if ctx.Token != "env-token" {
		t.Errorf("token: env should win, got %q", ctx.Token)
	}

	// Active beats default where flag + env are empty (Output has no env field).
	if ctx.Output != "yaml" {
		t.Errorf("output: active should beat default, got %q", ctx.Output)
	}

	// Default wins when flag, env, and active are all empty for that field.
	emptyEnv := apiclient.Config{}
	emptyActive := ActiveContext{}
	ctx2 := Resolve(nil, emptyEnv, emptyActive, defaults)
	if ctx2.Dataset != "production" {
		t.Errorf("dataset: default should be production, got %q", ctx2.Dataset)
	}
	if ctx2.Output != "table" {
		t.Errorf("output: default should be table, got %q", ctx2.Output)
	}
	if ctx2.Workspace != "default" || ctx2.Project != "default" {
		t.Errorf("ws/proj defaults wrong: %q/%q", ctx2.Workspace, ctx2.Project)
	}

	// Active beats default for a field env leaves empty: server, when env empty.
	ctx3 := Resolve(nil, apiclient.Config{}, active, defaults)
	if ctx3.Server != "http://active-server" {
		t.Errorf("server: active should beat default, got %q", ctx3.Server)
	}
}

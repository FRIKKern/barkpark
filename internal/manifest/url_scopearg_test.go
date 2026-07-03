package manifest

import "testing"

// A command may declare a positional arg whose name collides with a scope name
// (dataset/workspace/project) AND bind it to the matching :placeholder — the
// shipped onixedit.export does exactly this (`GET /v1/plugins/onixedit/export/
// :dataset/:id`, args [dataset, id]). The user's explicit positional value must
// fill the path segment; the ambient ctx scope is only the fallback. Before the
// fix, resolvePlaceholder returned ctx.Dataset unconditionally, silently
// discarding the positional and targeting the wrong dataset with no error.
func TestBuildURLPositionalScopeArgWins(t *testing.T) {
	m := &Manifest{}
	cmd := Command{
		ID:   "onixedit.export",
		Noun: "onixedit",
		Verb: "export",
		HTTP: HTTP{Method: "GET", PathTemplate: "/v1/plugins/onixedit/export/:dataset/:id"},
		Args: []Arg{{Name: "dataset", Required: true}, {Name: "id", Required: true}},
	}
	ctx := Context{Server: "https://api.example.com", Dataset: "production"}
	args := map[string]string{"dataset": "staging", "id": "book-42"}

	got, err := m.BuildURL(cmd, ctx, args)
	if err != nil {
		t.Fatalf("BuildURL returned error: %v", err)
	}
	want := "https://api.example.com/v1/plugins/onixedit/export/staging/book-42"
	if got != want {
		t.Errorf("explicit scope-named positional arg should win over ctx scope:\n got %q\nwant %q", got, want)
	}
}

// The fallback still holds: when no positional of that name is supplied, the
// :dataset placeholder resolves from ctx scope (the common core-command case,
// e.g. `bp doc get post p1` where dataset comes from --dataset / context).
func TestBuildURLScopePlaceholderFallsBackToCtx(t *testing.T) {
	m := &Manifest{}
	cmd := Command{
		ID:   "schema.list",
		HTTP: HTTP{Method: "GET", PathTemplate: "/v1/schemas/:dataset"},
	}
	ctx := Context{Server: "https://api.example.com", Dataset: "production"}
	got, err := m.BuildURL(cmd, ctx, map[string]string{})
	if err != nil {
		t.Fatalf("BuildURL returned error: %v", err)
	}
	want := "https://api.example.com/v1/schemas/production"
	if got != want {
		t.Errorf("scope placeholder should fall back to ctx when no arg supplied:\n got %q\nwant %q", got, want)
	}
}

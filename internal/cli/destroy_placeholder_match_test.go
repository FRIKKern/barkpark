package cli

import (
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// TestCommandReadsPlaceholderMatchesWholeNames pins the destroy gate's scope
// probe to the PLACEHOLDER SET the manifest's own parser extracts, not to a
// substring of the route text.
//
// commandReadsPlaceholder used to ask `strings.Contains(tmpl, ":"+n)`. The
// short scope aliases make that unsound by construction: the probe for the
// project scope passes the alias "p", and ":p" is a prefix of a great many
// legitimate placeholder names — :principal_ref, :paper_id, :plugin, :path.
// workspace.member-rm's own flat template IS "/v1/members/:principal_ref", so
// the substring test answers "this route reads the project scope" on the
// strength of a seat reference. requireStatedScope then refuses the destroy
// until the operator names a -p <project> the URL never consumes.
//
// The manifest already extracts the typed answer: placeholderRe /
// PathPlaceholders parse :names as whole tokens. Keying on that set makes the
// probe say what its own doc comment claims — "appears as a :placeholder".
func TestCommandReadsPlaceholderMatchesWholeNames(t *testing.T) {
	// The live shape: workspace.member-rm's flat template on its own.
	memberRm := manifest.Command{
		ID:   "workspace.member-rm",
		HTTP: manifest.HTTP{Method: "DELETE", PathTemplate: "/v1/members/:principal_ref"},
	}
	if commandReadsPlaceholder(memberRm, "project_slug", "project", "p") {
		t.Error(":principal_ref answered the :p scope query — the route reads no project " +
			"placeholder at all, but a substring match reported one, so requireStatedScope " +
			"would refuse the destroy until the operator states a scope the URL never consumes")
	}

	// The same false positive for the workspace alias, on a route that carries
	// a placeholder merely beginning with "ws".
	wsish := manifest.Command{
		HTTP: manifest.HTTP{Method: "DELETE", PathTemplate: "/v1/plugins/sheets/:wsheet_id"},
	}
	if commandReadsPlaceholder(wsish, "workspace_slug", "workspace", "ws") {
		t.Error(":wsheet_id answered the :ws scope query — a placeholder that merely " +
			"begins with the alias is not the alias")
	}

	// A longer name that merely EXTENDS a scope name is not that scope either.
	extended := manifest.Command{
		HTTP: manifest.HTTP{Method: "DELETE", PathTemplate: "/v1/things/:project_slugs"},
	}
	if commandReadsPlaceholder(extended, "project_slug", "project", "p") {
		t.Error(":project_slugs is a different placeholder from :project_slug")
	}

	// And the true positives must all survive — the gate's whole job.
	prefix := "/w/:workspace_slug/p/:project_slug"
	scoped := manifest.Command{
		HTTP:         manifest.HTTP{Method: "DELETE", PathTemplate: "/v1/tokens/:id"},
		ScopedPrefix: &prefix,
	}
	if !commandReadsPlaceholder(scoped, "workspace_slug", "workspace", "ws") {
		t.Error("lost :workspace_slug in the scoped_prefix — the gate would be dead")
	}
	if !commandReadsPlaceholder(scoped, "project_slug", "project", "p") {
		t.Error("lost :project_slug in the scoped_prefix")
	}
	selfScoped := manifest.Command{
		HTTP: manifest.HTTP{Method: "DELETE", PathTemplate: "/v1/workspaces/:ws/things/:id"},
	}
	if !commandReadsPlaceholder(selfScoped, "workspace_slug", "workspace", "ws") {
		t.Error("lost the short :ws alias when it IS the whole placeholder")
	}
}

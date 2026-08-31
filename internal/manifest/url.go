package manifest

import (
	"fmt"
	"net/url"
	"regexp"
	"strings"
)

// placeholderRe matches a :name path placeholder. Names are [A-Za-z0-9_], the
// Phoenix route-param convention the manifest templates use (e.g. :dataset,
// :type, :doc_id, :workspace_slug).
var placeholderRe = regexp.MustCompile(`:([A-Za-z0-9_]+)`)

// BuildURL assembles the absolute URL for cmd: it fills the flat
// http.path_template placeholders from ctx + args. The server base_url is read
// from ctx.Server.
//
// Scope prefix (contract rule #4): a command may carry a scoped_prefix HINT
// (e.g. "/w/:ws/p/:project"). Whether BuildURL prepends it is keyed on the
// command's auth_tier, because the tier is the code fact for WHERE the route is
// actually mounted:
//
//   - scoped_admin / scoped_read — the route exists ONLY under the
//     workspace/project prefix (e.g. POST /w/:ws/p/:project/v1/tokens; there is
//     no flat /v1/tokens). BuildURL MUST compose the prefix now, or every call
//     hits a non-existent flat path and 404s. This is the generic fix for the
//     whole scoped tier — token.create is the first inhabitant, not a special
//     case (vercel_cmd.go's vercelMintReadToken hand-rolls the same shape).
//   - read / write / admin / none — the flat path_template IS the live route
//     the server serves today; the scoped_prefix is a FUTURE mirror hint only
//     (e.g. doc.get). Prepending now would turn "/v1/data/query/..." into
//     "/w/default/p/default/v1/data/query/..." which 404/403s. These stay FLAT.
//
// The future full mirror (rule #4, all tiers scoped) still activates uniformly
// when ctx.ScopedMirror is true — a server that advertises the mirror composes
// every command's prefix, flat tiers included. A command with a nil/empty
// scoped_prefix is never composed regardless of tier (e.g. workspace.project-
// create is scoped_admin but self-scopes via :workspace_slug in its own path).
//
// Placeholder resolution per name:
//   - :dataset                          -> ctx.Dataset
//   - :workspace_slug / :workspace / :ws -> ctx.Workspace
//   - :project_slug / :project / :p      -> ctx.Project
//   - anything else                      -> args[name]
//
// A placeholder with no resolvable value is an error — better to fail loudly
// than to send a request to a path with an empty segment.
func (m *Manifest) BuildURL(cmd Command, ctx Context, args map[string]string) (string, error) {
	path := cmd.HTTP.PathTemplate

	if cmd.ScopedPrefix != nil && *cmd.ScopedPrefix != "" &&
		(isScopedTier(cmd.AuthTier) || ctx.ScopedMirror) {
		path = *cmd.ScopedPrefix + path
	}

	filled, err := fillTemplate(path, ctx, args)
	if err != nil {
		return "", fmt.Errorf("build url for %s: %w", cmd.ID, err)
	}

	base := strings.TrimRight(ctx.Server, "/")
	return base + filled, nil
}

// isScopedTier reports whether an auth_tier's route is mounted ONLY under the
// workspace/project prefix (never flat), so BuildURL must compose scoped_prefix
// for it now rather than deferring to the mirror. These are the two per-
// workspace-role tiers: scoped_admin (RequireWorkspaceRole admin/owner — e.g.
// token.create) and scoped_read (a workspace-scoped read). The global tiers
// (none/read/write/admin) keep serving their flat path_template today.
func isScopedTier(tier string) bool {
	switch tier {
	case "scoped_admin", "scoped_read":
		return true
	default:
		return false
	}
}

// fillTemplate replaces every :placeholder in tmpl, returning an error on the
// first one it cannot resolve.
func fillTemplate(tmpl string, ctx Context, args map[string]string) (string, error) {
	var missing string
	out := placeholderRe.ReplaceAllStringFunc(tmpl, func(match string) string {
		if missing != "" {
			return match
		}
		name := match[1:] // strip leading ':'
		val, ok := resolvePlaceholder(name, ctx, args)
		if !ok || val == "" {
			missing = name
			return match
		}
		// Path placeholders are single segments; escape so a value with a
		// space, '#', '?', or '%' can't corrupt the URL.
		return url.PathEscape(val)
	})
	if missing != "" {
		return "", fmt.Errorf("unresolved placeholder :%s", missing)
	}
	return out, nil
}

// PathPlaceholders returns the set of :placeholder names present in the
// command's flat http.path_template. The CLI uses this to decide whether a
// declared positional arg is path-bound (its name appears here) or whether it
// should instead ride as a ?query= param (reads) or a JSON body field (writes).
func (c Command) PathPlaceholders() map[string]bool {
	return PlaceholderNames(c.HTTP.PathTemplate)
}

// PlaceholderNames returns the set of :placeholder names in an ARBITRARY path
// template — the same whole-token parse fillTemplate performs, exposed for the
// callers that must judge a template the Command struct does not hold on its
// own (destroy_confirm's scope probe reads scoped_prefix + path_template
// composed, since :workspace_slug lives in the prefix).
//
// It exists so those callers stop reaching for `strings.Contains(tmpl, ":"+n)`.
// That substring test is unsound for the SHORT scope aliases the manifest
// defines (`ws`, `p`): ":p" is a prefix of :principal_ref, :paper_id, :plugin
// and :path, so a route carrying any of them was reported as reading the
// project scope. A placeholder is a whole token or it is not that placeholder.
func PlaceholderNames(tmpl string) map[string]bool {
	set := map[string]bool{}
	for _, m := range placeholderRe.FindAllString(tmpl, -1) {
		set[m[1:]] = true // strip leading ':'
	}
	return set
}

// ArgLocation reports where a declared arg's value belongs: "path", "query", or
// "body". The explicit arg.In hint wins when the Elixir manifest track sets it;
// otherwise the location is inferred — path if the arg name is a placeholder in
// http.path_template, else query for a read (GET) and body for a write
// (non-GET). A write GET (unusual) still infers query.
func (c Command) ArgLocation(a Arg) string {
	switch a.In {
	case "path", "query", "body":
		return a.In
	}
	if c.PathPlaceholders()[a.Name] {
		return "path"
	}
	if c.HTTP.Method == "GET" || (!c.Writes && c.HTTP.Method == "") {
		return "query"
	}
	if c.Writes {
		return "body"
	}
	return "query"
}

// resolvePlaceholder maps a placeholder name to its value. An explicitly-supplied
// positional arg of the same name wins over ambient ctx scope: a command that
// declares e.g. a positional `dataset` bound to `:dataset` (the shipped
// onixedit.export — `GET /v1/plugins/onixedit/export/:dataset/:id`) means the
// user to pick the dataset per call, so `bp onixedit export staging book-42`
// must hit /staging/, not the ctx default. Without this, resolvePlaceholder
// returned ctx.Dataset unconditionally and silently discarded the positional,
// targeting the wrong scope with no error. When no such arg is supplied, the
// scope names fall back to ctx (the common core-command case).
func resolvePlaceholder(name string, ctx Context, args map[string]string) (string, bool) {
	if v, ok := args[name]; ok && v != "" {
		return v, true
	}
	switch name {
	case "dataset":
		return ctx.Dataset, true
	case "workspace_slug", "workspace", "ws":
		return ctx.Workspace, true
	case "project_slug", "project", "p":
		return ctx.Project, true
	}
	v, ok := args[name]
	return v, ok
}

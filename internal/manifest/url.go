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
// (e.g. "/w/:ws/p/:project"). In v1 the scoped route mirror is deferred — it
// does not exist on any server — so the hint is INERT: BuildURL uses the flat
// path_template and does NOT prepend. Prepending against a flat-only server
// turns "/v1/data/query/..." into "/w/default/p/default/v1/data/query/..." which
// 404/403s. The prepend activates only when ctx.ScopedMirror is true (a future
// server that advertises the mirror); the hint still ships in the manifest so
// nothing needs a breaking change when that day comes.
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

	if ctx.ScopedMirror && cmd.ScopedPrefix != nil && *cmd.ScopedPrefix != "" {
		path = *cmd.ScopedPrefix + path
	}

	filled, err := fillTemplate(path, ctx, args)
	if err != nil {
		return "", fmt.Errorf("build url for %s: %w", cmd.ID, err)
	}

	base := strings.TrimRight(ctx.Server, "/")
	return base + filled, nil
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
	set := map[string]bool{}
	for _, m := range placeholderRe.FindAllString(c.HTTP.PathTemplate, -1) {
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

// resolvePlaceholder maps a placeholder name to its value from ctx-scope first,
// then the per-call args map.
func resolvePlaceholder(name string, ctx Context, args map[string]string) (string, bool) {
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

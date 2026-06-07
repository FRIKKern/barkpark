package manifest

import (
	"fmt"
	"regexp"
	"strings"
)

// placeholderRe matches a :name path placeholder. Names are [A-Za-z0-9_], the
// Phoenix route-param convention the manifest templates use (e.g. :dataset,
// :type, :doc_id, :workspace_slug).
var placeholderRe = regexp.MustCompile(`:([A-Za-z0-9_]+)`)

// BuildURL assembles the absolute URL for cmd: it fills the flat
// http.path_template placeholders from ctx + args and, when cmd.ScopedPrefix is
// non-nil, prepends the scope prefix LOCALLY (contract spine rule #4 — flat
// templates, CLI-side scope prepend). The server base_url is read from ctx.Server.
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

	if cmd.ScopedPrefix != nil && *cmd.ScopedPrefix != "" {
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
		return val
	})
	if missing != "" {
		return "", fmt.Errorf("unresolved placeholder :%s", missing)
	}
	return out, nil
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

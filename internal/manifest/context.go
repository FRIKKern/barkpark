package manifest

import "github.com/FRIKKern/barkpark/internal/apiclient"

// Context is the resolved target the CLI drives a command against: which server,
// which credential, and the workspace/project/dataset scope, plus the default
// output shape. It is the single bundle BuildURL fills path templates from.
type Context struct {
	Server    string
	Token     string
	Workspace string
	Project   string
	Dataset   string
	Output    string

	// ScopedMirror reports whether the target server exposes the workspace/
	// project-scoped route mirror. In v1 this is FALSE everywhere: the scoped
	// mirror is deferred (M0 decision rule #4), so a command's scoped_prefix hint
	// is INERT and BuildURL uses the flat path_template. When a future server
	// advertises the mirror, set this true (e.g. from a manifest server flag) and
	// BuildURL will prepend /w/:ws/p/:project. Prepending while false would point
	// the CLI at a non-existent path and break every scoped command.
	ScopedMirror bool

	// WorkspaceExplicit / ProjectExplicit record whether the scope was STATED by
	// the operator — via -w/-p, a BARKPARK_* var that is actually set, a repo
	// .barkpark.json, or the saved config — or whether it merely fell through to
	// the baked "default" floor. Resolve is the only thing that can know: by the
	// time anyone reads ctx.Workspace, `-w default` and no -w at all are the same
	// string. That is exactly why comparing the VALUE against "default" is not a
	// substitute — a workspace legitimately NAMED `default` is real, and naming it
	// explicitly has to keep working.
	//
	// Every read and every non-destructive write ignores these. The ambient floor
	// is a deliberate convenience and it stays. They exist for the destroy-tier
	// gate (cli/destroy_confirm.go), where a silent substitution is wrong even
	// where it is currently harmless: the server's cross-tenant rail downgrades a
	// misdirected revoke to a 404 only while `default` is an empty or unreachable
	// workspace, and on a local instance `default` is THE real, populated one.
	// "The server will catch it" is defence-in-depth reasoning resting on the last
	// remaining layer.
	//
	// FALSE IS THE FAIL-CLOSED ZERO VALUE, deliberately. A Context built as a
	// literal — a test, or a future caller that skips Resolve — reads as
	// not-explicit, so a destroy refuses and asks for the scope rather than
	// assuming one. Resolve sets them true when a layer above Defaults won.
	WorkspaceExplicit bool
	ProjectExplicit   bool
}

// ActiveContext is the persisted-context layer — the saved named target a user
// selects with `barkpark context use <name>`. v1 ships ONE default server and no
// persistence, so the layer is a clean seam: Resolve consults it between env and
// defaults, but the v1 caller passes a zero ActiveContext (everything empty).
// Wiring a real on-disk context store later means populating this struct;
// Resolve's precedence does not change.
type ActiveContext struct {
	Server    string
	Token     string
	Workspace string
	Project   string
	Dataset   string
	Output    string
}

// Defaults are the lowest-precedence fallbacks. Dataset defaults to "production"
// per M0 decision A2; Output defaults to "table".
type Defaults struct {
	Server    string
	Token     string
	Workspace string
	Project   string
	Dataset   string
	Output    string
}

// DefaultDefaults returns the baked-in v1 defaults (dataset "production",
// output "table", workspace/project "default"). A caller may override any of
// them before passing to Resolve.
func DefaultDefaults() Defaults {
	return Defaults{
		Workspace: "default",
		Project:   "default",
		Dataset:   "production",
		Output:    "table",
	}
}

// Flag keys recognised by Resolve's flags map. Using named constants keeps the
// flag-parsing layer and Resolve in agreement on one set of keys.
const (
	FlagServer    = "server"
	FlagToken     = "token"
	FlagWorkspace = "workspace"
	FlagProject   = "project"
	FlagDataset   = "dataset"
	FlagOutput    = "output"
)

// Resolve composes a Context by precedence: flags > env > active context >
// defaults. The first non-empty value at the highest-precedence layer wins per
// field, independently. The env layer is read through apiclient.ConfigFromEnv so
// the CLI and the existing client share one BARKPARK_* contract.
//
// Note: ConfigFromEnv itself bakes in fallbacks ("http://localhost:4000",
// "barkpark-dev-token", "default"/"default"/"production") when the env var is
// unset, so the env layer is effectively never empty for those fields. That
// matches the TUI's historical behaviour. To let the lower layers (active
// context, explicit defaults) win when the operator did NOT set an env var,
// pass a Defaults built from DefaultDefaults and rely on flags/active-context to
// override; the env fallbacks are the documented v1 floor.
func Resolve(flags map[string]string, env apiclient.Config, active ActiveContext, defaults Defaults) Context {
	ctx, _ := ResolveWithSources(flags, env, active, defaults)
	return ctx
}

// Layer names the precedence layer ResolveWithSources took a field's value from.
// These are the ONLY four layers Resolve folds, in order.
const (
	LayerFlag    = "flag"
	LayerEnv     = "env"
	LayerActive  = "active"
	LayerDefault = "default"
)

// Sources reports, per field, WHICH layer supplied the value Resolve returned.
// It exists so a caller that must EXPLAIN a resolved value ("which credential
// did bp just use?") reads the answer out of the same pick that chose it,
// instead of re-deriving the precedence next to it and drifting. Every field
// carries one of the Layer* constants.
type Sources struct {
	Server    string
	Token     string
	Workspace string
	Project   string
	Dataset   string
	Output    string
}

// ResolveWithSources is Resolve plus the provenance of every field it picked.
// Resolve delegates to it, so there is exactly ONE implementation of the
// precedence and the label can never disagree with the value it describes.
func ResolveWithSources(flags map[string]string, env apiclient.Config, active ActiveContext, defaults Defaults) (Context, Sources) {
	// stated reports whether a layer ABOVE Defaults supplied the value — the only
	// form of "the operator said so" that survives into the Context. It mirrors
	// pick's precedence deliberately and sits directly above it: a provenance flag
	// kept in a separate place from the value it describes is how the two drift.
	stated := func(flagKey, envVal, activeVal string) bool {
		if v, ok := flags[flagKey]; ok && v != "" {
			return true
		}
		return envVal != "" || activeVal != ""
	}
	// pick returns the winning value AND the layer it came from — one traversal,
	// so the label is a by-product of the choice rather than a second opinion
	// about it.
	pick := func(flagKey, envVal, activeVal, defVal string) (string, string) {
		if v, ok := flags[flagKey]; ok && v != "" {
			return v, LayerFlag
		}
		if envVal != "" {
			return envVal, LayerEnv
		}
		if activeVal != "" {
			return activeVal, LayerActive
		}
		return defVal, LayerDefault
	}

	var src Sources
	server, srcServer := pick(FlagServer, env.BaseURL, active.Server, defaults.Server)
	token, srcToken := pick(FlagToken, env.Token, active.Token, defaults.Token)
	workspace, srcWorkspace := pick(FlagWorkspace, env.Workspace, active.Workspace, defaults.Workspace)
	project, srcProject := pick(FlagProject, env.Project, active.Project, defaults.Project)
	dataset, srcDataset := pick(FlagDataset, env.Dataset, active.Dataset, defaults.Dataset)
	// Output has no env field on apiclient.Config; flags > active > default.
	output, srcOutput := pick(FlagOutput, "", active.Output, defaults.Output)
	src = Sources{
		Server:    srcServer,
		Token:     srcToken,
		Workspace: srcWorkspace,
		Project:   srcProject,
		Dataset:   srcDataset,
		Output:    srcOutput,
	}

	return Context{
		Server:    server,
		Token:     token,
		Workspace: workspace,
		Project:   project,
		Dataset:   dataset,
		Output:    output,

		WorkspaceExplicit: stated(FlagWorkspace, env.Workspace, active.Workspace),
		ProjectExplicit:   stated(FlagProject, env.Project, active.Project),
	}, src
}

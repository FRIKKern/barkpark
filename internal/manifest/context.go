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
	pick := func(flagKey, envVal, activeVal, defVal string) string {
		if v, ok := flags[flagKey]; ok && v != "" {
			return v
		}
		if envVal != "" {
			return envVal
		}
		if activeVal != "" {
			return activeVal
		}
		return defVal
	}

	return Context{
		Server:    pick(FlagServer, env.BaseURL, active.Server, defaults.Server),
		Token:     pick(FlagToken, env.Token, active.Token, defaults.Token),
		Workspace: pick(FlagWorkspace, env.Workspace, active.Workspace, defaults.Workspace),
		Project:   pick(FlagProject, env.Project, active.Project, defaults.Project),
		Dataset:   pick(FlagDataset, env.Dataset, active.Dataset, defaults.Dataset),
		// Output has no env field on apiclient.Config; flags > active > default.
		Output: pick(FlagOutput, "", active.Output, defaults.Output),
	}
}

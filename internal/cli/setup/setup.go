// Package setup is the engine behind the `bp setup` built-in. It turns a
// declarative SetupPlan into side effects: today the CONNECT target (point the
// CLI at an existing server, confirm reachability + caller tier, persist the
// connection); Local/Deploy/Provision are stubbed seams the modes step fills.
//
// The package is deliberately decoupled from the cli package's config storage to
// avoid an import cycle (cli imports setup for the built-in). Persistence is
// injected through Options.Store — the cli built-in passes an adapter over
// cli.LoadConfig / cli.SaveConfig, and a test passes an in-memory store. The
// interactive wizard is likewise a hook (Options.Wizard) the modes step wires;
// the foundation only defines the seam.
package setup

import (
	"errors"
	"fmt"
	"io"
	"strings"
)

// Target enumerates the four setup modes. Only "connect" is implemented in this
// foundation step; the others return a clear not-yet error from Execute.
type Target = string

const (
	TargetConnect   Target = "connect"   // point the CLI at an existing server
	TargetLocal     Target = "local"     // bring up a local dev server (modes step)
	TargetDeploy    Target = "deploy"    // deploy to an existing host over SSH (modes step)
	TargetProvision Target = "provision" // provision a fresh cloud host (modes step)
)

// SetupPlan is the fully-resolved, declarative description of what `bp setup`
// should do. The CLI built-in (or the wizard) fills it; Execute consumes it.
// Per-target fields are grouped by comment; an unused field for a given target
// is simply ignored.
type SetupPlan struct {
	Target Target

	// connect / all
	Server    string
	Token     string
	Workspace string
	Project   string
	Dataset   string

	// local / deploy
	Docker  bool   // run via docker-compose rather than native toolchain
	SSHHost string // user@host for the deploy target
	Domain  string // public DNS hostname for the cutover
	Scheme  string // http | https

	// provision
	Provider   string // hetzner | azure
	Region     string
	ServerType string // e.g. cax11

	// shared
	Plugins []string // plugin slugs to enable post-setup
}

// Validate checks the plan is internally consistent for its Target before any
// side effect runs. It is intentionally strict for connect (the implemented
// path) and lenient for the stubbed targets (their full validation lands with
// the modes step), only checking the Target itself is known.
func (p SetupPlan) Validate() error {
	switch p.Target {
	case TargetConnect:
		if strings.TrimSpace(p.Server) == "" {
			return fmt.Errorf("setup connect: --server is required")
		}
		if !strings.HasPrefix(p.Server, "http://") && !strings.HasPrefix(p.Server, "https://") {
			return fmt.Errorf("setup connect: --server %q must start with http:// or https://", p.Server)
		}
	case TargetLocal:
		// Local has no required inputs (docker-vs-native is a bool; plugins are
		// optional). Nothing to validate beyond the known target.
	case TargetDeploy:
		return validateDeploy(p)
	case TargetProvision:
		return validateProvision(p)
	case "":
		return fmt.Errorf("setup: no target (want one of connect|local|deploy|provision)")
	default:
		return fmt.Errorf("setup: unknown target %q (want connect|local|deploy|provision)", p.Target)
	}
	return nil
}

// ConfigStore is the persistence seam Execute writes the resolved connection
// through. The cli built-in adapts cli.LoadConfig / cli.SaveConfig onto it; a
// test passes an in-memory implementation. It is intentionally minimal — the
// only fields setup touches are the connection + scope.
type ConfigStore interface {
	// Save persists the resolved connection. Implementations write tokens to
	// disk at 0600; setup never inspects how.
	Save(SavedConfig) error
}

// SavedConfig is the connection bundle Execute hands the store on a successful
// connect. It mirrors the fields cli.Config carries that setup is responsible
// for; the adapter maps it onto the real cli.Config.
type SavedConfig struct {
	Server    string
	Token     string
	Workspace string
	Project   string
	Dataset   string
}

// WizardFunc is the interactive-wizard hook. The modes step implements it
// (prompt the user, return a fully-formed SetupPlan). The foundation leaves it
// nil; RunInteractive reports the clean "see modes step" message when it is.
type WizardFunc func(opts Options) (SetupPlan, error)

// Options carry the cross-cutting knobs for one Execute call: where to print,
// whether to actually mutate (DryRun), whether the caller pre-confirmed, the
// persistence store, and the interactive-wizard hook.
type Options struct {
	DryRun  bool
	Confirm bool
	Out     io.Writer

	// Store persists the connection on a successful connect. Required for a
	// non-dry-run connect; a nil store on a real connect is an error.
	Store ConfigStore

	// Wizard, when set, drives the interactive flow (no --target given on a TTY).
	// The foundation leaves it nil — RunInteractive then prints the modes-step
	// pointer. The modes agent wires the real wizard here.
	Wizard WizardFunc

	// JSON, when true, suppresses every executor's human prose on Out: the cli
	// built-in renders the structured Plan (dry-run) or Result (real run) itself
	// after Execute/BuildPlan returns. Executors check opts.json() before writing
	// any progress narration so a JSON run keeps stdout machine-clean.
	JSON bool

	// Result, when non-nil, receives the structured outcome of a successful real
	// (non-dry-run) Execute so the JSON caller can render it. Executors fill it on
	// success; a nil pointer means the caller does not want it (human path).
	Result *Result
}

// json reports whether this run should suppress human prose (the cli built-in
// renders structured JSON instead).
func (o Options) json() bool { return o.JSON }

// setResult records the structured real-run outcome when the caller wired a
// Result pointer; a no-op otherwise.
func (o Options) setResult(r Result) {
	if o.Result != nil {
		*o.Result = r
	}
}

// out returns a non-nil writer for opts, defaulting to io.Discard so a zero
// Options never panics.
func (o Options) out() io.Writer {
	if o.Out != nil {
		return o.Out
	}
	return io.Discard
}

// Execute dispatches a SetupPlan to its target executor after validating it.
// CONNECT is fully implemented; Local/Deploy/Provision are stubs that return a
// clear "implemented in the modes step" error so the dispatch shape is locked in
// and the modes agent only fills the executor bodies.
func Execute(plan SetupPlan, opts Options) error {
	if err := plan.Validate(); err != nil {
		return err
	}
	switch plan.Target {
	case TargetConnect:
		return executeConnect(plan, opts)
	case TargetLocal:
		return executeLocal(plan, opts)
	case TargetDeploy:
		return executeDeploy(plan, opts)
	case TargetProvision:
		return executeProvision(plan, opts)
	default:
		// Validate already rejects this; kept for total switch coverage.
		return fmt.Errorf("setup: unknown target %q", plan.Target)
	}
}

// BuildPlan returns the structured dry-run Plan for a SetupPlan WITHOUT any side
// effect (no network, no writes, no shelling out). It validates first, then
// dispatches to the per-target plan builder. The cli built-in calls this for the
// JSON dry-run path; the human dry-run path inside each executor builds the same
// Plan and renders it via Plan.RenderHuman, so the two never drift.
func BuildPlan(plan SetupPlan, opts Options) (Plan, error) {
	if err := plan.Validate(); err != nil {
		return Plan{}, err
	}
	switch plan.Target {
	case TargetConnect:
		return buildConnectPlan(plan, opts), nil
	case TargetLocal:
		return buildLocalPlan(plan, opts), nil
	case TargetDeploy:
		return buildDeployPlan(plan, opts)
	case TargetProvision:
		return buildProvisionPlan(plan, opts)
	default:
		return Plan{}, fmt.Errorf("setup: unknown target %q", plan.Target)
	}
}

// RunInteractive is the clean hook for the no-target-on-a-TTY path. The modes
// step wires a real wizard via Options.Wizard; until then it prints the pointer
// and returns nil so a bare `bp setup` on a TTY is informative, not an error.
func RunInteractive(opts Options) error {
	if opts.Wizard != nil {
		plan, err := opts.Wizard(opts)
		if err != nil {
			if errors.Is(err, ErrWizardAborted) {
				fmt.Fprintln(opts.out(), "setup: aborted — nothing was run.")
				return nil
			}
			return err
		}
		// The wizard already showed the dry-run plan and got the user's explicit
		// "y" on the confirm screen; run for real.
		runOpts := opts
		runOpts.DryRun = false
		runOpts.Confirm = true
		return Execute(plan, runOpts)
	}
	fmt.Fprintln(opts.out(), "interactive wizard: see modes step (run `bp setup --target connect --server <url>` for now)")
	return nil
}

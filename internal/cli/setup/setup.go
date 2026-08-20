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
	TargetCloud     Target = "cloud"     // log in to Barkpark Cloud and pick a Barkpark
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
	Name      string // optional short handle saved with the connection (bp use <name>)
	Token     string
	Workspace string
	Project   string
	Dataset   string

	// InstanceID is the STABLE control-plane identity of the target instance, when
	// the caller learned it (the cloud fleet row's Barkpark.ID). It threads through
	// to ServerEntry.InstanceID so two hostnames of one instance collapse to a
	// single known-server entry instead of minting a phantom "-2" (D4/D9). Empty on
	// a self-hosted connect with no control plane — identity falls back to URL.
	InstanceID string
	// Team is the human name of the Cloud team that owns the target instance, when
	// known (the fleet row's Team.Name). Threads through to ServerEntry.Team as
	// identity only. Empty when there is no control-plane team.
	Team string

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

	// Profile is the seed content profile for the targets that seed a database
	// (local/deploy/provision): "clean" (papers + media + one welcome paper —
	// the premium default on every bp-driven path) or "demo" (the 8-schema /
	// 27-doc kitchen-sink fixture). Empty defaults to clean; connect ignores it
	// (a pure upsert never seeds).
	Profile string
}

// Seed content profiles. Clean is the default on every bp-driven path; demo
// stays reachable via --profile demo (or a raw mix seed run, which never sets
// BARKPARK_SEED_PROFILE and therefore keep today's behaviour byte-identical).
const (
	ProfileClean = "clean"
	ProfileDemo  = "demo"
)

// profileOrDefault resolves the plan's seed profile, defaulting empty to clean.
func (p SetupPlan) profileOrDefault() string {
	if strings.TrimSpace(p.Profile) == "" {
		return ProfileClean
	}
	return strings.TrimSpace(p.Profile)
}

// Validate checks the plan is internally consistent for its Target before any
// side effect runs. It is intentionally strict for connect (the implemented
// path) and lenient for the stubbed targets (their full validation lands with
// the modes step), only checking the Target itself is known.
func (p SetupPlan) Validate() error {
	switch strings.TrimSpace(p.Profile) {
	case "", ProfileClean, ProfileDemo:
	default:
		return fmt.Errorf("setup: --profile %q must be clean or demo", p.Profile)
	}
	switch p.Target {
	case TargetConnect:
		if strings.TrimSpace(p.Server) == "" {
			return fmt.Errorf("setup connect: --server is required")
		}
		if !strings.HasPrefix(p.Server, "http://") && !strings.HasPrefix(p.Server, "https://") {
			return fmt.Errorf("setup connect: --server %q must start with http:// or https://", p.Server)
		}
	case TargetCloud:
		// Cloud has no plan-internal inputs: it logs in via the injected CloudLogin
		// hook and resolves the server from the picked Barkpark. The hook's presence
		// is Options-scoped, so it is enforced in executeCloud / buildCloudPlan
		// (which see Options) rather than here (Validate sees only the plan). A nil
		// hook there is a clear "no Barkpark Cloud login is wired" error.
	case TargetLocal:
		// Local has no required inputs (docker-vs-native is a bool; plugins are
		// optional). Nothing to validate beyond the known target.
	case TargetDeploy:
		return validateDeploy(p)
	case TargetProvision:
		return validateProvision(p)
	case "":
		return fmt.Errorf("setup: no target (want one of connect|cloud|local|deploy|provision)")
	default:
		return fmt.Errorf("setup: unknown target %q (want connect|cloud|local|deploy|provision)", p.Target)
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
// for; the adapter maps it onto the real cli.Config (and into the connect
// history via cli.Config.RememberServer).
type SavedConfig struct {
	Server    string
	Name      string // optional short handle (bp use <name>); empty → adapter derives one
	Token     string
	Workspace string
	Project   string
	Dataset   string

	// InstanceID + Team carry the control-plane identity the connect executor
	// resolved from the caller's plan onto the remembered ServerEntry: the adapter
	// stamps entry.InstanceID (the collapse key that kills the phantom "-2") and
	// entry.Team. Both empty on a self-hosted connect with no control plane.
	InstanceID string
	Team       string

	// Tier is the resolved auth tier the connect probe reported. The adapter
	// records it on the remembered ServerEntry so the pick-list can show it.
	Tier string

	// LastConnected is the RFC3339 timestamp the executor stamps on a successful
	// connect (time.Now in the executor — kept out of the pure history helper).
	// The adapter passes it straight into ServerEntry.LastConnected.
	LastConnected string
}

// KnownServerInfo is one remembered server projected into the setup package for
// the wizard pick-list and the connect Plan's known_servers array. The cli
// adapter builds these from cli.Config.KnownServerList so setup never imports
// cli. Token/scope ride along so the wizard can re-select a saved server
// without re-prompting for credentials.
type KnownServerInfo struct {
	Server        string
	Token         string
	Workspace     string
	Project       string
	Dataset       string
	Tier          string
	LastConnected string // RFC3339, "" if unknown
	Active        bool   // true for the currently-active server
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

	// KnownServers is the connect history (most-recent-first) the cli built-in
	// loaded from the persisted config. The connect Plan surfaces it as
	// known_servers; the wizard offers it as a pick-list. Empty on a first run.
	KnownServers []KnownServerInfo

	// CloudLogin drives the TargetCloud path: it logs the user in to Barkpark
	// Cloud, then resolves a Barkpark to connect to (or reports a logged-in-only
	// outcome). The cli built-in injects it (setup_cloud_login.go) so the setup
	// package never imports cloudclient. A nil hook makes TargetCloud a clear
	// error from executeCloud / buildCloudPlan.
	CloudLogin CloudLoginFunc
}

// CloudLoginResult is what a CloudLogin hook yields on success. Either it carries
// a Server + Token to connect bp to (the user picked a Barkpark from their fleet),
// or LoggedInOnly is true — the user is authenticated but has (or chose) no server
// to connect to. A logged-in-only outcome is COMPLETE, not a dead end: being
// logged in is itself a valid end state (exit 0).
type CloudLoginResult struct {
	Server       string // the picked Barkpark's URL (empty ⇒ logged-in-only)
	Token        string // the picked Barkpark's admin token (persisted as the server token; never printed)
	Name         string // the Barkpark's name, saved as the short handle
	InstanceID   string // the picked Barkpark's stable control-plane ID (fleet row Barkpark.ID); collapses aliases to one entry
	Team         string // the human name of the owning Cloud team (fleet row Team.Name); identity only
	LoggedInOnly bool   // true ⇒ authenticated but not connecting to any server
}

// CloudLoginFunc is the CLI-injected hook the setup package calls for TargetCloud.
// Keeping it a func (rather than importing cloudclient) is the whole point of the
// seam: setup stays free of the control-plane client. It receives the same Options
// Execute runs under so the hook can honor DryRun / Out if it wants.
type CloudLoginFunc func(opts Options) (CloudLoginResult, error)

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
	case TargetCloud:
		return executeCloud(plan, opts)
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
	case TargetCloud:
		return buildCloudPlan(plan, opts)
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

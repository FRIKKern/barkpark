package cli

import (
	"fmt"
	"os"

	"github.com/FRIKKern/barkpark/internal/cli/setup"
	"github.com/mattn/go-isatty"
)

// configStoreAdapter bridges the cli package's on-disk Config persistence onto
// the setup package's ConfigStore seam, breaking the would-be import cycle
// (cli imports setup; setup must not import cli). It loads the existing config
// so a connect preserves admin/ingest tokens the user set elsewhere, overlays
// the connection setup resolved, and writes it back 0600.
type configStoreAdapter struct{}

func (configStoreAdapter) Save(s setup.SavedConfig) error {
	// Preserve any non-connection fields (admin/ingest tokens, output pref) the
	// user already persisted; overlay the connection setup resolved. RememberServer
	// both promotes this server to the active flat context AND upserts it into the
	// most-recent-first connect history, so the next wizard run offers it.
	cfg, err := LoadConfig()
	if err != nil {
		cfg = &Config{}
	}
	cfg.RememberServer(ServerEntry{
		Name:          s.Name,
		Server:        s.Server,
		Token:         s.Token,
		Workspace:     s.Workspace,
		Project:       s.Project,
		Dataset:       s.Dataset,
		Tier:          s.Tier,
		LastConnected: s.LastConnected,
	})
	return SaveConfig(cfg)
}

// loadKnownServers projects the persisted connect history into the setup
// package's KnownServerInfo view (most-recent-first), marking the active one.
// A load failure yields an empty list — the wizard/plan simply show no cache.
func loadKnownServers() []setup.KnownServerInfo {
	cfg, err := LoadConfig()
	if err != nil {
		return nil
	}
	list := cfg.KnownServerList()
	out := make([]setup.KnownServerInfo, 0, len(list))
	for _, e := range list {
		out = append(out, setup.KnownServerInfo{
			Server:        e.Server,
			Token:         e.Token,
			Workspace:     e.Workspace,
			Project:       e.Project,
			Dataset:       e.Dataset,
			Tier:          e.Tier,
			LastConnected: e.LastConnected,
			Active:        cfg.IsActiveServer(e.Server),
		})
	}
	return out
}

// activeSavedServer resolves the currently-active saved server into a setup
// ServerEntry-equivalent for the connect-without-`--server` convenience: it loads
// the config, reads ActiveServer(), and finds the matching KnownServers entry so
// the reconnect carries that server's token + scope. It returns ok=false when no
// config / no active server exists (the clean usage-error case). When the active
// URL has no matching history entry (an edge case), it still returns the URL with
// empty credentials so the caller defaults to anonymous reads / standard scope.
func activeSavedServer() (ServerEntry, bool) {
	cfg, err := LoadConfig()
	if err != nil {
		return ServerEntry{}, false
	}
	active := cfg.ActiveServer()
	if active == "" {
		return ServerEntry{}, false
	}
	for _, e := range cfg.KnownServerList() {
		if cfg.IsActiveServer(e.Server) {
			return e, true
		}
	}
	return ServerEntry{Server: active}, true
}

// runSetup is the `bp setup` built-in. It is first-class for AI/automation: the
// interactive Bubble Tea wizard launches ONLY on a genuine interactive terminal
// with no --target and no machine-output/--yes flags; every other path is
// non-interactive and NEVER touches /dev/tty. With -o json (or --json) the plan,
// the real-run result, and any error are emitted as a single machine-readable
// JSON object on stdout.
//
// Recognised flags: --target, --server, --token, --workspace, --project,
// --dataset, --docker, --ssh-host, --domain, --scheme, --provider, --region,
// --server-type, --plugins. The global --dry-run drives DryRun; --yes confirms a
// destructive/outbound real run; -o json / --json select machine output.
func runSetup(out *writer, g globals, tail []string) int {
	// JSON mode is driven by an EXPLICIT -o json / --json only. The writer's
	// piped-default ("json when stdout is not a tty") must NOT silently turn
	// setup machine-mode: the contract is that an agent opts in with -o json, and
	// a plain piped run still gets human prose / a one-line error. g.outputSet is
	// true exactly when the user passed -o/--output or --json.
	jsonOut := g.outputSet && g.output == "json"

	// (2) TTY-SAFE HELP — must come BEFORE any wizard/TTY logic so `bp setup -h`
	// prints usage instead of opening /dev/tty.
	if g.help || hasHelpFlag(tail) {
		printSetupHelp(out)
		return exitOK
	}

	plan, parsed, perr := parseSetupFlags(tail)
	if perr != nil {
		return setupUsageError(out, jsonOut, "usage", perr.Error())
	}

	// Fall through to the global -s/-w/-p/-d when the setup-local flag is absent,
	// so `bp -s URL setup --target connect` works too.
	if plan.Server == "" {
		plan.Server = g.server
	}
	if plan.Workspace == "" {
		plan.Workspace = g.workspace
	}
	if plan.Project == "" {
		plan.Project = g.project
	}
	if plan.Dataset == "" {
		plan.Dataset = g.dataset
	}
	// --token is a GLOBAL flag (shared with migrate), so the global parser captures
	// it into g.token before setup's own flag parse sees it. Thread it through so
	// `bp setup --target connect --token X` actually persists the token onto the
	// saved server (otherwise plan.Token stays empty and the entry saves tokenless).
	if plan.Token == "" {
		plan.Token = g.token
	}

	// CONNECT convenience: when no --server was given anywhere (setup-local nor the
	// global -s fall-through), default to the ACTIVE saved server so a returning
	// agent/user reconnects without re-typing the URL. The matching KnownServers
	// entry's token + scope ride along so the reconnect is complete; an explicit
	// --server always overrides (handled above — this only fires on empty Server).
	// With no saved server yet, reconnectedToSaved stays false and the empty-Server
	// case falls through to Validate's clean usage error below.
	reconnectedToSaved := false
	if parsed["target"] && plan.Target == setup.TargetConnect && plan.Server == "" {
		if entry, ok := activeSavedServer(); ok {
			plan.Server = entry.Server
			if plan.Token == "" {
				plan.Token = entry.Token
			}
			if plan.Workspace == "" {
				plan.Workspace = entry.Workspace
			}
			if plan.Project == "" {
				plan.Project = entry.Project
			}
			if plan.Dataset == "" {
				plan.Dataset = entry.Dataset
			}
			reconnectedToSaved = true
		}
	}

	opts := setup.Options{
		DryRun:       g.dryRun,
		Confirm:      g.yes,
		Out:          out.stdout,
		Store:        configStoreAdapter{},
		Wizard:       setup.Wizard,
		JSON:         jsonOut,
		KnownServers: loadKnownServers(),
	}

	// (3) NEVER-PROMPT / NEVER-HANG. No --target: the interactive wizard launches
	// ONLY when ALL of: stdin AND stdout are a TTY, not -o json/--json, not --yes.
	// Any other no-target case is a CLEAN error (never /dev/tty), exit 2.
	if !parsed["target"] {
		if canRunWizard(jsonOut, g.yes) {
			if err := setup.RunInteractive(opts); err != nil {
				out.errf("barkpark: %v", err)
				return exitGeneric
			}
			return exitOK
		}
		return setupUsageError(out, jsonOut, "usage",
			"no --target and not an interactive terminal — pass --target connect|local|deploy|provision (see bp setup -h)")
	}

	// CONNECT with no --server AND no active saved server to fall back on: a clean
	// usage error (exit 2), never a prompt. This is more actionable than Validate's
	// bare "--server is required" because it tells the agent both escape hatches.
	if plan.Target == setup.TargetConnect && plan.Server == "" && !reconnectedToSaved {
		return setupUsageError(out, jsonOut, "usage",
			"no --server and no saved server yet — pass --server <url> or run `bp setup` interactively")
	}

	// (4) NON-INTERACTIVE INPUT VALIDATION — surface SetupPlan.Validate's errors as
	// a clean structured error (exit 2), NEVER a prompt. (Validate runs again
	// inside Execute/BuildPlan; this fail-fast keeps the error path uniform.)
	if verr := plan.Validate(); verr != nil {
		return setupUsageError(out, jsonOut, "usage", verr.Error())
	}

	// When the saved-server default kicked in, make the reconnect explicit on the
	// human path so the user/agent sees which URL we resolved and how to override.
	// JSON callers read connect_to / known_servers from the plan or result instead.
	if reconnectedToSaved && !jsonOut {
		out.outf("reconnecting to saved server %s (pass --server to override)", plan.Server)
	}

	// (1) STRUCTURED JSON / human DRY-RUN.
	if g.dryRun {
		built, berr := setup.BuildPlan(plan, opts)
		if berr != nil {
			return setupUsageError(out, jsonOut, "usage", berr.Error())
		}
		if jsonOut {
			out.renderJSON(setupPlanEnvelope(built))
			return exitOK
		}
		// Human dry-run: let the executor print its prose (byte-identical to the
		// pre-refactor output).
		if err := setup.Execute(plan, opts); err != nil {
			out.errf("barkpark: %v", err)
			return exitGeneric
		}
		return exitOK
	}

	// REAL RUN. (5) --yes is the confirm for destructive/outbound runs (unchanged).
	var result setup.Result
	opts.Result = &result
	if err := setup.Execute(plan, opts); err != nil {
		return setupRunError(out, jsonOut, err)
	}
	if jsonOut {
		result.OK = true
		out.renderJSON(result)
	}
	return exitOK
}

// RunFirstTimeSetup is the bare-`bp` first-run path: print the welcome banner,
// run the interactive setup wizard against the same store/wizard wiring
// runSetup uses, and report whether a server actually got configured so main
// can fall through into the TUI. An abort is a clean exit 0 (configured=false);
// a failed execute is exit 1. The caller is responsible for the TTY check —
// this never opens /dev/tty on its own beyond the Bubble Tea program itself.
func RunFirstTimeSetup() (configured bool, exit int) {
	out := newWriter(os.Stdout, os.Stderr)
	out.outf("Welcome to Barkpark — no server is configured yet.")
	out.outf("")
	out.outf("  bp can connect to an existing server, bring one up on this")
	out.outf("  machine, or install one on a server you own.")
	out.outf("")

	opts := setup.Options{
		Out:          os.Stdout,
		Store:        configStoreAdapter{},
		Wizard:       setup.Wizard,
		KnownServers: loadKnownServers(),
	}
	if err := setup.RunInteractive(opts); err != nil {
		out.errf("barkpark: %v", err)
		return false, exitGeneric
	}
	// RunInteractive returns nil on both success and a clean abort; a config on
	// disk is the success signal (the connect chain persisted it).
	return !FirstRun(), exitOK
}

// canRunWizard reports whether the interactive wizard may launch: a genuine
// interactive terminal (BOTH stdin and stdout are a TTY) AND not a machine-output
// request (-o json) AND not a pre-confirmed run (--yes). Any false here routes to
// the clean no-target error instead of opening /dev/tty.
func canRunWizard(jsonOut, yes bool) bool {
	if jsonOut || yes {
		return false
	}
	return isatty.IsTerminal(os.Stdin.Fd()) && isatty.IsTerminal(os.Stdout.Fd())
}

// hasHelpFlag scans setup's own tail for -h/--help (parseGlobals leaves these in
// tail for the setup noun, so we detect them here before any TTY logic).
func hasHelpFlag(tail []string) bool {
	for _, a := range tail {
		if a == "-h" || a == "--help" {
			return true
		}
	}
	return false
}

// setupPlanEnvelope wraps a structured Plan in the {"ok":true, …plan} object the
// JSON dry-run emits. The Plan's own JSON tags supply the body; ok is added.
func setupPlanEnvelope(p setup.Plan) map[string]any {
	return map[string]any{
		"ok":               true,
		"target":           p.Target,
		"dry_run":          p.DryRun,
		"destructive":      p.Destructive,
		"requires_confirm": p.RequiresConfirm,
		"steps":            planStepsJSON(p.Steps),
		"env":              p.Env,
		"plugins":          planPluginsJSON(p.Plugins),
		"needs":            planNeedsJSON(p.Needs),
		"connect_to":       p.ConnectTo,
		"known_servers":    planKnownServersJSON(p.KnownServers),
		"profile":          emptyToOmit(p.Profile),
		"provider":         emptyToOmit(p.Provider),
		"region":           emptyToOmit(p.Region),
		"server_type":      emptyToOmit(p.ServerType),
	}
}

// planKnownServersJSON renders the connect history for the JSON dry-run. Always
// an array (possibly empty) so an agent can rely on the key being present on a
// connect plan.
func planKnownServersJSON(servers []setup.PlanKnownServer) []map[string]any {
	out := make([]map[string]any, 0, len(servers))
	for _, s := range servers {
		m := map[string]any{"server": s.Server, "active": s.Active}
		if s.LastConnected != "" {
			m["last_connected"] = s.LastConnected
		}
		out = append(out, m)
	}
	return out
}

func planStepsJSON(steps []setup.PlanStep) []map[string]any {
	out := make([]map[string]any, 0, len(steps))
	for _, s := range steps {
		m := map[string]any{"n": s.N, "description": s.Description}
		if s.Command != "" {
			m["command"] = s.Command
		}
		out = append(out, m)
	}
	return out
}

func planPluginsJSON(p setup.PlanPlugins) map[string]any {
	m := map[string]any{"mode": p.Mode}
	if p.Value != "" {
		m["value"] = p.Value
	}
	return m
}

func planNeedsJSON(needs []setup.PlanNeed) []map[string]any {
	out := make([]map[string]any, 0, len(needs))
	for _, n := range needs {
		out = append(out, map[string]any{"what": n.What, "present": n.Present})
	}
	return out
}

func emptyToOmit(s string) any {
	if s == "" {
		return nil
	}
	return s
}

// setupUsageError emits a usage-class error: JSON {ok:false,error:{code,message}}
// on stdout when -o json, else a one-line message on stderr. Always exit 2.
func setupUsageError(out *writer, jsonOut bool, code, msg string) int {
	if jsonOut {
		out.renderJSON(map[string]any{
			"ok":    false,
			"error": map[string]any{"code": code, "message": msg},
		})
		return exitUsage
	}
	out.errf("barkpark: %s", msg)
	return exitUsage
}

// setupRunError emits a real-run failure. JSON callers get the structured error
// on stdout; human callers get the message on stderr. Exit is generic (1) — the
// setup engine's errors are operational (network/SSH/install), not the API's
// coded envelope.
func setupRunError(out *writer, jsonOut bool, err error) int {
	if jsonOut {
		out.renderJSON(map[string]any{
			"ok":    false,
			"error": map[string]any{"code": "failed", "message": err.Error()},
		})
		return exitGeneric
	}
	out.errf("barkpark: %v", err)
	return exitGeneric
}

// printSetupHelp writes the `bp setup` usage to stdout WITHOUT touching the TTY.
func printSetupHelp(out *writer) {
	const help = `bp setup — connect to, bring up, deploy, or provision a Barkpark server.

USAGE
  bp setup --target <connect|local|deploy|provision> [flags]
  bp setup                       # interactive wizard (TTY only)

TARGETS
  connect     point bp at an existing server (--server URL)
  local       bring up a local dev server here (--docker for compose)
  deploy      install on a server you own over SSH (--ssh-host, --domain)
  provision   create a cloud host, then deploy (--provider; staged)

FLAGS
  --target <t>        one of connect|local|deploy|provision
  --server <url>      server URL for connect (http:// or https://)
  --name <handle>     short name to save this server under (bp use <handle>)
  --token <tok>       bearer token to persist with the connection
  -w, --workspace <w> workspace scope (default: default)
  -p, --project <p>   project scope (default: default)
  -d, --dataset <ds>  dataset scope (default: production)
  --docker            local: bring up via docker compose (else native mix)
  --profile <p>       seed content profile for local/deploy/provision:
                      clean (papers + media, default) | demo (8 schemas, 27 docs)
  --ssh-host <h>      deploy: user@host (bare host defaults to root@)
  --domain <d>        deploy: public DNS hostname (required for deploy)
  --scheme <http|https>  deploy: public scheme (default: https)
  --provider <p>      provision: hetzner | azure
  --region <r>        provision: region (provider default if omitted)
  --server-type <t>   provision: instance type (provider default if omitted)
  --plugins <csv>     plugin whitelist; "" = none (kill switch); absent = all
  --dry-run           print the plan; run NOTHING
  --yes               confirm a destructive/outbound real run (no prompt)
  -o json | --json    emit one machine-readable JSON object on stdout
  -h, --help          print this help (never opens a TTY)

AUTOMATION / AI
  # Preview as JSON (no side effects), then execute with --yes:
  bp setup --target connect --server https://api.example.com --dry-run -o json
  bp setup --target connect --server https://api.example.com --yes -o json

  bp setup --target local --docker --plugins bulldocs,onixedit --dry-run -o json
  bp setup --target local --profile demo --dry-run -o json
  bp setup --target deploy --ssh-host root@1.2.3.4 --domain d.example.com --dry-run -o json
  bp setup --target provision --provider hetzner --region nbg1 --server-type cax11 --dry-run -o json

  # Without --target on a non-interactive stdin/stdout, setup errors (exit 2)
  # instead of prompting — pass --target so an agent is never blocked.`
	out.outf("%s", help)
}

// parseSetupFlags pulls the setup-local flags out of tail and returns the
// partially-filled plan plus a set of which flags were seen (so the caller can
// tell "no --target" from "--target connect"). It is a small hand parser in the
// same spirit as splitArgs but scoped to setup's known flags.
func parseSetupFlags(tail []string) (setup.SetupPlan, map[string]bool, error) {
	plan := setup.SetupPlan{}
	seen := map[string]bool{}

	valueFlag := map[string]*string{
		"target":    &plan.Target,
		"server":    &plan.Server,
		"name":      &plan.Name,
		"token":     &plan.Token,
		"workspace": &plan.Workspace,
		"project":   &plan.Project,
		"dataset":   &plan.Dataset,
		// modes-step fields, accepted now so the flags don't error before the
		// executors exist:
		"ssh-host":    &plan.SSHHost,
		"domain":      &plan.Domain,
		"scheme":      &plan.Scheme,
		"provider":    &plan.Provider,
		"region":      &plan.Region,
		"server-type": &plan.ServerType,
		"profile":     &plan.Profile,
	}

	i := 0
	for i < len(tail) {
		a := tail[i]
		if len(a) < 3 || a[0] != '-' || a[1] != '-' {
			return plan, nil, fmt.Errorf("unexpected argument %q for setup (use --flag value)", a)
		}
		name := a[2:]
		val := ""
		hasInline := false
		if eq := indexByte(name, '='); eq >= 0 {
			val = name[eq+1:]
			name = name[:eq]
			hasInline = true
		}

		// Boolean: --docker.
		if name == "docker" {
			plan.Docker = true
			seen["docker"] = true
			i++
			continue
		}

		// --plugins is a CSV with kill-switch semantics: a present-but-empty value
		// (`--plugins ""`) is the explicit kill switch ([]string{}); a non-empty
		// value is the whitelist; the flag being ABSENT leaves plan.Plugins nil
		// (all bundled). We must distinguish "" from absent, so it gets its own
		// branch rather than the generic *string path.
		if name == "plugins" {
			if !hasInline {
				if i+1 >= len(tail) {
					return plan, nil, fmt.Errorf("flag --plugins needs a value (use --plugins \"\" for none)")
				}
				val = tail[i+1]
				i++
			}
			plan.Plugins = parsePluginsCSV(val)
			seen["plugins"] = true
			i++
			continue
		}

		dst, ok := valueFlag[name]
		if !ok {
			return plan, nil, fmt.Errorf("unknown setup flag --%s", name)
		}
		if !hasInline {
			if i+1 >= len(tail) {
				return plan, nil, fmt.Errorf("flag --%s needs a value", name)
			}
			val = tail[i+1]
			i++
		}
		*dst = val
		seen[name] = true
		i++
	}
	return plan, seen, nil
}

// parsePluginsCSV turns a --plugins value into the plan's Plugins slice with the
// kill-switch contract: an empty/whitespace value => []string{} (explicit kill
// switch, BARKPARK_PLUGINS=), otherwise the trimmed, blank-stripped name list.
// A nil return is reserved for "flag absent" and is never produced here (the
// caller only invokes this when --plugins was seen).
func parsePluginsCSV(v string) []string {
	out := []string{}
	for _, part := range splitComma(v) {
		part = trimSpace(part)
		if part != "" {
			out = append(out, part)
		}
	}
	return out
}

// splitComma splits on commas without importing strings (the file keeps a
// minimal import surface; indexByte already established the convention).
func splitComma(s string) []string {
	var parts []string
	start := 0
	for i := 0; i < len(s); i++ {
		if s[i] == ',' {
			parts = append(parts, s[start:i])
			start = i + 1
		}
	}
	parts = append(parts, s[start:])
	return parts
}

// trimSpace trims ASCII spaces/tabs from both ends (minimal, no strings import).
func trimSpace(s string) string {
	i := 0
	for i < len(s) && (s[i] == ' ' || s[i] == '\t') {
		i++
	}
	j := len(s)
	for j > i && (s[j-1] == ' ' || s[j-1] == '\t') {
		j--
	}
	return s[i:j]
}

// indexByte is a tiny local helper to avoid importing strings just for one call
// site (keeps the file's import surface minimal).
func indexByte(s string, b byte) int {
	for i := 0; i < len(s); i++ {
		if s[i] == b {
			return i
		}
	}
	return -1
}

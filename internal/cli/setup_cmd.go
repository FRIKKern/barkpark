package cli

import (
	"fmt"

	"github.com/FRIKKern/barkpark/internal/cli/setup"
)

// configStoreAdapter bridges the cli package's on-disk Config persistence onto
// the setup package's ConfigStore seam, breaking the would-be import cycle
// (cli imports setup; setup must not import cli). It loads the existing config
// so a connect preserves admin/ingest tokens the user set elsewhere, overlays
// the connection setup resolved, and writes it back 0600.
type configStoreAdapter struct{}

func (configStoreAdapter) Save(s setup.SavedConfig) error {
	// Preserve any non-connection fields (admin/ingest tokens, output pref) the
	// user already persisted; overlay the connection setup resolved.
	cfg, err := LoadConfig()
	if err != nil {
		cfg = &Config{}
	}
	cfg.Server = s.Server
	cfg.Token = s.Token
	cfg.Workspace = s.Workspace
	cfg.Project = s.Project
	cfg.Dataset = s.Dataset
	return SaveConfig(cfg)
}

// runSetup is the `bp setup` built-in. It supports the non-interactive flag form
// (parsed from tail) and leaves the no-target-on-a-TTY path to the setup
// package's RunInteractive hook (the modes step wires the real wizard there).
//
// Recognised flags: --target, --server, --token, --workspace, --project,
// --dataset. The global --dry-run (g.dryRun) drives DryRun.
func runSetup(out *writer, g globals, tail []string) int {
	plan, parsed, perr := parseSetupFlags(tail)
	if perr != nil {
		out.errf("barkpark: %v", perr)
		return exitUsage
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

	opts := setup.Options{
		DryRun:  g.dryRun,
		Confirm: g.yes,
		Out:     out.stdout,
		Store:   configStoreAdapter{},
		Wizard:  setup.Wizard,
	}

	// No --target: interactive path (the modes step fills the wizard). On the
	// foundation this prints the modes-step pointer and exits 0.
	if !parsed["target"] {
		if err := setup.RunInteractive(opts); err != nil {
			out.errf("barkpark: %v", err)
			return exitGeneric
		}
		return exitOK
	}

	if err := setup.Execute(plan, opts); err != nil {
		out.errf("barkpark: %v", err)
		return exitGeneric
	}
	return exitOK
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

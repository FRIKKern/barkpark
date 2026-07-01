package cli

import (
	"encoding/json"
	"fmt"
	"strings"
	"unicode/utf8"
)

// runUse is the `bp use <name|url>` built-in — the headline of the named-server
// switching layer. It flips the active server LOCALLY: resolve the argument to a
// known entry, promote it to the active flat context, save, and print. There is
// NO network call — switching is instant and works offline.
//
// With no argument it prints the current active server plus the list of known
// names as a hint. An unknown name/URL is a clean usage error (exit 2) that
// lists the known names so the user can correct the typo.
func runUse(out *writer, args []string) int {
	cfg, err := LoadConfig()
	if err != nil {
		return useError(out, "failed", "read config: "+err.Error(), exitGeneric)
	}

	// No arg: show active + the hint list.
	if len(args) == 0 || args[0] == "" {
		return runUseStatus(out, cfg)
	}

	q := args[0]
	entry, ok := cfg.FindServer(q)
	if !ok {
		return useUnknown(out, cfg, q)
	}

	cfg.SetActiveServer(entry)
	if serr := SaveConfig(cfg); serr != nil {
		return useError(out, "failed", "save config: "+serr.Error(), exitGeneric)
	}

	name := cfg.DisplayName(entry)
	kind := cfg.KindOf(entry)
	payload := map[string]any{
		"ok": true,
		"active": map[string]any{
			"name":      name,
			"server":    cfg.Server,
			"kind":      kind,
			"workspace": cfg.Workspace,
			"project":   cfg.Project,
			"dataset":   cfg.Dataset,
		},
	}
	switch out.output {
	case "json":
		out.renderJSON(payload)
		return exitOK
	case "yaml":
		out.renderYAML(toGeneric(payload))
		return exitOK
	}
	out.outf("✓ now using %s [%s] — %s  (scope w=%s p=%s d=%s)",
		name, kind, cfg.Server, cfg.Workspace, cfg.Project, cfg.Dataset)
	return exitOK
}

// runUseStatus handles `bp use` with no argument: print the active server (if
// any) and the known names as a hint to what `bp use <name>` accepts.
func runUseStatus(out *writer, cfg *Config) int {
	activeEntry, hasActive := activeEntry(cfg)
	activeName := ""
	activeKind := ""
	if hasActive {
		activeName = cfg.DisplayName(activeEntry)
		activeKind = cfg.KindOf(activeEntry)
	}
	names := knownNames(cfg)

	var active any
	if hasActive {
		active = map[string]any{
			"name":      activeName,
			"server":    cfg.Server,
			"kind":      activeKind,
			"workspace": cfg.Workspace,
			"project":   cfg.Project,
			"dataset":   cfg.Dataset,
		}
	}
	payload := map[string]any{
		"ok":     true,
		"active": active,
		"known":  names,
	}
	switch out.output {
	case "json":
		out.renderJSON(payload)
		return exitOK
	case "yaml":
		out.renderYAML(toGeneric(payload))
		return exitOK
	}

	if hasActive {
		out.outf("active: %s [%s] — %s  (scope w=%s p=%s d=%s)",
			activeName, activeKind, cfg.Server, cfg.Workspace, cfg.Project, cfg.Dataset)
	} else if cfg.Server != "" {
		out.outf("active: %s  (not in known servers)", cfg.Server)
	} else {
		out.outf("active: (none — run 'bp setup --target connect --server <url>')")
	}
	if len(names) > 0 {
		out.outf("known:  %s", joinComma(names))
		out.outf("hint:   bp use <name>   to switch")
	} else {
		out.outf("no saved servers yet — run 'bp setup --target connect --server <url>'")
	}
	return exitOK
}

// useUnknown is the clean miss path for `bp use <name>`: list the known names so
// the user can correct the typo. Exit 2 (usage).
func useUnknown(out *writer, cfg *Config, q string) int {
	names := knownNames(cfg)
	m := map[string]any{
		"ok": false,
		"error": map[string]any{
			"code":    "not_found",
			"message": "no known server matches " + q,
			"known":   names,
		},
	}
	switch out.output {
	case "json":
		out.renderJSON(m)
		return exitUsage
	case "yaml":
		out.renderYAML(toGeneric(m))
		return exitUsage
	}
	out.errf("barkpark: no known server matches %q", q)
	if len(names) > 0 {
		out.errf("known servers: %s", joinComma(names))
		out.errf("run `bp servers` for details.")
	} else {
		out.errf("no saved servers yet — run 'bp setup --target connect --server <url>'")
	}
	return exitUsage
}

// runServers is the `bp servers` (alias `bp server ls`) built-in: list every
// saved server with its name, url, active marker, last-connected stamp, and
// tier. Read-only — no network, no mutation.
func runServers(out *writer, args []string) int {
	cfg, err := LoadConfig()
	if err != nil {
		return useError(out, "failed", "read config: "+err.Error(), exitGeneric)
	}

	// Optional --kind local|cloud filter. An unrecognised value is a usage error.
	kindFilter, kerr := parseKindFlag(args)
	if kerr != nil {
		return useError(out, "usage", kerr.Error(), exitUsage)
	}

	list := cfg.KnownServerList()
	if kindFilter != "" {
		filtered := make([]ServerEntry, 0, len(list))
		for _, e := range list {
			if cfg.KindOf(e) == kindFilter {
				filtered = append(filtered, e)
			}
		}
		list = filtered
	}
	activeName := ""
	if e, ok := activeEntry(cfg); ok {
		activeName = cfg.DisplayName(e)
	}

	switch out.output {
	case "json", "yaml":
		rows := make([]map[string]any, 0, len(list))
		for _, e := range list {
			rows = append(rows, map[string]any{
				"name":           cfg.DisplayName(e),
				"server":         e.Server,
				"kind":           cfg.KindOf(e),
				"active":         cfg.IsActiveServer(e.Server),
				"last_connected": e.LastConnected,
				"tier":           e.Tier,
			})
		}
		payload := map[string]any{
			"servers": rows,
			"active":  activeName,
		}
		if out.output == "yaml" {
			out.renderYAML(toGeneric(payload))
		} else {
			out.renderJSON(payload)
		}
		return exitOK
	}

	if len(list) == 0 {
		if kindFilter != "" {
			out.outf("no saved %s servers", kindFilter)
		} else {
			out.outf("no saved servers yet — run 'bp setup --target connect --server <url>'")
		}
		return exitOK
	}

	// Human table: ★ NAME  [kind]  URL  (tier, last_connected)
	// Two-pass render so a long DisplayName or [kind] never overruns its
	// field and desyncs the URL column (mirrors renderRows in table.go).
	// First pass: measure the widest name and kind cell (rune-counted).
	maxName, maxKind := 12, 8
	for _, e := range list {
		if n := utf8.RuneCountInString(cfg.DisplayName(e)); n > maxName {
			maxName = n
		}
		if k := utf8.RuneCountInString("[" + cfg.KindOf(e) + "]"); k > maxKind {
			maxKind = k
		}
	}
	// Second pass: print each row padded to the measured widths.
	for _, e := range list {
		mark := "  "
		if cfg.IsActiveServer(e.Server) {
			mark = "★ "
		}
		name := cfg.DisplayName(e)
		kind := "[" + cfg.KindOf(e) + "]"
		extra := ""
		switch {
		case e.Tier != "" && e.LastConnected != "":
			extra = "  (" + e.Tier + ", " + e.LastConnected + ")"
		case e.Tier != "":
			extra = "  (" + e.Tier + ")"
		case e.LastConnected != "":
			extra = "  (" + e.LastConnected + ")"
		}
		out.outf("%s%-*s %-*s %s%s", mark, maxName, name, maxKind, kind, e.Server, extra)
	}
	return exitOK
}

// parseKindFlag scans args for a `--kind <value>` or `--kind=<value>` flag and
// returns the lowercased value ("local"/"cloud"), "" when absent. Any other
// value — or a missing argument after a bare `--kind` — is a usage error.
func parseKindFlag(args []string) (string, error) {
	for i := 0; i < len(args); i++ {
		a := args[i]
		val := ""
		switch {
		case a == "--kind":
			if i+1 >= len(args) {
				return "", fmt.Errorf("--kind needs a value: local|cloud")
			}
			val = args[i+1]
			i++
		case strings.HasPrefix(a, "--kind="):
			val = a[len("--kind="):]
		default:
			continue
		}
		switch strings.ToLower(strings.TrimSpace(val)) {
		case "local":
			return "local", nil
		case "cloud":
			return "cloud", nil
		default:
			return "", fmt.Errorf("invalid --kind %q: want local|cloud", val)
		}
	}
	return "", nil
}

// activeEntry returns the known ServerEntry that matches the active flat server,
// if any. When the active URL is not in the history (an edge case), it returns a
// synthetic entry carrying just the active URL so callers can still derive a
// name and show scope.
func activeEntry(cfg *Config) (ServerEntry, bool) {
	if cfg == nil || cfg.ActiveServer() == "" {
		return ServerEntry{}, false
	}
	for _, e := range cfg.KnownServerList() {
		if cfg.IsActiveServer(e.Server) {
			return e, true
		}
	}
	return ServerEntry{Server: cfg.Server, Token: cfg.Token, Workspace: cfg.Workspace, Project: cfg.Project, Dataset: cfg.Dataset}, true
}

// knownNames returns the display names of all known servers, most-recent-first.
func knownNames(cfg *Config) []string {
	if cfg == nil {
		return nil
	}
	list := cfg.KnownServerList()
	names := make([]string, 0, len(list))
	for _, e := range list {
		names = append(names, cfg.DisplayName(e))
	}
	return names
}

// useError emits a {ok:false,error:{code,message}} envelope on -o json/-o yaml,
// else a one-line stderr message, and returns the given exit code.
func useError(out *writer, code, msg string, exit int) int {
	m := map[string]any{
		"ok":    false,
		"error": map[string]any{"code": code, "message": msg},
	}
	switch out.output {
	case "json":
		out.renderJSON(m)
		return exit
	case "yaml":
		out.renderYAML(toGeneric(m))
		return exit
	}
	out.errf("barkpark: %s", msg)
	return exit
}

// toGeneric round-trips a value through JSON into a generic any so the YAML
// emitter renders the SAME shape as -o json (map[string]any keys sort, structs
// flatten to their json tags). Mirrors the inline pattern in runVersion.
func toGeneric(v any) any {
	b, _ := json.Marshal(v)
	var out any
	_ = json.Unmarshal(b, &out)
	return out
}

// joinComma joins names with ", " without importing strings into this file's
// hot path (keeps the built-in self-contained alongside the other tiny helpers).
func joinComma(names []string) string {
	out := ""
	for i, n := range names {
		if i > 0 {
			out += ", "
		}
		out += n
	}
	return out
}

package cli

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
	if out.output == "json" {
		out.renderJSON(map[string]any{
			"ok": true,
			"active": map[string]any{
				"name":      name,
				"server":    cfg.Server,
				"workspace": cfg.Workspace,
				"project":   cfg.Project,
				"dataset":   cfg.Dataset,
			},
		})
		return exitOK
	}
	out.outf("✓ now using %s — %s  (scope w=%s p=%s d=%s)",
		name, cfg.Server, cfg.Workspace, cfg.Project, cfg.Dataset)
	return exitOK
}

// runUseStatus handles `bp use` with no argument: print the active server (if
// any) and the known names as a hint to what `bp use <name>` accepts.
func runUseStatus(out *writer, cfg *Config) int {
	activeEntry, hasActive := activeEntry(cfg)
	activeName := ""
	if hasActive {
		activeName = cfg.DisplayName(activeEntry)
	}
	names := knownNames(cfg)

	if out.output == "json" {
		var active any
		if hasActive {
			active = map[string]any{
				"name":      activeName,
				"server":    cfg.Server,
				"workspace": cfg.Workspace,
				"project":   cfg.Project,
				"dataset":   cfg.Dataset,
			}
		}
		out.renderJSON(map[string]any{
			"ok":     true,
			"active": active,
			"known":  names,
		})
		return exitOK
	}

	if hasActive {
		out.outf("active: %s — %s  (scope w=%s p=%s d=%s)",
			activeName, cfg.Server, cfg.Workspace, cfg.Project, cfg.Dataset)
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
	if out.output == "json" {
		out.renderJSON(map[string]any{
			"ok": false,
			"error": map[string]any{
				"code":    "not_found",
				"message": "no known server matches " + q,
				"known":   names,
			},
		})
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
	list := cfg.KnownServerList()
	activeName := ""
	if e, ok := activeEntry(cfg); ok {
		activeName = cfg.DisplayName(e)
	}

	if out.output == "json" {
		rows := make([]map[string]any, 0, len(list))
		for _, e := range list {
			rows = append(rows, map[string]any{
				"name":           cfg.DisplayName(e),
				"server":         e.Server,
				"active":         cfg.IsActiveServer(e.Server),
				"last_connected": e.LastConnected,
				"tier":           e.Tier,
			})
		}
		out.renderJSON(map[string]any{
			"servers": rows,
			"active":  activeName,
		})
		return exitOK
	}

	if len(list) == 0 {
		out.outf("no saved servers yet — run 'bp setup --target connect --server <url>'")
		return exitOK
	}

	// Human table: ★ NAME  URL  (tier, last_connected)
	for _, e := range list {
		mark := "  "
		if cfg.IsActiveServer(e.Server) {
			mark = "★ "
		}
		name := cfg.DisplayName(e)
		extra := ""
		switch {
		case e.Tier != "" && e.LastConnected != "":
			extra = "  (" + e.Tier + ", " + e.LastConnected + ")"
		case e.Tier != "":
			extra = "  (" + e.Tier + ")"
		case e.LastConnected != "":
			extra = "  (" + e.LastConnected + ")"
		}
		out.outf("%s%-12s %s%s", mark, name, e.Server, extra)
	}
	return exitOK
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

// useError emits a JSON {ok:false,error:{code,message}} on -o json, else a
// one-line stderr message, and returns the given exit code.
func useError(out *writer, code, msg string, exit int) int {
	if out.output == "json" {
		out.renderJSON(map[string]any{
			"ok":    false,
			"error": map[string]any{"code": code, "message": msg},
		})
		return exit
	}
	out.errf("barkpark: %s", msg)
	return exit
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

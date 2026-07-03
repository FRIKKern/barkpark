package cli

import (
	"fmt"
	"strings"
	"time"

	"github.com/mattn/go-runewidth"
)

// This file is the LOCAL-ONLY surface of the bp Cloud commands — the half of
// "one login for all your Barkparks" that needs NO control plane. Everything
// here reads/writes the on-disk config (KnownServers via config.go) and renders
// the SSH command an agent action WOULD run; nothing here makes a control-plane
// HTTP call. The control-plane-backed counterparts — `bp login`, `bp go-live`,
// and the live registry view of `bp barkparks` — are cloud-12 and land later.
//
// The three commands mirror the existing built-in idiom exactly:
//   - bp barkparks            — the cloud-facing view of `bp servers` (cloud-11)
//   - bp attach / register    — upsert a known Barkpark via RememberServer
//   - bp agent disable|uninstall — render the SSH command, never execute it
//
// Dispatch lives in cli.go's noun switch alongside `servers`/`use`; these stay
// thin and route through the same writer + config helpers the rest of the CLI
// uses.

// cloudClock is the time source for the LastConnected stamp on a freshly
// registered Barkpark. A var so the golden tests can pin it to a fixed instant
// and keep RememberServer a deterministic, dependency-free helper.
var cloudClock = func() time.Time { return time.Now().UTC() }

// runBarkparks is the `bp barkparks` built-in — the cloud-facing view of the
// known servers. It is the LOCAL-CONFIG view (cloud-11): every Barkpark bp has
// been told about, rendered as a clean table of name · url · kind · status.
// Status is "unknown" until the agent / control plane reports it (cloud-10 /
// cloud-12); here it is always read from local config, never fetched.
//
// Read-only, no network, no mutation — the same contract as `bp servers`, just
// labelled and columned as Barkparks. An optional `--kind local|cloud` filter
// reuses the servers parser.
func runBarkparks(out *writer, args []string) int {
	for _, a := range args {
		if a == "-h" || a == "--help" {
			printBarkparksHelp(out)
			return exitOK
		}
	}

	cfg, err := LoadConfig()
	if err != nil {
		return useError(out, "failed", "read config: "+err.Error(), exitGeneric)
	}

	kindFilter, kerr := parseKindFlag(args)
	if kerr != nil {
		return useError(out, "usage", kerr.Error(), exitUsage)
	}

	// AUTHORITATIVE path (cloud-12): when a Cloud token is present, the live
	// control-plane registry is the source of truth — query it instead of the
	// local KnownServers cache. The --kind filter is a local-config concept, so a
	// caller passing it explicitly opts back into the local view; bare
	// `bp barkparks` with a token hits the control plane. No token → local view.
	if cfg.HasCloudToken() && kindFilter == "" {
		return runBarkparksCloud(out, cfg)
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

	rows := make([]map[string]any, 0, len(list))
	for _, e := range list {
		rows = append(rows, map[string]any{
			"name":   cfg.DisplayName(e),
			"url":    e.Server,
			"kind":   cfg.KindOf(e),
			"status": barkparkStatus(e),
			"active": cfg.IsActiveServer(e.Server),
		})
	}
	if out.emitStructured(map[string]any{
		"barkparks": rows,
		"source":    "local-config",
	}) {
		return exitOK
	}

	if len(list) == 0 {
		if kindFilter != "" {
			out.outf("no %s Barkparks known yet — add one with 'bp register ssh root@<host> --name <name>'", kindFilter)
		} else {
			out.outf("no Barkparks known yet — add one with 'bp register ssh root@<host> --name <name>'")
		}
		return exitOK
	}

	renderBarkparksTable(out, cfg, list)
	return exitOK
}

// barkparkStatus is the LOCAL-CONFIG status of a known Barkpark — a deliberately
// thin vocabulary because a ServerEntry carries no liveness fields. The only
// honest answer from local config is "active" for the currently-selected server
// (computed at render time) and "unknown" for the rest; we never claim a server
// is up without checking it.
//
// This is NOT a second, competing status vocabulary: the AUTHORITATIVE fleet
// triage vocabulary — removal_failed/failed/suspended/degraded/behind/removing/
// provisioning/ok, charter decision 15 — lives in attentionStatus
// (cloud_status_cmd.go) and drives `bp cloud status`, because it needs the
// control-plane health/agent/provision/suspend fields this local ServerEntry
// simply does not have. When a caller has a cloudclient.Barkpark, it should
// classify with attentionStatus, not this. Kept as a function so a later task
// can fold a cached control-plane status in here without touching callers.
func barkparkStatus(_ ServerEntry) string {
	return "unknown"
}

// renderBarkparksTable prints the aligned Barkparks table: a ★ active marker,
// then NAME · URL · KIND · STATUS. Column widths are computed from the data so
// the output is stable for golden comparison.
func renderBarkparksTable(out *writer, cfg *Config, list []ServerEntry) {
	const (
		hMark   = "  "
		hName   = "NAME"
		hURL    = "URL"
		hKind   = "KIND"
		hStatus = "STATUS"
	)
	// Widths are measured in terminal display cells (runewidth), not bytes: a
	// multibyte name or URL is fewer cells than bytes, so a byte width would shear
	// the alignment. FillRight pads to that same cell width. Matches renderHzTable.
	nameW, urlW, kindW := runewidth.StringWidth(hName), runewidth.StringWidth(hURL), runewidth.StringWidth(hKind)
	for _, e := range list {
		if n := runewidth.StringWidth(cfg.DisplayName(e)); n > nameW {
			nameW = n
		}
		if n := runewidth.StringWidth(e.Server); n > urlW {
			urlW = n
		}
		if n := runewidth.StringWidth(cfg.KindOf(e)); n > kindW {
			kindW = n
		}
	}

	out.outf("%s%s", hMark, strings.Join([]string{
		runewidth.FillRight(hName, nameW), runewidth.FillRight(hURL, urlW),
		runewidth.FillRight(hKind, kindW), hStatus,
	}, "  "))
	for _, e := range list {
		mark := "  "
		status := barkparkStatus(e)
		if cfg.IsActiveServer(e.Server) {
			mark = "★ "
			status = "active"
		}
		out.outf("%s%s", mark, strings.Join([]string{
			runewidth.FillRight(cfg.DisplayName(e), nameW), runewidth.FillRight(e.Server, urlW),
			runewidth.FillRight(cfg.KindOf(e), kindW), status,
		}, "  "))
	}
}

// runAttach is the `bp attach` / `bp register` built-in — add an existing
// (self-hosted) Barkpark to the local known list. It is the LOCAL command: it
// upserts the entry into config via RememberServer and saves. NO network call,
// NO control plane.
//
// Two surfaces share one executor:
//   - `bp register ssh root@<host> --name <name>` — the explicit form
//   - `bp attach root@<host> --name <name>`       — the interactive/short form
//
// `attach` accepts the same ssh target positionally (the leading `ssh` literal
// is optional). The ssh target is validated (must look like [user@]host) and the
// resulting server URL is derived from the host.
func runAttach(out *writer, verb string, args []string) int {
	for _, a := range args {
		if a == "-h" || a == "--help" {
			printRegisterHelp(out)
			return exitOK
		}
	}

	// `bp register ssh <target>` carries a leading `ssh` literal (verb=="register",
	// args[0]=="ssh"); `bp attach <target>` does not. Strip an optional leading
	// `ssh` so both forms reach the same target-parsing path.
	rest := args
	if verb == "register" {
		if len(rest) > 0 && rest[0] == "ssh" {
			rest = rest[1:]
		} else {
			return attachUsageErr(out, "bp register needs a transport: bp register ssh root@<host> --name <name>")
		}
	}

	target, name, perr := parseAttachArgs(rest)
	if perr != nil {
		return attachUsageErr(out, perr.Error())
	}
	if target == "" {
		return attachUsageErr(out, "missing ssh target — e.g. bp register ssh root@1.2.3.4 --name acme")
	}

	host, herr := sshHostOnly(target)
	if herr != nil {
		return attachUsageErr(out, herr.Error())
	}

	// Derive the server URL from the host. A self-hosted Barkpark reached over SSH
	// serves HTTP on :4000 by default (the same floor bakedDefaults uses for
	// localhost); the user can re-point it later with `bp setup --target connect`.
	server := "http://" + host + ":4000"
	sshTarget := normalizeSSHTarget(target)

	cfg, err := LoadConfig()
	if err != nil {
		return useError(out, "failed", "read config: "+err.Error(), exitGeneric)
	}

	entry := ServerEntry{
		Name:          strings.TrimSpace(name),
		Server:        server,
		LastConnected: cloudClock().Format(time.RFC3339),
	}
	cfg.RememberServer(entry)
	if serr := SaveConfig(cfg); serr != nil {
		return useError(out, "failed", "save config: "+serr.Error(), exitGeneric)
	}

	// RememberServer derives a name when none was given; read back the actual
	// handle the entry landed under so the confirmation is accurate.
	saved, _ := cfg.FindServer(server)
	savedName := cfg.DisplayName(saved)
	kind := cfg.KindOf(saved)

	if out.emitStructured(map[string]any{
		"ok": true,
		"barkpark": map[string]any{
			"name":       savedName,
			"url":        server,
			"kind":       kind,
			"ssh_target": sshTarget,
			"active":     cfg.IsActiveServer(server),
		},
	}) {
		return exitOK
	}

	out.outf("✓ registered %s [%s] — %s  (ssh %s)", savedName, kind, server, sshTarget)
	out.outf("  now active. agent install is `bp agent install` (cloud-10).")
	return exitOK
}

// runAgent is the `bp agent <verb>` built-in — the LOCAL command surface for
// managing the Barkpark agent on a known server. The agent itself is cloud-10
// (not built yet), so these commands build the arg parsing and RENDER the SSH
// command they WOULD run; they do not execute it here. The rendered command acts
// on the selected (active) server, or a `--name <handle>` override.
//
// Supported verbs: `disable` (stop the agent, keep it installed) and `uninstall`
// (remove it entirely). Both mirror the dry-run / step idiom: they always print
// the command; a real run is a later task once the agent exists.
func runAgent(out *writer, verb string, args []string) int {
	if verb == "-h" || verb == "--help" {
		printAgentHelp(out)
		return exitOK
	}
	if verb == "" {
		return useError(out, "usage", "missing agent command (run `bp agent -h` for usage)", exitUsage)
	}

	action, ok := agentAction(verb)
	if !ok {
		// Route through useError so -o json/yaml callers get the shared
		// {ok:false,error:{code,message}} envelope and plain callers get one
		// stderr line — never the help wall on stdout.
		return useError(out, "usage", fmt.Sprintf("unknown agent command %q (run `bp agent -h` for usage)", verb), exitUsage)
	}

	name, perr := parseNameFlag(args)
	if perr != nil {
		return useError(out, "usage", perr.Error(), exitUsage)
	}

	cfg, err := LoadConfig()
	if err != nil {
		return useError(out, "failed", "read config: "+err.Error(), exitGeneric)
	}

	// Resolve the target server: an explicit --name wins; else the active server.
	var entry ServerEntry
	switch {
	case name != "":
		e, found := cfg.FindServer(name)
		if !found {
			return agentNoTarget(out, fmt.Sprintf("no known Barkpark matches %q", name), cfg)
		}
		entry = e
	default:
		e, found := activeEntry(cfg)
		if !found {
			return agentNoTarget(out, "no active Barkpark — pass --name <handle> or run `bp use <name>`", cfg)
		}
		entry = e
	}

	host, herr := sshHostOnly(hostOf(entry.Server))
	if herr != nil {
		return useError(out, "failed", "cannot derive ssh host from "+entry.Server+": "+herr.Error(), exitGeneric)
	}
	sshTarget := normalizeSSHTarget(host)
	remote := agentRemoteCommand(action)
	rendered := fmt.Sprintf("ssh %s '%s'", sshTarget, remote)
	target := cfg.DisplayName(entry)

	if out.emitStructured(map[string]any{
		"ok":         true,
		"dry_run":    true,
		"action":     action,
		"target":     target,
		"url":        entry.Server,
		"ssh_target": sshTarget,
		"command":    rendered,
	}) {
		return exitOK
	}

	out.outf("bp agent %s — would run on %s (%s):", action, target, entry.Server)
	out.outf("  $ %s", rendered)
	out.outf("")
	out.outf("(no execution — the agent is cloud-10; this renders the command only)")
	return exitOK
}

// agentAction validates an agent verb and returns its canonical action name.
func agentAction(verb string) (string, bool) {
	switch verb {
	case "disable", "uninstall":
		return verb, true
	default:
		return "", false
	}
}

// agentRemoteCommand renders the remote shell command for an agent action. The
// agent ships as a systemd unit (cloud-10); disable stops + masks it, uninstall
// stops it and removes the unit + binary. These are the commands `bp agent` WILL
// run once the agent exists.
func agentRemoteCommand(action string) string {
	switch action {
	case "disable":
		return "systemctl disable --now barkpark-agent"
	case "uninstall":
		return "systemctl disable --now barkpark-agent && rm -f /etc/systemd/system/barkpark-agent.service /usr/local/bin/barkpark-agent && systemctl daemon-reload"
	default:
		return ""
	}
}

// agentNoTarget emits the clean miss path for `bp agent <verb>` when no target
// server resolves: a JSON error envelope or a one-line stderr message, with the
// known names as a hint. Exit 2 (usage).
func agentNoTarget(out *writer, msg string, cfg *Config) int {
	names := knownNames(cfg)
	if out.emitStructured(map[string]any{
		"ok": false,
		"error": map[string]any{
			"code":    "not_found",
			"message": msg,
			"known":   names,
		},
	}) {
		return exitUsage
	}
	out.errf("barkpark: %s", msg)
	if len(names) > 0 {
		out.errf("known Barkparks: %s", joinComma(names))
	}
	return exitUsage
}

// parseAttachArgs splits an attach/register tail into the positional ssh target
// and the value of --name. The first non-flag token is the target; `--name <v>`
// or `--name=<v>` supplies the handle. An unknown flag is a usage error.
func parseAttachArgs(args []string) (target, name string, err error) {
	for i := 0; i < len(args); i++ {
		a := args[i]
		switch {
		case a == "--name":
			if i+1 >= len(args) {
				return "", "", fmt.Errorf("--name needs a value")
			}
			name = args[i+1]
			i++
		case strings.HasPrefix(a, "--name="):
			name = a[len("--name="):]
		case strings.HasPrefix(a, "-"):
			return "", "", fmt.Errorf("unknown flag %q (usage: bp register ssh root@<host> --name <name>)", a)
		default:
			if target != "" {
				return "", "", fmt.Errorf("unexpected extra argument %q", a)
			}
			target = a
		}
	}
	return target, name, nil
}

// parseNameFlag scans args for `--name <value>` / `--name=<value>` and returns
// the value, "" when absent. Any other flag is a usage error; the agent commands
// take no positionals.
func parseNameFlag(args []string) (string, error) {
	name := ""
	for i := 0; i < len(args); i++ {
		a := args[i]
		switch {
		case a == "--name":
			if i+1 >= len(args) {
				return "", fmt.Errorf("--name needs a value")
			}
			name = args[i+1]
			i++
		case strings.HasPrefix(a, "--name="):
			name = a[len("--name="):]
		case a == "-h" || a == "--help":
			// handled by the caller before this point; ignore defensively.
		default:
			return "", fmt.Errorf("unexpected argument %q (usage: bp agent disable|uninstall [--name <handle>])", a)
		}
	}
	return name, nil
}

// sshHostOnly validates an ssh target ([user@]host) and returns just the host.
// An empty target, or one with empty user/host halves, is a usage error. It is
// dependency-free (no net/url), matching config.go's parsing style.
func sshHostOnly(target string) (string, error) {
	t := strings.TrimSpace(target)
	if t == "" {
		return "", fmt.Errorf("empty ssh target")
	}
	host := t
	if at := strings.LastIndexByte(t, '@'); at >= 0 {
		user := t[:at]
		host = t[at+1:]
		if user == "" {
			return "", fmt.Errorf("invalid ssh target %q: empty user before @", target)
		}
	}
	host = strings.TrimSpace(host)
	if host == "" {
		return "", fmt.Errorf("invalid ssh target %q: empty host", target)
	}
	// A host with whitespace or a scheme is not an ssh target.
	if strings.ContainsAny(host, " \t/") || strings.Contains(host, "://") {
		return "", fmt.Errorf("invalid ssh host %q", host)
	}
	return host, nil
}

// normalizeSSHTarget defaults a bare host to root@<host> (the deploy.sh / agent
// convention) while leaving an explicit user@host untouched. Mirrors the setup
// package's normalizeSSHHost so the rendered ssh line matches what deploy uses.
func normalizeSSHTarget(target string) string {
	t := strings.TrimSpace(target)
	if t == "" {
		return t
	}
	if strings.Contains(t, "@") {
		return t
	}
	return "root@" + t
}

// attachUsageErr emits the attach/register usage error envelope (exit 2). It
// routes the structured shape through emitStructured so -o yaml is honoured too.
func attachUsageErr(out *writer, msg string) int {
	if out.emitStructured(map[string]any{
		"ok":    false,
		"error": map[string]any{"code": "usage", "message": msg},
	}) {
		return exitUsage
	}
	out.errf("barkpark: %s", msg)
	out.errf("usage: bp register ssh root@<host> --name <name>")
	return exitUsage
}

// printBarkparksHelp writes `bp barkparks` usage WITHOUT touching the TTY.
func printBarkparksHelp(out *writer) {
	const help = `bp barkparks — list the Barkparks bp knows about (local config view).

USAGE
  bp barkparks [--kind local|cloud] [-o json]

WHAT IT SHOWS
  every Barkpark in local config — name · url · kind · status. The ★ marks the
  active one. Status is read from local config: "active" for the selected
  Barkpark, "unknown" for the rest (live status arrives with the agent + control
  plane in a later task — this command makes NO network call).

FLAGS
  --kind local|cloud   show only local or only cloud Barkparks
  -o json              emit one machine-readable JSON object on stdout

RELATED
  bp register ssh root@<host> --name <name>   add a self-hosted Barkpark
  bp use <name>                               switch the active Barkpark`
	out.outf("%s", help)
}

// printRegisterHelp writes `bp register` / `bp attach` usage.
func printRegisterHelp(out *writer) {
	const help = `bp register / bp attach — add an existing Barkpark to your local known list.

USAGE
  bp register ssh root@<host> --name <name>
  bp attach root@<host> --name <name>

WHAT IT DOES
  upserts the Barkpark into local config (the same store bp servers / bp use
  read) and makes it active. NO network call — it records the server so later
  commands (bp use, bp agent, and cloud-12's bp login) can reach it.

FLAGS
  --name <handle>   short name to save it under (bp use <handle>); derived from
                    the host when omitted
  -o json           emit one machine-readable JSON object on stdout`
	out.outf("%s", help)
}

// printAgentHelp writes `bp agent` usage.
func printAgentHelp(out *writer) {
	const help = `bp agent — manage the Barkpark agent on a known server (local command surface).

USAGE
  bp agent disable   [--name <handle>] [-o json]
  bp agent uninstall [--name <handle>] [-o json]

WHAT IT DOES
  renders the SSH command that disables / uninstalls the agent on the SELECTED
  server (the active Barkpark, or --name <handle>). The agent itself is cloud-10
  and not built yet, so these print the command they WOULD run — they do not
  execute it.

FLAGS
  --name <handle>   act on this known Barkpark instead of the active one
  -o json           emit one machine-readable JSON object on stdout`
	out.outf("%s", help)
}

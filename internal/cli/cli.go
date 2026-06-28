// Package cli is the manifest-driven command layer for the barkpark binary.
//
// The SAME binary serves the interactive TUI (invoked with no args) and this
// CLI (invoked as `barkpark <noun> <verb> …`). main() routes to Execute when
// any positional arg is present; otherwise the TUI launches unchanged.
//
// Nothing in this package hardcodes a noun, verb, or route. The command tree is
// a pure function of the capabilities manifest (manifest.Tree); dispatch fills
// the per-command http.path_template via manifest.BuildURL. A future plugin that
// adds a noun/command appears in the CLI with zero code change here. Only a tiny
// set of CLI-native built-ins (capabilities, whoami, version, login, completion)
// live outside the manifest.
//
// Why hand-rolled instead of cobra: the command tree is *dynamic* — it is built
// at runtime from whatever manifest the server (or an override file) returns.
// cobra wants a static command graph registered at init; a manifest-driven
// dispatcher is the simpler fit and keeps the dependency surface at zero new
// modules. See the dispatch path in Execute below.
package cli

import (
	"os"

	"github.com/FRIKKern/barkpark/internal/apiclient"
	"github.com/FRIKKern/barkpark/internal/manifest"
)

// Exit codes — the stable scheme from docs/cli/error-exit-table.md. Codes 0–5
// are byte-identical to the published handbook; 6–8 are additive.
const (
	exitOK         = 0 // success
	exitGeneric    = 1 // other / network / timeout / unknown code fallback
	exitUsage      = 2 // bad args / unknown command / malformed request
	exitAuth       = 3 // missing/invalid credential or insufficient permission
	exitNotFound   = 4 // resource or schema does not exist
	exitValidation = 5 // payload failed schema/op validation
	exitConflict   = 6 // optimistic-concurrency / write-conflict / precondition
	exitRateLimit  = 7 // throttled
	exitServer     = 8 // server-side 5xx / internal_error
)

// Execute is the CLI entry point. args is os.Args[1:]. It returns the process
// exit code; main() passes it straight to os.Exit. Execute never calls os.Exit
// itself so it stays unit-testable.
func Execute(args []string) int {
	out := newWriter(os.Stdout, os.Stderr)

	g, rest, err := parseGlobals(args)
	if err != nil {
		out.errf("barkpark: %v", err)
		usageTop(out)
		return exitUsage
	}
	out.applyGlobals(g)

	if g.help && len(rest) == 0 {
		usageTop(out)
		return exitOK
	}
	if len(rest) == 0 {
		// No noun: a bare `barkpark -v` etc. Print top usage.
		usageTop(out)
		return exitUsage
	}

	noun := rest[0]
	verb := ""
	var tail []string
	if len(rest) > 1 {
		verb = rest[1]
		tail = rest[2:]
	}

	// Resolve the target context (flags > env > active > defaults).
	ctx := resolveContext(g)

	// Built-ins are CLI-native and do not consult the manifest tree for
	// dispatch (capabilities/version need no command; whoami composes /v1/meta
	// + the manifest's caller auth_tier).
	switch noun {
	case "version":
		return runVersion(out, g)
	case "upgrade":
		// `bp upgrade [--check]` — self-update from the cli-v* GitHub releases.
		// --check is not a global flag, so parseGlobals passed it through into
		// rest. Hand upgrade everything after the noun.
		return runUpgrade(out, g, rest[1:])
	case "completion":
		return runCompletion(out)
	case "login":
		// `bp login` — authenticate to the Barkpark Cloud control plane and store
		// the session token (cloud-12). Replaces the v1 token-stub. Its own flags
		// (--email/--password/--url) are not globals, so they arrive in rest.
		return runLoginCloud(out, rest[1:])
	case "signup":
		// `bp signup` — create a Barkpark Cloud account and log in (cloud-12). The
		// registration sibling of `bp login`. Its flags (--email/--team/--password/
		// --url) are not globals, so they arrive in rest.
		return runSignupCloud(out, rest[1:])
	case "capabilities":
		return runCapabilities(out, g, ctx)
	case "whoami":
		return runWhoami(out, g, ctx)
	case "use":
		// `bp use <name|url>` — flip the active server locally (no network).
		return runUse(out, rest[1:])
	case "servers":
		// `bp servers` — list saved servers.
		return runServers(out, rest[1:])
	case "barkparks":
		// `bp barkparks` — the fleet view. AUTHORITATIVE control-plane registry
		// (cloud-12) when a Cloud token is present; the local KnownServers view
		// (cloud-11) as the no-token fallback. The branch lives in runBarkparks.
		return runBarkparks(out, rest[1:])
	case "provider":
		// `bp provider add hetzner --token <t> [--label <l>]` — connect a cloud
		// account to the control plane (cloud-12). Requires `bp login`.
		return runProvider(out, rest[1:])
	case "launch":
		// `bp launch hetzner --name <n>` — provision a Barkpark into a connected
		// provider via the control plane (cloud-12). Requires `bp login`.
		return runLaunch(out, rest[1:])
	case "go-live":
		// `bp go-live --name <n> [--plan pro]` — provision a fully-managed
		// Barkpark via the control plane (cloud-12). Requires `bp login`.
		return runGoLive(out, rest[1:])
	case "sites":
		// `bp sites <verb> …` — the P6 hosted-site surface (create / list /
		// deployments / env / domain / logs). Requires `bp login`.
		return runSites(out, rest[1:])
	case "deploy":
		// `bp deploy <site> --artifact-url <url>` — enqueue a deployment for a
		// hosted site through the control plane (P6). Requires `bp login`.
		return runDeploy(out, rest[1:])
	case "subscribe":
		// `bp subscribe --plan <tier>` — start a subscription checkout for the
		// team (POST /v1/billing/checkout) and print the URL the customer opens
		// to add a card (billing). Requires `bp login`.
		return runSubscribe(out, rest[1:])
	case "attach", "register":
		// `bp attach root@<host> --name <name>` / `bp register ssh root@<host>
		// --name <name>` — upsert a self-hosted Barkpark into local config. No
		// network call. Pass the noun through so the executor knows which form ran.
		return runAttach(out, noun, rest[1:])
	case "agent":
		// `bp agent disable|uninstall [--name <handle>]` — the LOCAL command
		// surface for the agent (cloud-10). Renders the SSH command it WOULD run;
		// does not execute it. verb is the action, tail the flags.
		return runAgent(out, verb, tail)
	case "doctor":
		// `bp doctor [--name <handle>] [--url <url>]` — run the post-deploy health
		// gate against the active/named server and report each check (cloud-13).
		// Exits non-zero if any check fails. Its own flags are not globals, so they
		// arrive in rest.
		return runDoctor(out, rest[1:])
	case "server":
		// `bp server ls` is an alias for `bp servers`. Any other `server <verb>`
		// is not a built-in; fall through to the manifest tree below.
		if verb == "ls" {
			return runServers(out, tail)
		}
	case "setup":
		// setup's own --flags are not global flags, so parseGlobals passed them
		// through into rest as verb+tail. Hand setup everything after the noun.
		return runSetup(out, g, rest[1:])
	case "uninstall":
		// `bp uninstall [--local]` — remove bp's local state (config, optionally
		// the local dev stack). Never the binary, never a remote server.
		return runUninstall(out, g, rest[1:])
	case "migrate":
		// `bp migrate <from> <to> [flags]` — server-to-server data copy. A
		// built-in (not a manifest command) because it spans TWO servers and
		// must resolve both via the saved-server config before any network call.
		// --yes is a global bool, but migrate also accepts its own flags, so we
		// hand it everything after the noun.
		return runMigrate(out, g, rest[1:])
	case "paper":
		// `bp paper view <slug> [flags]` — one-shot CLI render of a Bulldocs
		// paper to the terminal (the headless counterpart to the browser reader).
		// A built-in (not a manifest command) because it drives the pdrender
		// pipeline the generic command runner knows nothing about; it resolves the
		// target server/token/scope through the saved-server config like the rest.
		return runPaper(out, g, rest[1:])
	case "vercel":
		// `bp vercel quick-setup …` — stand up a new Barkpark-backed site and
		// ship it to Vercel in one shot. A built-in (not a manifest command)
		// because it composes a multi-step provisioning + deploy pipeline (and a
		// shell-out to the `vercel` binary) the generic command runner knows
		// nothing about; it resolves the target server + admin token through the
		// saved-server config like the rest.
		return runVercel(out, g, rest[1:])
	case "tinker":
		// `bp tinker [--dataset <ds>]` — an interactive, authenticated REPL
		// against a live dataset. A built-in (not a manifest command) because it
		// drives a readline loop, not a single request; it resolves the same
		// server/scope/token as every other command via the already-resolved ctx.
		return runTinker(out, g, ctx, rest[1:])
	case "seed":
		// `bp seed <type> [--count N]` — fabricate schema-valid-ish sample
		// documents and write them as drafts. A built-in because it composes a
		// schema fetch + a generated mutate the generic command runner has no
		// shape for; it honours the prod write-guard like every other write.
		return runSeed(out, g, ctx, rest[1:])
	case "make":
		// `bp make schema <name>` — emit a schema v2 JSON skeleton to stdout or a
		// file. A purely-local built-in (no network, no manifest): authoring a
		// content type becomes fill-the-blanks instead of reading the contract.
		return runMakeSchema(out, rest[1:])
	case "help":
		// `barkpark help [noun]` — surface usage; manifest-driven below if loaded.
	}

	// Acquire the manifest (override file > cache/fetch).
	m, err := loadManifest(g, ctx)
	if err != nil {
		out.errf("barkpark: %v", err)
		return exitGeneric
	}
	tree := m.Tree()

	if noun == "help" {
		usageTreeTop(out, m, tree)
		return exitOK
	}

	if verb == "" || g.help {
		// `barkpark <noun>` or `barkpark <noun> -h` → list the noun's verbs.
		if _, ok := lookupNoun(tree, noun); !ok {
			out.errf("barkpark: unknown command %q", noun)
			usageSuggestNouns(out, tree)
			return exitUsage
		}
		usageNoun(out, tree, noun)
		if verb == "" {
			return exitUsage // a noun with no verb is incomplete usage
		}
		return exitOK
	}

	cmd, ok := tree.Lookup(noun, verb)
	if !ok {
		out.errf("barkpark: unknown command %q %q", noun, verb)
		if _, nounOK := lookupNoun(tree, noun); nounOK {
			usageNoun(out, tree, noun)
		} else {
			usageSuggestNouns(out, tree)
		}
		return exitUsage
	}

	return runCommand(out, g, ctx, m, *cmd, tail)
}

// resolveContext composes the manifest.Context by precedence:
//
//	flags > env(actually-set) > active(persisted config) > baked defaults
//
// The crucial subtlety: apiclient.ConfigFromEnv() bakes a non-empty
// localhost/dev-token/default floor even when no BARKPARK_* var is set, which
// would mask the persisted-config layer entirely. So the CLI reads the env layer
// from the RAW vars (envContext) — an UNSET var leaves the field empty so the
// saved config can win — and moves apiclient's historical floor down into the
// Defaults layer where it belongs. A var the operator DID set still wins over the
// config, exactly as documented. The TUI's apiclient.ConfigFromEnv contract is
// untouched (this is a CLI-local read).
func resolveContext(g globals) manifest.Context {
	// Persisted config is the ActiveContext layer. A missing/empty config is a
	// no-op (empty ActiveContext); a malformed one is non-fatal here — we fall
	// back to the empty active layer rather than failing every command.
	var cfg *Config
	var active manifest.ActiveContext
	if c, err := LoadConfig(); err == nil {
		cfg = c
		active = c.ToActiveContext()
	}

	flags := map[string]string{}
	if g.token != "" {
		flags[manifest.FlagToken] = g.token
	}
	if g.workspace != "" {
		flags[manifest.FlagWorkspace] = g.workspace
	}
	if g.project != "" {
		flags[manifest.FlagProject] = g.project
	}
	if g.dataset != "" {
		flags[manifest.FlagDataset] = g.dataset
	}
	if g.output != "" {
		flags[manifest.FlagOutput] = g.output
	}

	// -s/--server resolution: when the value matches a known server's name /
	// DisplayName / URL, resolve to that entry's URL and carry its token + scope
	// at flag precedence — but NEVER clobber an explicitly-passed -w/-p/-d/--token
	// (those are already in `flags` above and win). A value that matches nothing
	// known is treated as a raw URL (today's behaviour). Env vars still win over
	// these injected values? No — an explicit -s is the user's deliberate choice,
	// so the resolved URL goes in as a flag (highest layer); the carried token/
	// scope are injected as flags ONLY where the user did not set the matching
	// flag, so they sit above env/active config exactly like the -s URL does.
	if g.server != "" {
		if entry, ok := cfg.FindServer(g.server); ok {
			flags[manifest.FlagServer] = entry.Server
			if _, set := flags[manifest.FlagToken]; !set && entry.Token != "" {
				flags[manifest.FlagToken] = entry.Token
			}
			if _, set := flags[manifest.FlagWorkspace]; !set && entry.Workspace != "" {
				flags[manifest.FlagWorkspace] = entry.Workspace
			}
			if _, set := flags[manifest.FlagProject]; !set && entry.Project != "" {
				flags[manifest.FlagProject] = entry.Project
			}
			if _, set := flags[manifest.FlagDataset]; !set && entry.Dataset != "" {
				flags[manifest.FlagDataset] = entry.Dataset
			}
		} else {
			// Unknown name → raw URL, as before.
			flags[manifest.FlagServer] = g.server
		}
	}

	return manifest.Resolve(flags, envContext(), active, bakedDefaults())
}

// envContext reads ONLY the BARKPARK_* vars that are actually set, leaving every
// unset field empty so a lower layer (persisted config, baked defaults) can win.
// This is deliberately NOT apiclient.ConfigFromEnv (which bakes a non-empty
// floor); the floor lives in bakedDefaults instead.
func envContext() apiclient.Config {
	server := os.Getenv("BARKPARK_API_URL")
	if server == "" {
		server = os.Getenv("BARKPARK_SERVER")
	}
	return apiclient.Config{
		BaseURL:   server,
		Token:     os.Getenv("BARKPARK_API_TOKEN"),
		Workspace: os.Getenv("BARKPARK_WORKSPACE"),
		Project:   os.Getenv("BARKPARK_PROJECT"),
		Dataset:   os.Getenv("BARKPARK_DATASET"),
	}
}

// bakedDefaults is the lowest-precedence floor — the same values
// apiclient.ConfigFromEnv historically baked into the env layer, relocated here
// so they only apply when neither an env var nor the persisted config supplies
// the field.
func bakedDefaults() manifest.Defaults {
	d := manifest.DefaultDefaults()
	d.Server = "http://localhost:4000"
	d.Token = "barkpark-dev-token"
	return d
}

// ResolvedAPIConfig returns the connection the interactive TUI should use,
// resolved through the EXACT precedence the CLI applies to every command:
//
//	explicitly-set BARKPARK_* env  >  saved-config ACTIVE server  >  baked defaults
//
// It reuses resolveContext (which folds envContext / the persisted config's
// ToActiveContext / bakedDefaults through manifest.Resolve) so the TUI and CLI
// can never drift on what "the active server" is — `bp use <name>` moves the
// config's active server, and the TUI then connects there. An explicit
// BARKPARK_API_URL still wins, because envContext sits above the config layer.
//
// The Perspective field is the TUI's editing-view default ("drafts", overridable
// via BARKPARK_PERSPECTIVE) — it is set here, NOT in resolveContext, so the CLI's
// manifest-driven reads (which never call this) keep the server's published
// default.
func ResolvedAPIConfig() apiclient.Config {
	ctx := resolveContext(globals{})
	return apiclient.Config{
		BaseURL:     ctx.Server,
		Token:       ctx.Token,
		Workspace:   ctx.Workspace,
		Project:     ctx.Project,
		Dataset:     ctx.Dataset,
		Perspective: apiclient.PerspectiveFromEnv(),
	}
}

// ServerSource describes where ResolvedAPIConfig's server came from, for the
// TUI's startup banner. It is a cheap, best-effort attribution computed from the
// same layers resolveContext consults: an explicitly-set env var → "env"; else a
// saved active server → "saved: <name>" (the display handle from the config);
// else the baked floor → "default". It re-derives rather than threading state
// through manifest.Resolve, so it stays a pure read with no behavioural coupling.
func ServerSource() string {
	if os.Getenv("BARKPARK_API_URL") != "" || os.Getenv("BARKPARK_SERVER") != "" {
		return "env"
	}
	if c, err := LoadConfig(); err == nil && c != nil && c.Server != "" {
		// Name the active server the way `bp servers` / `bp use` would show it.
		if e, ok := c.FindServer(c.Server); ok {
			return "saved: " + c.DisplayName(e)
		}
		return "saved: " + c.Server
	}
	return "default"
}

// lookupNoun returns the noun node if present.
func lookupNoun(t *manifest.Tree, name string) (*manifest.TreeNoun, bool) {
	for _, n := range t.Nouns {
		if n.Name == name {
			return n, true
		}
	}
	return nil, false
}

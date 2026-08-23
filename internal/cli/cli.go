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

// taskVerbAliases maps the two common muscle-memory `bp task` verbs the manifest
// does not declare to their canonical spellings. Applied at the top of
// `case "task"` in Execute, before any verb-specific intercept or manifest
// dispatch. Task-noun-only by design (charter decision 12) — the census named
// `task show`/`task list` specifically; no other noun gets these aliases.
var taskVerbAliases = map[string]string{
	"show": "get",
	"list": "ls",
}

// Execute is the CLI entry point. args is os.Args[1:]. It returns the process
// exit code; main() passes it straight to os.Exit. Execute never calls os.Exit
// itself so it stays unit-testable.
func Execute(args []string) int {
	out := newWriter(os.Stdout, os.Stderr)

	g, rest, err := parseGlobals(args)
	if err != nil {
		out.userErr("%v", err)
		usageTop(out)
		return exitUsage
	}
	out.applyGlobals(g)

	// `bp --version` / `bp -V` print the version and exit, before any noun
	// dispatch — so it works offline, with no manifest fetch.
	if g.version {
		return runVersion(out, g)
	}

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

	// Quiet update notice (update_notice.go): the rare release lookup STARTS
	// here so it overlaps the command's own runtime, and the deferred finish
	// prints after the command — at most one stderr line, never stdout or the
	// exit code.
	pendingUpdate := startUpdateCheck(noun)
	defer finishUpdateNotice(os.Stderr, pendingUpdate)

	// A broken repo context file (.barkpark.json) fails LOUDLY before any
	// dispatch — above all one carrying a "token" field, which is a credential
	// committed into a repo, never something to skip over quietly. `bp --version`
	// stays reachable (it returns above, before context resolution).
	if _, err := loadRepoFile(); err != nil {
		out.userErr("%v", err)
		return exitUsage
	}

	// Resolve the target context (flags > env > repo file > active > defaults).
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
		return runCompletion(out, g, ctx, rest[1:])
	case "login":
		// `bp login` — authenticate to the Barkpark Cloud control plane and store
		// the session token (cloud-12). Replaces the v1 token-stub. Its own flags
		// (--email/--password/--url) are not globals, so they arrive in rest.
		if g.help {
			printLoginHelp(out)
			return exitOK
		}
		return runLoginCloud(out, rest[1:])
	case "signup":
		// `bp signup` — create a Barkpark Cloud account and log in (cloud-12). The
		// registration sibling of `bp login`. Its flags (--email/--team/--password/
		// --url) are not globals, so they arrive in rest.
		if g.help {
			printSignupHelp(out)
			return exitOK
		}
		return runSignupCloud(out, rest[1:])
	case "logout":
		// `bp logout` — clear the stored Barkpark Cloud session (cloud-12): the
		// sign-out sibling of `bp login`. Blanks the three Cloud* fields; `--all`
		// (a global → g.all) additionally drops the active content token. Help and
		// any other args arrive in rest.
		return runLogout(out, g, rest[1:])
	case "capabilities":
		return runCapabilities(out, g, ctx)
	case "whoami":
		return runWhoami(out, g, ctx)
	case "listen":
		// `bp listen [type[,type…]]` — stream the live change feed as JSON, one
		// event per line, until Ctrl-C. A built-in because SSE is a streaming
		// response, not the single JSON body the manifest command path expects.
		return runListen(out, g, ctx, rest[1:])
	case "export":
		// `bp export [--type <t>] [--perspective <p>]` — stream the active dataset
		// as NDJSON (one document per line) for backup: `bp export > backup.ndjson`.
		// A built-in because the response is a streamed NDJSON body.
		return runExport(out, g, ctx, rest[1:])
	case "tasks":
		// `bp tasks` — the live portrait task board (internal/taskboard). A built-in
		// because it is a full-screen interactive TUI, not a manifest JSON verb.
		// Distinct from the singular `bp task …` manifest noun (help cross-refs both).
		return runTasksBoard(out, g, ctx, rest[1:])
	case "chat":
		// `bp chat` — the native terminal chat client (internal/chat), the second
		// surface of One Chat, Two Surfaces. A built-in because it is a full-screen
		// interactive Bubble Tea program with its own SSE stream, not a manifest
		// JSON verb.
		return runChat(out, g, ctx, rest[1:])
	case "task":
		// Task-noun verb aliases (charter decision 12; census: 2,428 `task show`
		// + 329 `task list` typed errors — 1.19 MB of pure context waste). The
		// manifest declares `get`/`ls`, not the `show`/`list` spellings muscle
		// memory reaches for; `show` is not even Levenshtein-reachable from `get`,
		// so a bare did-you-mean cannot cover it. Rewrite the local verb IN PLACE,
		// note the rewrite on stderr ONLY (proven invisible to `-o json` stdout,
		// so machine output stays byte-identical to the canonical verb), and FALL
		// THROUGH to the normal manifest dispatch — the same shape as the `server
		// ls`→`servers` and `task tui` precedents. Task-noun-only by design.
		if alias, ok := taskVerbAliases[verb]; ok {
			out.errf("note: `task %s` is not a verb — running `barkpark task %s`", verb, alias)
			verb = alias
		}
		// `bp task tui` is the discoverable singular-noun spelling of the same
		// full-screen reader as `bp tasks`. Keep one implementation and one
		// renderer; this alias exists so a user already navigating `bp task …`
		// does not have to discover a separate noun to read rich task briefs.
		if verb == "tui" {
			return runTasksBoard(out, g, ctx, tail)
		}
		// `bp task frontier` — the dispatch surface (wave 13): the maximal set of
		// ready tasks that can run in parallel without their blast radii colliding.
		// A built-in because it computes the interference model client-side over the
		// board snapshot; the manifest `task` noun carries no `frontier` verb, so
		// this intercept shadows nothing. Every OTHER `task` verb falls through to
		// the manifest dispatch below (no return here).
		if verb == "frontier" {
			return runTaskFrontier(out, g, ctx, tail)
		}
		// `bp task lint` — an advisory metadata NUDGE (df-lint-area-nudge): every
		// workable leaf (ready, no children) carrying no authored area: label, the
		// gap that starves the frontier's interference model. Same client-side
		// intercept as frontier (the manifest `task` noun has no `lint` verb), and
		// it ALWAYS exits 0 — a nudge, never a gate.
		if verb == "lint" {
			return runTaskLint(out, g, ctx, tail)
		}
		// `bp task create [<title>]` — file a new task. A client-side builtin
		// like frontier/lint: the manifest `task` noun declares only the eight
		// lifecycle/read verbs (no `create`), so this intercept shadows nothing.
		// It injects the task schema's required kind/lifecycle_status defaults
		// and sends the create via the same mutate contract `bp doc create` uses
		// — the ergonomic front door that a bare `bp doc create task` (which does
		// not know those required fields) can't be.
		if verb == "create" {
			return runTaskCreate(out, g, ctx, tail)
		}
		// `bp task next <worker> --frontier` — the frontier-aware atomic claim
		// (df-next-frontier). Fires ONLY when --frontier is present; a BARE
		// `bp task next <worker>` falls through untouched to the manifest queue
		// endpoint (POST /v1/tasks/claim). --frontier computes the non-colliding
		// ready set and claims the top pick by id via the epoch-CAS claim,
		// skipping to the next pick on a lost race or a file-scope conflict.
		if verb == "next" && hasFlag(tail, "--frontier") {
			worker, fopts, err := parseNextFrontierArgs(tail)
			if err != nil {
				return usageErrf(out, func() { printTaskFrontierHelp(out) }, "%v", err)
			}
			return runTaskNextFrontier(out, g, ctx, worker, fopts)
		}
		// `bp task ready` capacity header — prepend one honest line naming the
		// dispatch frontier size before the normal manifest ready list renders
		// ("FRONTIER · N independent · P proven · U unproven"). Human/table output
		// only: -o json|yaml stays byte-identical (scripts parse it), so the header
		// is skipped in machine mode. Best-effort — a snapshot fetch error just
		// drops the header, never blocking the ready list. Then FALL THROUGH to the
		// manifest dispatch (no return) so `bp task ready` renders exactly as before.
		if verb == "ready" && !g.help && !out.machineOut() {
			printReadyFrontierHeader(out, ctx)
		}
		// `bp task` bare (a noun with no verb) — prepend ONE live counts line above
		// the verb list so the incomplete-usage view still answers "what's the state
		// of the board?" instead of only listing verbs (AXI R7). Sourced from GET
		// /v1/tasks/prime `counts`; best-effort and human-only: an offline server or
		// any fetch error simply drops the line, the usage block still prints, and the
		// exit stays exitUsage. Machine output (-o json|yaml) is left byte-identical.
		// Then FALL THROUGH (no return) to the manifest usage path below.
		if verb == "" && !g.help && !out.machineOut() {
			if counts, err := fetchTaskCounts(ctx); err == nil {
				if line := formatTaskCountsLine(counts); line != "" {
					out.errf("%s", line)
					out.errf("")
				}
			}
		}
	case "cmux":
		// `bp cmux <hook|dispatch|install|status>` — the CMUX × Barkpark bridge
		// (task-TUI epic, wave 14). A client-side builtin like `bp tasks` / `bp
		// task frontier`: `cmux` is not a manifest noun, so this intercept shadows
		// nothing and needs no server/API change. `bp cmux hook <event>` is the
		// fail-safe Claude Code hook adapter (claim on SessionStart, renew the
		// lease, close on proven acceptance); `dispatch` spawns the frontier into
		// agent panes; `install` prints the hook wiring; `status` shows this pane's
		// worker/task/lease. Everything after the noun rides in rest.
		return runCmux(out, g, ctx, rest[1:])
	case "mcp":
		// `bp mcp serve [--tools tasks|all]` — a stdio Model-Context-Protocol
		// server exposing Barkpark Tasks to MCP clients (Cursor, Claude Desktop).
		// A client-side builtin like cmux/doctor: `mcp` is not a manifest noun, so
		// this intercept shadows nothing and needs no server change. It loads the
		// manifest ONCE (inside runMCPServe, honouring --manifest/$BARKPARK_MANIFEST)
		// and reuses the manifest-driven request machinery to back each MCP tool.
		if verb == "serve" {
			return runMCPServe(out, g, ctx, tail)
		}
		if g.help || verb == "" {
			printMCPServeHelp(out)
			return exitOK
		}
		return usageErrf(out, func() { printMCPServeHelp(out) }, "unknown command %q %q", noun, verb)
	case "onramp":
		// `bp onramp <cursor|claude-code|codex|cursor-cloud>` — print the exact
		// MCP-registration config for one AI-agent surface (agent-onramps epic,
		// wave 1). A client-side builtin like cmux/mcp: `onramp` is not a manifest
		// noun, so this intercept shadows nothing and needs no server change.
		// PRINT-ONLY in v1 (the cmux_install.go precedent) — it never writes a
		// file. --server/--token are global flags already folded into g; the
		// target and any trailing tokens ride in rest[1:].
		return runOnramp(out, g, rest[1:])
	case "context":
		// `bp context pack <file…>` — pack files into an optical context bundle
		// (paginated PNG pages + a verbatim text sidecar) an agent reads at a
		// fraction of the text-token price. A client-side builtin like cmux/mcp/
		// onramp: `context` is not a manifest noun, so this intercept shadows
		// nothing and needs no server change. Local file I/O only — no network.
		// Research trail: /papers/optical-compression-research-report.
		if verb == "pack" {
			return runContextPack(out, g, tail)
		}
		if g.help || verb == "" {
			printContextPackHelp(out)
			return exitOK
		}
		return usageErrf(out, func() { printContextPackHelp(out) }, "unknown command %q %q", noun, verb)
	case "use":
		// `bp use <name|url>` — flip the active server locally (no network).
		return runUse(out, rest[1:])
	case "servers":
		// `bp servers` — list saved servers.
		return runServers(out, rest[1:])
	case "teams":
		// `bp teams` — list the Cloud team memberships (GET /v1/me), starring the
		// active team. The switcher's read half; the write half is `bp team use`.
		// Requires `bp login`.
		if g.help {
			printTeamsHelp(out)
			return exitOK
		}
		return runTeams(out, rest[1:])
	case "team":
		// `bp team use <slug|id>` — switch the active Cloud team (persists
		// cfg.CloudTeam). The switcher's write half. Requires `bp login`.
		if g.help {
			printTeamHelp(out)
			return exitOK
		}
		return runTeam(out, rest[1:])
	case "barkparks":
		// `bp barkparks` — the fleet view. AUTHORITATIVE control-plane registry
		// (cloud-12) when a Cloud token is present; the local KnownServers view
		// (cloud-11) as the no-token fallback. The branch lives in runBarkparks.
		if g.help {
			printBarkparksHelp(out)
			return exitOK
		}
		barkparksArgs := append([]string(nil), rest[1:]...)
		if g.all {
			barkparksArgs = append(barkparksArgs, "--all")
		}
		return runBarkparks(out, barkparksArgs)
	case "provider":
		// `bp provider add hetzner --token <t> [--label <l>]` — connect a cloud
		// account to the control plane (cloud-12). Requires `bp login`.
		if g.help {
			printProviderHelp(out)
			return exitOK
		}
		return runProvider(out, rest[1:])
	case "launch":
		// `bp launch hetzner --name <n>` — provision a Barkpark into a connected
		// provider via the control plane (cloud-12). Requires `bp login`.
		if g.help {
			printLaunchHelp(out)
			return exitOK
		}
		return runLaunch(out, rest[1:])
	case "go-live":
		// `bp go-live --name <n> [--plan supporter]` — provision a fully-managed
		// Barkpark via the control plane (cloud-12). Requires `bp login`.
		if g.help {
			printGoLiveHelp(out)
			return exitOK
		}
		return runGoLive(out, rest[1:])
	case "instance":
		// `bp instance credentials <id>` — retrieve the per-instance admin token the
		// platform minted at provision time (instance-admin-token), team-admin-gated.
		// Requires `bp login`.
		if g.help {
			printInstanceHelp(out)
			return exitOK
		}
		return runInstance(out, rest[1:])
	case "sites":
		// `bp sites <verb> …` — the P6 hosted-site surface (create / list /
		// deployments / env / domain / logs). Requires `bp login`.
		if g.help {
			printSitesHelp(out)
			return exitOK
		}
		return runSites(out, rest[1:])
	case "deploy":
		// `bp deploy <site> --artifact-url <url>` — enqueue a deployment for a
		// hosted site through the control plane (P6). Requires `bp login`.
		if g.help {
			printDeployHelp(out)
			return exitOK
		}
		return runDeploy(out, rest[1:])
	case "cloud":
		// `bp cloud hetzner <resource> <verb> …` — direct provider control over
		// the provider's OWN API (internal/hetzner's native SDK client), no
		// control plane and no bp login. Everything after the noun (provider,
		// resource, verb, command-local flags) rides in rest; -o/--token are
		// globals and arrive via g.
		return runCloud(out, g, rest[1:])
	case "subscribe":
		// `bp subscribe --plan <tier>` — start a subscription checkout for the
		// team (POST /v1/billing/checkout) and print the URL the customer opens
		// to add a card (billing). Requires `bp login`.
		if g.help {
			printSubscribeHelp(out)
			return exitOK
		}
		return runSubscribe(out, rest[1:])
	case "attach", "register":
		// `bp attach root@<host> --name <name>` / `bp register ssh root@<host>
		// --name <name>` — upsert a self-hosted Barkpark into local config. No
		// network call. Pass the noun through so the executor knows which form ran.
		if g.help {
			printRegisterHelp(out)
			return exitOK
		}
		return runAttach(out, noun, rest[1:])
	case "agent":
		// `bp agent disable|uninstall [--name <handle>]` — the LOCAL command
		// surface for the agent (cloud-10). Renders the SSH command it WOULD run;
		// does not execute it. verb is the action, tail the flags.
		if g.help {
			printAgentHelp(out)
			return exitOK
		}
		return runAgent(out, verb, tail)
	case "doctor":
		// `bp doctor [--name <handle>] [--url <url>]` — run the post-deploy health
		// gate against the active/named server and report each check (cloud-13).
		// Exits non-zero if any check fails. Its own flags are not globals, so they
		// arrive in rest.
		// `bp doctor --onboarding` is the D3 client-readiness receipt (a
		// disjoint mode, doctor_onboarding.go); plain `bp doctor` stays the
		// remote-server health gate. Check the mode BEFORE the shared --help so
		// the onboarding receipt gets its OWN help text (it still honours -h via
		// its own arg scan).
		if doctorOnboardingRequested(rest[1:]) {
			return runDoctorOnboarding(out, g, ctx, rest[1:])
		}
		if g.help {
			printDoctorHelp(out)
			return exitOK
		}
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
		return runMakeSchema(out, g, rest[1:])
	case "style":
		// `bp style` — render Barkpark's CLI/TUI design tokens (status roles,
		// lifecycle glyphs, priority severity, spinner) to the terminal. A purely-
		// local built-in (no network, no manifest): it reads the generated design
		// tokens through internal/semrole + taskboard so the sheet can never drift
		// from what the CLI/TUI actually paints. Honours NO_COLOR / a pipe.
		return runStyle(out, g, rest[1:])
	case "scaffy":
		// `bp scaffy validate|fmt <path>...` — validate/format .scaffy command
		// files against the pinned Scaffy v2 grammar (internal/scaffy). A purely-
		// local built-in like make/style (no network, no manifest): `scaffy` is
		// not a manifest noun, so this intercept shadows nothing. Everything
		// after the noun (verb, --check, paths) rides in rest.
		return runScaffy(out, g, rest[1:])
	case "help":
		// `barkpark help [noun]` — surface usage; manifest-driven below if loaded.
	}

	// Acquire the manifest (override file > cache/fetch).
	m, err := loadManifest(g, ctx)
	if err != nil {
		out.userErr("%v", err)
		return exitGeneric
	}
	tree := m.Tree()

	if noun == "help" {
		// `barkpark help <noun>` scopes usage to that noun (like git/gh/stripe);
		// bare `barkpark help` still prints the full tree.
		if verb != "" {
			if _, ok := lookupNoun(tree, verb); ok {
				usageNoun(out, tree, verb)
				return exitOK
			}
			return suggestUnknownNoun(out, tree, m.AuthTier, verb)
		}
		usageTreeTop(out, m, tree)
		return exitOK
	}

	if verb == "" || g.help {
		// `barkpark <noun>` or `barkpark <noun> -h` → list the noun's verbs.
		if _, ok := lookupNoun(tree, noun); !ok {
			return suggestUnknownNoun(out, tree, m.AuthTier, noun)
		}
		// `barkpark <noun> <verb> -h` → that command's own arg/flag help
		// (like git/gh/stripe), not the whole noun overview.
		if verb != "" {
			if cmd, ok := tree.Lookup(noun, verb); ok {
				usageCommand(out, *cmd)
				return exitOK
			}
		}
		// Bare `bp <noun>` (AXI R7 / charter decision 19): prepend ONE best-effort
		// counts line from GET /v1/data/counts/:dataset so the incomplete-usage view
		// still answers "how much of this content type is there?" instead of only
		// listing verbs. `task` is excluded — it prints its own richer lifecycle line
		// above (the `case "task"` bare branch). Human output only and silent-degrade:
		// a pre-counts / offline server, or a command noun that is not a stored type,
		// drops the line and the verb list prints exactly as before. Skipped for the
		// `-h` help request (g.help) — that is documentation, not a board glance.
		// Then FALL THROUGH to usageNoun (no return) so usage renders as before.
		if verb == "" && !g.help {
			if line := nounCountsLine(noun, out.machineOut(), ctx); line != "" {
				out.errf("%s", line)
				out.errf("")
			}
		}
		usageNoun(out, tree, noun)
		if verb == "" {
			return exitUsage // a noun with no verb is incomplete usage
		}
		return exitOK
	}

	cmd, ok := tree.Lookup(noun, verb)
	if !ok {
		// A REAL noun followed by something that is not one of its verbs used to
		// report `unknown command "search" "PDS crown proof"` — which reads as
		// "the noun `search` is unknown" and sent six independent agents in one
		// wave off to grep instead of searching Barkpark. The manifest tree can
		// tell the two cases apart, so it must: an unknown NOUN keeps its
		// noun-typo suggestion; a known noun gets a message that says the noun is
		// fine and names the exact fix.
		//
		// THE INFERENCE RULE (deliberately narrow — `soleReadVerb`):
		//   FIRES only when ALL of these hold:
		//     - the noun is real and declares EXACTLY ONE verb (no guessing which
		//       of several the user meant — one obvious answer or nothing);
		//     - that verb does not write (manifest `writes:false`) — a destructive
		//       verb is NEVER inferred, only suggested;
		//     - the typed token is not itself a near-typo of that verb (then it is
		//       a mistyped verb, not an argument: `search quer x` still corrects);
		//     - the token does not look like a flag (`-`/`--`).
		//   When it fires, the token and everything after it are re-dispatched as
		//   the verb's ARGUMENTS (`bp search "text"` → `bp search query "text"`),
		//   with one stderr note so the rewrite is never silent.
		//   DOES NOT FIRE for a multi-verb noun (`bp doc "text"`), for a writing
		//   sole verb, or for an unknown noun — each of those falls through to the
		//   precise error below, which names the corrected command when it can.
		if n, nounOK := lookupNoun(tree, noun); nounOK {
			if sole, inferable := soleReadVerb(n, verb); inferable {
				out.errf("note: `%s` has one verb — running `barkpark %s %s`", noun, noun, sole.Verb)
				return runCommand(out, g, ctx, m, *sole, append([]string{verb}, tail...))
			}
			return usageErrHintf(out, func() {
				usageSuggestVerb(out, tree, noun, verb)
			}, verbHint(tree, noun, verb), "%s", noVerbMsg(n, noun, verb))
		}
		return suggestUnknownNoun(out, tree, m.AuthTier, noun)
	}

	// `bp task stamp` — client-side ergonomic wrapper: echo the 0-based
	// --criterion index TRANSLATED to the 1-based position boards show, and
	// refuse a --met on a MERGE-GATED row without an explicit --merge-gated
	// override (the one mis-index that corrupts a lead's merge decision). The
	// actual POST still runs through runCommand — the wrapper only adds the two
	// CLI-only guards, then strips the CLI-only flag before delegating.
	if noun == "task" && verb == "stamp" {
		return runTaskStamp(out, g, ctx, m, *cmd, tail)
	}

	// `bp task claim` — client-side ergonomic wrapper: on a refused claim
	// (exit 6 — not_ready and its task-claim/close-contention siblings), read
	// the task doc back and print a diagnosis of WHICH of the several causes a
	// bare "not_ready" can mean (genuinely not ready / held live by someone
	// else / a stale-but-present claim.worker refusing every id but the
	// original holder — task-eb2b6170e19f1611). The POST itself is unchanged;
	// this only adds a stderr diagnosis after a conflict.
	if noun == "task" && verb == "claim" {
		return runTaskClaim(out, g, ctx, m, *cmd, tail)
	}

	// `bp task close` and `bp task pulse` — the SAME read-back `bp task stamp`
	// got in wave 26 (PDS-D359/D361), extended to its two siblings on this
	// ledger. close is the seal and pulse writes the board's now-line; both
	// reported success on an exit code alone. The POST is unchanged — each
	// wrapper only adds the second read and renders the verdict from what the
	// store holds. See tasks_close_pulse_cmd.go.
	if noun == "task" && verb == "close" {
		return runTaskClose(out, g, ctx, m, *cmd, tail)
	}
	if noun == "task" && verb == "pulse" {
		return runTaskPulse(out, g, ctx, m, *cmd, tail)
	}

	return runCommand(out, g, ctx, m, *cmd, tail)
}

// resolveContext composes the manifest.Context by precedence:
//
//	flags > env(actually-set) > repo file (.barkpark.json) > active(persisted config) > baked defaults
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

	// The repo-scoped context (.barkpark.json, discovered by walking up from
	// cwd) folds over the active layer per-field, which slots it between env and
	// the global config: flags > env > repo file > active > defaults. An
	// unloadable file is treated as ABSENT here — Execute has already refused to
	// dispatch on one (the loud token/parse gate), so this lenient read can
	// never silently honour a rejected file.
	if repo, err := loadRepoFile(); err == nil {
		active = repo.overlayActive(cfg, active)
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

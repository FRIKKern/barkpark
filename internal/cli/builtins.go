package cli

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"sort"
	"strings"
	"time"

	"github.com/FRIKKern/barkpark/internal/cloudclient"
	"github.com/FRIKKern/barkpark/internal/manifest"
)

// runVersion prints the CLI version. -o json/yaml emit a small object,
// -o minimal the bare version string; otherwise a human line.
func runVersion(out *writer, g globals) int {
	v := map[string]string{"cli_version": cliVersion}
	if cliCommit != "" {
		v["commit"] = cliCommit
	}
	if cliDate != "" {
		v["build_date"] = cliDate
	}
	switch out.output {
	case "json":
		out.renderJSON(v)
	case "yaml":
		// Round-trip through JSON to a generic value for the YAML emitter.
		b, _ := json.Marshal(v)
		var y any
		_ = json.Unmarshal(b, &y)
		out.renderYAML(y)
	case "minimal":
		out.outf("%s", cliVersion)
	default:
		out.outf("bp %s", cliVersion)
	}
	return exitOK
}

// runCapabilities prints the resolved manifest. Machine output (-o json/yaml)
// is BORN BRIEF: it renders the invoke-complete BRIEF-KEEP-LIST v1 projection
// (capsbrief.go) unless --full asks for the complete server document — the
// existing AXI opt-out predicate (machineOut && !g.full), so --full stays
// byte-identical to the pre-brief output. The human summary (-o table /
// minimal) is untouched. This is a CLI built-in, NOT a manifest command; the
// fetch/cache path always carries the FULL manifest — only the print projects.
func runCapabilities(out *writer, g globals, ctx manifest.Context) int {
	m, err := loadManifest(g, ctx)
	if err != nil {
		out.userErr("%v", err)
		return exitGeneric
	}

	// The machine payload: the brief projection by default, the full manifest
	// under --full. Chosen once so json and yaml can never disagree.
	var machine any = m
	if out.machineOut() && !g.full {
		machine = briefManifest(m)
	}

	switch out.output {
	case "json":
		out.renderJSON(machine)
		out.errf("%s", builtinPointerLine())
	case "yaml":
		// Round-trip through JSON to a generic value for the YAML emitter.
		b, _ := json.Marshal(machine)
		var v any
		_ = json.Unmarshal(b, &v)
		out.renderYAML(v)
		out.errf("%s", builtinPointerLine())
	default:
		tree := m.Tree()
		out.outf("server:    %s (%s)", m.Server.Name, m.Server.Version)
		out.outf("base_url:  %s", m.Server.BaseURL)
		out.outf("auth_tier: %s", m.AuthTier)
		out.outf("manifest:  v%s  etag=%s", m.ManifestVersion, m.ETag)
		out.outf("")
		out.outf("commands:")
		for _, n := range tree.Nouns {
			for _, c := range n.Verbs {
				out.outf("  %-10s %-16s %s", c.Noun, c.Verb, c.Summary)
			}
		}
		// The manifest is not the whole command surface: a handful of verbs are
		// dispatched CLIENT-SIDE (nounBuiltins, noun_builtins.go) and can never
		// appear in a server document. `bp task create` was invisible here for
		// months and readers concluded it did not exist. Additive and CLI-side
		// only — the manifest contract, the brief projection, and every byte of
		// machine stdout are untouched; machine mode gets the same fact as ONE
		// stderr line above.
		if lines := builtinCapabilityLines(); len(lines) > 0 {
			out.outf("")
			for _, line := range lines {
				out.outf("%s", line)
			}
		}
	}
	return exitOK
}

// metaResponse is the subset of GET /v1/meta the CLI surfaces in whoami.
//
// Production is the server-authoritative production signal consumed by the
// prod write-guard (serverDeclaredNonProd). It is a *bool so tolerance runs
// both directions — an old server that omits the key parses as nil (the guard
// stays fail-closed), and an old CLI ignores the extra key (plain
// json.Unmarshal). It rides /v1/meta and NEVER the capabilities manifest:
// manifest decoding is strict (DisallowUnknownFields), so a manifest field
// would brick every older CLI against a newer server (D16).
type metaResponse struct {
	ServerTime    string            `json:"serverTime"`
	MinAPIVersion string            `json:"minApiVersion"`
	MaxAPIVersion string            `json:"maxApiVersion"`
	SchemaHashes  map[string]string `json:"currentDatasetSchemaHash"`
	Production    *bool             `json:"production"`
}

// serverDeclaredNonProd asks GET /v1/meta whether the server explicitly
// advertises production:false — the ONLY server-side signal that may skip the
// prod write-confirm now that isProd/isProdServer fail closed on custom hosts.
// Everything else keeps the guard: field absent (old server), production:true,
// transport error, non-2xx, or an unparseable body all return false. Callers
// short-circuit behind the isProd heuristic and --yes, so this network consult
// only happens when a confirm would otherwise fire.
func serverDeclaredNonProd(server string) bool {
	metaURL := strings.TrimRight(server, "/") + "/v1/meta"
	status, body, err := doRequest("GET", metaURL, map[string]string{}, nil)
	if err != nil || status < 200 || status >= 300 {
		return false
	}
	var meta metaResponse
	if json.Unmarshal(body, &meta) != nil {
		return false
	}
	return meta.Production != nil && !*meta.Production
}

// whoamiSourceName classifies where ctx.Server was chosen from, for whoami's
// "saved/default/env/flag" annotation, plus the resolved server NAME: the
// DisplayName of whichever known entry matches ctx.Server (by name or URL),
// empty when no known entry matches (a raw -s URL or env var pointing somewhere
// unsaved). The name is purely cosmetic — it never changes the source/active
// classification.
func whoamiSourceName(g globals, ctx manifest.Context) (source string, active bool, name string) {
	cfg, _ := LoadConfig()
	if cfg != nil {
		// Resolve the name from whatever known entry matches the RESOLVED server
		// URL (works for a -s name, a -s URL, the saved active, or env).
		if e, ok := cfg.FindServer(ctx.Server); ok {
			name = cfg.DisplayName(e)
		}
	}

	// 1. Explicit --server flag wins.
	if g.server != "" {
		return "flag", false, name
	}
	// 2. Env var, if actually set — every name the resolver answers to, read from
	//    the SAME list envContext resolves through (ServerEnvNames). This label
	//    is what `bp whoami` prints under "source", so a name the resolver
	//    honours but this check misses makes whoami blame the saved config or
	//    the baked default for a server the environment chose. That is worse
	//    than silence: it sends the next person to change the wrong thing.
	if anyEnvSet(ServerEnvNames...) {
		return "env", false, name
	}
	// 3. Saved config — the resolved server matches the persisted active server.
	if cfg != nil && cfg.ActiveServer() != "" {
		if normalizeServerURL(cfg.ActiveServer()) == normalizeServerURL(ctx.Server) {
			return "saved", cfg.IsActiveServer(ctx.Server), name
		}
	}
	// 4. Otherwise it's the baked localhost default.
	return "default", false, name
}

// runWhoami answers "what am I connected to" — and it is LOCAL-FIRST, so it
// ALWAYS works even when the server is down. It prints the resolved target
// (server URL + how it was chosen, scope, token presence) from ctx alone; the
// manifest's caller auth_tier echo (M0 decision A3 — no dedicated endpoint) and
// GET /v1/meta are BEST-EFFORT enrichment that never fail the command. whoami
// reports your config; it is not a connectivity gate, so it always exits 0.
func runWhoami(out *writer, g globals, ctx manifest.Context, prov tokenProvenance) int {
	source, active, name := whoamiSourceName(g, ctx)
	tokenPresent := ctx.Token != ""

	// WHICH credential, not merely whether one exists. `token_present: true` was
	// the whole diagnosis before this line, and it is the same "true" for a saved
	// admin token and for a stale BARKPARK_TOKEN that outranked it — the exact
	// ambiguity that made a shadowed login unreadable. prov comes from
	// resolveContextProv, beside the fold that picked the token (tokensource.go);
	// a zero prov (a caller that resolved its own context) degrades to a stated
	// "unknown"/"none" rather than a blank field.
	tokenSource := prov.label()
	if prov.Source == "" {
		tokenSource = tokenSourceUnknown
		if !tokenPresent {
			tokenSource = tokenSourceNone
		}
	}

	// Kind classification of the resolved target — honour a known entry's Kind
	// override when ctx.Server matches one, else derive local/cloud from the URL.
	// whoami works without any saved config, so the free ServerKind is the floor.
	kind := ServerKind(ctx.Server)
	if cfg, _ := LoadConfig(); cfg != nil {
		if e, ok := cfg.FindServer(ctx.Server); ok {
			kind = cfg.KindOf(e)
		}
	}

	// Best-effort manifest fetch (short timeout via loadManifest's client). On
	// ANY failure we leave the server identity / tier / prod fields unknown and
	// mark the server unreachable — whoami must not die because the server is.
	reachable := false
	serverName := ""
	authTier := ""
	prod := false
	var loadedManifest *manifest.Manifest
	// credentialRefused is the server SAYING NO to this token (401/403), which is
	// a different fact from "unreachable" and from "reachable at tier none" — and
	// the shadow warning below needs all three to fire honestly.
	credentialRefused := false
	if m, err := loadManifest(g, ctx); err == nil {
		loadedManifest = m
		reachable = true
		serverName = m.Server.Name
		authTier = m.AuthTier
		prod = isProd(ctx, m)
	} else {
		var se *manifest.StatusError
		if errors.As(err, &se) && se.Unauthenticated() {
			credentialRefused = true
		}
	}

	// Best-effort /v1/meta for server_time + api version range. Never fatal.
	metaURL := strings.TrimRight(ctx.Server, "/") + "/v1/meta"
	var meta metaResponse
	if status, body, derr := doRequest("GET", metaURL, map[string]string{}, nil); derr == nil && status >= 200 && status < 300 {
		_ = json.Unmarshal(body, &meta)
	}

	var tierVal any // null when unreachable
	if reachable {
		tierVal = authTier
	}

	// THE ENV-SHADOWS-CONFIG WARNING. Three conditions, ALL required:
	//   1. the token came from an env var (prov.fromEnv),
	//   2. a DIFFERENT saved/repo-file token for the SAME server sits under it
	//      (prov.Alt — resolveContextProv already refused to claim a shadow
	//      across servers), and
	//   3. the server did not accept the env token: it reported auth_tier none
	//      (the measured shape — /v1/capabilities answers 200 with tier "none"
	//      for an unknown bearer) or it refused outright with 401/403.
	// The negative arm matters as much as the positive one: an env token the
	// server ACCEPTS is a deliberate override and prints nothing. An unreachable
	// server prints nothing either — we never learned whether the token works,
	// and "could not measure" is not "rejected".
	warnings := []string{}
	tierRejected := (reachable && (authTier == "" || authTier == "none")) || credentialRefused
	// ONE warning, not two lines that can be read apart: the finding and its
	// remedy travel together, in stderr and in warnings[] alike.
	if prov.shadowsSaved() && tierRejected {
		reason := shadowReasonTierNone
		if credentialRefused {
			reason = shadowReasonRefused
		}
		warnings = append(warnings, prov.shadowWarning(reason)+" — "+prov.shadowFix())
	}

	// Cloud control-plane session (cloud-12, re-derived in dr-w35) — SEPARATE
	// from the content target above, and no longer a presence oracle. The old
	// arm derived `logged_in: true` from cfg.HasCloudToken() alone — a config
	// file stat — while every control-plane call from the same session could be
	// 401ing: a green local reading over a dead remote, the epic's founding
	// shape, inside its own diagnostic. The SAME function already probes the
	// CONTENT server for `reachable`; the cloud plane now gets the same
	// treatment: one cheap authed GET /v1/me with a short timeout, best-effort,
	// never fatal (whoami still always exits 0).
	//
	// The verdict is a TRI-STATE and the json says which: `logged_in` is true
	// only when the control plane VERIFIED the token, false when there is no
	// token or the plane REJECTED it (401/403), and null when a token is
	// present but the plane could not be reached — "could not measure" is not
	// "no". `session` names the arm outright (none/verified/rejected/
	// unverified) and `token_present` keeps the old fact honest under its own
	// name. The token value itself still NEVER appears.
	cloudTokenPresent := false
	cloudURL := ""
	cloudTeam := ""
	cloudSession := "none"
	// WHICH tier the credential came from — the origin label only
	// (env:BARKPARK_CLOUD_TOKEN | config:cloud_token), never a byte of the
	// value. token_present says a credential exists; session says the plane
	// adjudicated it; this says WHICH ONE was adjudicated, which is the fact a
	// CI job needs when a deploy 401s while a stale config.json sits on the box.
	cloudTokenSource := ""
	var cloudLoggedIn any = false // true | false | nil (null = unverifiable)
	if cfg, _ := LoadConfig(); cfg != nil && cfg.HasCloudToken() {
		cloudTokenPresent = true
		cloudTokenSource = cfg.CloudTokenSource()
		cloudURL = strings.TrimSpace(cfg.CloudURL)
		if cloudURL == "" {
			cloudURL = cloudclient.DefaultBaseURL
		}
		cloudTeam = cfg.CloudTeam

		probe := cfg.CloudClient()
		// whoami is a diagnostic, not a workload: a plane that answers slowly
		// reads UNVERIFIED rather than hanging the command for 30s.
		probe.HTTP = &http.Client{Timeout: 4 * time.Second}
		pctx, cancel := context.WithTimeout(context.Background(), 4*time.Second)
		_, meErr := probe.Me(pctx)
		cancel()
		var refusal *cloudclient.CloudRefusal
		switch {
		case meErr == nil:
			cloudSession = "verified"
			cloudLoggedIn = true
		case errors.As(meErr, &refusal) && (refusal.HTTPStatus == http.StatusUnauthorized || refusal.HTTPStatus == http.StatusForbidden):
			cloudSession = "rejected"
			cloudLoggedIn = false
		default:
			// Network failure, timeout, 5xx: the token was never adjudicated.
			cloudSession = "unverified"
			cloudLoggedIn = nil
		}
	}

	cloudBlock := map[string]any{
		"logged_in":     cloudLoggedIn,
		"token_present": cloudTokenPresent,
		"session":       cloudSession,
		"url":           cloudURL,
		"team":          cloudTeam,
	}
	// Additive and CONDITIONAL: with no Cloud credential in either tier the
	// block is byte-identical to what it always was.
	if cloudTokenSource != "" {
		cloudBlock["token_source"] = cloudTokenSource
	}

	payload := map[string]any{
		"name":          name,
		"server":        ctx.Server,
		"kind":          kind,
		"source":        source,
		"active":        active,
		"workspace":     ctx.Workspace,
		"project":       ctx.Project,
		"dataset":       ctx.Dataset,
		"token_present": tokenPresent,
		"token_source":  tokenSource,
		"warnings":      warnings,
		"reachable":     reachable,
		"server_name":   serverName,
		"auth_tier":     tierVal,
		"prod":          prod,
		"server_time":   meta.ServerTime,
		"api_version_range": map[string]string{
			"min": meta.MinAPIVersion,
			"max": meta.MaxAPIVersion,
		},
		// Cloud session block — presence + probe verdict + url + team, no token
		// value. logged_in is a tri-state: null means the probe could not reach
		// the plane, which is a different fact from false.
		"cloud": cloudBlock,
	}
	// STRUCTURED PARITY with the human scope block. `workspace`/`project` alone
	// carry the same lie the print used to: they say what was SET, not what a
	// request will USE. The two keys below appear ONLY when a scope is stated,
	// so every floor-scope receipt (the onboarding spine included) keeps its
	// exact shape, and a consumer that reads workspace= has the fate beside it
	// the moment the value stops being ambient.
	if stated := manifest.StatedScope(ctx); len(stated) > 0 {
		payload["scope_stated"] = stated
		if loadedManifest != nil {
			t := manifest.ScopeFateTally(loadedManifest.Commands)
			payload["scope_fate_tally"] = map[string]int{
				"commands":                              len(loadedManifest.Commands),
				manifest.ScopeCarried.String():          t[manifest.ScopeCarried],
				manifest.ScopeMirrored.String():         t[manifest.ScopeMirrored],
				manifest.ScopeUnscopedByDesign.String(): t[manifest.ScopeUnscopedByDesign],
				manifest.ScopeRefused.String():          t[manifest.ScopeRefused],
			}
		}
	}
	// The warning goes to STDERR in every render — `-o json` included, where
	// stdout must stay a clean document. whoami still exits 0: it reports your
	// configuration, and a shadowed credential is a finding, not a failure.
	for _, w := range warnings {
		out.errf("%s", w)
	}

	switch out.output {
	case "json", "yaml":
		// D10: `bp whoami -o json` IS the onboarding receipt SPINE. Merge the
		// additive tail — instance identity, the MCP tool catalog (version +
		// names), the read-only tool-call proof, and the client-reload
		// instruction — that `bp doctor --onboarding` composes over, so the two
		// never fork into a second receipt shape. It reuses the manifest already
		// fetched above (no second probe) and is best-effort: the tool-call proof
		// only leaves the process when the target is reachable, and nothing here
		// can fail whoami (it still exits 0). Confined to the structured output
		// so the human report — and its cost — stay exactly as before.
		cfgSpine, _ := LoadConfig()
		for k, v := range onboardingWhoamiSpine(g, ctx, cfgSpine, loadedManifest) {
			payload[k] = v
		}
		if out.output == "json" {
			out.renderJSON(payload)
			return exitOK
		}
		// Round-trip through JSON to a generic value for the YAML emitter.
		b, _ := json.Marshal(payload)
		var v any
		_ = json.Unmarshal(b, &v)
		out.renderYAML(v)
		return exitOK
	}

	// Human output — the target line always renders. When the resolved server
	// matches a known entry, lead with its NAME so "target: prod — https://…" reads
	// at a glance; an unknown server (raw -s URL) shows the URL alone as before.
	prodMark := ""
	if prod {
		prodMark = "  ⚠ PROD"
	}
	if name != "" {
		out.outf("target:    %s — %s [%s] (%s)%s", name, ctx.Server, kind, whoamiSourceLabel(source, active), prodMark)
	} else {
		out.outf("target:    %s [%s] (%s)%s", ctx.Server, kind, whoamiSourceLabel(source, active), prodMark)
	}
	// The scope block is no longer an unconditional echo of ctx — see
	// whoamiScopeLines. Floor scope prints exactly one byte-identical line;
	// a stated scope is marked and carries its per-command fate tally.
	for _, l := range whoamiScopeLines(ctx, loadedManifest) {
		out.outf("%s", l)
	}
	if tokenPresent {
		out.outf("token:     set (%s)", prov.describe())
	} else {
		out.outf("token:     none — anonymous")
	}

	// Cloud control-plane session line — the probe's verdict, never the token.
	// Four arms, and none of them reads token-presence as a session.
	teamSuffix := ""
	if cloudTeam != "" {
		teamSuffix = fmt.Sprintf(" (team %s)", cloudTeam)
	}
	// The source rides on the three token-present arms only; the logged-out arm
	// has no credential to attribute and keeps its exact former bytes.
	sourceSuffix := ""
	if cloudTokenSource != "" {
		sourceSuffix = fmt.Sprintf(" [source %s]", cloudTokenSource)
	}
	switch cloudSession {
	case "verified":
		out.outf("cloud:     logged in to %s%s — session verified%s", cloudURL, teamSuffix, sourceSuffix)
	case "rejected":
		out.outf("cloud:     token PRESENT but REJECTED by %s — the saved session is dead; run 'bp login'%s", cloudURL, sourceSuffix)
	case "unverified":
		out.outf("cloud:     token present for %s — UNVERIFIED (control plane unreachable); presence is not a session%s", cloudURL, sourceSuffix)
	default:
		out.outf("cloud:     not logged in — run 'bp login' (or set BARKPARK_CLOUD_TOKEN for a CI job)")
	}

	if reachable {
		out.outf("server:    %s (%s)", serverName, ctx.Server)
		out.outf("auth_tier: %s", authTier)
		if meta.ServerTime != "" {
			out.outf("server_time: %s", meta.ServerTime)
		}
		if meta.MinAPIVersion != "" {
			out.outf("api_version: %s..%s", meta.MinAPIVersion, meta.MaxAPIVersion)
		}
	} else {
		out.outf("server:    (unreachable — check it's running or run 'bp setup --target connect')")
	}
	return exitOK
}

// whoamiSourceLabel renders the parenthetical source annotation for the human
// target line, e.g. "saved · active", "default — no saved config; run 'bp setup
// --target connect'", "env", "flag".
func whoamiSourceLabel(source string, active bool) string {
	switch source {
	case "saved":
		if active {
			return "saved · active"
		}
		return "saved"
	case "default":
		return "default — no saved config; run 'bp setup --target connect'"
	default:
		return source // "env" or "flag"
	}
}

// completionNouns is the static set of top-level commands shell completion
// offers: the built-in verbs plus the core manifest nouns. Plugin-custom nouns
// aren't enumerated here — `bp capabilities` lists the live tree.
//
// INVARIANT: every verb dispatched in cli.go's `switch noun` must appear here so
// `bp <TAB>` offers it. TestCompletionNounsCoverAllDispatchedBuiltins parses that
// switch and fails on drift — do not hand-trim this without updating the switch.
var completionNouns = []string{
	"agent", "attach", "barkparks", "capabilities", "chat", "cloud", "cmux", "completion", "context", "deploy",
	"dev", "doc", "doctor", "export", "go-live", "help", "instance", "launch", "listen", "login",
	"logout", "make", "mcp", "media", "migrate", "onramp", "paper", "plugin", "provider", "register",
	"scaffy", "schema", "search", "seed", "server", "servers", "setup", "sheet", "signup",
	"sites", "style", "subscribe", "task", "tasks", "team", "teams", "tinker", "token", "uninstall", "upgrade",
	"use", "vercel", "version", "webhook", "whoami", "workspace",
}

// completionGlobals are the global flags valid before any noun.
var completionGlobals = []string{
	"-s", "--server", "--token", "-w", "--workspace", "-p", "--project",
	"-d", "--dataset", "-o", "--output", "--limit", "--offset", "--manifest",
	"--json", "-q", "--quiet", "-v", "--verbose", "--no-color", "--dry-run",
	"--yes", "--all", "--full", "-h", "--help", "--version", "-V",
}

// runCompletion emits a shell completion script for `bp` (`bash`, `zsh`, or
// `fish`). Usage: `eval "$(bp completion bash)"`, `bp completion zsh` saved on
// $fpath, or `bp completion fish | source`. The noun set AND the per-noun verbs
// are baked at generation time, so re-run after upgrading or after a plugin adds
// commands.
func runCompletion(out *writer, g globals, ctx manifest.Context, args []string) int {
	if g.help {
		out.outf("usage: bp completion <bash|zsh|fish>")
		out.outf("  print a shell completion script — eval \"$(bp completion bash)\", or save it on your fpath")
		return exitOK
	}
	shell := "bash"
	if len(args) > 0 {
		shell = args[0]
	}
	verbMap := completionVerbMap(ctx)
	flagMap := completionFlagMap(ctx)
	nouns := completionNounList(verbMap)
	globals := strings.Join(completionGlobals, " ")
	switch shell {
	case "bash":
		out.outf("%s", bashCompletionScript(nouns, globals, verbMap, flagMap))
	case "zsh":
		out.outf("%s", zshCompletionScript(nouns, globals, verbMap, flagMap))
	case "fish":
		out.outf("%s", fishCompletionScript(nouns, globals, verbMap, flagMap))
	default:
		out.userErr("unsupported shell %q (want bash, zsh, or fish)", shell)
		return exitUsage
	}
	return exitOK
}

// completionNounList returns the space-joined noun set for completion: the baked
// CLI-native built-ins (completionNouns) UNIONed with the manifest nouns present
// in the on-disk cache (verbMap's keys). The union keeps completion consistent
// with the CLI's manifest-is-source-of-truth rule — a plugin-added or
// server-specific noun (auth, graph, onixedit, secret, share, …) completes at
// position 1 without editing the baked list, exactly as its verbs already do.
// With no cache the result is the baked floor, so a fresh install is unchanged.
// Sorted, so the generated script stays byte-stable.
func completionNounList(verbMap map[string][]string) string {
	set := make(map[string]bool, len(completionNouns)+len(verbMap))
	for _, n := range completionNouns {
		set[n] = true
	}
	for n := range verbMap {
		set[n] = true
	}
	nouns := make([]string, 0, len(set))
	for n := range set {
		nouns = append(nouns, n)
	}
	sort.Strings(nouns)
	return strings.Join(nouns, " ")
}

// completionVerbMap reads the ON-DISK manifest cache (never the network) and
// returns noun -> sorted verbs for the resolved server, so `bp task <TAB>` can
// offer ready/next/close. It is empty when no cache exists yet (fresh install /
// never contacted a server), and completion then degrades to noun-only —
// exactly the pre-verb behaviour. Staying network-free is deliberate:
// `bp completion <shell>` is often run at shell startup and must stay instant
// and offline-safe.
func completionVerbMap(ctx manifest.Context) map[string][]string {
	cache := manifest.NewCache("")
	m, _, ok := cache.Load(manifest.CacheKey(ctx.Server, ctx.Token))
	if !ok || m == nil {
		return nil
	}
	vm := make(map[string][]string)
	for _, n := range m.Tree().Nouns {
		if len(n.Verbs) == 0 {
			continue
		}
		verbs := make([]string, 0, len(n.Verbs))
		for _, c := range n.Verbs {
			verbs = append(verbs, c.Verb)
		}
		sort.Strings(verbs)
		vm[n.Name] = verbs
	}
	return vm
}

// sortedVerbNouns returns verbMap's nouns in a stable order so generated scripts
// are deterministic (byte-identical across runs for the same cache).
func sortedVerbNouns(verbMap map[string][]string) []string {
	nouns := make([]string, 0, len(verbMap))
	for n := range verbMap {
		nouns = append(nouns, n)
	}
	sort.Strings(nouns)
	return nouns
}

// completionFlagMap reads the ON-DISK manifest cache (never the network) and
// returns "<noun> <verb>" -> sorted, "--"-prefixed flag names, so
// `bp <noun> <verb> --<TAB>` offers that command's OWN flags, not just the
// globals. Empty when no cache exists — completion then offers globals only,
// the prior behaviour. Network-free for the same reason as completionVerbMap:
// the script is often generated at shell startup and must stay instant.
func completionFlagMap(ctx manifest.Context) map[string][]string {
	cache := manifest.NewCache("")
	m, _, ok := cache.Load(manifest.CacheKey(ctx.Server, ctx.Token))
	if !ok || m == nil {
		return nil
	}
	fm := make(map[string][]string)
	for _, n := range m.Tree().Nouns {
		for _, c := range n.Verbs {
			if len(c.Flags) == 0 {
				continue
			}
			flags := make([]string, 0, len(c.Flags))
			for _, f := range c.Flags {
				flags = append(flags, "--"+f.Name)
			}
			sort.Strings(flags)
			fm[n.Name+" "+c.Verb] = flags
		}
	}
	return fm
}

// sortedFlagKeys returns flagMap's "<noun> <verb>" keys in a stable order so the
// generated scripts stay byte-stable for the same cache.
func sortedFlagKeys(flagMap map[string][]string) []string {
	keys := make([]string, 0, len(flagMap))
	for k := range flagMap {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}

// Flag names are the ONE completion-token class the server can poison: they come
// from the manifest cache (control-plane JSON) and manifest.Parse's safeName only
// validates noun.Name / command.Noun / command.Verb — never Flag.Name. Without
// escaping, a flag name like `--$(touch pwned)` reaches the emitted shell script
// and executes on TAB. Go's `%q` verb is NOT sufficient: it quotes for a Go
// double-quoted string literal and leaves `$`, backtick and `$(...)` LIVE in a
// POSIX shell, so a %q-formatted token still command-substitutes. Only real shell
// single-quoting neutralizes those metacharacters, so we single-quote flag tokens
// at emit in every emitter below.

// (shSingleQuote — the POSIX single-quote wrapper, with the classic `'\''` splice
// for an embedded quote — lives in cloud_deploy_cmd.go and is reused here: inside
// single quotes the shell performs no expansion, so `$`/backtick are inert. It
// serves bash and zsh, whose single-quote semantics are identical here.)

// shSingleQuoteEach single-quotes each token and space-joins them, for a context
// (e.g. a zsh `arr=(...)` literal) that parses the quotes at assignment time and
// performs quote removal — so the elements stay separate and land unquoted.
func shSingleQuoteEach(toks []string) string {
	q := make([]string, len(toks))
	for i, t := range toks {
		q[i] = shSingleQuote(t)
	}
	return strings.Join(q, " ")
}

// fishSingleQuoteEscape escapes toks for interpolation INSIDE a fish single-quoted
// string. fish single quotes treat only `\` and `'` specially (`$` and `(...)` are
// literal there), so those two are the whole escape set. Tokens are space-joined
// as one `-a` candidate list.
func fishSingleQuoteEscape(toks []string) string {
	q := make([]string, len(toks))
	for i, t := range toks {
		e := strings.ReplaceAll(t, `\`, `\\`)
		e = strings.ReplaceAll(e, `'`, `\'`)
		q[i] = e
	}
	return strings.Join(q, " ")
}

func bashCompletionScript(nouns, globals string, verbMap, flagMap map[string][]string) string {
	// bash 3.2 (macOS default) has no associative arrays, so per-noun verbs go
	// through a `case` on the noun word. An empty verbMap yields an empty case,
	// which matches nothing — position-2 then falls back to globals as before.
	var cases strings.Builder
	for _, noun := range sortedVerbNouns(verbMap) {
		fmt.Fprintf(&cases, "      %s) __bpverbs=%q;;\n", noun, strings.Join(verbMap[noun], " "))
	}
	// Position 3+ offers the command's own flags, keyed on the "noun verb" pair.
	// The flag list is single-quoted as ONE value (not %q): the untrusted flag
	// tokens must never be command-substituted when the case body assigns
	// __bpflags. We deliberately store the raw space-joined names (no per-token
	// quotes) because a shell variable's value is word-split but NOT quote-removed
	// on re-expansion — interior quotes would survive as literal characters.
	var flagCases strings.Builder
	for _, key := range sortedFlagKeys(flagMap) {
		fmt.Fprintf(&flagCases, "      %q) __bpflags=%s;;\n", key, shSingleQuote(strings.Join(flagMap[key], " ")))
	}
	return `# bash completion for bp — eval "$(bp completion bash)" or source a saved copy.
_bp_complete() {
  local cur="${COMP_WORDS[COMP_CWORD]}"
  local nouns="` + nouns + `"
  local globals="` + globals + `"
  if [[ $COMP_CWORD -eq 1 ]]; then
    # A bare TAB offers nouns; a leading dash offers the global flags.
    if [[ "$cur" == -* ]]; then
      COMPREPLY=( $(compgen -W "$globals" -- "$cur") )
    else
      COMPREPLY=( $(compgen -W "$nouns" -- "$cur") )
    fi
  elif [[ $COMP_CWORD -eq 2 ]]; then
    local __bpverbs=""
    case "${COMP_WORDS[1]}" in
` + cases.String() + `      *) ;;
    esac
    COMPREPLY=( $(compgen -W "$__bpverbs $globals" -- "$cur") )
  else
    local __bpflags=""
    case "${COMP_WORDS[1]} ${COMP_WORDS[2]}" in
` + flagCases.String() + `      *) ;;
    esac
    # SECURITY: flag names are untrusted (manifest cache). compgen -W RE-EXPANDS
    # its wordlist — command substitution included — so a poisoned flag reaching
    # ` + "`compgen -W \"$__bpflags\"`" + ` would execute on TAB even though the
    # assignment above is single-quoted. Match manually instead: expanding a
    # variable word-splits but does not re-scan for $(...), so nothing runs.
    local __bpword
    COMPREPLY=()
    for __bpword in $__bpflags $globals; do
      case "$__bpword" in "$cur"*) COMPREPLY+=("$__bpword");; esac
    done
  fi
}
complete -F _bp_complete bp
`
}

func zshCompletionScript(nouns, globals string, verbMap, flagMap map[string][]string) string {
	var cases strings.Builder
	for _, noun := range sortedVerbNouns(verbMap) {
		fmt.Fprintf(&cases, "      %s) verbs=(%s);;\n", noun, strings.Join(verbMap[noun], " "))
	}
	// Untrusted flag tokens go into a zsh `flags=(...)` array literal, which
	// command-substitutes `$(...)` at assignment. Single-quote EACH element (not
	// %q, which leaves $/backtick live): zsh performs quote removal when it parses
	// the literal, so the elements land unquoted and inert.
	var flagCases strings.Builder
	for _, key := range sortedFlagKeys(flagMap) {
		fmt.Fprintf(&flagCases, "      %q) flags=(%s);;\n", key, shSingleQuoteEach(flagMap[key]))
	}
	return `#compdef bp
# zsh completion for bp — eval "$(bp completion zsh)" or save to a file on $fpath.
_bp_complete() {
  local -a nouns globals verbs flags
  nouns=(` + nouns + `)
  globals=(` + globals + `)
  if (( CURRENT == 2 )); then
    # A bare TAB offers nouns; a leading dash offers the global flags.
    if [[ "${words[CURRENT]}" == -* ]]; then
      compadd -- $globals
    else
      compadd -- $nouns
    fi
  elif (( CURRENT == 3 )); then
    case "${words[2]}" in
` + cases.String() + `      *) ;;
    esac
    compadd -- $verbs $globals
  else
    case "${words[2]} ${words[3]}" in
` + flagCases.String() + `      *) ;;
    esac
    compadd -- $flags $globals
  fi
}
compdef _bp_complete bp
`
}

func fishCompletionScript(nouns, globals string, verbMap, flagMap map[string][]string) string {
	// `__fish_use_subcommand` is true only while no noun has been typed yet, so
	// nouns complete at the top level and globals complete afterwards — parity
	// with the bash/zsh position logic. `-f` disables the default file
	// completion so a bare `bp <TAB>` offers commands, not the cwd's files.
	// Per-noun verbs use `__fish_seen_subcommand_from <noun>`.
	var verbLines strings.Builder
	for _, noun := range sortedVerbNouns(verbMap) {
		fmt.Fprintf(&verbLines, "complete -c bp -n '__fish_seen_subcommand_from %s' -a '%s'\n",
			noun, strings.Join(verbMap[noun], " "))
	}
	// Per-command flags require BOTH the noun and its verb to have been seen, so a
	// flag only completes under its own command (`bp doc create --<TAB>`).
	var flagLines strings.Builder
	for _, key := range sortedFlagKeys(flagMap) {
		parts := strings.SplitN(key, " ", 2)
		if len(parts) != 2 {
			continue
		}
		// Untrusted flag tokens sit inside a single-quoted fish `-a '...'` list.
		// fish single quotes make `$`/`(...)` literal, so only `\` and `'` need
		// escaping — but they DO need it, or a `'`-bearing name breaks out of the
		// quote. (Go %q would leave $/backtick live in other shells; escape here.)
		fmt.Fprintf(&flagLines,
			"complete -c bp -n '__fish_seen_subcommand_from %s; and __fish_seen_subcommand_from %s' -a '%s'\n",
			parts[0], parts[1], fishSingleQuoteEscape(flagMap[key]))
	}
	return `# fish completion for bp — ` + "`bp completion fish | source`" + `, or save to
# ~/.config/fish/completions/bp.fish (then it loads automatically).
complete -c bp -f
complete -c bp -n '__fish_use_subcommand' -a '` + nouns + `'
complete -c bp -n 'not __fish_use_subcommand' -a '` + globals + `'
` + verbLines.String() + flagLines.String()
}

// whoamiScopeLines renders whoami's scope block.
//
// THE DEFECT IT CLOSES. The line used to be one unconditional echo of the
// context — `scope:     w=%s p=%s d=%s` — which reported what the operator SET
// and never what a request would USE. After the scope-honesty contract
// (internal/manifest/scope.go, PR #16010) those are different facts: a stated
// -w reaches the wire on the commands whose path carries it, re-routes the URL
// through the advertised mirror on the commands with a scoped_prefix, and is
// REFUSED before any I/O on the rest. Printing `w=beta` and stopping told an
// operator their session was pointed at beta when most verbs would have
// answered about the floor.
//
// Two arms, and the split is the same one StatedScope draws:
//
//	floor scope (nothing stated) — the ambient case, which is CORRECT today.
//	  The single line is byte-identical to what it has always been. This is
//	  load-bearing: every operator without a -w sees no change at all.
//	stated scope — each stated value is marked "(stated)" so it cannot be read
//	  as ambient, and a second line gives the per-fate tally DERIVED from the
//	  live manifest. Never hard-coded: the numbers move the moment the server
//	  advertises one more scoped_prefix, and a stale count in an honesty line
//	  is worse than no line.
//
// An unreachable manifest is a MISSING MEASUREMENT, not a fate. It says so
// rather than guessing a tally in either direction.
func whoamiScopeLines(ctx manifest.Context, m *manifest.Manifest) []string {
	stated := manifest.StatedScope(ctx)
	if len(stated) == 0 {
		return []string{fmt.Sprintf("scope:     w=%s p=%s d=%s", ctx.Workspace, ctx.Project, ctx.Dataset)}
	}

	w, p := ctx.Workspace, ctx.Project
	var named []string
	for _, f := range stated {
		switch f {
		case "-w":
			w += " (stated)"
			named = append(named, fmt.Sprintf("-w %s", ctx.Workspace))
		case "-p":
			p += " (stated)"
			named = append(named, fmt.Sprintf("-p %s", ctx.Project))
		}
	}
	lines := []string{fmt.Sprintf("scope:     w=%s p=%s d=%s", w, p, ctx.Dataset)}

	subject := strings.Join(named, " / ")
	if m == nil {
		lines = append(lines, fmt.Sprintf(
			"           %s is NOT ambient — which commands can carry it is UNKNOWN "+
				"here (the server manifest was unreachable), so this line cannot "+
				"promise any request will use it.", subject))
		return lines
	}

	t := manifest.ScopeFateTally(m.Commands)
	lines = append(lines, fmt.Sprintf(
		"           %s is NOT ambient — of %d commands: %d carry it in their own path, "+
			"%d route to the workspace mirror, %d ignore it by design, %d are REFUSED "+
			"before any request is sent (`bp capabilities` marks them).",
		subject, len(m.Commands),
		t[manifest.ScopeCarried], t[manifest.ScopeMirrored],
		t[manifest.ScopeUnscopedByDesign], t[manifest.ScopeRefused]))
	return lines
}

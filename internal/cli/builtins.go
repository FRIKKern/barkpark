package cli

import (
	"encoding/json"
	"fmt"
	"os"
	"sort"
	"strings"

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

// runCapabilities prints the resolved manifest. With -o json it prints the
// manifest JSON; otherwise a human summary (server identity, caller tier, and
// the noun/verb tree). This is a CLI built-in, NOT a manifest command.
func runCapabilities(out *writer, g globals, ctx manifest.Context) int {
	m, err := loadManifest(g, ctx)
	if err != nil {
		out.errf("barkpark: %v", err)
		return exitGeneric
	}

	switch out.output {
	case "json":
		out.renderJSON(m)
	case "yaml":
		// Round-trip through JSON to a generic value for the YAML emitter.
		b, _ := json.Marshal(m)
		var v any
		_ = json.Unmarshal(b, &v)
		out.renderYAML(v)
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
	}
	return exitOK
}

// metaResponse is the subset of GET /v1/meta the CLI surfaces in whoami.
type metaResponse struct {
	ServerTime    string            `json:"serverTime"`
	MinAPIVersion string            `json:"minApiVersion"`
	MaxAPIVersion string            `json:"maxApiVersion"`
	SchemaHashes  map[string]string `json:"currentDatasetSchemaHash"`
}

// whoamiSource classifies where ctx.Server was chosen from, for whoami's
// "saved/default/env/flag" annotation. It mirrors resolveContext's precedence
// (flags > env > saved config > baked default) WITHOUT touching that function —
// it re-derives the winning layer by comparing the resolved server against each
// candidate. active reports whether the resolved server is the saved config's
// active server (only meaningful for "saved").
func whoamiSource(g globals, ctx manifest.Context) (source string, active bool) {
	s, a, _ := whoamiSourceName(g, ctx)
	return s, a
}

// whoamiSourceName extends whoamiSource with the resolved server NAME: the
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
	// 2. Env var (BARKPARK_API_URL / BARKPARK_SERVER), if actually set.
	if os.Getenv("BARKPARK_API_URL") != "" || os.Getenv("BARKPARK_SERVER") != "" {
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
func runWhoami(out *writer, g globals, ctx manifest.Context) int {
	source, active, name := whoamiSourceName(g, ctx)
	tokenPresent := ctx.Token != ""

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
	if m, err := loadManifest(g, ctx); err == nil {
		reachable = true
		serverName = m.Server.Name
		authTier = m.AuthTier
		prod = isProd(ctx, m)
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
		"reachable":     reachable,
		"server_name":   serverName,
		"auth_tier":     tierVal,
		"prod":          prod,
		"server_time":   meta.ServerTime,
		"api_version_range": map[string]string{
			"min": meta.MinAPIVersion,
			"max": meta.MaxAPIVersion,
		},
	}
	switch out.output {
	case "json":
		out.renderJSON(payload)
		return exitOK
	case "yaml":
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
	out.outf("scope:     w=%s p=%s d=%s", ctx.Workspace, ctx.Project, ctx.Dataset)
	if tokenPresent {
		out.outf("token:     set")
	} else {
		out.outf("token:     none — anonymous")
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
	"agent", "attach", "barkparks", "capabilities", "cloud", "completion", "deploy",
	"doc", "doctor", "export", "go-live", "help", "instance", "launch", "listen", "login",
	"make", "media", "migrate", "paper", "plugin", "provider", "register",
	"schema", "search", "seed", "server", "servers", "setup", "sheet", "signup",
	"sites", "subscribe", "task", "tinker", "token", "uninstall", "upgrade",
	"use", "vercel", "version", "webhook", "whoami", "workspace",
}

// completionGlobals are the global flags valid before any noun.
var completionGlobals = []string{
	"-s", "--server", "--token", "-w", "--workspace", "-p", "--project",
	"-d", "--dataset", "-o", "--output", "--limit", "--offset", "--manifest",
	"--json", "-q", "--quiet", "-v", "--verbose", "--no-color", "--dry-run",
	"--yes", "--all", "-h", "--help", "--version", "-V",
}

// runCompletion emits a shell completion script for `bp` (`bash`, `zsh`, or
// `fish`). Usage: `eval "$(bp completion bash)"`, `bp completion zsh` saved on
// $fpath, or `bp completion fish | source`. The noun set AND the per-noun verbs
// are baked at generation time, so re-run after upgrading or after a plugin adds
// commands.
func runCompletion(out *writer, g globals, ctx manifest.Context, args []string) int {
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
		out.errf("barkpark: unsupported shell %q (want bash, zsh, or fish)", shell)
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

func bashCompletionScript(nouns, globals string, verbMap, flagMap map[string][]string) string {
	// bash 3.2 (macOS default) has no associative arrays, so per-noun verbs go
	// through a `case` on the noun word. An empty verbMap yields an empty case,
	// which matches nothing — position-2 then falls back to globals as before.
	var cases strings.Builder
	for _, noun := range sortedVerbNouns(verbMap) {
		fmt.Fprintf(&cases, "      %s) __bpverbs=%q;;\n", noun, strings.Join(verbMap[noun], " "))
	}
	// Position 3+ offers the command's own flags, keyed on the "noun verb" pair.
	var flagCases strings.Builder
	for _, key := range sortedFlagKeys(flagMap) {
		fmt.Fprintf(&flagCases, "      %q) __bpflags=%q;;\n", key, strings.Join(flagMap[key], " "))
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
    COMPREPLY=( $(compgen -W "$__bpflags $globals" -- "$cur") )
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
	var flagCases strings.Builder
	for _, key := range sortedFlagKeys(flagMap) {
		fmt.Fprintf(&flagCases, "      %q) flags=(%s);;\n", key, strings.Join(flagMap[key], " "))
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
		fmt.Fprintf(&flagLines,
			"complete -c bp -n '__fish_seen_subcommand_from %s; and __fish_seen_subcommand_from %s' -a '%s'\n",
			parts[0], parts[1], strings.Join(flagMap[key], " "))
	}
	return `# fish completion for bp — ` + "`bp completion fish | source`" + `, or save to
# ~/.config/fish/completions/bp.fish (then it loads automatically).
complete -c bp -f
complete -c bp -n '__fish_use_subcommand' -a '` + nouns + `'
complete -c bp -n 'not __fish_use_subcommand' -a '` + globals + `'
` + verbLines.String() + flagLines.String()
}

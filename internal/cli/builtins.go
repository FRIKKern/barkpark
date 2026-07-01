package cli

import (
	"encoding/json"
	"os"
	"strings"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// runVersion prints the CLI version. -o json emits a small object.
func runVersion(out *writer, g globals) int {
	if out.output == "json" {
		v := map[string]string{"cli_version": cliVersion}
		if cliCommit != "" {
			v["commit"] = cliCommit
		}
		if cliDate != "" {
			v["build_date"] = cliDate
		}
		out.renderJSON(v)
		return exitOK
	}
	out.outf("barkpark %s", cliVersion)
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

	if out.output == "json" {
		var tierVal any // null when unreachable
		if reachable {
			tierVal = authTier
		}
		out.renderJSON(map[string]any{
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
		})
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
	"agent", "attach", "barkparks", "capabilities", "completion", "deploy",
	"doc", "doctor", "go-live", "help", "instance", "launch", "listen", "login",
	"make", "media", "migrate", "paper", "plugin", "provider", "register",
	"schema", "search", "seed", "server", "servers", "setup", "sheet", "signup",
	"sites", "subscribe", "task", "tinker", "token", "uninstall", "upgrade",
	"use", "vercel", "version", "webhook", "whoami", "workspace",
}

// completionGlobals are the global flags valid before any noun.
var completionGlobals = []string{
	"-s", "--server", "-w", "--workspace", "-p", "--project", "-d", "--dataset",
	"-o", "--output", "-q", "--quiet", "-v", "--verbose", "--token", "--dry-run",
	"--yes", "--all", "--file", "--limit", "--offset", "--no-color", "--manifest",
}

// runCompletion emits a shell completion script for `bp` (`bash` or `zsh`).
// Usage: `eval "$(bp completion bash)"` or save the output and source it. The
// noun set is baked at generation time, so re-run after upgrading.
func runCompletion(out *writer, args []string) int {
	shell := "bash"
	if len(args) > 0 {
		shell = args[0]
	}
	nouns := strings.Join(completionNouns, " ")
	globals := strings.Join(completionGlobals, " ")
	switch shell {
	case "bash":
		out.outf("%s", bashCompletionScript(nouns, globals))
	case "zsh":
		out.outf("%s", zshCompletionScript(nouns, globals))
	default:
		out.errf("barkpark: unsupported shell %q (want bash or zsh)", shell)
		return exitUsage
	}
	return exitOK
}

func bashCompletionScript(nouns, globals string) string {
	return `# bash completion for bp — eval "$(bp completion bash)" or source a saved copy.
_bp_complete() {
  local cur="${COMP_WORDS[COMP_CWORD]}"
  local nouns="` + nouns + `"
  local globals="` + globals + `"
  if [[ "$cur" == -* ]]; then
    COMPREPLY=( $(compgen -W "$globals" -- "$cur") )
  elif [[ $COMP_CWORD -eq 1 ]]; then
    COMPREPLY=( $(compgen -W "$nouns" -- "$cur") )
  else
    COMPREPLY=( $(compgen -W "$globals" -- "$cur") )
  fi
}
complete -F _bp_complete bp
`
}

func zshCompletionScript(nouns, globals string) string {
	return `#compdef bp
# zsh completion for bp — eval "$(bp completion zsh)" or save to a file on $fpath.
_bp_complete() {
  local -a nouns globals
  nouns=(` + nouns + `)
  globals=(` + globals + `)
  if [[ "${words[CURRENT]}" == -* ]]; then
    compadd -- $globals
  elif (( CURRENT == 2 )); then
    compadd -- $nouns
  else
    compadd -- $globals
  fi
}
compdef _bp_complete bp
`
}

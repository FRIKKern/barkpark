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

// runLogin is a v1 stub: token-based auth is configured via BARKPARK_API_TOKEN /
// -s + the dev token, so there is no interactive login yet. It explains the
// current mechanism and exits 0.
func runLogin(out *writer, ctx manifest.Context) int {
	out.outf("login: barkpark uses a bearer token via BARKPARK_API_TOKEN (or the")
	out.outf("       built-in dev token). Interactive login is not implemented in v1.")
	out.outf("       current token resolves for server %s", ctx.Server)
	return exitOK
}

// runCompletion is a v1 stub. Shell completion generation is deferred.
func runCompletion(out *writer) int {
	out.outf("completion: not implemented in v1 (the command tree is manifest-driven;")
	out.outf("            dynamic completion is a forward seam).")
	return exitOK
}

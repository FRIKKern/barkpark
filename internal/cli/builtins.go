package cli

import (
	"encoding/json"
	"strings"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// runVersion prints the CLI version. -o json emits a small object.
func runVersion(out *writer, g globals) int {
	if out.output == "json" {
		out.renderJSON(map[string]string{"cli_version": cliVersion})
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

// runWhoami composes identity from GET /v1/meta + the manifest's caller
// auth_tier echo (M0 decision A3 — no dedicated endpoint). It shows the active
// target, ⚠ PROD when prod, and the resolved caller tier.
func runWhoami(out *writer, g globals, ctx manifest.Context) int {
	m, err := loadManifest(g, ctx)
	if err != nil {
		out.errf("barkpark: %v", err)
		return exitGeneric
	}

	// Best-effort /v1/meta fetch; whoami still renders if it fails.
	metaURL := strings.TrimRight(ctx.Server, "/") + "/v1/meta"
	var meta metaResponse
	if status, body, derr := doRequest("GET", metaURL, map[string]string{}, nil); derr == nil && status >= 200 && status < 300 {
		_ = json.Unmarshal(body, &meta)
	}

	prod := isProd(ctx, m)

	if out.output == "json" {
		out.renderJSON(map[string]any{
			"server":      ctx.Server,
			"server_name": m.Server.Name,
			"workspace":   ctx.Workspace,
			"project":     ctx.Project,
			"dataset":     ctx.Dataset,
			"auth_tier":   m.AuthTier,
			"prod":        prod,
			"server_time": meta.ServerTime,
			"api_version_range": map[string]string{
				"min": meta.MinAPIVersion,
				"max": meta.MaxAPIVersion,
			},
		})
		return exitOK
	}

	prodMark := ""
	if prod {
		prodMark = "  ⚠ PROD"
	}
	out.outf("server:    %s (%s)%s", ctx.Server, m.Server.Name, prodMark)
	out.outf("scope:     w=%s p=%s d=%s", ctx.Workspace, ctx.Project, ctx.Dataset)
	out.outf("auth_tier: %s", m.AuthTier)
	if meta.ServerTime != "" {
		out.outf("server_time: %s", meta.ServerTime)
	}
	if meta.MinAPIVersion != "" {
		out.outf("api_version: %s..%s", meta.MinAPIVersion, meta.MaxAPIVersion)
	}
	return exitOK
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

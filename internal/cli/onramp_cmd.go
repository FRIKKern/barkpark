package cli

// onramp_cmd.go — `bp onramp <target>`: emit the exact MCP-registration config
// block(s) for ONE AI-agent surface, where they belong, and how to verify.
// PRINT-FIRST and print-only in v1 (exactly the cmux_install.go precedent): it
// SHOWS the blocks and never writes a file. `--write` (safe JSON merge for the
// JSON targets, marker-append for Codex TOML) is the reserved wave-2/3 slice and
// is deliberately NOT defined here — a stray `--write` is a usage error, not a
// silently-ignored flag.
//
// Targets: cursor | claude-code | codex | cursor-cloud | windsurf | gemini-cli.
// windsurf and gemini-cli both reuse mcpJSONStanza verbatim (charter decision 7)
// — zero new mechanism — differing only in destination path and env dialect, and
// both print codex-style MERGE-the-mcpServers-key guidance (their files are
// user-global / whole-CLI-config, never a Barkpark-only file to clobber).
// chatgpt / claude-ai are
// REMOTE-agent onramps (Custom GPT Actions on /v1/openapi.json; remote MCP over
// OAuth) — they have no local config block to print and are rejected with a
// pointer to docs/setup/REMOTE.md.
//
// Env dialects are per-tool and never mixed (charter decision 9): Cursor reads
// ${env:VAR}, Claude Code reads ${VAR}, and Codex FORWARDS a shell whitelist via
// env_vars = [...] — it never expands ${VAR} inside a TOML value (decision 7), so
// the secret token never lands in config.toml. Every emitted stanza is
// byte-compatible with the per-target docs (decision 14: the doc block IS what
// the verb prints), so `bp onramp <target> --write` can later replace those doc
// steps verbatim.

import (
	"fmt"
	"strings"
)

// onrampDefaultServer is the URL baked into a stanza when neither --server nor an
// active saved server resolves one — the public content API most onramps target.
const onrampDefaultServer = "https://guerrilla.barkpark.cloud"

// onrampInstallLine is the one-command bp installer Cursor Cloud's
// environment.json runs before the agent boots (matches README/CURSOR.md).
const onrampInstallLine = "curl -fsSL https://raw.githubusercontent.com/FRIKKern/barkpark/main/scripts/install-cli.sh | sh"

// Per-tool token env-dialect references. The DEFAULT stanza carries the dialect
// placeholder (secret stays in the shell); --token bakes a literal in its place.
const (
	cursorTokenRef     = "${env:BARKPARK_API_TOKEN}" // Cursor dialect
	claudeCodeTokenRef = "${BARKPARK_API_TOKEN}"     // Claude Code dialect
	// geminiTokenRef is Gemini CLI's dialect. Gemini CLI expands $VAR and ${VAR}
	// environment references inside settings.json values, so the braced form reads
	// the token from the shell and keeps the secret out of the committed file —
	// cited: github.com/google-gemini/gemini-cli docs/tools/mcp-server.md
	// ("environment variables ... using $VAR or ${VAR} syntax"). Its VALUE coincides
	// with claudeCodeTokenRef, but it stays its OWN named constant — dialects are
	// per-tool and never shared across tools even when they happen to match
	// (charter decision 9).
	geminiTokenRef = "${BARKPARK_API_TOKEN}" // Gemini CLI dialect
)

// onrampFile is one config file a target needs: where it belongs + its content.
type onrampFile struct {
	Path    string `json:"path"`
	Content string `json:"content"`
}

// onrampSpec is the `-o json` emission: the resolved target, the file(s) to
// create, and the one-line verify step. It is the single source both the human
// print and the JSON envelope render from.
type onrampSpec struct {
	Target string       `json:"target"`
	Files  []onrampFile `json:"files"`
	Verify string       `json:"verify"`
}

// onrampLocalTargets is the ordered set of targets the verb prints config for.
func onrampLocalTargets() []string {
	return []string{"cursor", "claude-code", "codex", "cursor-cloud", "windsurf", "gemini-cli"}
}

// onrampServer resolves the URL to bake into the env block: --server wins, else
// the active saved server (setup_cmd.go activeSavedServer), else the public
// fallback. Trailing slashes are trimmed so the stanza carries a clean base URL.
func onrampServer(g globals) string {
	if s := strings.TrimSpace(g.server); s != "" {
		return strings.TrimRight(s, "/")
	}
	if e, ok := activeSavedServer(); ok && strings.TrimSpace(e.Server) != "" {
		return strings.TrimRight(strings.TrimSpace(e.Server), "/")
	}
	return onrampDefaultServer
}

// onrampTokenValue returns the literal --token when the user baked one in, else
// the tool's dialect placeholder — the safe default that keeps the secret in the
// shell environment and out of a committed file.
func onrampTokenValue(dialectRef, override string) string {
	if override != "" {
		return override
	}
	return dialectRef
}

// mcpJSONStanza renders the `.cursor/mcp.json` / `.mcp.json` server block. The
// two JSON targets share one shape; only the token env-dialect differs, so the
// resolved token value is passed in. Key ORDER (command, args, env, then URL,
// TOKEN) is fixed by a raw template — a map marshal would sort keys alphabetically
// and drift from the docs (decision 14). %q gives JSON-safe quoting for the URL
// and the ${…} placeholder alike.
func mcpJSONStanza(server, tokenValue string) string {
	return fmt.Sprintf(`{
  "mcpServers": {
    "barkpark": {
      "command": "bp",
      "args": ["mcp", "serve"],
      "env": {
        "BARKPARK_API_URL": %q,
        "BARKPARK_API_TOKEN": %q
      }
    }
  }
}`, server, tokenValue)
}

// claudeCodeMcpJSONStanza renders the committed `.mcp.json` server block in
// Claude Code's shape — identical to the Cursor stanza plus the explicit
// `"type": "stdio"` discriminator docs/setup/CLAUDE-CODE.md publishes (decision
// 14: the doc block IS what the verb prints, and the two docs differ on exactly
// this key).
func claudeCodeMcpJSONStanza(server, tokenValue string) string {
	return fmt.Sprintf(`{
  "mcpServers": {
    "barkpark": {
      "type": "stdio",
      "command": "bp",
      "args": ["mcp", "serve"],
      "env": {
        "BARKPARK_API_URL": %q,
        "BARKPARK_API_TOKEN": %q
      }
    }
  }
}`, server, tokenValue)
}

// codexTOMLBlock renders the `~/.codex/config.toml` [mcp_servers.barkpark] block.
// The static env table carries ONLY the non-secret URL; the token rides
// env_vars = ["BARKPARK_API_TOKEN"] (shell-forward whitelist). There is no ${…}
// anywhere — Codex does not expand it inside a TOML value, so a placeholder would
// ship as a literal string (charter decision 7). The raised timeouts (defaults
// 10/60) match docs/setup/CODEX.md — a cold bp binary + first manifest fetch
// must not trip the launcher.
func codexTOMLBlock(server string) string {
	return fmt.Sprintf(`[mcp_servers.barkpark]
command = "bp"
args = ["mcp", "serve"]
env = { BARKPARK_API_URL = %q }
env_vars = ["BARKPARK_API_TOKEN"]
startup_timeout_sec = 15
tool_timeout_sec = 120`, server)
}

// cursorCloudEnvironmentJSON renders the `.cursor/environment.json` install step
// Cursor Cloud runs before the agent boots. Secrets go through Cursor's Secrets
// UI, never this committed file (charter decision 13).
func cursorCloudEnvironmentJSON() string {
	return fmt.Sprintf(`{
  "install": %q
}`, onrampInstallLine)
}

// buildOnrampSpec assembles the file set + verify step for a local target. ok is
// false for an unknown target (the caller renders the valid-set usage error).
func buildOnrampSpec(target, server, token string) (onrampSpec, bool) {
	switch target {
	case "cursor":
		return onrampSpec{
			Target: target,
			Files: []onrampFile{
				{Path: ".cursor/mcp.json", Content: mcpJSONStanza(server, onrampTokenValue(cursorTokenRef, token))},
			},
			Verify: "reload MCP servers in Cursor Settings — the barkpark task tools appear in the Agent's tool list",
		}, true
	case "claude-code":
		return onrampSpec{
			Target: target,
			Files: []onrampFile{
				{Path: ".mcp.json", Content: claudeCodeMcpJSONStanza(server, onrampTokenValue(claudeCodeTokenRef, token))},
			},
			Verify: "claude mcp list",
		}, true
	case "codex":
		return onrampSpec{
			Target: target,
			Files: []onrampFile{
				{Path: "~/.codex/config.toml", Content: codexTOMLBlock(server)},
			},
			Verify: "codex mcp list",
		}, true
	case "cursor-cloud":
		return onrampSpec{
			Target: target,
			Files: []onrampFile{
				{Path: ".cursor/environment.json", Content: cursorCloudEnvironmentJSON()},
				{Path: ".cursor/mcp.json", Content: mcpJSONStanza(server, onrampTokenValue(cursorTokenRef, token))},
			},
			Verify: "open the Cursor Cloud agent — the barkpark task tools appear in its tool list once the environment builds",
		}, true
	case "windsurf":
		// Windsurf (Cascade) reads the same `mcpServers` shape Cursor does and the
		// same ${env:VAR} dialect — verbatim mcpJSONStanza reuse (charter decision
		// 7). Its config is the USER-GLOBAL ~/.codeium/mcp_config.json, so the human
		// print carries a merge-the-key note, never a whole-file label.
		return onrampSpec{
			Target: target,
			Files: []onrampFile{
				{Path: "~/.codeium/mcp_config.json", Content: mcpJSONStanza(server, onrampTokenValue(cursorTokenRef, token))},
			},
			Verify: "click Refresh in Windsurf's MCP settings (or reload the window) — the barkpark task tools appear in Cascade's tool list",
		}, true
	case "gemini-cli":
		// Gemini CLI reads the same `mcpServers` shape and expands ${VAR} inside
		// settings.json values (geminiTokenRef) — verbatim mcpJSONStanza reuse. The
		// project-local .gemini/settings.json is the default target; ~/.gemini/
		// settings.json is the global alternative. Either file holds the WHOLE CLI
		// config, so the human print carries a merge-the-key note.
		return onrampSpec{
			Target: target,
			Files: []onrampFile{
				{Path: ".gemini/settings.json", Content: mcpJSONStanza(server, onrampTokenValue(geminiTokenRef, token))},
			},
			Verify: "gemini mcp list  (or /mcp inside the Gemini CLI) — barkpark appears with its tools",
		}, true
	}
	return onrampSpec{}, false
}

// runOnramp is the `bp onramp <target>` built-in. PRINT-ONLY in v1.
func runOnramp(out *writer, g globals, args []string) int {
	if g.help {
		printOnrampHelp(out)
		return exitOK
	}

	// Separate the single target from any trailing tokens. --server/--token are
	// GLOBAL flags already folded into g, so any `-flag` reaching here is unknown
	// — reject it (this is where a stray --write, reserved for a later wave, dies
	// with a clear message rather than being silently accepted-and-ignored).
	target := ""
	for _, a := range args {
		if strings.HasPrefix(a, "-") {
			return usageErrf(out, func() { printOnrampHelp(out) },
				"unknown flag %q (onramp is print-only in v1 — --write is a later wave)", a)
		}
		if target != "" {
			return usageErrf(out, func() { printOnrampHelp(out) },
				"onramp takes exactly one target (got %q and %q)", target, a)
		}
		target = a
	}
	if target == "" {
		return usageErrf(out, func() { printOnrampHelp(out) },
			"onramp needs a target: %s", strings.Join(onrampLocalTargets(), ", "))
	}

	// Remote surfaces have no local config block to print — Custom GPT Actions
	// (ChatGPT) and remote MCP (Claude.ai) are documented on their own.
	switch target {
	case "chatgpt", "claude-ai":
		return usageErrf(out, nil,
			"%q is a remote-agent onramp with no local config to print — see docs/setup/REMOTE.md", target)
	}

	server := onrampServer(g)
	token := strings.TrimSpace(g.token)

	spec, ok := buildOnrampSpec(target, server, token)
	if !ok {
		return usageErrf(out, func() { printOnrampHelp(out) },
			"unknown target %q (valid: %s)", target, strings.Join(onrampLocalTargets(), ", "))
	}

	if out.machineOut() {
		out.renderJSON(spec)
		return exitOK
	}
	printOnrampHuman(out, target, server, token, spec)
	return exitOK
}

// printOnrampHuman renders the paste-by-hand view: each file block with its
// destination path, the per-target extras (one-liner shortcut, rules pointer,
// dialect reminder), and the verify + full-journey pointer.
func printOnrampHuman(out *writer, target, server, token string, spec onrampSpec) {
	out.outf("# bp onramp %s — paste these by hand (print-only in v1; nothing is written for you).", target)
	out.outf("# server: %s", server)
	if token != "" {
		out.outf("# token:  a literal from --token is baked in below (the default keeps the secret in your shell env).")
	}
	out.outf("")

	for i, f := range spec.Files {
		out.outf("# %d. → %s", i+1, f.Path)
		out.outf("")
		out.outf("%s", f.Content)
		out.outf("")
	}

	switch target {
	case "cursor":
		out.outf("# Claim-first task rules asset ships alongside it:")
		out.outf("#   .cursor/rules/barkpark-tasks.mdc  (see docs/setup/CURSOR.md)")
		out.outf("# Set BARKPARK_API_TOKEN in your shell; ${env:BARKPARK_API_TOKEN} reads it (Cursor dialect).")
	case "claude-code":
		out.outf("# Or register it in one line (Claude Code writes .mcp.json for you):")
		out.outf("#   claude mcp add --scope project --transport stdio --env BARKPARK_API_URL=%s --env 'BARKPARK_API_TOKEN=${BARKPARK_API_TOKEN}' barkpark -- bp mcp serve", server)
		out.outf("# ${BARKPARK_API_TOKEN} is the Claude Code dialect — set it in your shell. Keep the")
		out.outf("# single quotes: --scope project writes the COMMITTED .mcp.json, and they stop your")
		out.outf("# shell expanding the placeholder into a literal token.")
	case "codex":
		out.outf("# Or register it in one line:")
		out.outf("#   codex mcp add barkpark --env BARKPARK_API_URL=%s -- bp mcp serve", server)
		out.outf("# The token is FORWARDED from your shell via env_vars — never written into config.toml.")
		out.outf("# Codex does not expand ${VAR} inside a TOML value, so a placeholder there would ship literally.")
	case "cursor-cloud":
		out.outf("# Set BARKPARK_API_URL and BARKPARK_API_TOKEN in Cursor's Secrets UI — never commit them.")
		out.outf("# ${env:BARKPARK_API_TOKEN} in .cursor/mcp.json reads the secret at runtime (Cursor dialect).")
	case "windsurf":
		out.outf("# ~/.codeium/mcp_config.json is USER-GLOBAL and may already hold other servers:")
		out.outf("# MERGE the \"barkpark\" entry into the existing \"mcpServers\" object — don't overwrite the file.")
		out.outf("# Set BARKPARK_API_TOKEN in your shell; ${env:BARKPARK_API_TOKEN} reads it (Windsurf shares Cursor's dialect).")
	case "gemini-cli":
		out.outf("# Global alternative: ~/.gemini/settings.json (project .gemini/settings.json wins for that repo).")
		out.outf("# settings.json holds your WHOLE Gemini CLI config — MERGE the \"barkpark\" entry into any")
		out.outf("# existing \"mcpServers\" object rather than replacing the file.")
		out.outf("# Set BARKPARK_API_TOKEN in your shell; ${BARKPARK_API_TOKEN} is expanded by Gemini CLI (its dialect).")
	}

	out.outf("")
	out.outf("# verify: %s", spec.Verify)
	out.outf("#")
	out.outf("# `bp mcp serve` needs the Tasks plugin enabled on the server.")
	out.outf("# Full journey (install · auth · create): docs/setup/AGENT-ONRAMPS.md")
}

// printOnrampHelp is the usage/help screen for `bp onramp`.
func printOnrampHelp(out *writer) {
	out.outf("usage: bp onramp <cursor|claude-code|codex|cursor-cloud|windsurf|gemini-cli> [--server URL] [--token TOKEN]")
	out.outf("")
	out.outf("Print the exact MCP-registration config for one AI-agent surface — the config")
	out.outf("block(s), where they belong, and how to verify. PRINT-ONLY in v1: nothing is")
	out.outf("written for you (--write is a later wave).")
	out.outf("")
	out.outf("targets")
	out.outf("  cursor        .cursor/mcp.json stanza (${env:BARKPARK_API_TOKEN}) + rules pointer")
	out.outf("  claude-code   .mcp.json stanza (${BARKPARK_API_TOKEN}) + `claude mcp add` one-liner")
	out.outf("  codex         ~/.codex/config.toml [mcp_servers.barkpark] (env_vars token forwarding)")
	out.outf("  cursor-cloud  .cursor/environment.json install + Secrets UI note + the cursor stanza")
	out.outf("  windsurf      ~/.codeium/mcp_config.json stanza (${env:BARKPARK_API_TOKEN}) + merge note")
	out.outf("  gemini-cli    .gemini/settings.json stanza (${BARKPARK_API_TOKEN}) + global/merge note")
	out.outf("")
	out.outf("chatgpt / claude-ai are remote-agent onramps (no local config) — see docs/setup/REMOTE.md")
	out.outf("")
	out.outf("flags")
	out.outf("  --server URL   BARKPARK_API_URL to bake in (default: your active server, else %s)", onrampDefaultServer)
	out.outf("  --token TOKEN  bake a literal token instead of the ${…} env placeholder (default: keep it in the shell)")
	out.outf("  -o json        emit {target, files:[{path,content}], verify} for scripted setup")
}

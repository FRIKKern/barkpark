package cli

// onramp_cmd.go — `bp onramp <target>`: emit the exact MCP-registration config
// block(s) for ONE AI-agent surface, where they belong, and how to verify.
// PRINT-FIRST: by default it SHOWS the blocks and writes nothing. `--write` does
// the work — a safe merge that touches ONLY the barkpark entry
// (onramp_write.go), idempotent and atomic; `--force` overwrites a differing
// barkpark entry. Codex's config.toml is merged by a parse-lite textual span
// splice — deliberately NO TOML dependency in go.mod (charter D10/D11). A stray
// unknown flag is a usage error, never silently ignored.
//
// Targets: cursor | claude-code | codex | cursor-cloud | windsurf | gemini-cli |
// copilot | zed | agents-md. zed is the odd one on the stanza side — Zed has no
// ${env:} interpolation, so its context_servers entry carries an EMPTY env {} and
// the credential rides bp's OWN saved config, never a token in settings.json
// (charter D21). agents-md is the odd one out — not an MCP stanza but the ONE
// canonical consumer AGENTS.md teach block (the ~23-tool convergence standard),
// marker-wrapped, that the three wave-1 teach-layer wrappers now derive from.
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
	// copilotTokenRef is VS Code / GitHub Copilot's dialect. VS Code expands
	// ${env:VAR} inside `.vscode/mcp.json` values, reading the token from the shell
	// so the secret never lands in the committed file — cited:
	// code.visualstudio.com/docs/agents/reference/mcp-configuration (2026-07-10).
	// Its VALUE coincides with cursorTokenRef, but it stays its OWN named constant
	// — dialects are per-tool and never shared across tools even when they happen
	// to match (charter decision 9; geminiTokenRef precedent above).
	copilotTokenRef = "${env:BARKPARK_API_TOKEN}" // VS Code / Copilot dialect
)

// onrampFile is one config file a target needs: where it belongs + its content.
// The merge-metadata fields (all omitempty, stamped in buildOnrampSpec) tell the
// `--write` engine HOW to merge just the barkpark entry into an existing file
// without a hardcoded key — see onramp_write.go. They stay omitempty so a file
// that carries none (there are none today) prints no empty noise in `-o json`.
type onrampFile struct {
	Path    string `json:"path"`
	Content string `json:"content"`
	// MergeKind ∈ server-map | flat | toml (onramp_write.go constants). Empty
	// means print-only, no --write strategy.
	MergeKind string `json:"mergeKind,omitempty"`
	// TopKey is the top-level object key --write merges under (mcpServers /
	// servers / install).
	TopKey string `json:"topKey,omitempty"`
	// ServerKey is the entry inside TopKey --write owns (always "barkpark" for a
	// server-map). Unused for flat/toml.
	ServerKey string `json:"serverKey,omitempty"`
}

// The single entry every server-map onramp owns inside its top-level object.
const onrampServerKey = "barkpark"

// mcpServerFile / serversFile / flatFile / tomlFile stamp the merge metadata for
// each shape so --write never hardcodes a key. mcpServerFile covers the
// `mcpServers` map every stdio target uses; serversFile covers copilot's
// `.vscode/mcp.json` (top-level `servers`) — wrap that target's file literal in
// it when the copilot slice lands.
func mcpServerFile(path, content string) onrampFile {
	return onrampFile{Path: path, Content: content, MergeKind: mergeServerMap, TopKey: "mcpServers", ServerKey: onrampServerKey}
}

func serversFile(path, content string) onrampFile {
	return onrampFile{Path: path, Content: content, MergeKind: mergeServerMap, TopKey: "servers", ServerKey: onrampServerKey}
}

// contextServersFile stamps the merge metadata for Zed's top-level
// `context_servers` map — the SAME generic server-map engine (mergeServerMap),
// only the TopKey differs. Zero new merge-kind code: the TopKey parametrization is
// already proven by the servers-shape sibling (TestOnrampWriteServersShape), and a
// w2 verify probe re-confirmed create/foreign-preserve/idempotent under
// context_servers (charter D21). This is NOT the copilot bare-literal onrampFile
// that shipped the --write silent no-op (D23).
func contextServersFile(path, content string) onrampFile {
	return onrampFile{Path: path, Content: content, MergeKind: mergeServerMap, TopKey: "context_servers", ServerKey: onrampServerKey}
}

func flatFile(path, content, topKey string) onrampFile {
	return onrampFile{Path: path, Content: content, MergeKind: mergeFlat, TopKey: topKey}
}

// tomlFile stamps codex's config.toml merge metadata: the parse-lite span
// splice (onramp_write.go mergeTOMLFile) locates the owned [TopKey.ServerKey]
// span from these — never a hardcoded key.
func tomlFile(path, content string) onrampFile {
	return onrampFile{Path: path, Content: content, MergeKind: mergeTOML, TopKey: "mcp_servers", ServerKey: onrampServerKey}
}

// markdownFile stamps the merge metadata for the agents-md target's marker-managed
// ./AGENTS.md block — the SAME atomicWriteFile seam the JSON mergers use, only the
// strategy differs (mergeMarkdownFile in onramp_write.go: create / append-without-
// markers / replace-between-markers / unchanged, with a --force deny path). No
// TopKey/ServerKey — a markdown block is not a keyed JSON object.
func markdownFile(path, content string) onrampFile {
	return onrampFile{Path: path, Content: content, MergeKind: mergeMarkdown}
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
	return []string{"cursor", "claude-code", "codex", "cursor-cloud", "windsurf", "gemini-cli", "copilot", "zed", "agents-md"}
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

// copilotMcpJSONStanza renders the `.vscode/mcp.json` server block in VS Code /
// GitHub Copilot's shape. The ONE structural difference from every sibling: the
// top-level key is `servers`, NOT `mcpServers` — VS Code renamed it during the
// MCP preview (live-pinned against
// code.visualstudio.com/docs/agents/reference/mcp-configuration, 2026-07-10).
// Otherwise it is the Claude Code shape: the explicit `"type": "stdio"`
// discriminator plus command/args/env, carrying the SAME BARKPARK_API_URL env
// key every sibling stanza uses (so COPILOT.md's retargeting prose stays
// consistent). Key ORDER is fixed by a raw template — a map marshal would sort
// keys and drift from the doc (decision 14). The token stays in the shell via
// ${env:…}; the `inputs`/promptString alternative is documented in COPILOT.md,
// never emitted here.
func copilotMcpJSONStanza(server, tokenValue string) string {
	return fmt.Sprintf(`{
  "servers": {
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

// zedContextServersStanza renders the GLOBAL `~/.config/zed/settings.json`
// `context_servers` block in Zed's shape. Zed's user-facing context_servers entry
// is a serde-UNTAGGED enum (zed crates/settings_content/src/project.rs:392) — there
// is NO `source` key of any kind; the entry is FLAT {command, args, env} directly
// (the charter's old `source:"custom"` premise was stale, corrected D21). Zed does
// NOT expand ${env:VAR} / ${VAR} inside settings.json (open FRs zed#26043 / #28632 /
// #18630 / #53780), so the stanza carries an EMPTY `env {}` and NEVER a token
// placeholder — `bp` resolves the server + token from its OWN saved config
// (~/.config/barkpark/config.json), independent of Zed's env map. An onramp never
// writes a literal token; on Zed the credential rides bp's config, so `bp setup`
// must have run first. There is no server/token to bake in, so this takes no args
// (unlike the mcpServers stanzas). Key ORDER (command, args, env) is fixed by a raw
// template — a map marshal would sort keys and drift from ZED.md (decision 14).
func zedContextServersStanza() string {
	return `{
  "context_servers": {
    "barkpark": {
      "command": "bp",
      "args": ["mcp", "serve"],
      "env": {}
    }
  }
}`
}

// codexTOMLBlock renders the `~/.codex/config.toml` [mcp_servers.barkpark] block.
// The static env table carries ONLY the non-secret URL; the token rides
// env_vars = ["BARKPARK_API_TOKEN"] (shell-forward whitelist). There is no ${…}
// anywhere — Codex does not expand it inside a TOML value, so a placeholder would
// ship as a literal string (charter decision 7). The raised timeouts (defaults
// 10/60) match docs/setup/CODEX.md — a cold bp binary + first manifest fetch
// must not trip the launcher. This block is the ONE stanza source: the doc, the
// print, and the --write splice all carry it byte-identically (decision 14).
// Provenance: codex-cli 0.144.1 accepts this flat env form, though its own
// `codex mcp add` writes env as a nested [mcp_servers.barkpark.env] sub-table
// (live-captured); openai/codex@5c19155c reads both (2026-07-11 source pin).
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

// AGENTS.md managed-block markers. `bp onramp agents-md` wraps the canonical
// teach text in these so a re-run (and, later, `--write`) can find its own block
// and replace ONLY between them — never a consumer's surrounding content.
const (
	agentsMDMarkerBegin = "<!-- barkpark:onramp:begin -->"
	agentsMDMarkerEnd   = "<!-- barkpark:onramp:end -->"
)

// agentsMDHeading is the section title the emitted AGENTS.md block carries — the
// framing above the shared body inside the markers.
const agentsMDHeading = "## Task tracking — Barkpark (bp)"

// renderAgentsMDBody is the ONE consumer-facing Barkpark teach text, the SUPERSET
// the three wave-1 wrappers converge on: the cursor/claude common body (keeping
// `bp task prime`, the mid-claim `bp task stamp`/`bp task pulse` pair, the
// Conventions header, the parent_id nesting line, and the 409
// doc_changed_since_claim line that CODEX.md's rendering had dropped). The two
// per-derivation lines are parameters: workerPrefix seeds the worker-id line
// (`<tool>-…`, `cursor-…`, `claude-…`) and mcpDocRef seeds the MCP footer's
// "see …" pointer. Every other line is invariant, so the three wrappers can only
// differ in exactly those two spots — the drift the parity test guards.
func renderAgentsMDBody(workerPrefix, mcpDocRef string) string {
	workerLine := "- Worker id: `" + workerPrefix + "-<your-name-or-branch>` — pick one and keep it for claim/close symmetry."
	mcpFooter := "MCP-native surface? The same verbs are first-class MCP tools via `bp mcp serve` — see `" + mcpDocRef + "`."
	lines := []string{
		// The doctrine leads: WHEN to register (always, before the work) and WHY,
		// ahead of the verb list that teaches HOW. One const, shared with the MCP
		// server instructions — see movement_doctrine.go.
		movementLedgerDoctrine,
		"",
		"All task tracking uses Barkpark — never markdown TODO lists, never a TODO tool.",
		"The `bp` CLI talks to the configured server (`~/.config/barkpark/`).",
		"",
		"- `bp task ready` — list available work",
		"- `bp task next <worker>` — atomically claim the next ready task; claim FIRST — it returns the brief and an epoch",
		"- `bp task get <id>` — task detail (carries children + child_count)",
		"- `bp task close <id> <worker> <epoch>` — complete; epoch comes from your claim. Lapsed? re-claim for a fresh epoch, then close.",
		"- `bp task create ...` — file new work (older binaries lack this verb; fall back to `bp doc create task`)",
		"- `bp task prime <worker>` — one-call rehydration: your in-progress claims, ready head, recent events",
		"- `bp task stamp <id> <worker> <epoch> --criterion N --criterion-text \"<its wording>\" --met --evidence \"…\"` — evidence on ONE criterion mid-claim. N is ZERO-BASED (first = 0); `--criterion-text` is REQUIRED for `--met` — an unguarded flip is REFUSED. `--miss --note \"…\"` = honest attempt, no flip.",
		"- `bp task pulse <id> <worker> --now \"…\"` — now-line + lease renewal in one write (no epoch arg — it bumps the claim epoch)",
		"- `bp capabilities -o json` — the whole API manifest when unsure",
		"",
		"Conventions:",
		workerLine,
		"- `lifecycle_status` is the done-signal (`open` → `done`), not the claim record.",
		"- Closing marks criteria in the same atomic write; a met:true entry MUST carry the criterion's exact wording:",
		"  `--set 'criteria:=[{\"index\":0,\"met\":true,\"evidence\":\"...\",\"criterion\":\"<wording>\"}]'`",
		"- Nest large work with `parent_id` (a slug) for a Goal → sub-task tree; keep it flat otherwise.",
		"- If a close 409s `doc_changed_since_claim`, re-read the changed brief, then close with `--set observed_rev=<current_rev>` (the rev the 409 names); a bare re-read then close just repeats the 409.",
		"",
		"Papers (design docs, specs, reports) live in Barkpark too — never hand-roll an HTML file:",
		"- `bp bulldocs publish <slug> --file payload.json` — the write door; the same slug MUST also appear as `\"slug\"` INSIDE the JSON, not just on the command line.",
		"- The payload is `blocks` — the renderer's own block deck (chart, diagram, asciicast, diff, table, callout, …). `body_html` is a legacy last resort that renders flat.",
		"- Inline leaves are VALUE-KEYED: every `items`/`cells` entry is an object carrying a `value` key, never a bare string — a bare string publishes clean and renders BLANK.",
		"- `bp paper view <slug>` reads one back in the terminal. Authoring guide: `/papers/paper-authoring-excellence`.",
		"",
		mcpFooter,
	}
	return strings.Join(lines, "\n")
}

// agentsMDCanonicalBody is the emitted/canonical rendering: worker-id generalized
// to `<tool>-…` and the MCP footer pointed at the onramp hub. This exact string is
// what CODEX.md documents; the .cursor/.claude wrappers embed their own
// per-tool renderings of the same body.
var agentsMDCanonicalBody = renderAgentsMDBody("<tool>", "docs/setup/AGENT-ONRAMPS.md")

// agentsMDBlock is the full marker-managed block `bp onramp agents-md` emits into
// a consumer's ./AGENTS.md: begin marker, section heading, the canonical body,
// end marker. The markers make the block idempotently findable so a re-run
// replaces only itself.
func agentsMDBlock() string {
	return agentsMDMarkerBegin + "\n" +
		agentsMDHeading + "\n\n" +
		agentsMDCanonicalBody + "\n" +
		agentsMDMarkerEnd
}

// buildOnrampSpec assembles the file set + verify step for a local target. ok is
// false for an unknown target (the caller renders the valid-set usage error).
func buildOnrampSpec(target, server, token string) (onrampSpec, bool) {
	switch target {
	case "cursor":
		return onrampSpec{
			Target: target,
			Files: []onrampFile{
				mcpServerFile(".cursor/mcp.json", mcpJSONStanza(server, onrampTokenValue(cursorTokenRef, token))),
			},
			Verify: "reload MCP servers in Cursor Settings — the barkpark task tools appear in the Agent's tool list",
		}, true
	case "claude-code":
		return onrampSpec{
			Target: target,
			Files: []onrampFile{
				mcpServerFile(".mcp.json", claudeCodeMcpJSONStanza(server, onrampTokenValue(claudeCodeTokenRef, token))),
			},
			Verify: "claude mcp list",
		}, true
	case "codex":
		return onrampSpec{
			Target: target,
			Files: []onrampFile{
				tomlFile("~/.codex/config.toml", codexTOMLBlock(server)),
			},
			Verify: "codex mcp list",
		}, true
	case "cursor-cloud":
		return onrampSpec{
			Target: target,
			Files: []onrampFile{
				flatFile(".cursor/environment.json", cursorCloudEnvironmentJSON(), "install"),
				mcpServerFile(".cursor/mcp.json", mcpJSONStanza(server, onrampTokenValue(cursorTokenRef, token))),
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
				mcpServerFile("~/.codeium/mcp_config.json", mcpJSONStanza(server, onrampTokenValue(cursorTokenRef, token))),
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
				mcpServerFile(".gemini/settings.json", mcpJSONStanza(server, onrampTokenValue(geminiTokenRef, token))),
			},
			Verify: "gemini mcp list  (or /mcp inside the Gemini CLI) — barkpark appears with its tools",
		}, true
	case "copilot":
		// VS Code / GitHub Copilot reads `.vscode/mcp.json`. The one structural
		// difference from every sibling is the top-level `servers` key (VS Code
		// renamed it from mcpServers during the MCP preview — copilotMcpJSONStanza).
		// It shares Cursor's ${env:VAR} dialect (copilotTokenRef, its own named
		// constant per decision 9). The file may already hold other servers, so the
		// human print carries a merge-the-key note rather than a whole-file label.
		return onrampSpec{
			Target: target,
			Files: []onrampFile{
				// serversFile stamps the generic server-map merge with
				// TopKey=servers (VS Code's shape, zero new merge-kind code) so
				// --write is REAL: a bare onrampFile literal here is the #2129
				// regression that shipped a silent no-op (charter D14 — mergeOnrampFile
				// falls to default and reports skipped). The zed/contextServersFile
				// sibling is the same TopKey-parametrization precedent.
				serversFile(".vscode/mcp.json", copilotMcpJSONStanza(server, onrampTokenValue(copilotTokenRef, token))),
			},
			Verify: `run "MCP: List Servers" from the VS Code Command Palette — barkpark appears; its task tools show in Copilot agent mode's tool picker`,
		}, true
	case "zed":
		// Zed reads MCP "context servers" from the GLOBAL ~/.config/zed/settings.json
		// (zed::OpenSettingsFile; project .zed/settings.json is not documented for
		// context_servers). The entry is FLAT — NO `source` key (charter D21) — and
		// carries an EMPTY env {}: Zed has no ${env:} interpolation, so the credential
		// rides bp's OWN saved config (~/.config/barkpark/), never a literal token in
		// settings.json. contextServersFile stamps the generic server-map merge with
		// TopKey=context_servers (zero new merge-kind code) so --write is real, not the
		// copilot bare-literal no-op. The file holds the whole editor config, so the
		// human print carries a merge-the-key note, never a whole-file label.
		return onrampSpec{
			Target: target,
			Files: []onrampFile{
				contextServersFile("~/.config/zed/settings.json", zedContextServersStanza()),
			},
			Verify: "reload Zed (or run `zed: reload`) — barkpark's task tools appear in the Agent Panel's tool list",
		}, true
	case "agents-md":
		// The tool-agnostic teach block for the ~23-tool AGENTS.md convergence
		// standard — Codex, Aider, and every AGENTS.md-reading agent. It carries no
		// server/token (it teaches the claim-first contract, not an MCP stanza), so
		// server and token are ignored. Marker-wrapped so a re-run replaces only its
		// own block, never a consumer's surrounding AGENTS.md content.
		return onrampSpec{
			Target: target,
			Files: []onrampFile{
				markdownFile("./AGENTS.md", agentsMDBlock()),
			},
			Verify: "open a fresh agent session in this repo — it reads AGENTS.md and knows the claim-first task contract before touching the board",
		}, true
	}
	return onrampSpec{}, false
}

// onrampTargetUsesServer reports whether a target bakes the resolved server URL
// into its emission. agents-md is a pure teach block with no MCP stanza; zed's
// stanza carries an empty env {} and reads the server from bp's saved config
// (charter D21) — neither bakes a URL, so the human print skips the `# server:`
// line for both (printing one would falsely imply the stanza targets it).
func onrampTargetUsesServer(target string) bool {
	return target != "agents-md" && target != "zed"
}

// runOnramp is the `bp onramp <target>` built-in. Prints the config by default;
// `--write` merges just the barkpark entry into the target's JSON config (safe,
// idempotent, atomic — see onramp_write.go), `--force` overwrites a differing
// barkpark entry.
func runOnramp(out *writer, g globals, args []string) int {
	if g.help {
		printOnrampHelp(out)
		return exitOK
	}

	// Separate the single target from the recognised local flags. --server/--token
	// are GLOBAL flags already folded into g; --write/--force are onramp-local; any
	// OTHER `-flag` reaching here is unknown and rejected (never silently ignored).
	target := ""
	write := false
	force := false
	for _, a := range args {
		switch a {
		case "--write":
			write = true
			continue
		case "--force":
			force = true
			continue
		}
		if strings.HasPrefix(a, "-") {
			return usageErrf(out, func() { printOnrampHelp(out) },
				"unknown flag %q (onramp accepts --write and --force; --server/--token are global)", a)
		}
		if target != "" {
			return usageErrf(out, func() { printOnrampHelp(out) },
				"onramp takes exactly one target (got %q and %q)", target, a)
		}
		target = a
	}
	if force && !write {
		return usageErrf(out, func() { printOnrampHelp(out) },
			"--force only applies with --write (it overwrites a differing barkpark entry)")
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

	if write {
		// --dry-run is a GLOBAL flag (globals.go): with --write it computes every
		// action but writes nothing — an honest doctor mode, no bespoke --check flag.
		return runOnrampWrite(out, spec, force, g.dryRun)
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
	out.outf("# bp onramp %s — paste these by hand, or re-run with --write to merge them for you.", target)
	if onrampTargetUsesServer(target) {
		out.outf("# server: %s", server)
	}
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
	case "copilot":
		out.outf("# .vscode/mcp.json uses a top-level \"servers\" key — VS Code's MCP shape (siblings nest under mcpServers).")
		out.outf("# If the file already holds other servers, MERGE the \"barkpark\" entry into \"servers\" — don't overwrite it.")
		out.outf("# Set BARKPARK_API_TOKEN in your shell; ${env:BARKPARK_API_TOKEN} reads it (VS Code dialect, shared with Cursor).")
		out.outf("# Prefer a typed prompt over a shell var? Add an \"inputs\" promptString and reference ${input:id} — see docs/setup/COPILOT.md.")
	case "zed":
		out.outf("# ~/.config/zed/settings.json is your GLOBAL Zed config and holds every editor setting:")
		out.outf("# MERGE the \"barkpark\" entry into a top-level \"context_servers\" object — don't overwrite the file.")
		out.outf("# No token goes here: Zed has no ${env:} interpolation, so env stays {} and `bp` reads your")
		out.outf("# server + token from its own saved config (~/.config/barkpark/) — run `bp setup` first.")
	case "agents-md":
		out.outf("# This is the ONE canonical teach block — the AGENTS.md standard that Codex,")
		out.outf("# Aider, and every AGENTS.md-reading agent converge on. It bakes no token and")
		out.outf("# no server URL: it teaches the claim-first task contract, not an MCP stanza.")
		out.outf("# The barkpark:onramp markers make it a managed block — paste it into your")
		out.outf("# repo-root ./AGENTS.md (or MERGE it in; keep the markers so a re-run updates")
		out.outf("# only this block, never your surrounding content).")
		out.outf("# The .cursor/rules/barkpark-tasks.mdc and .claude/CLAUDE-BARKPARK.md wrappers")
		out.outf("# are the same body in each tool's native framing.")
	}

	out.outf("")
	out.outf("# verify: %s", spec.Verify)
	out.outf("#")
	out.outf("# `bp mcp serve` needs the Tasks plugin enabled on the server.")
	out.outf("# Full journey (install · auth · create): docs/setup/AGENT-ONRAMPS.md")
}

// printOnrampHelp is the usage/help screen for `bp onramp`.
func printOnrampHelp(out *writer) {
	out.outf("usage: bp onramp <cursor|claude-code|codex|cursor-cloud|windsurf|gemini-cli|copilot|zed|agents-md> [--write [--force] [--dry-run]] [--server URL] [--token TOKEN]")
	out.outf("")
	out.outf("Print the exact MCP-registration config for one AI-agent surface — the config")
	out.outf("block(s), where they belong, and how to verify. With --write, merge just the")
	out.outf("barkpark entry into the target's config (idempotent — a JSON key, or codex's")
	out.outf("[mcp_servers.barkpark] TOML span; everything else survives verbatim).")
	out.outf("")
	out.outf("targets")
	out.outf("  cursor        .cursor/mcp.json stanza (${env:BARKPARK_API_TOKEN}) + rules pointer")
	out.outf("  claude-code   .mcp.json stanza (${BARKPARK_API_TOKEN}) + `claude mcp add` one-liner")
	out.outf("  codex         ~/.codex/config.toml [mcp_servers.barkpark] (env_vars token forwarding)")
	out.outf("  cursor-cloud  .cursor/environment.json install + Secrets UI note + the cursor stanza")
	out.outf("  windsurf      ~/.codeium/mcp_config.json stanza (${env:BARKPARK_API_TOKEN}) + merge note")
	out.outf("  gemini-cli    .gemini/settings.json stanza (${BARKPARK_API_TOKEN}) + global/merge note")
	out.outf("  copilot       .vscode/mcp.json stanza (top-level `servers`, ${env:BARKPARK_API_TOKEN}) + inputs note")
	out.outf("  zed           ~/.config/zed/settings.json context_servers (flat entry, env {} — token via bp saved config)")
	out.outf("  agents-md     ./AGENTS.md marker-managed teach block (the AGENTS.md convergence standard — Codex, Aider, …)")
	out.outf("")
	out.outf("chatgpt / claude-ai are remote-agent onramps (no local config) — see docs/setup/REMOTE.md")
	out.outf("")
	out.outf("flags")
	out.outf("  --write        merge the barkpark entry into the target's config in place —")
	out.outf("                 created / updated / unchanged / skipped, per file, atomically")
	out.outf("  --force        with --write: overwrite an existing, differing barkpark entry")
	out.outf("  --dry-run      with --write: report the per-file actions (created/updated/…) and write NOTHING (global flag)")
	out.outf("  --server URL   BARKPARK_API_URL to bake in (default: your active server, else %s)", onrampDefaultServer)
	out.outf("  --token TOKEN  bake a literal token instead of the ${…} env placeholder (default: keep it in the shell)")
	out.outf("  -o json        without --write: emit {target, files:[{path,content}], verify};")
	out.outf("                 with --write: emit {target, actions:[{path,action}]} for scripted setup")
}

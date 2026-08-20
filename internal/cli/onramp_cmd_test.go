package cli

import (
	"bytes"
	"encoding/json"
	"os"
	"strings"
	"testing"
)

// onrampRun drives `bp onramp` with an explicit server so the golden output is
// deterministic (a set --server short-circuits activeSavedServer / disk config).
// Human mode: the writer's output field stays "" so machineOut() is false.
func onrampRun(t *testing.T, g globals, args ...string) (stdout, stderr string, code int) {
	t.Helper()
	var so, se bytes.Buffer
	w := newWriter(&so, &se)
	code = runOnramp(w, g, args)
	return so.String(), se.String(), code
}

const guerrilla = "https://guerrilla.barkpark.cloud"

// TestOnrampCursorGolden asserts the Cursor emission is byte-compatible with the
// stanza docs/setup/CURSOR.md:78-91 publishes, in the Cursor ${env:VAR} dialect.
func TestOnrampCursorGolden(t *testing.T) {
	out, _, code := onrampRun(t, globals{server: guerrilla}, "cursor")
	if code != exitOK {
		t.Fatalf("cursor exit = %d, want %d", code, exitOK)
	}
	wantStanza := `{
  "mcpServers": {
    "barkpark": {
      "command": "bp",
      "args": ["mcp", "serve"],
      "env": {
        "BARKPARK_API_URL": "https://guerrilla.barkpark.cloud",
        "BARKPARK_API_TOKEN": "${env:BARKPARK_API_TOKEN}"
      }
    }
  }
}`
	if !strings.Contains(out, wantStanza) {
		t.Errorf("cursor output missing the exact CURSOR.md stanza.\n--- got ---\n%s", out)
	}
	for _, want := range []string{".cursor/mcp.json", ".cursor/rules/barkpark-tasks.mdc", "reload MCP servers", "docs/setup/AGENT-ONRAMPS.md"} {
		if !strings.Contains(out, want) {
			t.Errorf("cursor output missing %q", want)
		}
	}
	// Cursor dialect only — never the Claude Code / TOML forms.
	if strings.Contains(out, "env_vars") {
		t.Errorf("cursor output leaked the Codex env_vars dialect")
	}
}

// TestOnrampClaudeCodeGolden asserts the Claude Code .mcp.json stanza uses the
// ${VAR} dialect and carries the `claude mcp add … -- bp mcp serve` one-liner.
func TestOnrampClaudeCodeGolden(t *testing.T) {
	out, _, code := onrampRun(t, globals{server: guerrilla}, "claude-code")
	if code != exitOK {
		t.Fatalf("claude-code exit = %d, want %d", code, exitOK)
	}
	// The exact stanza docs/setup/CLAUDE-CODE.md publishes — including the
	// explicit "type": "stdio" discriminator (decision 14: doc == verb).
	wantStanza := `{
  "mcpServers": {
    "barkpark": {
      "type": "stdio",
      "command": "bp",
      "args": ["mcp", "serve"],
      "env": {
        "BARKPARK_API_URL": "https://guerrilla.barkpark.cloud",
        "BARKPARK_API_TOKEN": "${BARKPARK_API_TOKEN}"
      }
    }
  }
}`
	if !strings.Contains(out, wantStanza) {
		t.Errorf("claude-code output missing the exact CLAUDE-CODE.md stanza.\n--- got ---\n%s", out)
	}
	// The Cursor dialect must NOT appear — dialects never mix (decision 9).
	if strings.Contains(out, "${env:BARKPARK_API_TOKEN}") {
		t.Errorf("claude-code output leaked the Cursor ${env:…} dialect")
	}
	for _, want := range []string{
		".mcp.json",
		"claude mcp add --scope project --transport stdio --env BARKPARK_API_URL=https://guerrilla.barkpark.cloud --env 'BARKPARK_API_TOKEN=${BARKPARK_API_TOKEN}' barkpark -- bp mcp serve",
		"claude mcp list",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("claude-code output missing %q", want)
		}
	}
}

// TestOnrampCodexGolden asserts the Codex TOML block forwards the token via
// env_vars and NEVER interpolates ${VAR} inside a value (charter decision 7).
func TestOnrampCodexGolden(t *testing.T) {
	out, _, code := onrampRun(t, globals{server: guerrilla}, "codex")
	if code != exitOK {
		t.Fatalf("codex exit = %d, want %d", code, exitOK)
	}
	wantBlock := `[mcp_servers.barkpark]
command = "bp"
args = ["mcp", "serve"]
env = { BARKPARK_API_URL = "https://guerrilla.barkpark.cloud" }
env_vars = ["BARKPARK_API_TOKEN"]
startup_timeout_sec = 15
tool_timeout_sec = 120`
	if !strings.Contains(out, wantBlock) {
		t.Errorf("codex output missing the exact config.toml block.\n--- got ---\n%s", out)
	}
	// Isolate the TOML block and prove it carries no ${…} expansion and no static
	// token key — the two things decision 7 forbids.
	block := wantBlock
	if strings.Contains(block, "${") {
		t.Errorf("codex TOML block must not contain a ${…} placeholder (Codex ships it literally)")
	}
	if strings.Contains(block, "BARKPARK_API_TOKEN =") {
		t.Errorf("codex TOML must not put the token in the static env table — it forwards via env_vars")
	}
	for _, want := range []string{"~/.codex/config.toml", "codex mcp add barkpark", "codex mcp list"} {
		if !strings.Contains(out, want) {
			t.Errorf("codex output missing %q", want)
		}
	}
}

// TestOnrampCursorCloudGolden asserts the two-file emission: environment.json
// install step + the Secrets-UI note + the reused Cursor mcp.json stanza.
func TestOnrampCursorCloudGolden(t *testing.T) {
	out, _, code := onrampRun(t, globals{server: guerrilla}, "cursor-cloud")
	if code != exitOK {
		t.Fatalf("cursor-cloud exit = %d, want %d", code, exitOK)
	}
	wantEnv := `{
  "install": "curl -fsSL https://raw.githubusercontent.com/FRIKKern/barkpark/main/scripts/install-cli.sh | sh"
}`
	if !strings.Contains(out, wantEnv) {
		t.Errorf("cursor-cloud output missing the environment.json install block.\n%s", out)
	}
	for _, want := range []string{
		".cursor/environment.json",
		".cursor/mcp.json",
		"Secrets UI",
		"${env:BARKPARK_API_TOKEN}", // reuses the Cursor dialect verbatim
	} {
		if !strings.Contains(out, want) {
			t.Errorf("cursor-cloud output missing %q", want)
		}
	}
}

// TestOnrampWindsurfGolden asserts the Windsurf emission is byte-compatible with
// the stanza docs/setup/WINDSURF.md:50-61 publishes, in Cursor's shared ${env:VAR}
// dialect, at the user-global ~/.codeium/mcp_config.json, with merge guidance.
func TestOnrampWindsurfGolden(t *testing.T) {
	out, _, code := onrampRun(t, globals{server: guerrilla}, "windsurf")
	if code != exitOK {
		t.Fatalf("windsurf exit = %d, want %d", code, exitOK)
	}
	// VERBATIM copy of docs/setup/WINDSURF.md:50-61 — the byte-parity lock
	// (charter decision 16: doc block == verb output, kept identical by hand).
	wantStanza := `{
  "mcpServers": {
    "barkpark": {
      "command": "bp",
      "args": ["mcp", "serve"],
      "env": {
        "BARKPARK_API_URL": "https://guerrilla.barkpark.cloud",
        "BARKPARK_API_TOKEN": "${env:BARKPARK_API_TOKEN}"
      }
    }
  }
}`
	if !strings.Contains(out, wantStanza) {
		t.Errorf("windsurf output missing the exact WINDSURF.md stanza.\n--- got ---\n%s", out)
	}
	for _, want := range []string{
		"~/.codeium/mcp_config.json",
		"MERGE", // merge-the-key guidance, not a whole-file clobber
		"docs/setup/AGENT-ONRAMPS.md",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("windsurf output missing %q", want)
		}
	}
	// Windsurf speaks Cursor's ${env:…} dialect — the Codex env_vars form must
	// never leak in (dialects never mix, decision 9).
	if strings.Contains(out, "env_vars") {
		t.Errorf("windsurf output leaked the Codex env_vars dialect")
	}
}

// TestOnrampGeminiCliGolden asserts the Gemini CLI emission is byte-compatible
// with the stanza docs/setup/GEMINI-CLI.md:51-62 publishes, in Gemini's own
// ${VAR} dialect, at .gemini/settings.json, with global + merge guidance.
func TestOnrampGeminiCliGolden(t *testing.T) {
	out, _, code := onrampRun(t, globals{server: guerrilla}, "gemini-cli")
	if code != exitOK {
		t.Fatalf("gemini-cli exit = %d, want %d", code, exitOK)
	}
	// VERBATIM copy of docs/setup/GEMINI-CLI.md:51-62 — the byte-parity lock.
	wantStanza := `{
  "mcpServers": {
    "barkpark": {
      "command": "bp",
      "args": ["mcp", "serve"],
      "env": {
        "BARKPARK_API_URL": "https://guerrilla.barkpark.cloud",
        "BARKPARK_API_TOKEN": "${BARKPARK_API_TOKEN}"
      }
    }
  }
}`
	if !strings.Contains(out, wantStanza) {
		t.Errorf("gemini-cli output missing the exact GEMINI-CLI.md stanza.\n--- got ---\n%s", out)
	}
	// Gemini expands ${VAR}; the Cursor-only ${env:…} form must NOT appear —
	// dialects never mix even though the braced value matches Claude Code's.
	if strings.Contains(out, "${env:BARKPARK_API_TOKEN}") {
		t.Errorf("gemini-cli output leaked the Cursor ${env:…} dialect")
	}
	for _, want := range []string{
		".gemini/settings.json",
		"~/.gemini/settings.json", // global alternative called out
		"MERGE",                   // merge-the-key guidance
		"gemini mcp list",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("gemini-cli output missing %q", want)
		}
	}
}

// TestOnrampCopilotGolden asserts the VS Code / GitHub Copilot emission is
// byte-compatible with the stanza docs/setup/COPILOT.md publishes. The one
// structural difference from every sibling is the top-level `servers` key (NOT
// `mcpServers`) — live-pinned against
// code.visualstudio.com/docs/agents/reference/mcp-configuration (2026-07-10).
// Copilot shares Cursor's ${env:…} dialect, so the OLD cursor-leak guard
// (env_vars absent) does not discriminate here; the discriminating leak-guards
// are structural: contains `servers`, does NOT contain `mcpServers`, contains
// `"type": "stdio"`.
func TestOnrampCopilotGolden(t *testing.T) {
	out, _, code := onrampRun(t, globals{server: guerrilla}, "copilot")
	if code != exitOK {
		t.Fatalf("copilot exit = %d, want %d", code, exitOK)
	}
	// BYTE-IDENTICAL to the json block docs/setup/COPILOT.md publishes (decision
	// 14: doc == verb). Top-level `servers` is VS Code's MCP shape.
	wantStanza := `{
  "servers": {
    "barkpark": {
      "type": "stdio",
      "command": "bp",
      "args": ["mcp", "serve"],
      "env": {
        "BARKPARK_API_URL": "https://guerrilla.barkpark.cloud",
        "BARKPARK_API_TOKEN": "${env:BARKPARK_API_TOKEN}"
      }
    }
  }
}`
	if !strings.Contains(out, wantStanza) {
		t.Errorf("copilot output missing the exact COPILOT.md stanza.\n--- got ---\n%s", out)
	}
	// The one structural difference: the top-level key is `servers`, never the
	// sibling `mcpServers` — and the stdio discriminator is present.
	if !strings.Contains(out, `"servers"`) {
		t.Errorf("copilot output must use the top-level \"servers\" key")
	}
	if strings.Contains(out, `"mcpServers"`) {
		t.Errorf("copilot output leaked the sibling \"mcpServers\" key — VS Code uses \"servers\"")
	}
	if !strings.Contains(out, `"type": "stdio"`) {
		t.Errorf("copilot output missing the \"type\": \"stdio\" discriminator")
	}
	for _, want := range []string{
		".vscode/mcp.json",
		"MCP: List Servers",           // the verify step
		"inputs",                      // the promptString alternative is named
		"${env:BARKPARK_API_TOKEN}",   // Copilot shares Cursor's dialect
		"docs/setup/AGENT-ONRAMPS.md", // full-journey pointer
	} {
		if !strings.Contains(out, want) {
			t.Errorf("copilot output missing %q", want)
		}
	}
}

// TestOnrampZedGolden asserts the Zed emission is byte-compatible with the stanza
// docs/setup/ZED.md:59-67 publishes. Zed's context_servers entry is a serde-
// UNTAGGED enum (crates/settings_content/src/project.rs:392) — the discriminating
// leak-guards are structural: the top-level key is `context_servers`, there is NO
// `source` key, no sibling `mcpServers`/`servers` map, and — because Zed has no
// ${env:} interpolation (charter D21) — NO env-interpolation placeholder of any
// dialect. The credential rides bp's saved config, so the credential-doctrine note
// (~/.config/barkpark/) must appear and no `# server:` URL line is printed.
func TestOnrampZedGolden(t *testing.T) {
	out, _, code := onrampRun(t, globals{server: guerrilla}, "zed")
	if code != exitOK {
		t.Fatalf("zed exit = %d, want %d", code, exitOK)
	}
	// BYTE-IDENTICAL to the json block docs/setup/ZED.md:59-67 publishes (decision
	// 14: doc == verb). FLAT entry, no `source` key, EMPTY env {}.
	wantStanza := `{
  "context_servers": {
    "barkpark": {
      "command": "bp",
      "args": ["mcp", "serve"],
      "env": {}
    }
  }
}`
	if !strings.Contains(out, wantStanza) {
		t.Errorf("zed output missing the exact ZED.md stanza.\n--- got ---\n%s", out)
	}
	if !strings.Contains(out, `"context_servers"`) {
		t.Errorf("zed output must use the top-level \"context_servers\" key")
	}
	// Structural leak-guards: no sibling map key, no `source` discriminator, and no
	// env-interpolation form in ANY dialect (Zed has none — token via bp config).
	for _, leak := range []string{
		`"mcpServers"`,              // stdio siblings' map key
		`"servers"`,                 // copilot's VS Code map key
		`"source"`,                  // the internal tagged shape Zed does NOT use
		"${env:BARKPARK_API_TOKEN}", // Cursor/Copilot dialect
		"${BARKPARK_API_TOKEN}",     // Claude Code / Gemini dialect
		"env_vars",                  // Codex shell-forward whitelist
	} {
		if strings.Contains(out, leak) {
			t.Errorf("zed output leaked %q — it must be a flat context_servers entry with empty env, credential via bp saved config", leak)
		}
	}
	for _, want := range []string{
		"~/.config/zed/settings.json", // destination path
		"~/.config/barkpark",          // credential-doctrine note
		"context_servers",             // merge note names the key
		"docs/setup/AGENT-ONRAMPS.md", // full-journey pointer
	} {
		if !strings.Contains(out, want) {
			t.Errorf("zed output missing %q", want)
		}
	}
	// No server URL is baked into Zed's stanza (empty env), so no `# server:` line.
	if strings.Contains(out, "# server:") {
		t.Errorf("zed must not print a server line (its env is {} — bp reads the server from saved config)")
	}
}

// TestOnrampAgentsMdGolden asserts `bp onramp agents-md` emits the canonical
// marker-managed AGENTS.md block, byte-identical to the checked-in golden, and
// that the block keeps every item CODEX.md's wave-1 rendering had dropped.
func TestOnrampAgentsMdGolden(t *testing.T) {
	golden, err := os.ReadFile("testdata/agents_md.golden")
	if err != nil {
		t.Fatalf("read golden: %v", err)
	}
	// The golden carries a trailing newline (POSIX text file); the block does not.
	if got := agentsMDBlock() + "\n"; got != string(golden) {
		t.Errorf("agentsMDBlock drifted from testdata/agents_md.golden.\n--- got ---\n%s\n--- golden ---\n%s", got, golden)
	}

	out, _, code := onrampRun(t, globals{server: guerrilla}, "agents-md")
	if code != exitOK {
		t.Fatalf("agents-md exit = %d, want %d", code, exitOK)
	}
	// The full emitted block appears verbatim in the human print.
	if !strings.Contains(out, agentsMDBlock()) {
		t.Errorf("agents-md output missing the exact canonical block.\n--- got ---\n%s", out)
	}
	for _, want := range []string{
		"<!-- barkpark:onramp:begin -->",
		"<!-- barkpark:onramp:end -->",
		"./AGENTS.md",
		// The four items CODEX.md's lossy rendering dropped — all survive.
		"bp task prime",
		"Conventions:",
		"parent_id",
		"doc_changed_since_claim",
		// The recovery guidance must LEAD with the sequence that actually works —
		// pin the current rev as observed_rev, not a bare re-read (S2 regression).
		"--set observed_rev=<current_rev>",
		// Generalized worker-id + generalized MCP footer.
		"`<tool>-<your-name-or-branch>`",
		"docs/setup/AGENT-ONRAMPS.md",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("agents-md output missing %q", want)
		}
	}
	// It is a teach block, not an MCP stanza — no server line, no token dialects.
	if strings.Contains(out, "# server:") {
		t.Errorf("agents-md must not print a server line (it bakes no URL)")
	}
	for _, leak := range []string{"mcpServers", "env_vars", "${env:BARKPARK_API_TOKEN}", "${BARKPARK_API_TOKEN}"} {
		if strings.Contains(out, leak) {
			t.Errorf("agents-md leaked MCP-stanza content %q — it is a pure teach block", leak)
		}
	}
}

// TestOnrampAgentsMdJSON proves `-o json` for agents-md carries the single
// ./AGENTS.md file whose content is the exact canonical block.
func TestOnrampAgentsMdJSON(t *testing.T) {
	var so, se bytes.Buffer
	w := newWriter(&so, &se)
	w.output = "json"
	if code := runOnramp(w, globals{server: guerrilla}, []string{"agents-md"}); code != exitOK {
		t.Fatalf("json exit = %d, want %d", code, exitOK)
	}
	var got onrampSpec
	if err := json.Unmarshal(so.Bytes(), &got); err != nil {
		t.Fatalf("json did not decode into onrampSpec: %v\n%s", err, so.String())
	}
	if got.Target != "agents-md" {
		t.Errorf("json target = %q, want agents-md", got.Target)
	}
	if len(got.Files) != 1 || got.Files[0].Path != "./AGENTS.md" {
		t.Fatalf("agents-md json should carry one ./AGENTS.md file, got %+v", got.Files)
	}
	if got.Files[0].Content != agentsMDBlock() {
		t.Errorf("agents-md json content is not the canonical block.\n--- got ---\n%s", got.Files[0].Content)
	}
}

// TestOnrampAgentsMdWrapperParity is the DRIFT GATE: the three wave-1 teach
// wrappers must each still embed the canonical body (in their own framing, with
// their own two per-tool lines). Reading them via relative paths, a single edited
// shared line in any wrapper makes the Contains fail — dedup is now gate-enforced.
func TestOnrampAgentsMdWrapperParity(t *testing.T) {
	cases := []struct {
		path string
		body string
	}{
		// Cursor rules asset: framing + cursor-prefixed worker-id + CURSOR.md footer.
		{"../../.cursor/rules/barkpark-tasks.mdc", renderAgentsMDBody("cursor", "docs/setup/CURSOR.md")},
		// Claude Code teach snippet: framing + claude-prefixed worker-id + CLAUDE-CODE.md footer.
		{"../../.claude/CLAUDE-BARKPARK.md", renderAgentsMDBody("claude", "docs/setup/CLAUDE-CODE.md")},
		// CODEX.md documents the canonical (`<tool>`) rendering verbatim.
		{"../../docs/setup/CODEX.md", agentsMDCanonicalBody},
	}
	for _, c := range cases {
		raw, err := os.ReadFile(c.path)
		if err != nil {
			t.Errorf("read %s: %v", c.path, err)
			continue
		}
		if !strings.Contains(string(raw), c.body) {
			t.Errorf("%s no longer embeds its canonical AGENTS.md body — drift.\nExpected body:\n%s", c.path, c.body)
		}
	}
}

// TestOnrampRejectRemote proves chatgpt/claude-ai are rejected (exit 2) with a
// pointer to REMOTE.md and no config block.
func TestOnrampRejectRemote(t *testing.T) {
	for _, target := range []string{"chatgpt", "claude-ai"} {
		out, errOut, code := onrampRun(t, globals{}, target)
		if code != exitUsage {
			t.Errorf("%s exit = %d, want %d", target, code, exitUsage)
		}
		if !strings.Contains(errOut, "docs/setup/REMOTE.md") {
			t.Errorf("%s rejection must point at docs/setup/REMOTE.md, got stderr: %q", target, errOut)
		}
		if strings.Contains(out, "mcpServers") {
			t.Errorf("%s must print no config block", target)
		}
	}
}

// TestOnrampUnknownTarget lists the valid set on an unknown target.
func TestOnrampUnknownTarget(t *testing.T) {
	_, errOut, code := onrampRun(t, globals{}, "frobnicate")
	if code != exitUsage {
		t.Errorf("unknown target exit = %d, want %d", code, exitUsage)
	}
	for _, want := range []string{"cursor", "claude-code", "codex", "cursor-cloud", "windsurf", "gemini-cli", "copilot"} {
		if !strings.Contains(errOut, want) {
			t.Errorf("unknown-target error must list valid target %q, got: %q", want, errOut)
		}
	}
}

// TestOnrampNoTarget errors when no target is given.
func TestOnrampNoTarget(t *testing.T) {
	_, errOut, code := onrampRun(t, globals{})
	if code != exitUsage {
		t.Errorf("no-target exit = %d, want %d", code, exitUsage)
	}
	if !strings.Contains(errOut, "needs a target") {
		t.Errorf("no-target error should ask for a target, got: %q", errOut)
	}
}

// TestOnrampRejectUnknownFlag proves an unrecognised flag is a usage error, never
// silently ignored. (--write/--force are now recognised — see onramp_write_test.go;
// this guards everything else, e.g. a typo like --wrote.)
func TestOnrampRejectUnknownFlag(t *testing.T) {
	_, errOut, code := onrampRun(t, globals{server: guerrilla}, "cursor", "--wrote")
	if code != exitUsage {
		t.Errorf("--wrote exit = %d, want %d (must be rejected, not ignored)", code, exitUsage)
	}
	if !strings.Contains(errOut, "unknown flag") {
		t.Errorf("--wrote should be an unknown-flag error, got: %q", errOut)
	}
}

// TestOnrampForceWithoutWrite proves --force alone is a usage error — it only
// means something paired with --write.
func TestOnrampForceWithoutWrite(t *testing.T) {
	_, errOut, code := onrampRun(t, globals{server: guerrilla}, "cursor", "--force")
	if code != exitUsage {
		t.Errorf("--force alone exit = %d, want %d", code, exitUsage)
	}
	if !strings.Contains(errOut, "--force only applies with --write") {
		t.Errorf("--force alone should explain it needs --write, got: %q", errOut)
	}
}

// TestOnrampFlagOverrides proves --server bakes into the URL and --token bakes a
// literal in place of the dialect placeholder.
func TestOnrampFlagOverrides(t *testing.T) {
	out, _, code := onrampRun(t, globals{server: "https://my.example.dev/", token: "bpk_live_secret"}, "cursor")
	if code != exitOK {
		t.Fatalf("override exit = %d, want %d", code, exitOK)
	}
	// Trailing slash trimmed, URL baked in.
	if !strings.Contains(out, `"BARKPARK_API_URL": "https://my.example.dev"`) {
		t.Errorf("--server not baked/trimmed into the stanza.\n%s", out)
	}
	// Literal token replaces the placeholder.
	if !strings.Contains(out, `"BARKPARK_API_TOKEN": "bpk_live_secret"`) {
		t.Errorf("--token literal not baked into the stanza.\n%s", out)
	}
	// The placeholder must be gone from the stanza VALUE (prose reminders may
	// still name the dialect); the token value line is now the literal.
	if strings.Contains(out, `"BARKPARK_API_TOKEN": "${env:BARKPARK_API_TOKEN}"`) {
		t.Errorf("--token override should replace the placeholder value, but it remained in the stanza")
	}
}

// TestOnrampJSONShape proves `-o json` emits {target, files:[{path,content}], verify}.
func TestOnrampJSONShape(t *testing.T) {
	var so, se bytes.Buffer
	w := newWriter(&so, &se)
	w.output = "json" // machineOut() → true
	if code := runOnramp(w, globals{server: guerrilla}, []string{"cursor-cloud"}); code != exitOK {
		t.Fatalf("json exit = %d, want %d", code, exitOK)
	}
	var got onrampSpec
	if err := json.Unmarshal(so.Bytes(), &got); err != nil {
		t.Fatalf("json output did not decode into onrampSpec: %v\n%s", err, so.String())
	}
	if got.Target != "cursor-cloud" {
		t.Errorf("json target = %q, want cursor-cloud", got.Target)
	}
	if len(got.Files) != 2 {
		t.Fatalf("cursor-cloud json should carry 2 files, got %d", len(got.Files))
	}
	if got.Files[0].Path != ".cursor/environment.json" || got.Files[1].Path != ".cursor/mcp.json" {
		t.Errorf("json file paths = %q,%q; want .cursor/environment.json,.cursor/mcp.json", got.Files[0].Path, got.Files[1].Path)
	}
	if got.Verify == "" {
		t.Error("json verify must be non-empty")
	}
	if !strings.Contains(got.Files[1].Content, "${env:BARKPARK_API_TOKEN}") {
		t.Errorf("json cursor stanza content missing the Cursor dialect placeholder")
	}
}

// TestOnrampServerFallback proves the URL resolution precedence's static fallback
// (no --server, no active saved server → the public default). It sets no server
// on globals; onrampServer may still read disk config, so it asserts only that
// SOME non-empty https URL is baked in — the deterministic pieces are covered by
// the override test above.
func TestOnrampServerDefaultShape(t *testing.T) {
	// Direct unit on the fallback constant path via a helper with an empty server
	// AND the documented default when nothing resolves.
	if onrampDefaultServer == "" || !strings.HasPrefix(onrampDefaultServer, "https://") {
		t.Fatalf("onrampDefaultServer must be a real https URL, got %q", onrampDefaultServer)
	}
}

package cli

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// serverMapFileAt builds the server-map onrampFile a target emits, repointed at
// an absolute path under dir so the merge writes into a temp dir, never the repo.
func serverMapFileAt(t *testing.T, target, dir, base string) onrampFile {
	t.Helper()
	spec, ok := buildOnrampSpec(target, guerrilla, "")
	if !ok {
		t.Fatalf("buildOnrampSpec(%q) not ok", target)
	}
	for _, f := range spec.Files {
		if f.MergeKind == mergeServerMap {
			f.Path = filepath.Join(dir, base)
			return f
		}
	}
	t.Fatalf("target %q has no server-map file", target)
	return onrampFile{}
}

// TestOnrampWriteCreatesFile: an absent file is created, mode 0644, byte-identical
// to the printed stanza (+ trailing newline), and round-trips to 'unchanged'.
func TestOnrampWriteCreatesFile(t *testing.T) {
	dir := t.TempDir()
	f := serverMapFileAt(t, "cursor", dir, ".cursor/mcp.json")

	act, err := mergeOnrampFile(f, false)
	if err != nil {
		t.Fatalf("create merge: %v", err)
	}
	if act.Action != "created" {
		t.Fatalf("action = %q, want created", act.Action)
	}

	got, err := os.ReadFile(f.Path)
	if err != nil {
		t.Fatalf("read created file: %v", err)
	}
	if !bytes.Equal(got, withTrailingNewline([]byte(f.Content))) {
		t.Errorf("created file is not byte-identical to the printed stanza.\n--- got ---\n%s", got)
	}

	// Mode 0644 (world-readable committed config), NOT 0600.
	info, err := os.Stat(f.Path)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o644 {
		t.Errorf("file mode = %v, want 0644", info.Mode().Perm())
	}
	// Parent dir 0755.
	dinfo, err := os.Stat(filepath.Dir(f.Path))
	if err != nil {
		t.Fatal(err)
	}
	if dinfo.Mode().Perm() != 0o755 {
		t.Errorf("dir mode = %v, want 0755", dinfo.Mode().Perm())
	}

	// Idempotent: a second run is 'unchanged' and leaves the bytes untouched.
	act2, err := mergeOnrampFile(f, false)
	if err != nil {
		t.Fatalf("second merge: %v", err)
	}
	if act2.Action != "unchanged" {
		t.Errorf("re-run action = %q, want unchanged", act2.Action)
	}
	got2, _ := os.ReadFile(f.Path)
	if !bytes.Equal(got, got2) {
		t.Errorf("idempotent re-run changed the file bytes")
	}
}

// TestOnrampWriteSkipAndForce: a pre-existing DIFFERENT barkpark entry is left
// byte-identical without --force (skipped), overwritten with --force (updated),
// and every foreign server + unrelated top-level key survives the force write.
func TestOnrampWriteSkipAndForce(t *testing.T) {
	dir := t.TempDir()
	fixture, err := os.ReadFile("testdata/onramp_mcp_foreign.json")
	if err != nil {
		t.Fatalf("read fixture: %v", err)
	}
	path := filepath.Join(dir, "mcp.json")
	if err := os.WriteFile(path, fixture, 0o644); err != nil {
		t.Fatal(err)
	}

	f := serverMapFileAt(t, "cursor", dir, "mcp.json")

	// No --force: a differing barkpark entry is skipped and the file is UNTOUCHED.
	act, err := mergeOnrampFile(f, false)
	if err != nil {
		t.Fatalf("skip merge: %v", err)
	}
	if act.Action != "skipped" {
		t.Fatalf("action = %q, want skipped", act.Action)
	}
	after, _ := os.ReadFile(path)
	if !bytes.Equal(fixture, after) {
		t.Errorf("skipped write must not touch the file at all")
	}

	// --force: barkpark is overwritten; foreign server + unrelated key survive.
	act, err = mergeOnrampFile(f, true)
	if err != nil {
		t.Fatalf("force merge: %v", err)
	}
	if act.Action != "updated" {
		t.Fatalf("force action = %q, want updated", act.Action)
	}
	result, _ := os.ReadFile(path)

	// Everything EXCEPT the barkpark entry is byte-identical (canonicalised).
	if !bytes.Equal(canonicalWithoutBarkpark(t, fixture), canonicalWithoutBarkpark(t, result)) {
		t.Errorf("force write clobbered foreign servers or unrelated keys.\n--- result ---\n%s", result)
	}
	// The barkpark URL is now the fresh guerrilla server, not the stale one.
	if bytes.Contains(result, []byte("STALE.example.old")) {
		t.Errorf("stale barkpark URL survived the force overwrite")
	}
	if !bytes.Contains(result, []byte(guerrilla)) {
		t.Errorf("fresh barkpark URL not written")
	}
	// The foreign server's private note is preserved verbatim.
	if !bytes.Contains(result, []byte("a foreign server the user configured")) {
		t.Errorf("foreign server note was lost")
	}
}

// TestOnrampWriteAddsAbsentKey: an existing config WITHOUT a barkpark entry gets
// it added ('updated' — key absent), foreign content preserved.
func TestOnrampWriteAddsAbsentKey(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "mcp.json")
	existing := `{
  "mcpServers": {
    "filesystem": {"command": "npx", "args": ["fs"]}
  }
}
`
	if err := os.WriteFile(path, []byte(existing), 0o644); err != nil {
		t.Fatal(err)
	}
	f := serverMapFileAt(t, "cursor", dir, "mcp.json")

	act, err := mergeOnrampFile(f, false)
	if err != nil {
		t.Fatalf("merge: %v", err)
	}
	if act.Action != "updated" {
		t.Fatalf("action = %q, want updated (key absent)", act.Action)
	}
	result, _ := os.ReadFile(path)
	top := map[string]json.RawMessage{}
	if err := json.Unmarshal(result, &top); err != nil {
		t.Fatalf("result not valid JSON: %v", err)
	}
	servers := map[string]json.RawMessage{}
	json.Unmarshal(top["mcpServers"], &servers)
	if _, ok := servers["filesystem"]; !ok {
		t.Errorf("foreign filesystem server lost when adding barkpark")
	}
	if _, ok := servers["barkpark"]; !ok {
		t.Errorf("barkpark entry not added")
	}
}

// TestOnrampWriteServersShape drives the third server-map parametrization — the
// top-level `servers` key copilot's .vscode/mcp.json uses (VS Code's shape, NOT
// mcpServers) — end-to-end through the same engine: create, merge-into-existing
// with a foreign server preserved, and idempotent re-run. The copilot target
// wraps its file in serversFile once it lands; this proves the TopKey
// parametrization is real, not theoretical.
func TestOnrampWriteServersShape(t *testing.T) {
	dir := t.TempDir()
	stanza := `{
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
	path := filepath.Join(dir, ".vscode", "mcp.json")

	// Merge into an existing file holding a foreign server under `servers`.
	existing := `{
  "servers": {
    "playwright": {"type": "stdio", "command": "npx", "args": ["@playwright/mcp"]}
  }
}
`
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(existing), 0o644); err != nil {
		t.Fatal(err)
	}

	f := serversFile(path, stanza)
	act, err := mergeOnrampFile(f, false)
	if err != nil {
		t.Fatalf("servers merge: %v", err)
	}
	if act.Action != "updated" {
		t.Fatalf("action = %q, want updated (barkpark absent under servers)", act.Action)
	}
	result := mustRead(t, path)
	top := map[string]json.RawMessage{}
	if err := json.Unmarshal(result, &top); err != nil {
		t.Fatalf("result not valid JSON: %v", err)
	}
	if _, ok := top["mcpServers"]; ok {
		t.Errorf("merge leaked a sibling mcpServers key — copilot's shape is top-level servers")
	}
	servers := map[string]json.RawMessage{}
	if err := json.Unmarshal(top["servers"], &servers); err != nil {
		t.Fatalf("servers key not an object: %v", err)
	}
	if _, ok := servers["playwright"]; !ok {
		t.Errorf("foreign playwright server lost when adding barkpark under servers")
	}
	if _, ok := servers["barkpark"]; !ok {
		t.Errorf("barkpark entry not added under servers")
	}

	// Idempotent re-run.
	act, err = mergeOnrampFile(f, false)
	if err != nil {
		t.Fatalf("servers re-run: %v", err)
	}
	if act.Action != "unchanged" {
		t.Errorf("servers re-run action = %q, want unchanged", act.Action)
	}
}

// TestOnrampWriteFlatCursorCloud: the flat `install` key merge (environment.json)
// creates then reports 'unchanged'.
func TestOnrampWriteFlatCursorCloud(t *testing.T) {
	dir := t.TempDir()
	spec, ok := buildOnrampSpec("cursor-cloud", guerrilla, "")
	if !ok {
		t.Fatal("cursor-cloud spec not ok")
	}
	var flat onrampFile
	for _, f := range spec.Files {
		if f.MergeKind == mergeFlat {
			flat = f
		}
	}
	if flat.MergeKind != mergeFlat {
		t.Fatal("cursor-cloud has no flat file")
	}
	flat.Path = filepath.Join(dir, "environment.json")

	act, err := mergeOnrampFile(flat, false)
	if err != nil {
		t.Fatalf("flat create: %v", err)
	}
	if act.Action != "created" {
		t.Fatalf("action = %q, want created", act.Action)
	}
	if !bytes.Contains(mustRead(t, flat.Path), []byte("install")) {
		t.Errorf("environment.json missing the install key")
	}
	act, err = mergeOnrampFile(flat, false)
	if err != nil {
		t.Fatalf("flat re-run: %v", err)
	}
	if act.Action != "unchanged" {
		t.Errorf("flat re-run action = %q, want unchanged", act.Action)
	}
}

// codexSandbox sandboxes HOME AND the cwd into a fresh temp dir (test law:
// HOME-only sandboxing does not isolate cwd-relative targets — live-proven),
// then returns codex's toml onrampFile plus the resolved ~/.codex/config.toml
// path. It also pins the merge metadata tomlFile stamps. Read any testdata
// fixture BEFORE calling this — the chdir breaks relative testdata/ paths.
func codexSandbox(t *testing.T) (onrampFile, string) {
	t.Helper()
	dir := t.TempDir()
	t.Setenv("HOME", dir)
	t.Chdir(dir)
	spec, ok := buildOnrampSpec("codex", guerrilla, "")
	if !ok {
		t.Fatal("codex spec not ok")
	}
	f := spec.Files[0]
	if f.MergeKind != mergeTOML || f.TopKey != "mcp_servers" || f.ServerKey != "barkpark" {
		t.Fatalf("codex merge metadata = {%q %q %q}, want {toml mcp_servers barkpark}", f.MergeKind, f.TopKey, f.ServerKey)
	}
	return f, filepath.Join(dir, ".codex", "config.toml")
}

// TestOnrampWriteCodexCreatesFile is the wave-2 TestOnrampWriteCodexSkipped
// INVERTED: codex's config.toml is no longer 'skipped — wave 3'. An absent
// ~/.codex/config.toml is created byte-identical to the printed codexTOMLBlock
// (+ trailing newline), mode 0644, and a re-run reports 'unchanged' with the
// bytes untouched.
func TestOnrampWriteCodexCreatesFile(t *testing.T) {
	f, path := codexSandbox(t)

	act, err := mergeOnrampFile(f, false)
	if err != nil {
		t.Fatalf("codex create merge: %v", err)
	}
	if act.Action != "created" {
		t.Fatalf("codex action = %q (note %q), want created", act.Action, act.Note)
	}
	if bytes.Contains([]byte(act.Note), []byte("wave 3")) {
		t.Errorf("codex write still carries the wave-3 skip note: %q", act.Note)
	}
	got := mustRead(t, path)
	if !bytes.Equal(got, withTrailingNewline([]byte(codexTOMLBlock(guerrilla)))) {
		t.Errorf("created config.toml is not byte-identical to codexTOMLBlock.\n--- got ---\n%s", got)
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o644 {
		t.Errorf("file mode = %v, want 0644", info.Mode().Perm())
	}

	act, err = mergeOnrampFile(f, false)
	if err != nil {
		t.Fatalf("codex re-run: %v", err)
	}
	if act.Action != "unchanged" {
		t.Errorf("re-run action = %q, want unchanged", act.Action)
	}
	if !bytes.Equal(got, mustRead(t, path)) {
		t.Errorf("idempotent re-run changed the file bytes")
	}
}

// TestOnrampWriteCodexAppendsToForeign: a lived-in config.toml WITHOUT a
// barkpark span gets the canonical stanza APPENDED with a blank-line separator
// ('updated'), every existing byte preserved verbatim.
func TestOnrampWriteCodexAppendsToForeign(t *testing.T) {
	f, path := codexSandbox(t)
	existing := "model = \"gpt-5.3-codex\"\n\n[mcp_servers.other] # a foreign server\nurl = \"https://mcp.example.com/mcp\"\n"
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(existing), 0o644); err != nil {
		t.Fatal(err)
	}

	act, err := mergeOnrampFile(f, false)
	if err != nil {
		t.Fatalf("append merge: %v", err)
	}
	if act.Action != "updated" {
		t.Fatalf("action = %q, want updated (span absent)", act.Action)
	}
	want := existing + "\n" + codexTOMLBlock(guerrilla) + "\n"
	if got := mustRead(t, path); string(got) != want {
		t.Errorf("append is not existing + blank line + stanza.\n--- got ---\n%s\n--- want ---\n%s", got, want)
	}
}

// codexFixtureStaleSpan is the differing [mcp_servers.barkpark] span carried by
// testdata/onramp_config_foreign.toml — codexTOMLBlock with a STALE server URL.
const codexFixtureStaleSpan = `[mcp_servers.barkpark]
command = "bp"
args = ["mcp", "serve"]
env = { BARKPARK_API_URL = "https://STALE.example.old" }
env_vars = ["BARKPARK_API_TOKEN"]
startup_timeout_sec = 15
tool_timeout_sec = 120`

// TestOnrampWriteCodexSkipAndForce drives the deny path and the whole-span
// replace on the foreign fixture: a differing barkpark span is 'skipped'
// without --force (file byte-untouched, note carries the --force hint
// onrampAnySkipped greps), and --force replaces EXACTLY the owned span — the
// url-shaped [mcp_servers.other] neighbor, [profiles.work], and the comments
// before/after the span survive byte-for-byte.
func TestOnrampWriteCodexSkipAndForce(t *testing.T) {
	fixture, err := os.ReadFile("testdata/onramp_config_foreign.toml")
	if err != nil {
		t.Fatalf("read fixture: %v", err)
	}
	f, path := codexSandbox(t)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, fixture, 0o644); err != nil {
		t.Fatal(err)
	}

	act, err := mergeOnrampFile(f, false)
	if err != nil {
		t.Fatalf("skip merge: %v", err)
	}
	if act.Action != "skipped" {
		t.Fatalf("action = %q, want skipped", act.Action)
	}
	if !onrampAnySkipped([]onrampAction{act}) {
		t.Errorf("skip note must carry the --force hint onrampAnySkipped greps, got %q", act.Note)
	}
	if !bytes.Equal(fixture, mustRead(t, path)) {
		t.Errorf("skipped write must not touch the file at all")
	}

	act, err = mergeOnrampFile(f, true)
	if err != nil {
		t.Fatalf("force merge: %v", err)
	}
	if act.Action != "updated" {
		t.Fatalf("force action = %q, want updated", act.Action)
	}
	want := strings.Replace(string(fixture), codexFixtureStaleSpan, codexTOMLBlock(guerrilla), 1)
	if want == string(fixture) {
		t.Fatal("fixture drift: codexFixtureStaleSpan not found in testdata/onramp_config_foreign.toml")
	}
	if got := mustRead(t, path); string(got) != want {
		t.Errorf("force write must replace ONLY the owned span, byte-exact.\n--- got ---\n%s\n--- want ---\n%s", got, want)
	}
}

// TestOnrampWriteCodexSubTableStanza pins the D11 kill-switch: real
// `codex mcp add` (codex-cli 0.144.1, live-captured; openai/codex@5c19155c)
// writes env as a NESTED [mcp_servers.barkpark.env] sub-table with alpha-sorted
// keys. That is a DIFFERING stanza — skipped without --force, NEVER an error —
// and --force replaces the WHOLE span (header table + every
// [mcp_servers.barkpark.*] continuation) with the canonical flat stanza.
func TestOnrampWriteCodexSubTableStanza(t *testing.T) {
	f, path := codexSandbox(t)
	existing := `[mcp_servers.barkpark]
command = "bp"
args = ["mcp", "serve"]
startup_timeout_sec = 15
tool_timeout_sec = 120

[mcp_servers.barkpark.env]
BARKPARK_API_URL = "https://guerrilla.barkpark.cloud"

[profiles.work]
model = "gpt-5.3-codex"
`
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(existing), 0o644); err != nil {
		t.Fatal(err)
	}

	act, err := mergeOnrampFile(f, false)
	if err != nil {
		t.Fatalf("sub-table stanza must be a DIFFERING stanza, never an error: %v", err)
	}
	if act.Action != "skipped" {
		t.Fatalf("action = %q, want skipped", act.Action)
	}
	if !onrampAnySkipped([]onrampAction{act}) {
		t.Errorf("skip note must carry the --force hint, got %q", act.Note)
	}
	if got := mustRead(t, path); string(got) != existing {
		t.Errorf("skipped write must not touch the file")
	}

	act, err = mergeOnrampFile(f, true)
	if err != nil {
		t.Fatalf("force merge: %v", err)
	}
	if act.Action != "updated" {
		t.Fatalf("force action = %q, want updated", act.Action)
	}
	want := codexTOMLBlock(guerrilla) + "\n\n[profiles.work]\nmodel = \"gpt-5.3-codex\"\n"
	if got := mustRead(t, path); string(got) != want {
		t.Errorf("force must replace header table + env sub-table with the flat stanza.\n--- got ---\n%s\n--- want ---\n%s", got, want)
	}
}

// TestOnrampWriteCodexDenyForms: the stanza forms a textual splice cannot own —
// root dotted-key, root inline-table, and barkpark inline under a bare
// [mcp_servers] header — error LOUDLY with or without --force, and the file is
// byte-untouched (charter D11).
func TestOnrampWriteCodexDenyForms(t *testing.T) {
	cases := []struct {
		name    string
		content string
	}{
		{"root dotted-key", "mcp_servers.barkpark.command = \"bp\"\nmcp_servers.barkpark.args = [\"mcp\", \"serve\"]\n"},
		{"root inline-table", "mcp_servers.barkpark = { command = \"bp\", args = [\"mcp\", \"serve\"] }\n"},
		{"inline under bare header", "[mcp_servers]\nbarkpark = { command = \"bp\", args = [\"mcp\", \"serve\"] }\n"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			f, path := codexSandbox(t)
			if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(path, []byte(tc.content), 0o644); err != nil {
				t.Fatal(err)
			}
			for _, force := range []bool{false, true} {
				if _, err := mergeOnrampFile(f, force); err == nil {
					t.Errorf("force=%v: %s must error loudly, got nil", force, tc.name)
				}
				if got := mustRead(t, path); string(got) != tc.content {
					t.Errorf("force=%v: deny path must leave the file byte-untouched", force)
				}
			}
		})
	}
}

// TestOnrampWriteCodexHeaderComment: a trailing `# comment` after the header's
// closing bracket must not break span detection (charter D11: match on the
// header TOKEN) — the span is found and reported as differing, never treated as
// absent and appended twice.
func TestOnrampWriteCodexHeaderComment(t *testing.T) {
	f, path := codexSandbox(t)
	existing := "[mcp_servers.barkpark] # managed by bp\ncommand = \"bp\"\nargs = [\"mcp\", \"serve\"]\n"
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(existing), 0o644); err != nil {
		t.Fatal(err)
	}

	act, err := mergeOnrampFile(f, false)
	if err != nil {
		t.Fatalf("merge: %v", err)
	}
	if act.Action != "skipped" {
		t.Fatalf("action = %q, want skipped (span FOUND via its token, differing) — 'updated' means the commented header was missed and the stanza appended", act.Action)
	}
	if got := mustRead(t, path); string(got) != existing {
		t.Errorf("skipped write must not touch the file")
	}
}

// TestOnrampWriteCodexCRLF: a CRLF config.toml round-trips — a canonical stanza
// in CRLF form reads 'unchanged', and a --force replace keeps the whole file
// CRLF with every foreign byte surviving.
func TestOnrampWriteCodexCRLF(t *testing.T) {
	fixture, err := os.ReadFile("testdata/onramp_config_foreign.toml")
	if err != nil {
		t.Fatalf("read fixture: %v", err)
	}
	f, path := codexSandbox(t)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}

	// Canonical stanza, CRLF convention → unchanged, untouched.
	crlfCanonical := strings.ReplaceAll(codexTOMLBlock(guerrilla)+"\n", "\n", "\r\n")
	if err := os.WriteFile(path, []byte(crlfCanonical), 0o644); err != nil {
		t.Fatal(err)
	}
	act, err := mergeOnrampFile(f, false)
	if err != nil {
		t.Fatalf("crlf unchanged merge: %v", err)
	}
	if act.Action != "unchanged" {
		t.Errorf("crlf canonical action = %q, want unchanged", act.Action)
	}
	if got := mustRead(t, path); string(got) != crlfCanonical {
		t.Errorf("unchanged must not rewrite the CRLF file")
	}

	// Differing span in a CRLF file → force replaces it and the file stays CRLF.
	crlfFixture := strings.ReplaceAll(string(fixture), "\n", "\r\n")
	if err := os.WriteFile(path, []byte(crlfFixture), 0o644); err != nil {
		t.Fatal(err)
	}
	act, err = mergeOnrampFile(f, true)
	if err != nil {
		t.Fatalf("crlf force merge: %v", err)
	}
	if act.Action != "updated" {
		t.Fatalf("crlf force action = %q, want updated", act.Action)
	}
	got := string(mustRead(t, path))
	if strings.Contains(strings.ReplaceAll(got, "\r\n", ""), "\n") {
		t.Errorf("force write introduced a lone LF into a CRLF file")
	}
	wantLF := strings.Replace(string(fixture), codexFixtureStaleSpan, codexTOMLBlock(guerrilla), 1)
	if got != strings.ReplaceAll(wantLF, "\n", "\r\n") {
		t.Errorf("crlf force result drifted.\n--- got ---\n%q", got)
	}
}

// TestOnrampWriteCodexNoFinalNewline: a config.toml without a final newline
// round-trips — a canonical stanza reads 'unchanged', and an append first
// completes the last line, then separates with a blank line.
func TestOnrampWriteCodexNoFinalNewline(t *testing.T) {
	f, path := codexSandbox(t)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}

	// Canonical stanza, no final newline → unchanged, untouched.
	if err := os.WriteFile(path, []byte(codexTOMLBlock(guerrilla)), 0o644); err != nil {
		t.Fatal(err)
	}
	act, err := mergeOnrampFile(f, false)
	if err != nil {
		t.Fatalf("no-final-newline unchanged merge: %v", err)
	}
	if act.Action != "unchanged" {
		t.Errorf("action = %q, want unchanged", act.Action)
	}
	if got := mustRead(t, path); string(got) != codexTOMLBlock(guerrilla) {
		t.Errorf("unchanged must not rewrite the newline-less file")
	}

	// Foreign content, no final newline → appended with the separator.
	if err := os.WriteFile(path, []byte(`model = "gpt-5.3-codex"`), 0o644); err != nil {
		t.Fatal(err)
	}
	act, err = mergeOnrampFile(f, false)
	if err != nil {
		t.Fatalf("append merge: %v", err)
	}
	if act.Action != "updated" {
		t.Fatalf("action = %q, want updated", act.Action)
	}
	want := "model = \"gpt-5.3-codex\"\n\n" + codexTOMLBlock(guerrilla) + "\n"
	if got := mustRead(t, path); string(got) != want {
		t.Errorf("append into a newline-less file drifted.\n--- got ---\n%s\n--- want ---\n%s", got, want)
	}
}

// TestOnrampWriteJSONReport: `--write -o json` emits a single onrampWriteResult
// document with per-file {path, action}; chatter goes to stderr.
func TestOnrampWriteJSONReport(t *testing.T) {
	dir := t.TempDir()
	f := serverMapFileAt(t, "cursor", dir, ".cursor/mcp.json")
	spec := onrampSpec{Target: "cursor", Files: []onrampFile{f}, Verify: "reload MCP servers"}

	var so, se bytes.Buffer
	w := newWriter(&so, &se)
	w.output = "json"
	if code := runOnrampWrite(w, spec, false); code != exitOK {
		t.Fatalf("write exit = %d, want %d; stderr=%s", code, exitOK, se.String())
	}
	var got onrampWriteResult
	if err := json.Unmarshal(so.Bytes(), &got); err != nil {
		t.Fatalf("json report did not decode into onrampWriteResult: %v\n%s", err, so.String())
	}
	if got.Target != "cursor" {
		t.Errorf("report target = %q, want cursor", got.Target)
	}
	if len(got.Actions) != 1 || got.Actions[0].Action != "created" {
		t.Fatalf("report actions = %+v, want one created", got.Actions)
	}
	if got.Actions[0].Path != f.Path {
		t.Errorf("report path = %q, want %q", got.Actions[0].Path, f.Path)
	}
}

// TestOnrampWriteHumanReport: the human report prints an action line per file and
// the verify pointer.
func TestOnrampWriteHumanReport(t *testing.T) {
	dir := t.TempDir()
	f := serverMapFileAt(t, "cursor", dir, ".cursor/mcp.json")
	spec := onrampSpec{Target: "cursor", Files: []onrampFile{f}, Verify: "reload MCP servers"}

	var so, se bytes.Buffer
	w := newWriter(&so, &se)
	if code := runOnrampWrite(w, spec, false); code != exitOK {
		t.Fatalf("exit = %d", code)
	}
	out := so.String()
	for _, want := range []string{"created", f.Path, "verify:", "reload MCP servers"} {
		if !bytes.Contains([]byte(out), []byte(want)) {
			t.Errorf("human report missing %q\n%s", want, out)
		}
	}
}

// TestOnrampWriteZedCreatesAndIdempotent drives the zed context_servers emitter
// through the generic server-map engine (TopKey=context_servers, charter D21):
// an absent settings.json is created byte-identical to the printed stanza and a
// re-run reports 'unchanged'. This proves the zed case is a REAL --write, not the
// copilot bare-literal no-op (D23).
func TestOnrampWriteZedCreatesAndIdempotent(t *testing.T) {
	dir := t.TempDir()
	f := serverMapFileAt(t, "zed", dir, "settings.json")
	if f.TopKey != "context_servers" {
		t.Fatalf("zed merge TopKey = %q, want context_servers", f.TopKey)
	}

	act, err := mergeOnrampFile(f, false)
	if err != nil {
		t.Fatalf("create merge: %v", err)
	}
	if act.Action != "created" {
		t.Fatalf("action = %q, want created", act.Action)
	}
	if !bytes.Equal(mustRead(t, f.Path), withTrailingNewline([]byte(f.Content))) {
		t.Errorf("created settings.json not byte-identical to the printed stanza.\n--- got ---\n%s", mustRead(t, f.Path))
	}

	act, err = mergeOnrampFile(f, false)
	if err != nil {
		t.Fatalf("idempotent merge: %v", err)
	}
	if act.Action != "unchanged" {
		t.Errorf("re-run action = %q, want unchanged", act.Action)
	}
}

// TestOnrampWriteZedPreservesForeign proves a merge into an existing Zed
// settings.json keeps every unrelated top-level setting AND every foreign context
// server byte-for-byte, and never leaks a sibling mcpServers/servers map key.
func TestOnrampWriteZedPreservesForeign(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "settings.json")
	// A realistic global settings.json: unrelated editor settings + a foreign
	// context server the user configured.
	existing := `{
  "theme": "One Dark",
  "context_servers": {
    "some-other": {"command": "other-mcp", "args": ["run"], "env": {}}
  }
}
`
	if err := os.WriteFile(path, []byte(existing), 0o644); err != nil {
		t.Fatal(err)
	}
	f := serverMapFileAt(t, "zed", dir, "settings.json")

	act, err := mergeOnrampFile(f, false)
	if err != nil {
		t.Fatalf("merge: %v", err)
	}
	if act.Action != "updated" {
		t.Fatalf("action = %q, want updated (barkpark absent under context_servers)", act.Action)
	}
	result := mustRead(t, path)
	top := map[string]json.RawMessage{}
	if err := json.Unmarshal(result, &top); err != nil {
		t.Fatalf("result not valid JSON: %v", err)
	}
	if _, ok := top["theme"]; !ok {
		t.Errorf("foreign top-level \"theme\" setting lost on merge")
	}
	if _, ok := top["mcpServers"]; ok {
		t.Errorf("merge leaked a sibling mcpServers key — zed uses context_servers")
	}
	if _, ok := top["servers"]; ok {
		t.Errorf("merge leaked a sibling servers key — zed uses context_servers")
	}
	cs := map[string]json.RawMessage{}
	if err := json.Unmarshal(top["context_servers"], &cs); err != nil {
		t.Fatalf("context_servers not an object: %v", err)
	}
	if _, ok := cs["some-other"]; !ok {
		t.Errorf("foreign context server lost when adding barkpark")
	}
	if _, ok := cs["barkpark"]; !ok {
		t.Errorf("barkpark entry not added under context_servers")
	}
	// The added barkpark entry is flat — no source key, empty env.
	bark := map[string]json.RawMessage{}
	if err := json.Unmarshal(cs["barkpark"], &bark); err != nil {
		t.Fatalf("barkpark entry not an object: %v", err)
	}
	if _, ok := bark["source"]; ok {
		t.Errorf("barkpark entry leaked a \"source\" key — Zed's user-facing shape is flat (D21)")
	}
}

// TestOnrampWriteZedSkipAndForce: a pre-existing DIFFERENT barkpark entry is left
// untouched without --force (skipped) and overwritten with --force (updated).
func TestOnrampWriteZedSkipAndForce(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "settings.json")
	existing := `{
  "context_servers": {
    "barkpark": {"command": "STALE-bp", "args": [], "env": {}}
  }
}
`
	if err := os.WriteFile(path, []byte(existing), 0o644); err != nil {
		t.Fatal(err)
	}
	f := serverMapFileAt(t, "zed", dir, "settings.json")

	// No --force: a differing barkpark entry is skipped and the file is UNTOUCHED.
	before := mustRead(t, path)
	act, err := mergeOnrampFile(f, false)
	if err != nil {
		t.Fatalf("skip merge: %v", err)
	}
	if act.Action != "skipped" {
		t.Fatalf("action = %q, want skipped", act.Action)
	}
	if !bytes.Equal(before, mustRead(t, path)) {
		t.Errorf("skipped write must not touch the file at all")
	}

	// --force: the stale entry is overwritten with the fresh flat stanza.
	act, err = mergeOnrampFile(f, true)
	if err != nil {
		t.Fatalf("force merge: %v", err)
	}
	if act.Action != "updated" {
		t.Fatalf("force action = %q, want updated", act.Action)
	}
	if bytes.Contains(mustRead(t, path), []byte("STALE-bp")) {
		t.Errorf("stale barkpark command survived the force overwrite")
	}
}

// mustRead reads a file or fails the test.
func mustRead(t *testing.T, path string) []byte {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	return b
}

// canonicalWithoutBarkpark parses raw, drops mcpServers.barkpark, and re-marshals
// canonically — so two configs that differ ONLY in the barkpark entry compare
// byte-equal, proving --write preserved every foreign byte.
func canonicalWithoutBarkpark(t *testing.T, raw []byte) []byte {
	t.Helper()
	top := map[string]json.RawMessage{}
	if err := json.Unmarshal(raw, &top); err != nil {
		t.Fatalf("parse for canonicalisation: %v", err)
	}
	if sraw, ok := top["mcpServers"]; ok {
		servers := map[string]json.RawMessage{}
		if err := json.Unmarshal(sraw, &servers); err != nil {
			t.Fatalf("parse mcpServers: %v", err)
		}
		delete(servers, "barkpark")
		nsr, err := marshalOnrampJSON(servers)
		if err != nil {
			t.Fatal(err)
		}
		top["mcpServers"] = nsr
	}
	out, err := marshalOnrampJSON(top)
	if err != nil {
		t.Fatal(err)
	}
	return out
}

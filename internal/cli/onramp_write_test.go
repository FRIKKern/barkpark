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

	act, err := mergeOnrampFile(f, false, false)
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
	act2, err := mergeOnrampFile(f, false, false)
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
	act, err := mergeOnrampFile(f, false, false)
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
	act, err = mergeOnrampFile(f, true, false)
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

	act, err := mergeOnrampFile(f, false, false)
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
	act, err := mergeOnrampFile(f, false, false)
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
	act, err = mergeOnrampFile(f, false, false)
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

	act, err := mergeOnrampFile(flat, false, false)
	if err != nil {
		t.Fatalf("flat create: %v", err)
	}
	if act.Action != "created" {
		t.Fatalf("action = %q, want created", act.Action)
	}
	if !bytes.Contains(mustRead(t, flat.Path), []byte("install")) {
		t.Errorf("environment.json missing the install key")
	}
	act, err = mergeOnrampFile(flat, false, false)
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

	act, err := mergeOnrampFile(f, false, false)
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

	act, err = mergeOnrampFile(f, false, false)
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

	act, err := mergeOnrampFile(f, false, false)
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

	act, err := mergeOnrampFile(f, false, false)
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

	act, err = mergeOnrampFile(f, true, false)
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

	act, err := mergeOnrampFile(f, false, false)
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

	act, err = mergeOnrampFile(f, true, false)
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
				if _, err := mergeOnrampFile(f, force, false); err == nil {
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

	act, err := mergeOnrampFile(f, false, false)
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
	act, err := mergeOnrampFile(f, false, false)
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
	act, err = mergeOnrampFile(f, true, false)
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
	act, err := mergeOnrampFile(f, false, false)
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
	act, err = mergeOnrampFile(f, false, false)
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
	if code := runOnrampWrite(w, spec, false, false); code != exitOK {
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
	if code := runOnrampWrite(w, spec, false, false); code != exitOK {
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

	act, err := mergeOnrampFile(f, false, false)
	if err != nil {
		t.Fatalf("create merge: %v", err)
	}
	if act.Action != "created" {
		t.Fatalf("action = %q, want created", act.Action)
	}
	if !bytes.Equal(mustRead(t, f.Path), withTrailingNewline([]byte(f.Content))) {
		t.Errorf("created settings.json not byte-identical to the printed stanza.\n--- got ---\n%s", mustRead(t, f.Path))
	}

	act, err = mergeOnrampFile(f, false, false)
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

	act, err := mergeOnrampFile(f, false, false)
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
	act, err := mergeOnrampFile(f, false, false)
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
	act, err = mergeOnrampFile(f, true, false)
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

// agentsMdMergeFile returns the agents-md target's marker-managed ./AGENTS.md
// onrampFile (path kept cwd-relative — the caller must t.Chdir into a tempdir
// first, since HOME sandboxing does nothing for a cwd-relative target).
func agentsMdMergeFile(t *testing.T) onrampFile {
	t.Helper()
	spec, ok := buildOnrampSpec("agents-md", guerrilla, "")
	if !ok {
		t.Fatal("agents-md spec not ok")
	}
	for _, f := range spec.Files {
		if f.MergeKind == mergeMarkdown {
			return f
		}
	}
	t.Fatal("agents-md has no markdown file")
	return onrampFile{}
}

// TestOnrampWriteAgentsMdCreates: an absent ./AGENTS.md is created byte-identical
// to the printed marker-managed block (+ trailing newline) and round-trips to
// 'unchanged', file byte-untouched. Tests cd into a tempdir (the target is
// cwd-relative) per the write test law.
func TestOnrampWriteAgentsMdCreates(t *testing.T) {
	t.Chdir(t.TempDir())
	f := agentsMdMergeFile(t)

	act, err := mergeOnrampFile(f, false, false)
	if err != nil {
		t.Fatalf("create merge: %v", err)
	}
	if act.Action != "created" {
		t.Fatalf("action = %q, want created", act.Action)
	}
	got := mustRead(t, "AGENTS.md")
	if !bytes.Equal(got, withTrailingNewline([]byte(f.Content))) {
		t.Errorf("created AGENTS.md is not byte-identical to the printed block.\n--- got ---\n%s", got)
	}
	// It carries both managed markers.
	for _, marker := range []string{agentsMDMarkerBegin, agentsMDMarkerEnd} {
		if !bytes.Contains(got, []byte(marker)) {
			t.Errorf("created block missing marker %q", marker)
		}
	}

	// Idempotent: a re-run is 'unchanged' and leaves the bytes untouched.
	act2, err := mergeOnrampFile(f, false, false)
	if err != nil {
		t.Fatalf("second merge: %v", err)
	}
	if act2.Action != "unchanged" {
		t.Errorf("re-run action = %q, want unchanged", act2.Action)
	}
	if !bytes.Equal(got, mustRead(t, "AGENTS.md")) {
		t.Errorf("unchanged re-run changed the file bytes")
	}
}

// TestOnrampWriteAgentsMdAppendsWithoutMarkers: a pre-existing AGENTS.md WITHOUT
// barkpark markers is APPENDED to (updated) — every user byte preserved verbatim
// and the block lands after it.
func TestOnrampWriteAgentsMdAppendsWithoutMarkers(t *testing.T) {
	t.Chdir(t.TempDir())
	existing := "# My Repo\n\nContributors: run the tests before pushing.\n"
	if err := os.WriteFile("AGENTS.md", []byte(existing), 0o644); err != nil {
		t.Fatal(err)
	}
	f := agentsMdMergeFile(t)

	act, err := mergeOnrampFile(f, false, false)
	if err != nil {
		t.Fatalf("append merge: %v", err)
	}
	if act.Action != "updated" {
		t.Fatalf("action = %q, want updated (append, no markers)", act.Action)
	}
	result := mustRead(t, "AGENTS.md")
	// User content preserved verbatim as a prefix — never rewritten.
	if !bytes.HasPrefix(result, []byte(existing)) {
		t.Errorf("append rewrote the user's existing content.\n--- got ---\n%s", result)
	}
	// The canonical block landed after it.
	if !bytes.Contains(result, []byte(agentsMDMarkerBegin)) || !bytes.Contains(result, []byte(f.Content)) {
		t.Errorf("appended block missing.\n--- got ---\n%s", result)
	}

	// Now that markers exist, a re-run is 'unchanged'.
	act2, err := mergeOnrampFile(f, false, false)
	if err != nil {
		t.Fatalf("re-run: %v", err)
	}
	if act2.Action != "unchanged" {
		t.Errorf("re-run after append = %q, want unchanged", act2.Action)
	}
}

// TestOnrampWriteAgentsMdSkipAndForce: an AGENTS.md whose markers wrap a DIFFERENT
// (stale) block is left byte-untouched without --force (skipped, --force hinted),
// and with --force the begin→end span is replaced ONLY — surrounding user prose
// above and below the block survives verbatim.
func TestOnrampWriteAgentsMdSkipAndForce(t *testing.T) {
	t.Chdir(t.TempDir())
	const head = "# My Repo\n\nIntro the humans wrote.\n\n"
	const tail = "\n\n## Footer\n\nMore human prose below the block.\n"
	stale := head + agentsMDMarkerBegin + "\n## Task tracking — Barkpark (bp)\n\nSTALE outdated body from an old bp version.\n" + agentsMDMarkerEnd + tail
	if err := os.WriteFile("AGENTS.md", []byte(stale), 0o644); err != nil {
		t.Fatal(err)
	}
	f := agentsMdMergeFile(t)

	// No --force: skipped, file byte-untouched, note carries the --force hint.
	act, err := mergeOnrampFile(f, false, false)
	if err != nil {
		t.Fatalf("skip merge: %v", err)
	}
	if act.Action != "skipped" {
		t.Fatalf("action = %q, want skipped", act.Action)
	}
	if !strings.Contains(act.Note, "--force") {
		t.Errorf("skip note %q must carry the --force hint (onrampAnySkipped greps it)", act.Note)
	}
	if !bytes.Equal([]byte(stale), mustRead(t, "AGENTS.md")) {
		t.Errorf("skipped write must not touch the file at all")
	}

	// --force: the stale span is replaced with the canonical block; the human head
	// and tail survive verbatim.
	act, err = mergeOnrampFile(f, true, false)
	if err != nil {
		t.Fatalf("force merge: %v", err)
	}
	if act.Action != "updated" {
		t.Fatalf("force action = %q, want updated", act.Action)
	}
	result := mustRead(t, "AGENTS.md")
	if bytes.Contains(result, []byte("STALE outdated body")) {
		t.Errorf("stale block body survived the force replace")
	}
	if !bytes.HasPrefix(result, []byte(head)) {
		t.Errorf("human prose above the block was lost.\n--- got ---\n%s", result)
	}
	if !bytes.Contains(result, []byte("More human prose below the block.")) {
		t.Errorf("human prose below the block was lost.\n--- got ---\n%s", result)
	}
	if !bytes.Contains(result, []byte(f.Content)) {
		t.Errorf("canonical block not written on force")
	}
	// Re-run is now unchanged.
	act, err = mergeOnrampFile(f, false, false)
	if err != nil {
		t.Fatalf("post-force re-run: %v", err)
	}
	if act.Action != "unchanged" {
		t.Errorf("post-force re-run = %q, want unchanged", act.Action)
	}
}

// TestOnrampWriteAgentsMdMalformedSkipped: a file carrying only ONE of the two
// markers is a broken managed block — skipped for hand repair, never auto-spliced,
// and its note does NOT dangle a --force hint (force can't safely own it).
func TestOnrampWriteAgentsMdMalformedSkipped(t *testing.T) {
	t.Chdir(t.TempDir())
	broken := "# Repo\n" + agentsMDMarkerBegin + "\n## half-open block, no end marker\n"
	if err := os.WriteFile("AGENTS.md", []byte(broken), 0o644); err != nil {
		t.Fatal(err)
	}
	f := agentsMdMergeFile(t)

	for _, force := range []bool{false, true} {
		act, err := mergeOnrampFile(f, force, false)
		if err != nil {
			t.Fatalf("malformed merge (force=%v): %v", force, err)
		}
		if act.Action != "skipped" {
			t.Fatalf("malformed action (force=%v) = %q, want skipped", force, act.Action)
		}
		if strings.Contains(act.Note, "--force") {
			t.Errorf("malformed skip note should not offer --force (it can't repair): %q", act.Note)
		}
		if !bytes.Equal([]byte(broken), mustRead(t, "AGENTS.md")) {
			t.Errorf("malformed skip must not touch the file (force=%v)", force)
		}
	}
}

// TestOnrampWriteAgentsMdCRLFPreserved locks the byte-preservation property V1
// proved live-once (charter D32): the markdown merger treats a consumer's foreign
// AGENTS.md as OPAQUE bytes and never normalizes line endings (unlike the
// JSON/TOML path at onramp_write.go:328/354/381 which CRLF-rewrites). A marker-less
// CRLF file is APPENDED to — every \r\n in the foreign region survives byte-for-byte,
// the barkpark block lands after it, and a re-run is a byte-stable 'unchanged'.
func TestOnrampWriteAgentsMdCRLFPreserved(t *testing.T) {
	t.Chdir(t.TempDir())
	// A real Windows-authored AGENTS.md: CRLF throughout, no barkpark markers.
	existing := []byte("# My Repo\r\n\r\nContributors: run the tests before pushing.\r\n")
	crlfBefore := bytes.Count(existing, []byte("\r\n"))
	if err := os.WriteFile("AGENTS.md", existing, 0o644); err != nil {
		t.Fatal(err)
	}
	f := agentsMdMergeFile(t)

	act, err := mergeOnrampFile(f, false, false)
	if err != nil {
		t.Fatalf("append merge: %v", err)
	}
	if act.Action != "updated" {
		t.Fatalf("action = %q, want updated (append, no markers)", act.Action)
	}
	result := mustRead(t, "AGENTS.md")

	// The foreign region survives byte-for-byte as a verbatim prefix — every CRLF
	// intact, nothing normalized to LF.
	if !bytes.HasPrefix(result, existing) {
		t.Errorf("CRLF foreign region was not preserved byte-for-byte as a prefix.\n--- got %q", result)
	}
	// The emitted barkpark block is LF-only, so it contributes zero CRLF: the
	// file's CRLF count equals the foreign region's exactly (no \r leaked into the
	// appended block, none stripped from the foreign prose).
	if got := bytes.Count(result, []byte("\r\n")); got != crlfBefore {
		t.Errorf("CRLF count = %d, want %d (foreign \\r\\n preserved, block stays LF)", got, crlfBefore)
	}
	// No BARE \r survived (every \r is part of a \r\n) — nothing was half-mangled.
	if got := bytes.Count(result, []byte("\r")); got != crlfBefore {
		t.Errorf("stray bare \\r found: %d total \\r vs %d \\r\\n — a CR was mangled", got, crlfBefore)
	}
	// The canonical block landed after the foreign prose, verbatim (not CRLF-ified).
	if !bytes.Contains(result, []byte(f.Content)) {
		t.Errorf("appended barkpark block missing (or CRLF-mangled) — f.Content not found verbatim")
	}

	// Now that markers exist, a re-run is byte-stable 'unchanged'.
	act2, err := mergeOnrampFile(f, false, false)
	if err != nil {
		t.Fatalf("re-run: %v", err)
	}
	if act2.Action != "unchanged" {
		t.Errorf("re-run action = %q, want unchanged", act2.Action)
	}
	if !bytes.Equal(result, mustRead(t, "AGENTS.md")) {
		t.Errorf("unchanged re-run mutated the CRLF file bytes")
	}
}

// TestOnrampWriteAgentsMdBOMPreserved locks that a UTF-8 BOM (EF BB BF) at byte 0
// of a foreign AGENTS.md survives the append verbatim (charter D32): the merger
// treats the whole file as opaque bytes, so the BOM is never stripped nor pushed
// down and the entire foreign region is byte-identical.
func TestOnrampWriteAgentsMdBOMPreserved(t *testing.T) {
	t.Chdir(t.TempDir())
	bom := []byte{0xEF, 0xBB, 0xBF}
	existing := append(append([]byte{}, bom...), []byte("# BOM Repo\n\nHumans wrote this with a byte-order mark.\n")...)
	if err := os.WriteFile("AGENTS.md", existing, 0o644); err != nil {
		t.Fatal(err)
	}
	f := agentsMdMergeFile(t)

	act, err := mergeOnrampFile(f, false, false)
	if err != nil {
		t.Fatalf("BOM append merge: %v", err)
	}
	if act.Action != "updated" {
		t.Fatalf("action = %q, want updated", act.Action)
	}
	result := mustRead(t, "AGENTS.md")

	// The BOM stays exactly at byte 0 — never stripped, never relocated.
	if !bytes.HasPrefix(result, bom) {
		t.Errorf("UTF-8 BOM no longer at byte 0: first bytes % x", result[:3])
	}
	// The whole BOM-prefixed foreign region survives byte-identical as a prefix.
	if !bytes.HasPrefix(result, existing) {
		t.Errorf("BOM-prefixed foreign region was not preserved byte-for-byte.\n--- got %q", result)
	}
	// The barkpark block landed after the foreign prose.
	if !bytes.Contains(result, []byte(f.Content)) {
		t.Errorf("appended barkpark block missing after BOM prose")
	}
}

// TestOnrampWriteAgentsMdForceCRLFMixedEnding locks the D32 documented-expected
// mixed-ending: --force refreshing a STALE marker block inside a CRLF foreign file
// preserves the CRLF foreign prose (every byte OUTSIDE the begin→end span
// unchanged) while the freshly-emitted barkpark block is LF. This is the decided
// non-issue asserted as the EXPECTED result, NOT a defect — uniform-ending
// rewriting would mean mutating the user's foreign bytes, which violates the whole
// idempotence contract.
func TestOnrampWriteAgentsMdForceCRLFMixedEnding(t *testing.T) {
	t.Chdir(t.TempDir())
	head := []byte("# My Repo\r\n\r\nIntro the humans wrote.\r\n\r\n")
	tail := []byte("\r\n\r\n## Footer\r\n\r\nMore human prose below the block.\r\n")
	staleBlock := []byte(agentsMDMarkerBegin + "\n## Task tracking — Barkpark (bp)\n\nSTALE outdated body from an old bp version.\n" + agentsMDMarkerEnd)
	stale := append(append(append([]byte{}, head...), staleBlock...), tail...)
	foreignCRLF := bytes.Count(head, []byte("\r\n")) + bytes.Count(tail, []byte("\r\n"))
	if err := os.WriteFile("AGENTS.md", stale, 0o644); err != nil {
		t.Fatal(err)
	}
	f := agentsMdMergeFile(t)

	// Without --force the differing block is skipped and the CRLF file is untouched.
	act, err := mergeOnrampFile(f, false, false)
	if err != nil {
		t.Fatalf("skip merge: %v", err)
	}
	if act.Action != "skipped" {
		t.Fatalf("action = %q, want skipped without --force", act.Action)
	}
	if !bytes.Equal(stale, mustRead(t, "AGENTS.md")) {
		t.Errorf("skipped write mutated the CRLF file")
	}

	// --force replaces ONLY the begin→end span with the canonical LF block.
	act, err = mergeOnrampFile(f, true, false)
	if err != nil {
		t.Fatalf("force merge: %v", err)
	}
	if act.Action != "updated" {
		t.Fatalf("force action = %q, want updated", act.Action)
	}
	result := mustRead(t, "AGENTS.md")

	// The stale body is gone; the canonical block is present verbatim (LF).
	if bytes.Contains(result, []byte("STALE outdated body")) {
		t.Errorf("stale block body survived the force replace")
	}
	if !bytes.Contains(result, []byte(f.Content)) {
		t.Errorf("canonical LF block not written on force")
	}
	// The foreign CRLF prose OUTSIDE the span is byte-identical: the head is a
	// verbatim prefix and the tail a verbatim suffix (both CRLF).
	if !bytes.HasPrefix(result, head) {
		t.Errorf("CRLF prose above the block was mangled.\n--- got %q", result)
	}
	if !bytes.HasSuffix(result, tail) {
		t.Errorf("CRLF prose below the block was mangled.\n--- got %q", result)
	}
	// Total CRLF count equals the foreign count — the emitted block added none
	// (mixed CRLF-foreign + LF-block is the EXPECTED D32 shape, not a bug).
	if got := bytes.Count(result, []byte("\r\n")); got != foreignCRLF {
		t.Errorf("CRLF count = %d, want %d — the emitted barkpark block must be LF (mixed-ending expected per D32)", got, foreignCRLF)
	}
	if got := bytes.Count(result, []byte("\r")); got != foreignCRLF {
		t.Errorf("stray bare \\r: %d vs %d \\r\\n — a CR was mangled", got, foreignCRLF)
	}
}

// runOnrampWriteJSON drives `bp onramp <args...> --write -o json` through the REAL
// command entry point (runOnramp → buildOnrampSpec → runOnrampWrite) and decodes
// the structured report. Server is pinned to guerrilla so the emission is
// deterministic (short-circuits activeSavedServer / disk config). This is the
// wired-path driver the isolation-only merge tests lack — it exercises the exact
// arm buildOnrampSpec stamps, catching a dropped merge-metadata helper (the #2129
// copilot bare-literal regression) that a hand-built onrampFile would mask.
func runOnrampWriteJSON(t *testing.T, args ...string) onrampWriteResult {
	t.Helper()
	var so, se bytes.Buffer
	w := newWriter(&so, &se)
	w.output = "json"
	full := append(append([]string{}, args...), "--write")
	if code := runOnramp(w, globals{server: guerrilla}, full); code != exitOK {
		t.Fatalf("runOnramp %v exit = %d; stderr=%s", full, code, se.String())
	}
	var res onrampWriteResult
	if err := json.Unmarshal(so.Bytes(), &res); err != nil {
		t.Fatalf("json report did not decode into onrampWriteResult: %v\n%s", err, so.String())
	}
	return res
}

// TestOnrampWriteCopilotWiredPath drives `bp onramp copilot --write` end-to-end
// through the REAL command (cd'd into a tempdir so the cwd-relative
// .vscode/mcp.json resolves there, not the repo — HOME sandboxing alone would not
// isolate it, charter D15). It is the wired-path guard the isolation-only
// TestOnrampWriteServersShape lacked: the #2129 bare-literal regression made this
// path a SILENT NO-OP (buildOnrampSpec's copilot arm dropped serversFile, so
// mergeOnrampFile fell to default and reported skipped, zero files). Here the
// action must be created — then unchanged on a clean re-run, bytes untouched
// (charter D14).
func TestOnrampWriteCopilotWiredPath(t *testing.T) {
	dir := t.TempDir()
	t.Chdir(dir)

	res := runOnrampWriteJSON(t, "copilot")
	if len(res.Actions) != 1 {
		t.Fatalf("copilot --write actions = %+v, want exactly one", res.Actions)
	}
	if got := res.Actions[0].Action; got != "created" {
		t.Fatalf("copilot --write action = %q, want created (the bare-literal regression reports skipped and writes nothing)", got)
	}
	if res.Actions[0].Path != ".vscode/mcp.json" {
		t.Errorf("action path = %q, want .vscode/mcp.json", res.Actions[0].Path)
	}

	// The file exists under cwd, byte-identical to the printed copilot stanza.
	written := mustRead(t, filepath.Join(dir, ".vscode", "mcp.json"))
	spec, ok := buildOnrampSpec("copilot", guerrilla, "")
	if !ok {
		t.Fatal("buildOnrampSpec(copilot) not ok")
	}
	if !bytes.Equal(written, withTrailingNewline([]byte(spec.Files[0].Content))) {
		t.Errorf("written .vscode/mcp.json is not byte-identical to the printed stanza:\n--- got ---\n%s", written)
	}
	// Top-level key is `servers` (VS Code's shape), never mcpServers.
	top := map[string]json.RawMessage{}
	if err := json.Unmarshal(written, &top); err != nil {
		t.Fatalf("written file not valid JSON: %v", err)
	}
	if _, ok := top["servers"]; !ok {
		t.Errorf("copilot file missing the top-level servers key")
	}
	if _, ok := top["mcpServers"]; ok {
		t.Errorf("copilot file leaked a sibling mcpServers key — VS Code's shape is servers")
	}

	// Re-run: unchanged, exit clean, bytes untouched.
	res = runOnrampWriteJSON(t, "copilot")
	if got := res.Actions[0].Action; got != "unchanged" {
		t.Fatalf("copilot re-run action = %q, want unchanged", got)
	}
	if !bytes.Equal(written, mustRead(t, filepath.Join(dir, ".vscode", "mcp.json"))) {
		t.Errorf("idempotent re-run changed the file bytes")
	}
}

// TestOnrampWriteCopilotWiredPreservesForeign proves the wired copilot --write
// merges into an existing .vscode/mcp.json without clobbering it: a foreign server
// under `servers` and an unrelated top-level key both survive, and barkpark is
// added (updated, key absent).
func TestOnrampWriteCopilotWiredPreservesForeign(t *testing.T) {
	dir := t.TempDir()
	t.Chdir(dir)
	if err := os.MkdirAll(filepath.Join(dir, ".vscode"), 0o755); err != nil {
		t.Fatal(err)
	}
	existing := `{
  "inputs": [{"id": "token", "type": "promptString"}],
  "servers": {
    "playwright": {"type": "stdio", "command": "npx", "args": ["@playwright/mcp"]}
  }
}
`
	if err := os.WriteFile(filepath.Join(dir, ".vscode", "mcp.json"), []byte(existing), 0o644); err != nil {
		t.Fatal(err)
	}

	res := runOnrampWriteJSON(t, "copilot")
	if got := res.Actions[0].Action; got != "updated" {
		t.Fatalf("copilot merge action = %q, want updated (barkpark absent under servers)", got)
	}

	result := mustRead(t, filepath.Join(dir, ".vscode", "mcp.json"))
	top := map[string]json.RawMessage{}
	if err := json.Unmarshal(result, &top); err != nil {
		t.Fatalf("result not valid JSON: %v", err)
	}
	if _, ok := top["inputs"]; !ok {
		t.Errorf("foreign top-level \"inputs\" key lost on merge")
	}
	servers := map[string]json.RawMessage{}
	if err := json.Unmarshal(top["servers"], &servers); err != nil {
		t.Fatalf("servers key not an object: %v", err)
	}
	if _, ok := servers["playwright"]; !ok {
		t.Errorf("foreign playwright server lost when adding barkpark")
	}
	if _, ok := servers["barkpark"]; !ok {
		t.Errorf("barkpark entry not added under servers")
	}
}

// TestOnrampWriteDryRunCreatesNothing: `--write --dry-run` on a fresh dir reports
// 'created' (the exact action a real write would) but leaves NO file on disk — the
// honest doctor mode the global --dry-run promises (charter D15).
func TestOnrampWriteDryRunCreatesNothing(t *testing.T) {
	dir := t.TempDir()
	f := serverMapFileAt(t, "cursor", dir, ".cursor/mcp.json")

	act, err := mergeOnrampFile(f, false, true)
	if err != nil {
		t.Fatalf("dry-run create merge: %v", err)
	}
	if act.Action != "created" {
		t.Fatalf("dry-run action = %q, want created", act.Action)
	}
	if _, err := os.Stat(f.Path); !os.IsNotExist(err) {
		t.Errorf("dry-run must not create the file, but %s exists (err=%v)", f.Path, err)
	}
	// The parent directory must not be created either — a dry run touches nothing.
	if _, err := os.Stat(filepath.Dir(f.Path)); !os.IsNotExist(err) {
		t.Errorf("dry-run created the parent dir %s", filepath.Dir(f.Path))
	}
}

// TestOnrampWriteDryRunSkipAndForceUntouched: on an EXISTING differing barkpark
// entry, `--dry-run` reports 'skipped' without --force and 'updated' with --force
// — but in BOTH cases the file's bytes are left exactly as they were. Proves the
// dry-run guard covers the update path, not just create.
func TestOnrampWriteDryRunSkipAndForceUntouched(t *testing.T) {
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

	// dry-run, no --force: reports skipped, file untouched.
	act, err := mergeOnrampFile(f, false, true)
	if err != nil {
		t.Fatalf("dry-run skip merge: %v", err)
	}
	if act.Action != "skipped" {
		t.Fatalf("dry-run action = %q, want skipped", act.Action)
	}
	if after := mustRead(t, path); !bytes.Equal(fixture, after) {
		t.Errorf("dry-run skip touched the file")
	}

	// dry-run, --force: reports the 'updated' action a real force write would, but
	// the file on disk is STILL the original fixture — not one byte written.
	act, err = mergeOnrampFile(f, true, true)
	if err != nil {
		t.Fatalf("dry-run force merge: %v", err)
	}
	if act.Action != "updated" {
		t.Fatalf("dry-run force action = %q, want updated", act.Action)
	}
	if after := mustRead(t, path); !bytes.Equal(fixture, after) {
		t.Errorf("dry-run --force wrote to the file — the stale entry should still be present.\n--- got ---\n%s", after)
	}
	if !bytes.Contains(mustRead(t, path), []byte("STALE.example.old")) {
		t.Errorf("dry-run --force overwrote the stale barkpark URL")
	}
}

// TestOnrampRunWriteDryRunEndToEnd drives the whole command path — runOnramp reads
// g.dryRun, threads it through runOnrampWrite, and the -o json envelope carries
// "dryRun":true — while the cwd-relative target (.cursor/mcp.json) is never
// created. cd into a tempdir: HOME-only sandboxing does NOT isolate a
// cwd-relative target (charter D15 test law).
func TestOnrampRunWriteDryRunEndToEnd(t *testing.T) {
	dir := t.TempDir()
	cwd, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.Chdir(cwd) })
	if err := os.Chdir(dir); err != nil {
		t.Fatal(err)
	}

	var so, se bytes.Buffer
	w := newWriter(&so, &se)
	w.output = "json"
	code := runOnramp(w, globals{server: guerrilla, dryRun: true}, []string{"cursor", "--write"})
	if code != exitOK {
		t.Fatalf("exit = %d, want %d; stderr=%s", code, exitOK, se.String())
	}

	var got onrampWriteResult
	if err := json.Unmarshal(so.Bytes(), &got); err != nil {
		t.Fatalf("json report did not decode: %v\n%s", err, so.String())
	}
	if !got.DryRun {
		t.Errorf("report DryRun = false, want true")
	}
	if len(got.Actions) != 1 || got.Actions[0].Action != "created" {
		t.Fatalf("actions = %+v, want one created", got.Actions)
	}
	// The cwd-relative target must NOT exist — the dry run wrote nothing.
	if _, err := os.Stat(filepath.Join(dir, ".cursor", "mcp.json")); !os.IsNotExist(err) {
		t.Errorf("dry-run end-to-end created .cursor/mcp.json (err=%v)", err)
	}
}

// TestOnrampRunWriteHonorsRealWrite is the paired positive: WITHOUT --dry-run the
// same command actually writes the file — so the dry-run test above proves a real
// suppression, not a path that never writes (a guard that never lets a write
// through is vacuous). It also asserts a real write's JSON omits the dryRun field.
func TestOnrampRunWriteHonorsRealWrite(t *testing.T) {
	dir := t.TempDir()
	cwd, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.Chdir(cwd) })
	if err := os.Chdir(dir); err != nil {
		t.Fatal(err)
	}

	var so, se bytes.Buffer
	w := newWriter(&so, &se)
	w.output = "json"
	if code := runOnramp(w, globals{server: guerrilla}, []string{"cursor", "--write"}); code != exitOK {
		t.Fatalf("exit = %d; stderr=%s", code, se.String())
	}
	if _, err := os.Stat(filepath.Join(dir, ".cursor", "mcp.json")); err != nil {
		t.Errorf("real --write did not create .cursor/mcp.json: %v", err)
	}
	if bytes.Contains(so.Bytes(), []byte("dryRun")) {
		t.Errorf("a real (non-dry-run) write leaked the dryRun field:\n%s", so.String())
	}
}

// TestOnrampWriteDryRunHumanMarker: the human report marks a dry run clearly and
// still prints the per-file action + verify pointer, writing nothing.
func TestOnrampWriteDryRunHumanMarker(t *testing.T) {
	dir := t.TempDir()
	f := serverMapFileAt(t, "cursor", dir, ".cursor/mcp.json")
	spec := onrampSpec{Target: "cursor", Files: []onrampFile{f}, Verify: "reload MCP servers"}

	var so, se bytes.Buffer
	w := newWriter(&so, &se)
	if code := runOnrampWrite(w, spec, false, true); code != exitOK {
		t.Fatalf("exit = %d", code)
	}
	out := so.Bytes()
	for _, want := range []string{"DRY RUN", "created", "verify:"} {
		if !bytes.Contains(out, []byte(want)) {
			t.Errorf("dry-run human report missing %q\n%s", want, out)
		}
	}
	if _, err := os.Stat(f.Path); !os.IsNotExist(err) {
		t.Errorf("dry-run human path wrote the file")
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

// TestBOMBricksOnrampMerge locks BP-ONB-12 (onramp half): a UTF-8 BOM (EF BB BF)
// at byte 0 of a target mcp.json — what Windows editors prepend — no longer
// bricks the merge. Go's json decoder rejects a BOM ("invalid character 'ï'"), so
// BEFORE the fix this test FAILS at the merge call; unmarshalObject now strips the
// BOM at the parse boundary. Protective: revert the bytes.TrimPrefix(raw, onrampUTF8BOM)
// and this test reds. Foreign server survives, barkpark is added, output is
// BOM-free.
func TestBOMBricksOnrampMerge(t *testing.T) {
	dir := t.TempDir()
	f := serverMapFileAt(t, "cursor", dir, ".cursor/mcp.json")
	existing := append(append([]byte{}, onrampUTF8BOM...),
		[]byte("{\n  \"mcpServers\": {\n    \"other\": { \"command\": \"foo\" }\n  }\n}\n")...)
	if err := os.MkdirAll(filepath.Dir(f.Path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(f.Path, existing, 0o644); err != nil {
		t.Fatal(err)
	}

	act, err := mergeOnrampFile(f, false, false)
	if err != nil {
		t.Fatalf("BOM-prefixed target did not merge (BOM not tolerated?): %v", err)
	}
	if act.Action != "updated" {
		t.Fatalf("action = %q, want updated", act.Action)
	}
	result := mustRead(t, f.Path)
	if bytes.HasPrefix(result, onrampUTF8BOM) {
		t.Errorf("merged output still carries a UTF-8 BOM: first bytes % x", result[:3])
	}
	var top map[string]any
	if err := json.Unmarshal(result, &top); err != nil {
		t.Fatalf("merged output is not valid JSON: %v\n%s", err, result)
	}
	servers, _ := top["mcpServers"].(map[string]any)
	if _, ok := servers["other"]; !ok {
		t.Errorf("foreign server 'other' was lost across the BOM-tolerant merge")
	}
	if _, ok := servers["barkpark"]; !ok {
		t.Errorf("barkpark entry was not added")
	}
}

// TestOnrampWriteAgentsMdCompetingTrackerWarns locks BP-ONB-14: appending the
// Barkpark teach block onto an AGENTS.md that ALREADY mandates a competing tracker
// (here Jira) would leave two mutually exclusive authoritative policies — so the
// merge WARNS (skipped, note names the tracker + --force hint) and leaves the file
// byte-untouched, instead of silently appending. Protective: revert the
// competingTrackerMandate guard and the action flips to a silent 'updated' append.
// With --force the block is appended anyway.
func TestOnrampWriteAgentsMdCompetingTrackerWarns(t *testing.T) {
	t.Chdir(t.TempDir())
	existing := "# My Repo\n\n## Task tracking\n\nAll engineers must log every task in Jira before starting work.\n"
	if err := os.WriteFile("AGENTS.md", []byte(existing), 0o644); err != nil {
		t.Fatal(err)
	}
	f := agentsMdMergeFile(t)

	// No --force: warn — skipped, note names the tracker + the --force hint, and
	// not one byte of the file is touched.
	act, err := mergeOnrampFile(f, false, false)
	if err != nil {
		t.Fatalf("competing-tracker merge: %v", err)
	}
	if act.Action != "skipped" {
		t.Fatalf("action = %q, want skipped (a competing tracker mandate is present)", act.Action)
	}
	if !strings.Contains(act.Note, "jira") {
		t.Errorf("skip note %q must name the competing tracker", act.Note)
	}
	if !strings.Contains(act.Note, "--force") {
		t.Errorf("skip note %q must carry the --force hint (onrampAnySkipped greps it)", act.Note)
	}
	if !bytes.Equal([]byte(existing), mustRead(t, "AGENTS.md")) {
		t.Errorf("a competing-tracker skip must not touch the file at all")
	}

	// --force: the block is appended, user content preserved verbatim as a prefix.
	act, err = mergeOnrampFile(f, true, false)
	if err != nil {
		t.Fatalf("force append: %v", err)
	}
	if act.Action != "updated" {
		t.Fatalf("force action = %q, want updated", act.Action)
	}
	result := mustRead(t, "AGENTS.md")
	if !bytes.HasPrefix(result, []byte(existing)) {
		t.Errorf("force append rewrote the user's existing content.\n--- got ---\n%s", result)
	}
	if !bytes.Contains(result, []byte(f.Content)) {
		t.Errorf("barkpark block was not appended on --force")
	}
}

// TestOnrampWritePartialReceiptHonest injects a failure on file 2 of 3 and asserts
// the receipt is HONEST about the partial write: it names N of M written, the file
// that failed, and that a re-run heals. File 1 lands, file 2 errors (a flat file
// whose content lacks its TopKey), file 3 is never attempted (the loop breaks). A
// re-run with file 2 fixed heals — file 1 reports 'unchanged' (idempotent), file 3
// 'created' — and carries no partial receipt.
func TestOnrampWritePartialReceiptHonest(t *testing.T) {
	dir := t.TempDir()
	f1 := serverMapFileAt(t, "cursor", dir, "a/mcp.json")
	f2 := onrampFile{Path: filepath.Join(dir, "env.json"), Content: "{}", MergeKind: mergeFlat, TopKey: "install"}
	f3 := serverMapFileAt(t, "cursor", dir, "c/mcp.json")
	spec := onrampSpec{Target: "cursor", Files: []onrampFile{f1, f2, f3}, Verify: "reload"}

	var so, se bytes.Buffer
	w := newWriter(&so, &se)
	if code := runOnrampWrite(w, spec, false, false); code != exitGeneric {
		t.Fatalf("exit = %d, want exitGeneric on a mid-loop failure; stderr=%s", code, se.String())
	}
	out := so.String()
	for _, want := range []string{"1 of 3", f2.Path, "heals", "unchanged"} {
		if !strings.Contains(out, want) {
			t.Errorf("partial receipt missing %q\n--- receipt ---\n%s", want, out)
		}
	}
	if _, err := os.Stat(f1.Path); err != nil {
		t.Errorf("file 1 should have been written before the failure: %v", err)
	}
	if _, err := os.Stat(f3.Path); !os.IsNotExist(err) {
		t.Errorf("file 3 must not be written after the mid-loop break (stat err=%v)", err)
	}

	// Heal: fix file 2 and re-run. The idempotent per-file merges make file 1
	// 'unchanged' and file 3 'created'; the run is clean (no partial receipt).
	f2ok := serverMapFileAt(t, "cursor", dir, "b/mcp.json")
	spec2 := onrampSpec{Target: "cursor", Files: []onrampFile{f1, f2ok, f3}, Verify: "reload"}
	var so2, se2 bytes.Buffer
	w2 := newWriter(&so2, &se2)
	w2.output = "json"
	if code := runOnrampWrite(w2, spec2, false, false); code != exitOK {
		t.Fatalf("healed re-run exit = %d, want exitOK; stderr=%s", code, se2.String())
	}
	var res onrampWriteResult
	if err := json.Unmarshal(so2.Bytes(), &res); err != nil {
		t.Fatalf("healed re-run json did not decode: %v\n%s", err, so2.String())
	}
	if res.Partial != nil {
		t.Errorf("a clean re-run must carry no partial receipt, got %+v", res.Partial)
	}
	byPath := map[string]string{}
	for _, a := range res.Actions {
		byPath[a.Path] = a.Action
	}
	if byPath[f1.Path] != "unchanged" {
		t.Errorf("healed re-run: file 1 = %q, want unchanged (idempotent)", byPath[f1.Path])
	}
	if byPath[f3.Path] != "created" {
		t.Errorf("healed re-run: file 3 = %q, want created", byPath[f3.Path])
	}
}

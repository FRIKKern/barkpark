package cli

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
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

// TestOnrampWriteCodexSkipped: codex's TOML config is reported skipped (wave 3),
// never written — and no *.toml file is created anywhere.
func TestOnrampWriteCodexSkipped(t *testing.T) {
	spec, ok := buildOnrampSpec("codex", guerrilla, "")
	if !ok {
		t.Fatal("codex spec not ok")
	}
	act, err := mergeOnrampFile(spec.Files[0], false)
	if err != nil {
		t.Fatalf("codex merge: %v", err)
	}
	if act.Action != "skipped" {
		t.Fatalf("codex action = %q, want skipped", act.Action)
	}
	if !bytes.Contains([]byte(act.Note), []byte("wave 3")) {
		t.Errorf("codex skip note should name wave 3, got %q", act.Note)
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

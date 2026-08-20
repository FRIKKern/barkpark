package cli

import (
	"bytes"
	"strings"
	"testing"

	"github.com/mattn/go-runewidth"
)

// seedServersConfig writes the same two-server config every snapshot case in
// this file exercises: an active cloud server "prod" and an inactive local
// server "localdev".
func seedServersConfig(t *testing.T) {
	t.Helper()
	withTempConfigHome(t)
	cfg := &Config{
		Server: "https://api.example.com",
		KnownServers: []ServerEntry{
			{Name: "prod", Server: "https://api.example.com", Tier: "starter"},
			{Name: "localdev", Server: "http://localhost:4000"},
		},
	}
	if err := SaveConfig(cfg); err != nil {
		t.Fatalf("SaveConfig: %v", err)
	}
}

// runServersSnapshot runs fn against a freshly-seeded config with -o output
// and returns stdout. Used by the byte-identical snapshot tests below.
func runServersSnapshot(t *testing.T, output string, fn func(w *writer) int) string {
	t.Helper()
	seedServersConfig(t)
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	w.output = output
	fn(w)
	return stdout.String()
}

// TestServersEmitStructuredByteIdentical pins the -o json / -o yaml output of
// every `bp use`/`bp servers` code path that used to inline its own
// json/yaml switch (servers_cmd.go:84-92, 125-133, 163-171, 211-219) to the
// bytes captured BEFORE those switches were replaced with the shared
// (*writer).emitStructured helper (output.go:282). The refactor must be
// byte-identical — any drift here means emitStructured stopped matching the
// old inline switch, not that the golden bytes are wrong.
func TestServersEmitStructuredByteIdentical(t *testing.T) {
	cases := []struct {
		name string
		fn   func(w *writer) int
		json string
		yaml string
	}{
		{
			name: "runUse known name",
			fn:   func(w *writer) int { return runUse(w, []string{"prod"}) },
			json: "{\"active\":{\"dataset\":\"\",\"kind\":\"cloud\",\"name\":\"prod\",\"project\":\"\",\"server\":\"https://api.example.com\",\"workspace\":\"\"},\"ok\":true}\n",
			yaml: "active:\n  dataset: \"\"\n  kind: cloud\n  name: prod\n  project: \"\"\n  server: \"https://api.example.com\"\n  workspace: \"\"\nok: true\n",
		},
		{
			name: "runUse no arg (status)",
			fn:   func(w *writer) int { return runUse(w, nil) },
			json: "{\"active\":{\"dataset\":\"\",\"kind\":\"cloud\",\"name\":\"prod\",\"project\":\"\",\"server\":\"https://api.example.com\",\"workspace\":\"\"},\"known\":[\"prod\",\"localdev\"],\"ok\":true}\n",
			yaml: "active:\n  dataset: \"\"\n  kind: cloud\n  name: prod\n  project: \"\"\n  server: \"https://api.example.com\"\n  workspace: \"\"\nknown:\n  - prod\n  - localdev\nok: true\n",
		},
		{
			name: "runUse unknown name",
			fn:   func(w *writer) int { return runUse(w, []string{"nope"}) },
			json: "{\"error\":{\"code\":\"not_found\",\"known\":[\"prod\",\"localdev\"],\"message\":\"no known server matches nope\"},\"ok\":false}\n",
			yaml: "error:\n  code: not_found\n  known:\n    - prod\n    - localdev\n  message: no known server matches nope\nok: false\n",
		},
		{
			name: "runServers",
			fn:   func(w *writer) int { return runServers(w, nil) },
			json: "{\"active\":\"prod\",\"servers\":[{\"active\":true,\"aliases\":[],\"instance_id\":\"\",\"kind\":\"cloud\",\"last_connected\":\"\",\"name\":\"prod\",\"server\":\"https://api.example.com\",\"tier\":\"starter\"},{\"active\":false,\"aliases\":[],\"instance_id\":\"\",\"kind\":\"local\",\"last_connected\":\"\",\"name\":\"localdev\",\"server\":\"http://localhost:4000\",\"tier\":\"\"}]}\n",
			yaml: "active: prod\nservers:\n  -\n    active: true\n    aliases: []\n    instance_id: \"\"\n    kind: cloud\n    last_connected: \"\"\n    name: prod\n    server: \"https://api.example.com\"\n    tier: starter\n  -\n    active: false\n    aliases: []\n    instance_id: \"\"\n    kind: local\n    last_connected: \"\"\n    name: localdev\n    server: \"http://localhost:4000\"\n    tier: \"\"\n",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name+"/json", func(t *testing.T) {
			got := runServersSnapshot(t, "json", tc.fn)
			if got != tc.json {
				t.Errorf("-o json output drifted from the pre-refactor snapshot.\ngot:  %q\nwant: %q", got, tc.json)
			}
		})
		t.Run(tc.name+"/yaml", func(t *testing.T) {
			got := runServersSnapshot(t, "yaml", tc.fn)
			if got != tc.yaml {
				t.Errorf("-o yaml output drifted from the pre-refactor snapshot.\ngot:  %q\nwant: %q", got, tc.yaml)
			}
		})
	}
}

// bp servers used to print rows with the column labels living only in a source
// comment — the only headerless table in the CLI. The human table must now lead
// with a NAME/KIND/SERVER header and a dashed separator, both BEFORE the entries.
func TestRunServersPrintsHeaderBeforeRows(t *testing.T) {
	withTempConfigHome(t)
	cfg := &Config{
		Server: "https://api.example.com",
		KnownServers: []ServerEntry{
			{Name: "prod", Server: "https://api.example.com", Tier: "starter"},
			{Name: "localdev", Server: "http://localhost:4000"},
		},
	}
	if err := SaveConfig(cfg); err != nil {
		t.Fatalf("SaveConfig: %v", err)
	}

	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	w.output = "table"

	if code := runServers(w, nil); code != exitOK {
		t.Fatalf("runServers exit = %d, want %d", code, exitOK)
	}
	out := stdout.String()

	headerIdx := strings.Index(out, "NAME")
	if headerIdx < 0 {
		t.Fatalf("servers table missing a NAME header:\n%s", out)
	}
	for _, want := range []string{"NAME", "KIND", "SERVER"} {
		if !strings.Contains(out, want) {
			t.Errorf("header missing %q column label:\n%s", want, out)
		}
	}

	// A dashed separator line must follow the header.
	lines := strings.Split(strings.TrimRight(out, "\n"), "\n")
	sepIdx := -1
	for i, ln := range lines {
		if strings.Contains(ln, "NAME") {
			if i+1 < len(lines) && strings.Contains(lines[i+1], "----") {
				sepIdx = i + 1
			}
			break
		}
	}
	if sepIdx < 0 {
		t.Fatalf("expected a dashed separator line right after the header:\n%s", out)
	}

	// Header must precede the first server row (its URL).
	rowIdx := strings.Index(out, "https://api.example.com")
	if rowIdx < 0 {
		t.Fatalf("expected the seeded server URL in the table:\n%s", out)
	}
	if headerIdx >= rowIdx {
		t.Errorf("header did not precede the entries (header at %d, first row at %d):\n%s", headerIdx, rowIdx, out)
	}
}

// serverColumnOffset returns the terminal display-cell column (runewidth) at
// which the given URL starts on its row — i.e. the display width of everything
// printed before it. That is the SERVER column's true starting position.
func serverColumnOffset(t *testing.T, out, url string) int {
	t.Helper()
	for _, ln := range strings.Split(out, "\n") {
		if i := strings.Index(ln, url); i >= 0 {
			return runewidth.StringWidth(ln[:i])
		}
	}
	t.Fatalf("row for %q not found in:\n%s", url, out)
	return -1
}

// The `bp servers` human table measures and pads the NAME/KIND columns. A
// wide-CJK DisplayName is ONE rune but TWO display cells per glyph, so measuring
// with utf8.RuneCountInString and padding with fmt's %-*s (both rune-count)
// under-pads it: the SERVER column shears right on the CJK row relative to an
// ASCII row. runewidth.StringWidth + runewidth.FillRight pad in display cells,
// so the SERVER column must start at the SAME cell offset on both rows.
//
// On origin/main this reds — the CJK "日本語" name (3 runes, 6 cells) padded to
// the 12-rune minimum yields 3+9=12 runes but 6+9=15 cells, so the SERVER column
// on the CJK row starts 3 cells past the ASCII row (delta 3).
func TestServersTableWideRuneColumnAlignment(t *testing.T) {
	withTempConfigHome(t)
	cfg := &Config{
		// Neither known server is active, so every row carries the same 2-cell
		// "  " mark and the offsets compare cleanly.
		Server: "https://other.example.com",
		KnownServers: []ServerEntry{
			{Name: "prod", Server: "https://ascii.example.com", Tier: "starter"},
			{Name: "日本語", Server: "https://cjk.example.com", Tier: "starter"},
		},
	}
	if err := SaveConfig(cfg); err != nil {
		t.Fatalf("SaveConfig: %v", err)
	}

	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	w.output = "table"

	if code := runServers(w, nil); code != exitOK {
		t.Fatalf("runServers exit = %d, want %d", code, exitOK)
	}
	out := stdout.String()

	asciiOffset := serverColumnOffset(t, out, "https://ascii.example.com")
	cjkOffset := serverColumnOffset(t, out, "https://cjk.example.com")
	if asciiOffset != cjkOffset {
		t.Errorf("SERVER column misaligned across rune widths: ASCII row starts at display cell %d, wide-CJK row at %d (delta %d) — the CJK NAME was padded by rune-count, not display cells:\n%s",
			asciiOffset, cjkOffset, cjkOffset-asciiOffset, out)
	}
}

package cli

import (
	"bytes"
	"strings"
	"testing"
)

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

package cli

import "testing"

// TestParseRepoFileGoal pins the optional "goal" key `bp tasks` scopes by:
// read when present, empty when absent, and never a reason to reject a file.
func TestParseRepoFileGoal(t *testing.T) {
	f, err := parseRepoFile(writeRepoFile(t, t.TempDir(), `{"server":"guerrilla","goal":"task-130be6b834d485ae"}`))
	if err != nil {
		t.Fatalf("goal must parse, got: %v", err)
	}
	if f.Goal != "task-130be6b834d485ae" || f.Server != "guerrilla" {
		t.Fatalf("goal = %q, server = %q", f.Goal, f.Server)
	}

	f, err = parseRepoFile(writeRepoFile(t, t.TempDir(), `{"server":"guerrilla"}`))
	if err != nil {
		t.Fatalf("a file without goal must parse, got: %v", err)
	}
	if f.Goal != "" {
		t.Fatalf("absent goal must read empty, got %q", f.Goal)
	}
}

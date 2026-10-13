package cli

import (
	"strings"
	"testing"
)

// A global flag given a value it cannot take (`--limit abc`) is reported on
// one line with exit 2. It used to be followed by the whole global usage
// block, which buried the line that says what to fix. Found dogfooding
// `bp doc ls post --limit abc` against a fresh local instance.
func TestGlobalFlagBadValuePrintsNoUsageBlock(t *testing.T) {
	t.Setenv("BARKPARK_MANIFEST", fullManifest)
	for _, args := range [][]string{
		{"doc", "ls", "post", "--limit", "abc"},
		{"doc", "ls", "post", "--offset=-1"},
		{"-o", "xml", "doc", "ls", "post"},
	} {
		out, code := captureExecuteCode(t, args)
		if code != exitUsage {
			t.Errorf("%v: exit = %d, want %d", args, code, exitUsage)
		}
		if !strings.Contains(out, "invalid --") {
			t.Errorf("%v: missing the invalid-value line; got:\n%s", args, out)
		}
		if strings.Contains(out, "usage: barkpark [global flags]") {
			t.Errorf("%v: a bad flag value must not print the global usage block; got:\n%s", args, out)
		}
	}
}

// A structural global-flag error (no value at all) keeps the usage block: the
// block lists the global flags, which is what the caller needs there.
func TestGlobalFlagMissingValueKeepsUsageBlock(t *testing.T) {
	t.Setenv("BARKPARK_MANIFEST", fullManifest)
	out, code := captureExecuteCode(t, []string{"doc", "ls", "post", "--limit"})
	if code != exitUsage {
		t.Errorf("exit = %d, want %d", code, exitUsage)
	}
	if !strings.Contains(out, "needs a value") || !strings.Contains(out, "usage: barkpark [global flags]") {
		t.Errorf("missing value should report and print the global usage; got:\n%s", out)
	}
}

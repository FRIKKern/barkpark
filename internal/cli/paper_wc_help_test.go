package cli

import (
	"strings"
	"testing"
)

// `bp paper export --help` answered "paper export: exactly one <slug>" and exit
// 2 (stranger walk, 2026-10-01): the global parser folds --help into g.help and
// strips it, so the working-copy verbs saw no slug. view, capture and new
// already honour g.help; pull, export, status, diff and push now do too.
func TestPaperWorkingCopyVerbsAnswerHelp(t *testing.T) {
	for _, verb := range []string{"pull", "export", "status", "diff", "push"} {
		for _, flag := range []string{"--help", "-h"} {
			out, code := captureExecuteCode(t, []string{"paper", verb, flag})
			if code != exitOK {
				t.Errorf("bp paper %s %s: exit %d, want 0\n%s", verb, flag, code, out)
			}
			if strings.Contains(out, "exactly one <slug>") || !strings.Contains(out, "usage: bp paper") {
				t.Errorf("bp paper %s %s: want the paper usage, got:\n%s", verb, flag, out)
			}
		}
	}
}

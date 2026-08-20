package main

import (
	"bytes"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/apiclient"
)

// TestHeadlessStatusCardPrintsAndExitsZero proves the R7 non-TTY contract: when
// schemas have loaded but there is no usable terminal, bp prints the compact
// content-first status card and returns exit code 0 (not bubbletea's raw /dev/tty
// error + exit 1). No live server or faked TTY is needed — headlessStatusCard is
// the extracted seam runTUI calls in the non-interactive branch.
func TestHeadlessStatusCardPrintsAndExitsZero(t *testing.T) {
	ds := apiclient.New(apiclient.Config{
		BaseURL:   "https://guerrilla.barkpark.cloud",
		Workspace: "default",
		Project:   "default",
		Dataset:   "production",
	})
	var buf bytes.Buffer
	code := headlessStatusCard(&buf, apiclient.Config{BaseURL: "https://guerrilla.barkpark.cloud"}, ds, 12)

	if code != 0 {
		t.Fatalf("headlessStatusCard exit code = %d, want 0", code)
	}
	out := buf.String()
	for _, want := range []string{
		"headless CMS",
		"schemas:  12 loaded",
		"server:   https://guerrilla.barkpark.cloud",
		"workspace=default · project=default · dataset=production",
		"help[1]:  `bp task ready`",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("status card missing %q:\n%s", want, out)
		}
	}
}

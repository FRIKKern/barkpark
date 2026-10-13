package cli

import (
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/cloudclient"
)

// A paused box never updates again until a team admin resumes it: no code path
// clears `autoupdate_paused`, and the rollout itself pauses a box whose update
// did not land. The detail column must say so and name the command, or an
// operator reading `bp cloud status` sees "behind" and waits for a rollout that
// will never come.
func TestAttentionDetailNamesAPausedBox(t *testing.T) {
	on := true
	b := cloudclient.Barkpark{
		Name:              "dooodo",
		Slug:              "dooodo",
		UpdateState:       "behind",
		AutoupdateEnabled: &on,
		AutoupdatePaused:  true,
	}

	d := attentionDetail(b, "behind")
	if !strings.Contains(d, "autoupdate paused") {
		t.Fatalf("detail does not say the box is paused: %q", d)
	}
	if !strings.Contains(d, "bp cloud autoupdate resume dooodo") {
		t.Fatalf("detail does not name the resume command: %q", d)
	}
}

func TestAttentionDetailQuietWhenNotPaused(t *testing.T) {
	on := true
	b := cloudclient.Barkpark{Name: "dnd", Slug: "dnd", UpdateState: "current", AutoupdateEnabled: &on}
	if d := attentionDetail(b, "ok"); strings.Contains(d, "autoupdate paused") {
		t.Fatalf("an unpaused box must not carry the paused marker: %q", d)
	}
}

// A pin is a deliberate freeze the POLICY column already names ("pin@<tag>");
// the paused marker would be a second, competing sentence.
func TestAttentionDetailPinWinsOverPaused(t *testing.T) {
	on := true
	b := cloudclient.Barkpark{
		Name: "jarl", Slug: "jarl", UpdateState: "behind",
		AutoupdateEnabled: &on, AutoupdatePaused: true, PinnedRelease: "0.2.26",
	}
	if d := attentionDetail(b, "behind"); strings.Contains(d, "autoupdate paused") {
		t.Fatalf("a pinned box must not carry the paused marker: %q", d)
	}
}

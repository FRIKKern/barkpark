package pdrender

import (
	"strings"
	"testing"
)

// A linked master instance (master-ref) renders the neutral placeholder the
// Elixir walker shows when masters are not resolved, never the "unknown block"
// fallback (task-59f078a2fd248698).
func TestMasterRefRendersPlaceholderNotUnknownBlock(t *testing.T) {
	reg := testRegistry()
	ctx := RenderCtx{Width: 60, Theme: DarkTheme(), Profile: NoColor}

	out := strings.Join(
		reg.Render(Block{Type: "master-ref", Attrs: map[string]any{"master": "paper_master-1", "version": nil}}, ctx),
		"\n",
	)
	if !strings.Contains(out, "Linked master") {
		t.Fatalf("master-ref should render the Linked master placeholder; got %q", out)
	}
	if strings.Contains(out, "paper_master-1") {
		t.Fatalf("master-ref placeholder must not print the master id; got %q", out)
	}
	assertNoUnknownBlock(t, "master-ref", out)
}

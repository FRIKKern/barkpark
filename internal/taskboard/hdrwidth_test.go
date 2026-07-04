package taskboard

import (
	"strings"
	"testing"

	"github.com/charmbracelet/x/ansi"
)

// TestHeaderShedLadderNarrow guards the D-A shed-ladder BELOW the portrait band
// the golden covers (TestLiveCorpusInvariants asserts 40..80). The interesting
// behaviour lives in the tight widths: the droppable "barkpark · " brand sheds
// first, then the connection chip clips — but the primary label "tasks" is
// SACRED and must survive whole at every width, and the line must never overflow
// the pane. A full-FQDN server exercises firstDNSLabel at render time.
func TestHeaderShedLadderNarrow(t *testing.T) {
	old := Chrome
	Chrome = ChromeInfo{RepoName: "barkpark", Branch: "main", Server: "https://guerrilla.barkpark.cloud"}
	t.Cleanup(func() { Chrome = old })
	st := corpusUIState()
	for w := 8; w <= 90; w++ {
		line := ansi.Strip(headerLine1(st, w, corpusFixedNow))
		if got := ansi.StringWidth(line); got > w {
			t.Fatalf("w=%d: header width=%d overflows the pane: %q", w, got, line)
		}
		if !strings.Contains(line, "tasks") {
			t.Fatalf("w=%d: the sacred label \"tasks\" was dropped/clipped: %q", w, line)
		}
		// The server, whenever any part of the chip survives, is its first DNS
		// label — never the FQDN or a scheme.
		if strings.Contains(line, "guerrilla.barkpark.cloud") || strings.Contains(line, "://") {
			t.Fatalf("w=%d: header shows the full server, not its first DNS label: %q", w, line)
		}
	}
}

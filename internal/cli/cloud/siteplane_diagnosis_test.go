package cloud

import (
	"strings"
	"testing"
)

// TestSitePlaneLogTailKeepsTheLastLines: the tail is the END of the log — the
// lines where an installer says why it stopped — bounded in lines and bytes.
func TestSitePlaneLogTailKeepsTheLastLines(t *testing.T) {
	var in []string
	for i := 0; i < 20; i++ {
		in = append(in, "line "+strings.Repeat("x", i%3)+string(rune('a'+i)))
	}
	in = append(in, "", "E: Failed to fetch http://ports.ubuntu.com/pool 503  Service Unavailable")
	got := sitePlaneLogTail(strings.Join(in, "\n"))
	if !strings.HasSuffix(got, "E: Failed to fetch http://ports.ubuntu.com/pool 503  Service Unavailable") {
		t.Fatalf("tail %q must end with the installer's last line", got)
	}
	if n := strings.Count(got, " | ") + 1; n != sitePlaneLogTailLines {
		t.Fatalf("tail has %d lines, want %d: %q", n, sitePlaneLogTailLines, got)
	}
	if strings.Contains(got, "line a") {
		t.Fatalf("tail %q kept an early line", got)
	}

	long := strings.Repeat("y", 2000) + "\nlast"
	if got := sitePlaneLogTail(long); len(got) > sitePlaneLogTailBytes+len("…") || !strings.HasSuffix(got, "last") {
		t.Fatalf("byte bound broken: len %d, tail %q…", len(got), got[len(got)-10:])
	}
}

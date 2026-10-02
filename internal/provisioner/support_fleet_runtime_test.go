package provisioner

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/FRIKKern/barkpark/internal/fleetruntime"
)

// TestSupportChainInstallsTheSharedFleetRuntime (task-837f1013efdf100f): the
// provision_support chain's verify leg runs EXACTLY the runtime step
// `bp cloud support add` runs — fleetruntime.FilesStep(sha, true) — pinned to
// the resolved origin/main sha, degrading to the checkout (sha "") when the sha
// cannot be resolved. The content arm asserts the file set independently of
// the shared builder, so a local copy that drops bp-read.sh or the version
// file reds here even if someone also edits the comparison.
func TestSupportChainInstallsTheSharedFleetRuntime(t *testing.T) {
	const pinned = "abcdefabcdefabcdefabcdefabcdefabcdefabcd"
	for _, resolved := range []bool{true, false} {
		prev := supportResolveMainSHA
		if resolved {
			supportResolveMainSHA = func(context.Context) (string, error) { return pinned, nil }
		} else {
			supportResolveMainSHA = func(context.Context) (string, error) { return "", errors.New("rate limited") }
		}

		h := newSupportHarness(t)
		runner := &supportFakeRunner{capacityJSON: `{"size_class":"standard"}`}
		var deleted []string
		w := h.worker(runner, &deleted)
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		done := make(chan struct{})
		go func() {
			defer close(done)
			_ = w.RunSupportWith(ctx, func(claimed bool, err error) {
				if claimed {
					cancel()
				}
			})
		}()
		<-done
		cancel()
		supportResolveMainSHA = prev

		h.mu.Lock()
		succeeds, fails, consoles := len(h.succeeds), h.fails, strings.Join(h.console, "\n")
		h.mu.Unlock()
		if succeeds != 1 {
			t.Fatalf("resolved=%v: want one succeed, got %d (fails: %v)", resolved, succeeds, fails)
		}

		wantSHA := ""
		if resolved {
			wantSHA = pinned
		} else if !strings.Contains(consoles, "could not resolve origin/main's sha (rate limited)") {
			t.Fatalf("an unresolved sha must degrade LOUDLY on the console\n%s", consoles)
		}
		want := strings.Join(fleetruntime.FilesStep(wantSHA, true).Argv, " ")
		var got string
		for _, s := range runner.steps {
			j := strings.Join(s.Argv, " ")
			if strings.Contains(j, "fleet-run.sh") && strings.Contains(j, "mkdir -p") {
				got = j
			}
		}
		if got != want {
			t.Fatalf("resolved=%v: the chain's runtime step is not fleetruntime.FilesStep(%q, true)\n got: %s\nwant: %s", resolved, wantSHA, got, want)
		}
		for _, must := range []string{
			"tooling/fleet/fleet-run.sh:fleet-run.sh",
			"tooling/fleet/fleet-protocol.md:fleet-protocol.md",
			"scripts/lib/bp-read.sh:bp-read.sh",
			"fleet-run.version",
			"sha='" + wantSHA + "'",
			"cp \"/opt/barkpark/", // the on-box checkout fallback survives
		} {
			if !strings.Contains(got, must) {
				t.Fatalf("resolved=%v: runtime step lacks %q\n%s", resolved, must, got)
			}
		}
	}
}

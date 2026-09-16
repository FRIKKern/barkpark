package cli

import (
	"bytes"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)


// TestMinCLICheckVerdicts is the FIRES-WHEN-IT-SHOULD half paired with the
// STAYS-QUIET half in one table: every row that must produce a message, and
// every row that must produce none. A gate that only has positive rows cannot
// tell "always fires" from "fires correctly" — both of which read as working.
func TestMinCLICheckVerdicts(t *testing.T) {
	cases := []struct {
		name    string
		floor   *string
		cli     string
		want    minCLIVerdict
		wantMsg bool
	}{
		// FIRES. An old released client against today's live prod floor.
		{"released client below the live prod floor", strp("1.0.0"), "0.2.26", minCLIBelow, true},
		{"one patch below", strp("1.2.4"), "1.2.3", minCLIBelow, true},
		{"prerelease below its own release", strp("1.2.3"), "1.2.3-rc1", minCLIBelow, true},

		// QUIET. Each for a DIFFERENT reason, so one fix cannot silence all.
		{"exactly at the floor", strp("1.2.3"), "1.2.3", minCLISatisfied, false},
		{"above the floor", strp("1.0.0"), "1.2.3", minCLISatisfied, false},
		{"server omits min_cli", nil, "0.2.26", minCLIUnknown, false},
		{"server sends empty min_cli", strp(""), "0.2.26", minCLIUnknown, false},
		{"dev build has no release identity", strp("1.0.0"), "dev", minCLIUnknown, false},
		{"empty cli version", strp("1.0.0"), "", minCLIUnknown, false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got, msg := minCLICheck(manifest.Server{MinCLI: c.floor}, c.cli)
			if got != c.want {
				t.Errorf("verdict = %d, want %d", got, c.want)
			}
			if (msg != "") != c.wantMsg {
				t.Errorf("message presence = %v (%q), want %v", msg != "", msg, c.wantMsg)
			}
		})
	}
}

// TestMinCLIMessageIsActionable: a message that does not name both numbers and
// a remedy is not "an actionable message", it is a scold. It must also say what
// to do when NO release can satisfy the floor — which is today's live situation
// on prod (floor "1.0.0", newest published bp tag v0.2.26).
func TestMinCLIMessageIsActionable(t *testing.T) {
	_, msg := minCLICheck(manifest.Server{MinCLI: strp("1.0.0")}, "0.2.26")
	for _, needle := range []string{"0.2.26", "1.0.0", "bp upgrade", "misconfigured"} {
		if !strings.Contains(msg, needle) {
			t.Errorf("min_cli message omits %q: %q", needle, msg)
		}
	}
}

// TestCapabilitiesReportsMinCLIFloor: the human `bp capabilities` surface
// reports the advertised floor, and labels server.version as ADVERTISED rather
// than presenting the frozen placeholder as the running release.
func TestCapabilitiesReportsMinCLIFloor(t *testing.T) {
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	g := globals{manifestPath: fullManifest}
	if code := runCapabilities(w, g, manifest.Context{}); code != exitOK {
		t.Fatalf("runCapabilities exit=%d stderr=%s", code, stderr.String())
	}
	out := stdout.String()
	if !strings.Contains(out, "advertised") {
		t.Errorf("server line does not label version as advertised:\n%s", firstLines(out, 4))
	}
	if !strings.Contains(out, "status.json") {
		t.Errorf("server line does not point at the running-release oracle:\n%s", firstLines(out, 4))
	}
	m, _ := loadTreeFrom(t, fullManifest)
	if m.Server.MinCLI != nil && *m.Server.MinCLI != "" {
		if !strings.Contains(out, "min_cli:") {
			t.Errorf("fixture advertises min_cli %q but no min_cli line was printed:\n%s", *m.Server.MinCLI, firstLines(out, 6))
		}
	}
}

// TestCapabilitiesMinCLINoticeRidesStderr: when the floor is unmet the notice
// reaches stderr in MACHINE mode too — a piped `-o json` consumer must not be
// the one reader who never learns its client is under the floor — and stdout
// stays untouched JSON.
func TestCapabilitiesMinCLINoticeRidesStderr(t *testing.T) {
	old := cliVersion
	cliVersion = "0.0.1"
	t.Cleanup(func() { cliVersion = old })

	m, _ := loadTreeFrom(t, fullManifest)
	if m.Server.MinCLI == nil || *m.Server.MinCLI == "" {
		t.Skip("fixture advertises no min_cli floor; nothing to compare against")
	}

	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	w.output = "json"
	if code := runCapabilities(w, globals{manifestPath: fullManifest}, manifest.Context{}); code != exitOK {
		t.Fatalf("runCapabilities exit=%d stderr=%s", code, stderr.String())
	}
	if !strings.Contains(stderr.String(), "below this server's advertised min_cli") {
		t.Errorf("under-floor client got no stderr notice in json mode; stderr=%q", stderr.String())
	}
	if strings.Contains(stdout.String(), "min_cli is below") {
		t.Errorf("advisory leaked into machine stdout")
	}
	// And the gate must NOT refuse: exit stayed exitOK above. A refusal would
	// brick every released client against today's live floor.
}

// TestCapabilitiesMinCLIQuietWhenSatisfied is the control for the test above:
// same command, same fixture, a client ABOVE the floor, and the notice must be
// absent. Without it, a gate that always fires passes the test above.
func TestCapabilitiesMinCLIQuietWhenSatisfied(t *testing.T) {
	old := cliVersion
	cliVersion = "999.0.0"
	t.Cleanup(func() { cliVersion = old })

	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	w.output = "json"
	if code := runCapabilities(w, globals{manifestPath: fullManifest}, manifest.Context{}); code != exitOK {
		t.Fatalf("runCapabilities exit=%d stderr=%s", code, stderr.String())
	}
	if strings.Contains(stderr.String(), "below this server's advertised min_cli") {
		t.Errorf("a client above the floor was warned anyway; stderr=%q", stderr.String())
	}
}

func firstLines(s string, n int) string {
	parts := strings.SplitN(s, "\n", n+1)
	if len(parts) > n {
		parts = parts[:n]
	}
	return strings.Join(parts, "\n")
}

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

// ── THE REAL-SHAPE ARM ───────────────────────────────────────────────────────
//
// TestMinCLICheckVerdicts above drives "0.2.26" as "a released client below the
// live prod floor". No bp CLI release has ever carried that version: 0.2.x is
// the SERVER tag series (status.json "0.2.26.929"), while the CLI channel is
// cli-v1.x.y (cli-release.yml:47 `VERSION=${TAG#cli-v}`, upgrade.go resolving
// only cli-v* tags). So that row measures a shape the system never emits, and
// on its own it hides the actual production state.
//
// This is the arm with the real shape: every version a published bp has ever
// carried, against the floor the live box actually advertises. Measured
// 2026-09-17 — `git tag -l 'cli-v*' | sed 's/cli-v//' | sort -V` lists 27
// releases from 1.1.0 to 1.21.0 with none below 1.0.0, and
// `GET /v1/capabilities` returns min_cli "1.0.0".
func TestMinCLIFloorIsSatisfiedByEveryPublishedCLIRelease(t *testing.T) {
	const liveFloor = "1.0.0"
	// The oldest and newest cli-v* releases in the repo, and the boundary.
	for _, released := range []string{"1.1.0", "1.21.0", "1.0.0"} {
		got, msg := minCLICheck(manifest.Server{MinCLI: strp(liveFloor)}, released)
		if got != minCLISatisfied {
			t.Errorf("published release %s vs live floor %s: verdict = %d, want minCLISatisfied — "+
				"the floor is already met by every shipped client, which is why the guard has never fired",
				released, liveFloor, got)
		}
		if msg != "" {
			t.Errorf("published release %s vs live floor %s produced a notice %q; a satisfied client must be told nothing",
				released, liveFloor, msg)
		}
	}
	// THE CONTROL. Without it the loop above passes on a minCLICheck that
	// always returns Satisfied. A version genuinely below the floor — which is
	// what the server-tag series 0.2.x would be if it were ever a CLI version —
	// must still be caught.
	if got, _ := minCLICheck(manifest.Server{MinCLI: strp(liveFloor)}, "0.2.26"); got != minCLIBelow {
		t.Fatalf("a client below the floor read %d, want minCLIBelow — the comparison does not discriminate", got)
	}
}

// ── THE SERVER-SOURCED FRESHNESS ARM ─────────────────────────────────────────

// FIRES-WHEN-IT-SHOULD, and it fires exactly where no self-sourced reading can.
//
// The fixture is the one the QUIET channel test uses: the post-release commit is
// outside internal/cli, so channelStaleness has nothing to say and the green
// would stand. On top of that the binary is UNSTAMPED — the `curl | sh` install
// with no checkout, the population cli_staleness.go explicitly does not cover.
// The ONLY thing that differs from a passing green is the server's declaration.
//
// Delete the serverFloorStaleness call in whoamiCLIFreshness and this test gets
// `up-to-date` / true back and reds.
func TestWhoamiCLIFreshnessRefusesGreenWhenTheServerDeclaresThisClientBelowItsFloor(t *testing.T) {
	stalenessChannelFixture(t, "docs/unrelated.md", "1.21.0", "1.21.0")
	withStamp(t, "", "") // no provenance: no git reading is possible at all

	m := &manifest.Manifest{Server: manifest.Server{MinCLI: strp("2.0.0")}}
	c := whoamiCLIFreshness(m)

	if c.Status != onbCLIBehind {
		t.Fatalf("status = %q, want %q — the server declared this client under its floor", c.Status, onbCLIBehind)
	}
	if c.UpToDate == nil || *c.UpToDate {
		t.Fatalf("up_to_date = %v, want a taken reading of false — a stale client must not claim currency "+
			"when the thing it just talked to says otherwise", c.UpToDate)
	}
	if !strings.Contains(c.Detail, "SERVER FLOOR") {
		t.Fatalf("detail must name the SERVER as the source, not the binary's own reading; got %q", c.Detail)
	}
	for _, needle := range []string{"1.21.0", "2.0.0"} {
		if !strings.Contains(c.Detail, needle) {
			t.Fatalf("detail omits %q, so the operator cannot see which numbers were compared; got %q", needle, c.Detail)
		}
	}
	if c.Latest != "1.21.0" {
		t.Fatalf("latest = %q, want the resolved release still reported so the receipt stays readable", c.Latest)
	}
}

// The doctor receipt is the OTHER surface rendering this leg, reached by a
// different (network-bearing) path. Delete ITS serverFloorStaleness call and
// only this test reds.
func TestOnboardingCLIFreshnessRefusesGreenWhenTheServerDeclaresThisClientBelowItsFloor(t *testing.T) {
	stalenessChannelFixture(t, "docs/unrelated.md", "1.21.0", "1.21.0")
	withStamp(t, "", "")
	orig := onboardingLatestRelease
	onboardingLatestRelease = func() (string, error) { return "1.21.0", nil }
	t.Cleanup(func() { onboardingLatestRelease = orig })

	m := &manifest.Manifest{Server: manifest.Server{MinCLI: strp("2.0.0")}}
	c := onboardingCLIFreshness(m)

	if c.Status != onbCLIBehind || c.UpToDate == nil || *c.UpToDate {
		t.Fatalf("doctor leg = %+v, want behind/false — the server declared this client under its floor", c)
	}
	if !strings.Contains(c.Detail, "SERVER FLOOR") {
		t.Fatalf("doctor detail = %q, want the server-sourced verdict", c.Detail)
	}
}

// STAYS-QUIET #1, and it is TODAY'S LIVE SHAPE. Floor "1.0.0" (what prod
// actually advertises) against a published release "1.21.0". The server is not
// claiming anybody is stale, so the green must stand untouched. Without this
// arm a serverFloorStaleness that fires unconditionally passes the two tests
// above — and would have reported every operator on prod as behind.
func TestWhoamiCLIFreshnessKeepsGreenWhenTheServerFloorIsSatisfied(t *testing.T) {
	stalenessChannelFixture(t, "docs/unrelated.md", "1.21.0", "1.21.0")
	withStamp(t, "", "")

	m := &manifest.Manifest{Server: manifest.Server{MinCLI: strp("1.0.0")}}
	c := whoamiCLIFreshness(m)

	if c.Status != onbCLIUpToDate {
		t.Fatalf("status = %q, want %q — the live floor is met by every published release", c.Status, onbCLIUpToDate)
	}
	if c.UpToDate == nil || !*c.UpToDate {
		t.Fatalf("up_to_date = %v, want true", c.UpToDate)
	}
	if strings.Contains(c.Detail, "SERVER FLOOR") {
		t.Fatalf("a satisfied floor must produce no server verdict; got %q", c.Detail)
	}
}

// STAYS-QUIET #2, a DIFFERENT reason so one fix cannot silence both: there is
// no manifest at all — offline, or an unreachable target. An absence is never
// laundered into a verdict, and the leg keeps the release-channel answer.
func TestWhoamiCLIFreshnessMakesNoServerClaimWithoutAManifest(t *testing.T) {
	stalenessChannelFixture(t, "docs/unrelated.md", "1.21.0", "1.21.0")
	withStamp(t, "", "")

	c := whoamiCLIFreshness(nil)

	if c.Status != onbCLIUpToDate {
		t.Fatalf("status = %q, want %q — with no manifest the server said nothing", c.Status, onbCLIUpToDate)
	}
	if strings.Contains(c.Detail, "SERVER FLOOR") {
		t.Fatalf("a missing manifest must never be read as a server verdict; got %q", c.Detail)
	}
}

// STAYS-QUIET #3: the manifest is present but advertises no floor (an older or
// minimal server). Same requirement, third distinct cause.
func TestWhoamiCLIFreshnessMakesNoServerClaimWhenNoFloorIsAdvertised(t *testing.T) {
	stalenessChannelFixture(t, "docs/unrelated.md", "1.21.0", "1.21.0")
	withStamp(t, "", "")

	m := &manifest.Manifest{Server: manifest.Server{Version: "0.1.0"}} // MinCLI nil
	c := whoamiCLIFreshness(m)

	if c.Status != onbCLIUpToDate {
		t.Fatalf("status = %q, want %q — a server that advertises no floor makes no claim", c.Status, onbCLIUpToDate)
	}
	if strings.Contains(c.Detail, "SERVER FLOOR") {
		t.Fatalf("an absent min_cli must never be read as a verdict; got %q", c.Detail)
	}
}

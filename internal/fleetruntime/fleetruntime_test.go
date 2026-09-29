package fleetruntime

import (
	"strings"
	"testing"
)

// TestFilesStepCarriesTheWholeRuntime pins the file set both chains install:
// the runner, the protocol, bp-read.sh BESIDE the runner (without it the
// listener cannot call bp_json from /opt/barkpark-fleet), and the version
// file capacity.runner_sha is read from.
func TestFilesStepCarriesTheWholeRuntime(t *testing.T) {
	const sha = "0123456789abcdef0123456789abcdef01234567"
	s := FilesStep(sha, true)
	joined := strings.Join(s.Argv, " ")
	for _, want := range []string{
		"tooling/fleet/fleet-run.sh:fleet-run.sh",
		"tooling/fleet/fleet-protocol.md:fleet-protocol.md",
		"scripts/lib/bp-read.sh:bp-read.sh",
		`"$d/fleet-run.version"`,
		RawRoot + "/$sha/",
		"sha='" + sha + "'",
	} {
		if !strings.Contains(joined, want) {
			t.Fatalf("runtime step lacks %q\n%s", want, joined)
		}
	}
	if s.Title != "write fleet-run.sh + fleet-protocol.md + bp-read.sh from origin/main content at "+sha {
		t.Fatalf("title drifted: %q", s.Title)
	}
}

// TestFilesStepRefusesAnUnfencedSha: the sha is single-quoted into a shell
// script; anything but 40 lowercase hex must never reach it.
func TestFilesStepRefusesAnUnfencedSha(t *testing.T) {
	bad := "main'; rm -rf / #"
	s := FilesStep(bad, true)
	if strings.Contains(strings.Join(s.Argv, " "), bad) {
		t.Fatalf("an unfenced sha reached the script: %v", s.Argv)
	}
	if !strings.Contains(s.Argv[2], "exit 1") {
		t.Fatalf("an unfenced sha must build a failing step, got %v", s.Argv)
	}
}

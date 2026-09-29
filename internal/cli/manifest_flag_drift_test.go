package cli

import (
	"errors"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// driftStampCmd is `task stamp` as the SERVER really ships it in the shape this
// row is about: the command summary and the --criterion-text flag summary both
// document `--criterion-text-file`, which the manifest CANNOT declare (it is a
// client-side path flag). A binary predating that feature therefore meets a
// flag its parser does not know and the manifest's own prose demands.
func driftStampCmd() manifest.Command {
	return manifest.Command{
		ID:   "task.stamp",
		Noun: "task",
		Verb: "stamp",
		Summary: "Stamp ONE acceptance criterion mid-claim. --met ALSO REQUIRES the criterion's " +
			"exact stored wording, and it must ride a FILE: --criterion-text-file <path> (or `-` for stdin).",
		Flags: []manifest.Flag{
			{Name: "criterion", Type: "string", Summary: "ZERO-BASED index."},
			{Name: "criterion-text", Type: "string", Summary: "bp reads it from a FILE with --criterion-text-file <path>."},
			{Name: "evidence", Type: "string", Summary: "The proof."},
		},
	}
}

// TestSplitArgsManifestAdvertisedFlagIsNamedDriftRefusal is the DETECTOR for
// criterion 0: a flag the server manifest advertises but this parser does not
// declare must produce a NAMED drift refusal that says the binary is behind the
// manifest and names the refresh command — never a bare unknown-flag line.
func TestSplitArgsManifestAdvertisedFlagIsNamedDriftRefusal(t *testing.T) {
	cmd := driftStampCmd()
	tail := []string{"task-1", "worker", "1", "--criterion", "0", "--criterion-text-file", "crit.txt", "--met"}

	_, _, err := splitArgs(cmd, tail)
	if err == nil {
		t.Fatalf("splitArgs accepted a flag the parser does not declare")
	}

	var drift *flagDriftError
	if !errors.As(err, &drift) {
		t.Fatalf("refusal is not a typed drift refusal: %T %q", err, err)
	}

	msg := err.Error()
	for _, want := range []string{
		manifestFlagDriftCode,
		"BEHIND the server manifest",
		"--criterion-text-file",
		onbCLIDevRemedy,
	} {
		if !strings.Contains(msg, want) {
			t.Errorf("drift refusal missing %q:\n%s", want, msg)
		}
	}
	// The bare unknown-flag sentence is what the operator got before, and it is
	// the wrong story: it blames the typist for a flag the tool demanded.
	if strings.Contains(msg, "unknown flag --criterion-text-file for task stamp") {
		t.Errorf("drift refusal still speaks the bare unknown-flag line:\n%s", msg)
	}
}

// TestSplitArgsUnadvertisedFlagKeepsBareUsageRefusal is the CONTROL: the guard
// must be able to LOSE. A flag that appears NOWHERE in the manifest's prose is
// an ordinary typo and keeps the ordinary unknown-flag usage error — otherwise
// the drift refusal would be a uniform verdict that measures nothing.
func TestSplitArgsUnadvertisedFlagKeepsBareUsageRefusal(t *testing.T) {
	cmd := driftStampCmd()

	_, _, err := splitArgs(cmd, []string{"task-1", "--criteriom-text-file", "crit.txt"})
	if err == nil {
		t.Fatalf("splitArgs accepted an undeclared flag")
	}
	var drift *flagDriftError
	if errors.As(err, &drift) {
		t.Fatalf("a typo the manifest never mentions was called drift: %q", err)
	}
	if want := "unknown flag --criteriom-text-file for task stamp"; err.Error() != want {
		t.Errorf("typo refusal = %q, want %q", err.Error(), want)
	}
}

// TestManifestAdvertisesFlagBoundaries: the prose scan matches whole flag names
// only. A PREFIX of an advertised flag is still a typo, and a flag whose name
// merely CONTAINS an advertised one is not advertised either.
func TestManifestAdvertisesFlagBoundaries(t *testing.T) {
	cmd := driftStampCmd()
	cases := []struct {
		name string
		want bool
	}{
		{"criterion-text-file", true},
		// A strict PREFIX of an advertised flag is not advertised: the prose in
		// this fixture spells only `--criterion-text-file`, never a bare
		// `--criterion-text`, so neither of these is drift.
		{"criterion-text", false},
		{"criterion-te", false},
		{"criterion-text-files", false},
		{"nope", false},
		{"", false},
	}
	for _, c := range cases {
		if got := manifestAdvertisesFlag(cmd, c.name); got != c.want {
			t.Errorf("manifestAdvertisesFlag(%q) = %v, want %v", c.name, got, c.want)
		}
	}
}

// TestBuildManifestRequestDriftSuppressesUsageDump: at the dispatch seam the
// drift refusal carries its own named code and turns the per-command usage
// block OFF, while an ordinary typo keeps both. That is the difference between
// "your binary is stale" and "you mistyped".
func TestBuildManifestRequestDriftSuppressesUsageDump(t *testing.T) {
	cmd := driftStampCmd()
	cmd.HTTP = manifest.HTTP{Method: "POST", PathTemplate: "/v1/tasks/:id/criteria"}
	cmd.Args = []manifest.Arg{{Name: "id", Required: true}}
	m := &manifest.Manifest{}

	_, derr := buildManifestRequest(globals{}, manifest.Context{}, m, cmd,
		[]string{"task-1", "--criterion-text-file", "crit.txt"}, false)
	if derr == nil {
		t.Fatalf("expected a dispatch error")
	}
	if derr.withUsage {
		t.Errorf("drift refusal still prints the usage dump")
	}
	if got := derr.envelopeCode(); got != manifestFlagDriftCode {
		t.Errorf("drift envelope code = %q, want %q", got, manifestFlagDriftCode)
	}

	_, derr = buildManifestRequest(globals{}, manifest.Context{}, m, cmd,
		[]string{"task-1", "--criteriom-text-file", "crit.txt"}, false)
	if derr == nil {
		t.Fatalf("expected a dispatch error for the typo")
	}
	if !derr.withUsage {
		t.Errorf("an ordinary typo lost its usage dump")
	}
	if got := derr.envelopeCode(); got != "usage" {
		t.Errorf("typo envelope code = %q, want usage", got)
	}
}

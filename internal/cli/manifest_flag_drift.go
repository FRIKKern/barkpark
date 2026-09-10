package cli

import (
	"fmt"
	"strings"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// ─── THE MANIFEST/PARSER DRIFT REFUSAL ──────────────────────────────────────
//
// bp is manifest-driven: `bp <noun> <verb> --help` renders the SERVER's
// `GET /v1/capabilities` prose, while the flag PARSER is compiled into the
// local binary. The two can disagree in exactly one direction — the server's
// prose can document a flag this binary does not implement — and when it does
// the CLI actively INSTRUCTS the operator to pass a flag it will then refuse.
//
// Measured shape (task-d69061081fccd709): the tasks plugin's manifest summary
// for `task stamp` tells the operator that `--met` REQUIRES the wording via
// `--criterion-text-file <path>`, and the server's own rejection hint prints
// that flag as THE fix. `--criterion-text-file` is a CLIENT-SIDE flag —
// resolveCriterionTextFile rewrites it away before splitArgs ever sees it, and
// the manifest cannot declare it (the server knows nothing about a local path).
// So a binary older than that feature parses the flag as unknown and answers
// `bp: unknown flag --criterion-text-file for task stamp` plus a usage dump.
//
// A usage dump is the WRONG refusal for that: it says "you typed something
// wrong" about a flag the tool itself just told the operator to type. The
// operator's next move is to retype the wording inline as
// `--criterion-text "…"` — which is the command-substitution trap the file
// door exists to close.
//
// So: whenever an unknown flag is one the manifest's OWN PROSE advertises,
// refuse by NAME — the binary is behind the server manifest — and name the one
// command that fixes it (onbCLIDevRemedy, the same string bp doctor and
// bp upgrade name). A flag that appears nowhere in the manifest prose is an
// ordinary typo and keeps the ordinary usage refusal: the guard can lose.

// manifestFlagDriftCode is the named error code for the drift refusal. It rides
// the CLI-side envelope (nothing was sent, so there is no server reason to map)
// and is deliberately NOT "usage": a stale binary is not a typo.
const manifestFlagDriftCode = "cli_manifest_drift"

// flagDriftError is the unknown-flag error raised when the manifest documents
// the flag. It is a distinct type so the dispatch seam can suppress the usage
// dump (errors.As) without matching on message text.
type flagDriftError struct{ msg string }

func (e *flagDriftError) Error() string { return e.msg }

// manifestAdvertisesFlag reports whether the manifest's prose for cmd mentions
// the long flag `--name` — the command summary or any declared flag's summary.
// Boundary-checked on the right so `--c` does not match `--criterion-text-file`
// and `--criterion` does not match `--criterion-text`.
func manifestAdvertisesFlag(cmd manifest.Command, name string) bool {
	if name == "" {
		return false
	}
	needle := "--" + name
	haystacks := make([]string, 0, len(cmd.Flags)+1)
	haystacks = append(haystacks, cmd.Summary)
	for _, f := range cmd.Flags {
		haystacks = append(haystacks, f.Summary)
	}
	for _, h := range haystacks {
		for i := 0; ; {
			j := strings.Index(h[i:], needle)
			if j < 0 {
				break
			}
			end := i + j + len(needle)
			if end >= len(h) || !isFlagNameByte(h[end]) {
				return true
			}
			i = end
		}
	}
	return false
}

// isFlagNameByte reports whether b can continue a long flag name.
func isFlagNameByte(b byte) bool {
	switch {
	case b >= 'a' && b <= 'z', b >= 'A' && b <= 'Z', b >= '0' && b <= '9':
		return true
	case b == '-', b == '_':
		return true
	}
	return false
}

// unknownFlagError builds the refusal for a flag this binary's parser does not
// declare: the NAMED drift refusal when the manifest advertises it, and the
// ordinary usage error otherwise.
func unknownFlagError(cmd manifest.Command, spelled, name string) error {
	if manifestAdvertisesFlag(cmd, name) {
		return &flagDriftError{msg: fmt.Sprintf(
			"%s: this bp is BEHIND the server manifest — the manifest for %s %s DOCUMENTS %s, but this binary's parser does not implement it. This is a stale install, not a typo: refresh it with `%s`, then re-run. (Do not work around it by retyping the value inline — the flag the manifest names is the safe door.)",
			manifestFlagDriftCode, cmd.Noun, cmd.Verb, spelled, onbCLIDevRemedy)}
	}
	return fmt.Errorf("unknown flag %s for %s %s", spelled, cmd.Noun, cmd.Verb)
}

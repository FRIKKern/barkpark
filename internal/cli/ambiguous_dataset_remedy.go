package cli

import (
	"encoding/json"
	"fmt"
	"strings"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// ambiguousDatasetCode is the server's twin-resolver refusal: one task doc_id
// lives in more than one dataset of the same workspace+project, so the door
// refuses rather than pick a copy for the caller.
const ambiguousDatasetCode = "ambiguous_dataset"

// ambiguousDatasetRemedy is the INBOUND half of the scope-honesty contract, and
// the mirror of scope_honesty.go's outbound half.
//
// scope_honesty.go answers "the operator typed -d and this command cannot carry
// it, so do not send the request." This answers the other direction: the request
// WAS sent, the server refused it honestly, and the refusal names a remedy in a
// dialect the operator cannot type.
//
// The server's hint is correct and stays the headline — it says "Name the
// dataset you mean (?dataset=<name> on the task route)". But `?dataset=` is the
// HTTP query-string spelling. Nobody typing `bp` has a query string; they have
// argv, where the same scope is `-d <name>`. Before this line the operator read
// a refusal, applied the remedy as printed, and got no result, because there is
// no place on a bp command line to put `?dataset=`. Measured 2026-09-16 against
// guerrilla on all eleven live cross-dataset twins: the refusal is a 409 (exit
// 6) whose only printed remedy is the query-param form.
//
// It is DERIVED, never remembered. The datasets come from the envelope's own
// `details.datasets` — the same list the server's hint points at — and whether
// `-d` is typeable on THIS command comes from manifest.DatasetFateFor, the same
// classifier the outbound refusal uses. So a command that cannot carry -d is
// never told to type it, and a future verb that gains or loses the declaration
// changes this line without a code edit. There is no list of verbs here, by
// design: a hand-kept list is the shape of the defect, not the fix.
//
// It returns "" for every other error code, for a details payload that carries
// no dataset list, and for a single-element list (which is not a collision and
// would read as noise).
func ambiguousDatasetRemedy(cmd manifest.Command, roster []manifest.Command, raw json.RawMessage) string {
	names := ambiguousDatasetNames(raw)
	if len(names) < 2 {
		return ""
	}

	verb := strings.TrimSpace(cmd.Noun + " " + cmd.Verb)

	flags := make([]string, 0, len(names))
	for _, n := range names {
		flags = append(flags, "-d "+n)
	}

	if manifest.DatasetFateFor(cmd) == manifest.DatasetCarried {
		return fmt.Sprintf(
			"the dataset above goes on a bp command line as `-d`, not as a query parameter — re-run `bp %s` with %s",
			verb, joinOr(flags))
	}

	// The command cannot carry -d. Naming the flag anyway would hand back a
	// remedy the outbound refusal (scope_honesty.go) will reject on the next
	// keystroke, so name the family's carrying doors instead.
	remedy := "`bp capabilities` marks the commands that carry a dataset"
	if siblings := manifest.DatasetCarryingSiblings(roster, cmd.Noun); len(siblings) > 0 {
		quoted := make([]string, 0, len(siblings))
		for _, s := range siblings {
			quoted = append(quoted, "`bp "+s+"`")
		}
		remedy = fmt.Sprintf("in this family %s %s the dataset",
			strings.Join(quoted, ", "), pluralCarry(len(siblings)))
	}
	return fmt.Sprintf(
		"`bp %s` cannot carry -d, so the disambiguator above is not typeable on this command — %s",
		verb, remedy)
}

// ambiguousDatasetNames pulls the colliding dataset names out of the envelope's
// `details`. It reads ONLY the `datasets` key and tolerates every other shape,
// for the reason apiError.details is kept as raw JSON: `details` is per-code and
// a typed decode that fits one shape fails the whole unmarshal on the others.
func ambiguousDatasetNames(raw json.RawMessage) []string {
	d := normalizeDetails(raw)
	if d == nil {
		return nil
	}
	var body struct {
		Datasets []string `json:"datasets"`
	}
	if err := json.Unmarshal(d, &body); err != nil {
		return nil
	}
	out := make([]string, 0, len(body.Datasets))
	for _, n := range body.Datasets {
		if n = strings.TrimSpace(n); n != "" {
			out = append(out, n)
		}
	}
	return out
}

// joinOr renders "a, b or c" — the operator picks exactly one.
func joinOr(parts []string) string {
	switch len(parts) {
	case 0:
		return ""
	case 1:
		return parts[0]
	}
	return strings.Join(parts[:len(parts)-1], ", ") + " or " + parts[len(parts)-1]
}

// manifestRoster is the served command list, or nil when the manifest is
// absent. handleResponseHinted's `m` is nil on several dispatch paths (the
// bootstrap/offline ones), and a nil roster is legal — DatasetCarryingSiblings
// simply finds no sibling and the generic `bp capabilities` clause answers.
func manifestRoster(m *manifest.Manifest) []manifest.Command {
	if m == nil {
		return nil
	}
	return m.Commands
}

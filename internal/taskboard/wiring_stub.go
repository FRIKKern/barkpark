// WIRING STUB — DELETE AT MERGE; real impls land from the spine and render slices
//
// This file exists ONLY so the Bubble Tea shell slice compiles and tests
// standalone on its own branch. It provides throwaway implementations of the
// three charter-frozen signatures owned by OTHER wave-1 slices:
//
//   - FetchSnapshot / BuildBoard  → data-spine slice (#1)
//   - Render                      → theme + portrait render slice (#2)
//
// The lead DELETES this file when merging, after those slices land their real
// implementations. The shell (program.go / live.go) calls these three by their
// frozen signatures and does not care which body answers — every test in this
// slice injects its own fetch/build funcs (Model.fetch / Model.build) so none
// of them depends on the stub behaviour below.
package taskboard

import (
	"time"

	"github.com/FRIKKern/barkpark/internal/apiclient"
)

// FetchSnapshot (stub) returns an empty, well-formed snapshot. The real impl
// decodes GET /v1/tasks + /v1/tasks/prime.
func FetchSnapshot(_ *apiclient.Client) (Snapshot, error) {
	return Snapshot{Counts: map[string]int{}, FetchedAt: time.Now()}, nil
}

// BuildBoard (stub) drops every task under Orphans with no organization. The
// real impl encodes the whole NOW/epic/orphan ranking + folding policy.
func BuildBoard(s Snapshot, _ RepoContext, _ time.Time) Board {
	return Board{
		Orphans: s.Tasks,
		Counts:  s.Counts,
		Events:  s.Events,
	}
}

// Render (stub) emits a single placeholder line. The real impl paints the
// portrait frame (header strip, NOW band, epic spine, ticker, footer).
func Render(_ Board, _ UIState, _, _ int, _ time.Time) string {
	return "loading task board…"
}

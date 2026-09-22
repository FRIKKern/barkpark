package cli

import (
	"encoding/json"
	"fmt"
	"sort"
	"strings"
)

// THE PAGE IS SHORT BY DESIGN AND SAID SO; THE CLIENT THREW THE SAYING AWAY.
//
// An UNSCOPED task index page withholds every doc_id that exists in more than
// one dataset. That is the dataset axis of the one-rule resolver, and it is
// correct: the same rule makes `GET /v1/tasks/:doc_id` answer 409
// `ambiguous_dataset` rather than silently pick a copy. Collapsing to one copy,
// or serving both, is exactly the guess the honest refusal replaced — so the
// remedy here reports the omission and MUST NOT un-collapse the page.
//
// The server does not hide what it withheld. The page envelope carries
//
//	page.dataset_ambiguous: [{doc_id, datasets:[…]}, …]
//
// naming every suppressed id and the datasets holding it. Measured live against
// guerrilla 2026-09-16: `bp task ls --all` returned 9424 rows and all eleven
// live twins (the ten aker-brygge<->production `akbr-*` rows plus the
// production<->tasks `stw1-basepath-redirect-fix`) had in-ls=0, while
// `grep -rn dataset_ambiguous internal/` on origin/main returned ZERO hits. The
// caller got a page short by eleven with no signal of any kind — and, the real
// cost, no way to DISCOVER the twin ids at all, because the `ambiguous_dataset`
// refusal only tells you about a twin once you already know its id.
//
// TWO HOLES, NOT ONE, AND THEY NEED DIFFERENT REMEDIES.
//
//  1. THE MACHINE HALF, AND ONLY UNDER --all. A single page passes the server's
//     envelope through untouched, so `-o json | jq .page.dataset_ambiguous`
//     already worked there. `--all` is the mode whose whole premise is "this is
//     the population", and it is the one that loses the field: the multi-page
//     stitch in paginatedAllWalk re-wraps as `{key: rows}` and drops every
//     sibling of the row array, `page` first among them. So the harder a caller
//     asked for completeness, the less they were told about the incompleteness.
//     Fixed by carrying the withheld set across the stitch (mergeDatasetTwins /
//     attachDatasetTwins) — metadata only, never a row.
//
//  2. THE PROSE HALF, IN BOTH MODES. Nothing on stderr, ever. Fixed by
//     datasetTwinsNotice, modelled on warnIfServerPromisesMoreRows: it only ever
//     ADDS a line, it fires only when the envelope itself names a withheld id,
//     and a missing or empty block says nothing — so no complete page becomes
//     noisy and the render of a twin-free ledger stays byte-identical.
//
// Derived from the envelope on every path. Never from a list of ids: an
// enumeration is a snapshot of one ledger on one day, and this one has already
// moved once.

// datasetTwin is one withheld doc_id and the datasets that hold it, exactly as
// the server states it.
type datasetTwin struct {
	DocID    string   `json:"doc_id"`
	Datasets []string `json:"datasets"`
}

// datasetTwinsFromPage reads `page.dataset_ambiguous` off a list envelope.
// A missing page block, a missing field, an unreadable body or an empty array
// all answer nil: this value only ever ADDS a claim that rows were withheld, so
// the absent case must be the one that claims nothing.
func datasetTwinsFromPage(payload []byte) []datasetTwin {
	var env struct {
		Page *struct {
			DatasetAmbiguous []datasetTwin `json:"dataset_ambiguous"`
		} `json:"page"`
	}
	if json.Unmarshal(payload, &env) != nil || env.Page == nil {
		return nil
	}
	out := make([]datasetTwin, 0, len(env.Page.DatasetAmbiguous))
	for _, twin := range env.Page.DatasetAmbiguous {
		if strings.TrimSpace(twin.DocID) == "" {
			continue
		}
		out = append(out, twin)
	}
	if len(out) == 0 {
		return nil
	}
	return out
}

// mergeDatasetTwins unions the withheld sets of two pages of one walk, keyed by
// doc_id. The set is a property of the SCOPE, not of the window, so every page
// of a walk restates the same ids — but a union rather than "keep page one" is
// what makes this correct if the ledger gains a twin mid-walk, and it is the
// only shape that does not depend on which page happened to answer first.
// Result is sorted by doc_id so the stitched envelope is deterministic.
func mergeDatasetTwins(acc []datasetTwin, page []datasetTwin) []datasetTwin {
	if len(page) == 0 {
		return acc
	}
	byID := make(map[string]datasetTwin, len(acc)+len(page))
	for _, twin := range acc {
		byID[twin.DocID] = twin
	}
	for _, twin := range page {
		byID[twin.DocID] = twin
	}
	merged := make([]datasetTwin, 0, len(byID))
	for _, twin := range byID {
		merged = append(merged, twin)
	}
	sort.Slice(merged, func(i, j int) bool { return merged[i].DocID < merged[j].DocID })
	return merged
}

// attachDatasetTwins puts the withheld set back onto the multi-page stitch, as
// `page.dataset_ambiguous` — the SAME path a single page carries, so one jq
// expression reads both modes and a script never has to know whether --all was
// used.
//
// It is a no-op for an empty set. That is the positive control this whole file
// turns on: a walk over a ledger with no twins re-wraps to byte-identical bytes,
// because a field that is always present measures nothing. It also never touches
// the row array — reporting the omission is the entire remedy; un-collapsing the
// page would be the guess the server deliberately refuses to make.
func attachDatasetTwins(wrapped []byte, twins []datasetTwin) []byte {
	if len(twins) == 0 {
		return wrapped
	}
	var env map[string]json.RawMessage
	if json.Unmarshal(wrapped, &env) != nil || env == nil {
		return wrapped
	}
	twinsJSON, err := json.Marshal(twins)
	if err != nil {
		return wrapped
	}
	page := map[string]json.RawMessage{}
	if raw, ok := env["page"]; ok {
		// Never clobber a page block the stitch already carries.
		_ = json.Unmarshal(raw, &page)
	}
	page["dataset_ambiguous"] = twinsJSON
	pageJSON, err := json.Marshal(page)
	if err != nil {
		return wrapped
	}
	env["page"] = pageJSON
	out, err := json.Marshal(env)
	if err != nil {
		return wrapped
	}
	return out
}

// datasetTwinsNotice is the prose half: the one stderr line that turns a
// silently-short page into a stated one. Empty string when nothing was
// withheld, which is every page on a single-dataset ledger.
//
// It names the ids, not just the count, because the count alone leaves the
// caller exactly where the defect left them: knowing a row is missing and having
// no way to name it. The list is capped so a pathological ledger cannot bury the
// rest of stderr, and the cap says how many it did not print.
func datasetTwinsNotice(twins []datasetTwin) string {
	if len(twins) == 0 {
		return ""
	}
	const maxNamed = 12
	named := twins
	suffix := ""
	if len(named) > maxNamed {
		named = named[:maxNamed]
		suffix = fmt.Sprintf(", and %d more", len(twins)-maxNamed)
	}
	parts := make([]string, 0, len(named))
	for _, twin := range named {
		if len(twin.Datasets) == 0 {
			parts = append(parts, twin.DocID)
			continue
		}
		parts = append(parts, fmt.Sprintf("%s (%s)", twin.DocID, strings.Join(twin.Datasets, ", ")))
	}
	return fmt.Sprintf(
		"this page WITHHELD %d row(s) that exist in more than one dataset, so it is SHORT by that many and the count is not the population: %s%s. "+
			"They are withheld, not missing — an unscoped page refuses to pick a copy, the same rule that makes `bp task get <id>` answer 409 ambiguous_dataset. "+
			"Name the dataset to see one (the envelope's page.dataset_ambiguous carries this same list under -o json).",
		len(twins), strings.Join(parts, "; "), suffix,
	)
}

// warnIfDatasetTwinsWithheld emits the notice for one response body. Silent for
// every envelope that carries no withheld set — which is the only reason it can
// be called unconditionally on every list page.
func warnIfDatasetTwinsWithheld(out *writer, body []byte) {
	if note := datasetTwinsNotice(datasetTwinsFromPage(body)); note != "" {
		out.userErr("%s", note)
	}
}

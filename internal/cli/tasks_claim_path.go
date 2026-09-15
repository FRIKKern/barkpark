package cli

import (
	"encoding/json"
	"fmt"
	"sort"
	"strings"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// THE CLAIM LIVES AT A DIFFERENT PATH PER READ VERB, AND THE WRONG PATH NEVER
// ERRORS — IT ANSWERS "UNCLAIMED", ON EVERY ROW, SILENTLY.
//
// MEASURED 2026-09-15 on origin/main 7bc83e643b1ef4b53c1845be24eb54eee00ca9ac
// against the live store, with `bp task ls --status in_progress -o json`:
//
//	rows on the page ................................... 25
//	.claim.worker non-null      (the TRUE path here) ... 25
//	.doc.claim.worker non-null  (the `task get` path) ...  0
//	rows carrying a `doc` key at all ....................  0
//	occurrences of `_misread` anywhere in the page ......  0
//
// Every live claim reads as absent. A UNIFORM VERDICT IS THE SIGNATURE OF A
// BROKEN INSTRUMENT, and this one FAILS TOWARD A WRITE: "nobody holds this row"
// is the precondition for a release or a re-claim, so a reconciliation sweep
// built on the wrong path steals rows another lane is actively working. This
// campaign's own coordinator issued a fleet-wide round-start order off exactly
// that reading and had to retract it.
//
// WHY THE `bp task get` REMEDY DOES NOT TRANSPLANT. tasks_get_misread.go closes
// the mirror-image misread by MATERIALISING the wrong path: `bp task get -o
// json` plants a `_misread` sentinel at `.doc.content.claim` so the wrong read
// answers a WRONG PATH string instead of null. That works there because it
// plants INSIDE an object (`doc.content`) the envelope already has, where the
// absence of the `claim` key carried no meaning.
//
// Here it would not. The dangerous path on a flat row is `.doc.claim.*`, so
// planting the sentinel means GIVING A FLAT ROW A `doc` KEY IT DOES NOT HAVE —
// and the presence or absence of `doc` is the load-bearing discriminator this
// repo's own readers use to tell the two shapes apart:
//
//	scripts/lib/landed_open_report.py:100  doc = row.get("doc", row) or {}
//	scripts/landed-mark.sh:551             doc = row.get("doc", row) or {}
//	scripts/ledger/claim-health.sh:92      doc = row.get("doc") if dict else row
//	scripts/branch-owner.sh:229            row = d.get("doc") if dict else d
//	scripts/epic-zero-criteria-census.sh:214,392,419,532
//	scripts/withdrawn_but_met.py:193 · scripts/pdf-mvp0-journey-proof.sh:1414
//	.codex/skills/legendary-cycle/scripts/validate_legendary_cycle.py:171,205
//
// Nine files, all CORRECT today, all of which would start reading the sentinel
// as the document. So the sentinel would fix a hypothetical hand-rolled jq
// reader by breaking nine real ones — including the repo's own claim-health
// tool, and the scheduled `landed-open-report` CI job, whose `--min-population`
// floor would then refuse at exit 2. A remedy that corrupts the discriminator
// is not the mirror image of the `get` sentinel; it is its inverse.
//
// WHAT THIS FILE DOES INSTEAD. It makes the WRONG SHAPE REFUSE rather than
// making the wrong PATH loud. There is exactly one place that says where a
// claim lives per read verb (taskReadShapes), and one reader that uses it
// (readTaskClaims). Point that reader at a payload from a DIFFERENT verb and it
// returns ErrReadyPageUnreadable — the `CANNOT READ:` refusal already
// established in tasks_ready_shape.go — naming the verb the payload actually
// came from and the path that verb's claims live at. The 30-of-30 silent
// NOCLAIM becomes one loud refusal, and nothing is added to the wire.
//
// THE SET IS FOUR, NOT TWO. A hand-listed get/ls pair is a snapshot. `bp task
// prime` is a THIRD shape — flat rows like ls, but under `in_progress` and
// `ready`, with no `docs` key at all — so a reader generalising from `ready`
// reads ZERO rows out of a prime payload. It is in the map below, and
// TestTaskClaimPathSymmetryHoldsForEveryVerb is a predicate over the map: a
// fifth shape added without a fixture and without a cross-refusal reds by name.

// taskReadShape says, for ONE task read verb, where its rows are and where a
// claim sits inside a row. It is the single source of truth this file, the
// help block, the stderr advisory and the tests all read.
type taskReadShape struct {
	// RowsKeys are the ENVELOPE keys carrying rows, in report order.
	RowsKeys []string
	// SingleRow marks a shape whose RowsKeys point at ONE object rather than a
	// list — `bp task get` answers {"doc":{…}}, not {"docs":[…]}.
	SingleRow bool
	// ClaimKey is the key, ON A ROW, holding the claim object. Every shape
	// agrees on this; the shapes differ only in how you reach the row.
	ClaimKey string
}

// taskReadShapes maps manifest command id -> shape. Keyed on the ID, never on
// the noun: `task stamp` and `task close` also take a doc_id and must not be
// treated as read shapes.
func taskReadShapes() map[string]taskReadShape {
	return map[string]taskReadShape{
		taskGetCommandID:   {RowsKeys: []string{"doc"}, SingleRow: true, ClaimKey: "claim"},
		taskLsCommandID:    {RowsKeys: []string{"docs"}, ClaimKey: "claim"},
		taskReadyCommandID: {RowsKeys: []string{"docs"}, ClaimKey: "claim"},
		taskPrimeCommandID: {RowsKeys: []string{"in_progress", "ready"}, ClaimKey: "claim"},
	}
}

const (
	taskReadyCommandID = "task.ready"
	taskPrimeCommandID = "task.prime"
)

// ClaimPaths renders the full jq paths a claim holder lives at for this shape,
// e.g. ".doc.claim.worker" or ".docs[].claim.worker". Rendered, never typed by
// hand, so the help, the advisory and the refusal text cannot drift from the
// reader.
func (s taskReadShape) ClaimPaths() []string {
	out := make([]string, 0, len(s.RowsKeys))
	for _, key := range s.RowsKeys {
		if s.SingleRow {
			out = append(out, fmt.Sprintf(".%s.%s.worker", key, s.ClaimKey))
			continue
		}
		out = append(out, fmt.Sprintf(".%s[].%s.worker", key, s.ClaimKey))
	}
	return out
}

// TaskClaimReport is the verdict over one task read payload.
type TaskClaimReport struct {
	// Rows is how many rows the payload carried, across every RowsKey.
	Rows int
	// ClaimKeyPresent is how many rows carry the claim key at all. A ready row
	// with nobody on it OMITS `claim` entirely, so this is NOT the claim count.
	ClaimKeyPresent int
	// Claimed is how many rows carry a non-empty claim worker.
	Claimed int
	// Workers are the distinct non-empty claim holders, sorted.
	Workers []string
}

// readTaskClaims reads `raw` AS the shape `shape` describes and reports who
// holds what — or refuses. It never returns a verdict it could not measure:
// every failure is ErrReadyPageUnreadable, whose message begins `CANNOT READ:`,
// so a failed read is never byte-identical to "nobody holds anything". Pure: no
// network, no writes, no mutation of raw.
func readTaskClaims(raw []byte, id string, shape taskReadShape) (TaskClaimReport, error) {
	var report TaskClaimReport

	if len(raw) == 0 {
		return report, readyPageUnreadable("%s: the payload was empty (0 bytes); a claim read over nothing is the confident zero this refusal exists to replace", id)
	}
	var env map[string]any
	if err := json.Unmarshal(raw, &env); err != nil {
		return report, readyPageUnreadable("%s: the payload is not a JSON object: %v", id, err)
	}

	found := false
	for _, key := range shape.RowsKeys {
		if _, present := env[key]; present {
			found = true
			break
		}
	}
	if !found {
		return report, readyPageUnreadable("%s: none of the row keys %v are present (top-level keys: %v)%s",
			id, shape.RowsKeys, sortedReadyKeys(env), taskShapeMismatchHint(id, env))
	}

	for _, key := range shape.RowsKeys {
		rawRows, present := env[key]
		if !present {
			// A shape may legitimately carry only some of its keys — `task
			// prime` with nothing in flight has no `in_progress`. The absence
			// of ALL of them is the refusal above; the absence of one is not.
			continue
		}
		rows, err := taskShapeRows(id, key, shape, rawRows)
		if err != nil {
			return TaskClaimReport{}, err
		}
		for i, entry := range rows {
			row, ok := entry.(map[string]any)
			if !ok {
				return TaskClaimReport{}, readyPageUnreadable("%s: %s[%d] is %T, not an object", id, key, i, entry)
			}
			report.Rows++
			claim, present := row[shape.ClaimKey]
			if !present {
				continue
			}
			report.ClaimKeyPresent++
			obj, ok := claim.(map[string]any)
			if !ok {
				continue
			}
			worker, _ := obj["worker"].(string)
			if worker == "" {
				continue
			}
			report.Claimed++
			report.Workers = append(report.Workers, worker)
		}
	}

	if report.Rows == 0 {
		return TaskClaimReport{}, readyPageUnreadable("%s: the payload carried ZERO rows under %v; a claim verdict over an empty page is indistinguishable from a page where nobody holds anything, which is the whole defect",
			id, shape.RowsKeys)
	}
	report.Workers = dedupeSortedStrings(report.Workers)
	return report, nil
}

// taskShapeRows normalises one RowsKey's value into a row list, refusing on the
// wrong container type. `task get`'s single `doc` object becomes a one-row list
// so the caller has ONE loop and cannot grow a second, divergent reader.
func taskShapeRows(id, key string, shape taskReadShape, rawRows any) ([]any, error) {
	if shape.SingleRow {
		obj, ok := rawRows.(map[string]any)
		if !ok {
			return nil, readyPageUnreadable("%s: `%s` is %T, not the single object this shape reads", id, key, rawRows)
		}
		return []any{obj}, nil
	}
	list, ok := rawRows.([]any)
	if !ok {
		return nil, readyPageUnreadable("%s: `%s` is %T, not a list", id, key, rawRows)
	}
	return list, nil
}

// taskShapeMismatchHint turns "I could not find my rows" into "you are holding
// another verb's payload, and here is whose, and here is where ITS claims are".
// This is the measured incident converted into a sentence: a `task get`-shaped
// reader aimed at a `task ls` page used to answer NOCLAIM on every row; it now
// gets told the page is a task.ls page and that the claims are at
// `.docs[].claim.worker`.
func taskShapeMismatchHint(id string, env map[string]any) string {
	var hints []string
	for otherID, other := range taskReadShapes() {
		if otherID == id {
			continue
		}
		for _, key := range other.RowsKeys {
			if _, present := env[key]; !present {
				continue
			}
			hints = append(hints, fmt.Sprintf("this payload is keyed `%s`, which is the %s shape — ITS claims live at %s",
				key, otherID, strings.Join(other.ClaimPaths(), " and ")))
			break
		}
	}
	if _, wrong := env["documents"]; wrong {
		hints = append(hints, "this envelope is keyed `documents`, which is what `bp doc ls` answers — no task verb does")
	}
	if len(hints) == 0 {
		return ""
	}
	sort.Strings(hints)
	return "; " + strings.Join(hints, "; ")
}

func dedupeSortedStrings(in []string) []string {
	if len(in) == 0 {
		return nil
	}
	seen := map[string]bool{}
	for _, s := range in {
		seen[s] = true
	}
	return sortedReadyKeys(seen)
}

// taskClaimPathHelpLines is the `--help` block for every task read verb. Each
// verb states ITS OWN claim path and disclaims the others', derived from
// taskReadShapes() so help and behaviour cannot drift — the same lock
// taskGetEnvelopeHelpLines carries on the other verb.
func taskClaimPathHelpLines(cmd manifest.Command) []string {
	shape, ok := taskReadShapes()[cmd.ID]
	if !ok {
		return nil
	}
	var others []string
	for otherID, other := range taskReadShapes() {
		if otherID == cmd.ID {
			continue
		}
		if sameClaimPaths(shape, other) {
			continue
		}
		others = append(others, fmt.Sprintf("%s (%s)", strings.Join(other.ClaimPaths(), ", "), otherID))
	}
	sort.Strings(others)

	lines := []string{
		"",
		"the claim on this verb's rows: " + strings.Join(shape.ClaimPaths(), " and "),
	}
	if len(others) > 0 {
		lines = append(lines,
			"  Other task read verbs put it somewhere else: "+strings.Join(others, ", ")+".",
			"  Those paths are ABSENT here and a missing key is not an error: the wrong one",
			"  answers null on EVERY row, which reads as UNCLAIMED and invites a claim steal.")
	}
	return lines
}

func sameClaimPaths(a, b taskReadShape) bool {
	return strings.Join(a.ClaimPaths(), "|") == strings.Join(b.ClaimPaths(), "|")
}

// emitTaskClaimPathAdvisory writes ONE stderr line, on machine output of a task
// read verb, WHEN AND ONLY WHEN the page actually carries a live claim — the
// only moment the misread can cost anything. stdout is never touched, so `-o
// json` stays one byte-identical document, and a page with nobody on it stays
// silent rather than teaching the fleet to ignore a line it sees every call.
//
// This is deliberately WEAKER than the `task get` sentinel, which reaches the
// jq reader in band. It has to be: the in-band remedy here would mean planting a
// `doc` key on a flat row, and the presence of `doc` is the discriminator nine
// of this repo's own readers use to tell the two shapes apart (see the header).
// Weaker and safe beats stronger and corrupting.
func emitTaskClaimPathAdvisory(out *writer, cmd manifest.Command, status int, machineOut bool, respBody []byte) {
	if !machineOut || status < 200 || status >= 300 {
		return
	}
	shape, ok := taskReadShapes()[cmd.ID]
	if !ok || shape.SingleRow {
		return
	}
	report, err := readTaskClaims(respBody, cmd.ID, shape)
	if err != nil || report.Claimed == 0 {
		return
	}
	out.errf("bp: %d of %d rows on this page are CLAIMED — the holder is at %s. `.doc.claim` is the `bp task get` shape and is absent from every row here; reading it answers null, which reads as UNCLAIMED.",
		report.Claimed, report.Rows, strings.Join(shape.ClaimPaths(), " / "))
}

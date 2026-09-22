package cli

import (
	"encoding/json"
	"fmt"
	"os"
	"sort"
	"testing"
)

// ─── THE RE-MEASUREMENT HARNESS ─────────────────────────────────────────────
//
// task-573618865e3c2b3f c3 asks for the affected rows to be RE-MEASURED at the
// time of the decision by running the SHIPPED predicate over every row carrying
// a `landed:pr-*` label — never by reusing an earlier figure, because "a row set
// is a snapshot and this one has already been shown to move within a day". It
// moved a great deal: nine rows on 2026-09-13, 1451 on 2026-09-17.
//
// A figure quoted in a comment goes stale the moment it is written, so the
// durable deliverable is the MEASURING INSTRUMENT, not the number. This test
// runs `landedMergeShaped`/`landedMergeDischarges` — the same two functions the
// verb itself calls, reached by being in-package — over a corpus file, and
// prints the population, the candidate count and the per-SHAPE split.
//
// It is SKIPPED unless `BP_LANDED_CORPUS` names a file, so it never turns a
// unit-test run into a network read or pins a number that the ledger owns.
// Cut the corpus with:
//
//	bp doc query task --filter 'labels *= landed:pr-' --all -o json > corpus.json
//	BP_LANDED_CORPUS=corpus.json go test ./internal/cli/ \
//	    -run TestMeasureLandedCandidatesOverCorpus -v
//
// INSTRUMENT NOTES, both of which have already produced a confident wrong zero
// on this exact question:
//
//   - the labels live at the DOCUMENT level (`.documents[].labels`), a list of
//     STRINGS. `.tags` on the same row is a list of OBJECTS, so a reader that
//     greps `.tags[]` for "landed" answers a clean ZERO on every row.
//   - `merge_gate` and `merge_discharges` are TRI-STATE. Decoding either into a
//     plain bool collapses ABSENT into false and erases the prose arm, which is
//     the arm that decides most of the corpus.
type landedCorpusRow struct {
	ID       string   `json:"_id"`
	Labels   []string `json:"-"`
	RawLabel []any    `json:"labels"`
	Criteria []struct {
		Criterion       string `json:"criterion"`
		Met             bool   `json:"met"`
		MergeGate       *bool  `json:"merge_gate"`
		MergeDischarges *bool  `json:"merge_discharges"`
	} `json:"acceptance_criteria"`
}

// landedCandidateShape names WHICH arm of landedMergeShaped admitted a
// criterion. The whole polarity question is about one of these three arms, so a
// measurement that reports only a total cannot answer it.
type landedCandidateShape string

const (
	shapeFieldTrue   landedCandidateShape = "field merge_gate:true"
	shapeWordedGate  landedCandidateShape = "prose MERGE-GATE(D) marker, no field"
	shapeWordedLand  landedCandidateShape = "prose landing wording, no field"
	shapeUnattribute landedCandidateShape = "unattributed"
)

func landedShapeOf(c landedCriterion) landedCandidateShape {
	if c.mergeGate != nil {
		if *c.mergeGate {
			return shapeFieldTrue
		}
		return shapeUnattribute
	}
	if mergeGateWordedRe.MatchString(c.text) {
		return shapeWordedGate
	}
	if landingWordedRe.MatchString(c.text) {
		return shapeWordedLand
	}
	return shapeUnattribute
}

func TestMeasureLandedCandidatesOverCorpus(t *testing.T) {
	path := os.Getenv("BP_LANDED_CORPUS")
	if path == "" {
		t.Skip("set BP_LANDED_CORPUS=<bp doc query task --filter 'labels *= landed:pr-' --all -o json> to re-measure")
	}

	blob, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("corpus %q: %v", path, err)
	}
	var page struct {
		Documents []landedCorpusRow `json:"documents"`
	}
	if err := json.Unmarshal(blob, &page); err != nil {
		t.Fatalf("corpus %q did not decode: %v", path, err)
	}
	if len(page.Documents) == 0 {
		t.Fatalf("corpus %q holds ZERO rows under .documents[] — an empty read is not a measurement", path)
	}

	var (
		rowsWithAny   int
		rowsResolvabl int
		criteriaSeen  int
		byShape       = map[landedCandidateShape]int{}
		resolvable    []string
	)

	for _, row := range page.Documents {
		var cands []landedCriterion
		for i, raw := range row.Criteria {
			criteriaSeen++
			lc := landedCriterion{
				index:           i,
				text:            raw.Criterion,
				met:             raw.Met,
				mergeGate:       raw.MergeGate,
				mergeDischarges: raw.MergeDischarges,
			}
			if lc.met {
				continue
			}
			if !landedMergeShaped(lc) || !landedMergeDischarges(lc) {
				continue
			}
			cands = append(cands, lc)
			byShape[landedShapeOf(lc)]++
		}
		if len(cands) > 0 {
			rowsWithAny++
		}
		// THE ARITY RULE is the measurement that matters. The verb sends an
		// index only when EXACTLY ONE criterion is a candidate; two or more and
		// it sends NONE and names them, because picking the first would be the
		// client adjudicating. So "carries a resolvable candidate" — the phrase
		// the 2026-09-13 figure used — means exactly one, not at least one.
		if len(cands) == 1 {
			rowsResolvabl++
			resolvable = append(resolvable, fmt.Sprintf("%s index %d [%s]", row.ID, cands[0].index, landedShapeOf(cands[0])))
		}
	}

	sort.Strings(resolvable)
	t.Logf("population: %d rows carrying a landed:pr-* label, %d acceptance criteria", len(page.Documents), criteriaSeen)
	t.Logf("rows with AT LEAST ONE candidate: %d", rowsWithAny)
	t.Logf("rows with EXACTLY ONE candidate (the verb actually sends an index): %d", rowsResolvabl)
	for _, s := range []landedCandidateShape{shapeFieldTrue, shapeWordedGate, shapeWordedLand, shapeUnattribute} {
		t.Logf("  candidate criteria admitted by %-34s %d", string(s)+":", byShape[s])
	}
	if os.Getenv("BP_LANDED_CORPUS_LIST") != "" {
		for _, r := range resolvable {
			t.Logf("resolvable: %s", r)
		}
	}
}

// TestMeasureProseFallbackMisfiresOverCorpus counts the population the
// `merge_gated?/1` moduledoc's 3.51% false-POSITIVE figure is a rate over:
// criteria whose WORDING carries the MERGE-GATE marker while no `merge_gate`
// field is present, so the wide prose arm — and only it — decides.
//
// It reports the denominator and the exemption take-up. It deliberately does
// NOT classify "genuine gate" vs "merely mentions": that is a reading of intent,
// not a predicate, and a harness that guessed it would manufacture a rate.
// Point it at a WHOLE-corpus cut, not the landed subset:
//
//	bp doc query task --fields acceptance_criteria --all -o json > all.json
//	BP_LANDED_CORPUS=all.json go test ./internal/cli/ \
//	    -run TestMeasureProseFallbackMisfiresOverCorpus -v
func TestMeasureProseFallbackMisfiresOverCorpus(t *testing.T) {
	path := os.Getenv("BP_LANDED_CORPUS")
	if path == "" {
		t.Skip("set BP_LANDED_CORPUS=<bp doc query task --fields acceptance_criteria --all -o json> to re-measure")
	}
	blob, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("corpus %q: %v", path, err)
	}
	var page struct {
		Documents []landedCorpusRow `json:"documents"`
	}
	if err := json.Unmarshal(blob, &page); err != nil {
		t.Fatalf("corpus %q did not decode: %v", path, err)
	}
	if len(page.Documents) == 0 {
		t.Fatalf("corpus %q holds ZERO rows under .documents[]", path)
	}

	var total, markerWorded, markerNoField, fieldTrue, fieldFalse, fieldFalseMarker int
	for _, row := range page.Documents {
		for _, raw := range row.Criteria {
			total++
			marker := mergeGateWordedRe.MatchString(raw.Criterion)
			if marker {
				markerWorded++
			}
			switch {
			case raw.MergeGate == nil:
				if marker {
					markerNoField++
				}
			case *raw.MergeGate:
				fieldTrue++
			default:
				fieldFalse++
				if marker {
					fieldFalseMarker++
				}
			}
		}
	}

	t.Logf("population: %d rows, %d acceptance criteria", len(page.Documents), total)
	t.Logf("criteria matching @merge_gate_worded at all:            %d", markerWorded)
	t.Logf("  ...of which the PROSE ARM decides (no merge_gate key): %d  <- the mis-fire denominator", markerNoField)
	t.Logf("criteria carrying an explicit merge_gate:true:           %d", fieldTrue)
	t.Logf("criteria carrying an explicit merge_gate:false:          %d", fieldFalse)
	t.Logf("  ...of those, marker-worded (the exemption door in use): %d", fieldFalseMarker)
}

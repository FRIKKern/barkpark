// Floor + shape guard for the hermetic fixture corpus (D130, task
// ttw22-fixture-overflow-enrichment).
//
// WHY THIS FILE EXISTS. drive.sh's hermetic D119 marker asserts can only fire
// while the flattened spine OVERFLOWS the wide board's window, and windowSpine
// paints nothing when it does not. So a corpus shrunk back under the overflow
// boundary would not RED those asserts — it would quietly turn each of them
// into a no-op, and a no-op passes. That is the same failure shape as a test
// file with zero subtests: zero subtests is also zero failures. The guard is
// therefore twofold and both halves are mechanical:
//
//   - auditCorpus (main.go) refuses to BOOT below the floors, so a shrink is a
//     loud fixture start-up failure rather than a silently disarmed assert;
//   - this file WALKS the committed corpus, enrols every document as its own
//     subtest, and asserts the floor on the enrolment count itself — so a
//     corpus that stopped being enrolled cannot read as a clean pass.
//
// The refusal arms below are controls: each mutates the corpus in exactly one
// way that must be refused, and the last one mutates it in a way that must NOT
// be. A guard that refuses everything and a guard that refuses nothing both
// look green from one direction only.
package main

import (
	"encoding/json"
	"strings"
	"testing"
)

type auditDoc struct {
	DocID     string `json:"doc_id"`
	Title     string `json:"title"`
	Lifecycle string `json:"lifecycle_status"`
	ParentID  string `json:"parent_id"`
}

func parseCorpus(t *testing.T, corpus string) []auditDoc {
	t.Helper()
	var raws []json.RawMessage
	if err := json.Unmarshal([]byte(corpus), &raws); err != nil {
		t.Fatalf("corpus does not parse: %v", err)
	}
	docs := make([]auditDoc, 0, len(raws))
	for i, raw := range raws {
		var d auditDoc
		if err := json.Unmarshal(raw, &d); err != nil {
			t.Fatalf("corpus doc %d does not parse: %v", i, err)
		}
		docs = append(docs, d)
	}
	return docs
}

// reserialize rebuilds a corpus literal from decoded docs so a mutation arm can
// hand auditCorpus a corpus that differs in exactly one respect.
func reserialize(t *testing.T, docs []auditDoc) string {
	t.Helper()
	body, err := json.Marshal(docs)
	if err != nil {
		t.Fatalf("reserialize: %v", err)
	}
	return string(body)
}

func primeFor(t *testing.T, docs []auditDoc) string {
	t.Helper()
	counts := map[string]int{}
	for _, d := range docs {
		counts[d.Lifecycle]++
	}
	body, err := json.Marshal(struct {
		OK     bool           `json:"ok"`
		Counts map[string]int `json:"counts"`
	}{OK: true, Counts: counts})
	if err != nil {
		t.Fatalf("primeFor: %v", err)
	}
	return string(body)
}

// TestCommittedCorpusPasses is the positive arm AND the floor guard: it enrols
// every committed document as a subtest and then requires the enrolment count
// to clear corpusFloorDocs, so an empty or shrunken walk cannot read as a pass.
func TestCommittedCorpusPasses(t *testing.T) {
	all, inProgress, err := auditCorpus(corpusJSON, primeJSON)
	if err != nil {
		t.Fatalf("committed corpus refused by its own audit: %v", err)
	}

	docs := parseCorpus(t, corpusJSON)
	if len(docs) != len(all) {
		t.Fatalf("audit returned %d docs, corpus holds %d", len(all), len(docs))
	}

	ids := map[string]bool{}
	for _, d := range docs {
		ids[d.DocID] = true
	}
	enrolled, sections, claimed := 0, 0, 0
	children := map[string]int{}
	for _, d := range docs {
		if d.ParentID != "" {
			children[d.ParentID]++
		}
	}
	for _, d := range docs {
		d := d
		t.Run(d.DocID, func(t *testing.T) {
			if strings.TrimSpace(d.Title) == "" {
				t.Errorf("%s has no title — the rendered title IS the row identity (D118)", d.DocID)
			}
			if d.ParentID != "" && !ids[d.ParentID] {
				t.Errorf("%s names parent %q, which is not in the corpus", d.DocID, d.ParentID)
			}
			switch d.Lifecycle {
			case "open", "in_progress", "blocked", "done":
			default:
				t.Errorf("%s has lifecycle_status %q, which the board does not render", d.DocID, d.Lifecycle)
			}
		})
		enrolled++
		if children[d.DocID] > 0 {
			sections++
		}
		if d.Lifecycle == "in_progress" {
			claimed++
		}
	}

	// THE FLOOR. Everything above this line is per-document; this is the check
	// that the walk covered enough documents to mean anything.
	if enrolled < corpusFloorDocs {
		t.Fatalf("enrolled %d documents, floor is %d — below the floor the wide spine stops overflowing at 130x40 and drive.sh's D119 marker asserts measure nothing", enrolled, corpusFloorDocs)
	}
	if sections < corpusFloorSections {
		t.Fatalf("enrolled %d epic sections, floor is %d", sections, corpusFloorSections)
	}
	if claimed != len(inProgress) {
		t.Fatalf("audit filtered %d in_progress docs, the walk counted %d", len(inProgress), claimed)
	}
}

// TestCorpusAuditRefuses is the control set: each arm mutates the committed
// corpus in exactly ONE way and states whether the audit must refuse it.
func TestCorpusAuditRefuses(t *testing.T) {
	base := parseCorpus(t, corpusJSON)

	cases := []struct {
		name    string
		mutate  func([]auditDoc) []auditDoc
		refuse  bool
		wantSub string
	}{
		{
			name:    "empty corpus",
			mutate:  func([]auditDoc) []auditDoc { return nil },
			refuse:  true,
			wantSub: "EMPTY",
		},
		{
			name:    "shrunk below the overflow floor",
			mutate:  func(d []auditDoc) []auditDoc { return d[:corpusFloorDocs-1] },
			refuse:  true,
			wantSub: "floor is",
		},
		{
			name: "two rows share a title",
			mutate: func(d []auditDoc) []auditDoc {
				out := append([]auditDoc(nil), d...)
				out[len(out)-1].Title = out[0].Title
				return out
			},
			refuse:  true,
			wantSub: "row identity",
		},
		{
			name: "two rows share a doc_id",
			mutate: func(d []auditDoc) []auditDoc {
				out := append([]auditDoc(nil), d...)
				out[len(out)-1].DocID = out[0].DocID
				return out
			},
			refuse:  true,
			wantSub: "appears twice",
		},
		{
			name: "a leaf points at a parent that is not there",
			mutate: func(d []auditDoc) []auditDoc {
				out := append([]auditDoc(nil), d...)
				out[1].ParentID = "fx-does-not-exist"
				return out
			},
			refuse:  true,
			wantSub: "names no document",
		},
		{
			name: "one more open row, prime counts kept in step",
			mutate: func(d []auditDoc) []auditDoc {
				return append(append([]auditDoc(nil), d...), auditDoc{
					DocID:     "fx-extra-open",
					Title:     "An extra fixture row",
					Lifecycle: "open",
				})
			},
			refuse: false,
		},
	}

	for _, tc := range cases {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			docs := tc.mutate(append([]auditDoc(nil), base...))
			_, _, err := auditCorpus(reserialize(t, docs), primeFor(t, docs))
			if tc.refuse {
				if err == nil {
					t.Fatalf("audit ACCEPTED a corpus it must refuse (%s)", tc.name)
				}
				if !strings.Contains(err.Error(), tc.wantSub) {
					t.Fatalf("refusal did not name the cause: got %q, want a message containing %q", err, tc.wantSub)
				}
				return
			}
			if err != nil {
				t.Fatalf("audit refused a legitimate corpus (%s): %v", tc.name, err)
			}
		})
	}
}

// TestPrimeCountsMustTrackTheCorpus pins the OTHER half of the boot audit: the
// board's truncation-honesty check compares len(tasks) against the summed prime
// counts, so a corpus edit that forgets primeJSON makes the board declare
// itself truncated. The committed pair must agree; a drifted pair must refuse.
func TestPrimeCountsMustTrackTheCorpus(t *testing.T) {
	if _, _, err := auditCorpus(corpusJSON, primeJSON); err != nil {
		t.Fatalf("committed corpus/prime pair disagree: %v", err)
	}
	docs := parseCorpus(t, corpusJSON)
	drifted := strings.Replace(primeJSON, `"open": 21`, `"open": 20`, 1)
	if drifted == primeJSON {
		t.Fatalf("prime drift arm did not mutate anything — the open count is no longer 21, re-point this control")
	}
	_, _, err := auditCorpus(reserialize(t, docs), drifted)
	if err == nil {
		t.Fatal("audit ACCEPTED prime counts that do not sum to the corpus")
	}
	if !strings.Contains(err.Error(), "truncated") && !strings.Contains(err.Error(), "prime counts") {
		t.Fatalf("refusal did not name the cause: %v", err)
	}
}

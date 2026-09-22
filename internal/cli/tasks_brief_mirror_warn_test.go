package cli

import (
	"encoding/json"
	"os"
	"strings"
	"testing"
)

// WHICH STRIP RULE THE WARNING USES, RECORDED HERE BECAUSE AN UNSTATED CHOICE
// MAKES THE WARNING LIE ON EXACTLY THE ROWS THAT PROVOKED IT.
//
// The warning's canonical expectation is THE GO COMPOSER'S ONE PASS —
// briefPurposeStripOnePass, strings.NewReplacer over "**", "__" and "`", one
// non-overlapping left-to-right sweep — and NOT the server's three sequential,
// rescanning String.replace/3 passes in brief_mirror.ex.
//
// THE REASON THE CHOICE MATTERS IS task-8ba550b59141bccb. That row reported
// that the two sites transform differently (`foo_**_bar` -> `foo__bar` one
// pass, `foobar` three passes); task-b641646addba4bdf carries the server-side
// remedy; both are open. The composer's pass is canonical because the server
// declares the composer as its contract and is the side that breaks it, because
// the composer is upstream (the CLI writes the brief, the server RE-derives
// it), and because a rescanning strip destroys literal characters that only
// became adjacent when a delimiter was removed — which a mirror whose whole job
// is not to rewrite prose must never do. tasks_brief_strip_parity_test.go
// argues all three at length and pins the composer's side against the 1,313-row
// shared corpus.
//
// AND THE WARNING TOLERATES THE OTHER RULE. A brief that fails the one-pass
// expectation but MATCHES the three-pass one was written faithfully by the
// server as it behaves today, so it is legacy normalisation, not a false
// record, and the warning stays quiet. Measured over all 9,119 published task
// documents on 2026-09-17, EXACTLY ONE row is in that class — and it is
// task-8ba550b59141bccb itself. It is in the fixture below, asserted QUIET, so
// a future edit that drops the tolerance reds here on the very row the
// tolerance exists for.
//
// THE POPULATION THE FIXTURE IS DRAWN FROM, same measurement, stated as a SPLIT
// because a uniform verdict is the signature of a broken comparator and this
// family has already produced three of those:
//
//	purpose-copy   EXACT 4,774 | DIVERGENT 1,611 terminal + 147 live |
//	               THREE-PASS-ONLY 1 | stub/no-block the rest
//	criteria-list  EXACT 3,052 | DIVERGENT 150 (94 by count, 56 by text)
//
// Those figures reproduce the counts this row inherited (1,611 / 150 = 94+56)
// from an independent implementation, which is why the rules below are believed
// to be the server's rules and not a guess at them.

type briefMirrorFixtureRow struct {
	Name       string          `json:"name"`
	Note       string          `json:"note"`
	Lifecycle  string          `json:"lifecycle_status"`
	WantWarn   bool            `json:"want_warn"`
	WantBlocks []string        `json:"want_blocks"`
	Envelope   json.RawMessage `json:"envelope"`
}

const briefMirrorFixturePath = "testdata/brief_mirror_rows.json"

func loadBriefMirrorFixture(t *testing.T) []briefMirrorFixtureRow {
	t.Helper()
	raw, err := os.ReadFile(briefMirrorFixturePath)
	if err != nil {
		t.Fatalf("read %s: %v", briefMirrorFixturePath, err)
	}
	var rows []briefMirrorFixtureRow
	if err := json.Unmarshal(raw, &rows); err != nil {
		t.Fatalf("parse %s: %v", briefMirrorFixturePath, err)
	}
	if len(rows) == 0 {
		t.Fatalf("%s is empty — an empty fixture makes every assertion below vacuous", briefMirrorFixturePath)
	}
	return rows
}

// TestBriefMirrorWarningOnLiveFixture is the row's pinning test. Every envelope
// is a REAL published document, field-for-field as the server returned it on
// 2026-09-17, so the rules are checked against the shapes they actually meet
// rather than against the author's model of them.
func TestBriefMirrorWarningOnLiveFixture(t *testing.T) {
	rows := loadBriefMirrorFixture(t)

	// THE FIXTURE MUST CARRY BOTH VERDICTS ON BOTH SURFACES. A fixture that
	// drifted to all-quiet or all-loud would pass a comparator that had stopped
	// working, which is exactly how the three previous comparators on this
	// family got believed.
	saw := map[string]int{}
	for _, row := range rows {
		if !row.WantWarn {
			saw["quiet"]++
			continue
		}
		saw["loud"]++
		for _, b := range row.WantBlocks {
			saw[strings.SplitN(b, " ", 2)[0]]++
		}
	}
	for _, need := range []string{"quiet", "loud", "purpose-copy", "criteria-list"} {
		if saw[need] == 0 {
			t.Fatalf("fixture carries no %q case (%v) — this test can no longer discriminate", need, saw)
		}
	}

	for _, row := range rows {
		t.Run(row.Name, func(t *testing.T) {
			got, ok := briefMirrorDivergenceFrom(row.Envelope)
			if ok != row.WantWarn {
				t.Fatalf("%s (%s): warn=%v, want %v. %s", row.Name, row.Lifecycle, ok, row.WantWarn, row.Note)
			}
			if !row.WantWarn {
				return
			}
			if got.DocID != row.Name {
				t.Fatalf("warning named %q, want %q — a notice that misnames its row sends the reader to the wrong document", got.DocID, row.Name)
			}
			if strings.Join(got.Blocks, "|") != strings.Join(row.WantBlocks, "|") {
				t.Fatalf("%s: divergent blocks %v, want %v", row.Name, got.Blocks, row.WantBlocks)
			}
			// The rendered line must NAME the divergent block id — criterion 1
			// of task-909ce143996407e3 — and must carry the remedy that fits
			// this row's lifecycle, not the other one.
			lines := strings.Join(briefMirrorWarnLines(got), "\n")
			for _, want := range row.WantBlocks {
				if !strings.Contains(lines, strings.SplitN(want, " ", 2)[0]) {
					t.Fatalf("%s: warning does not name block %q:\n%s", row.Name, want, lines)
				}
			}
			terminal := row.Lifecycle == "done" || row.Lifecycle == "cancelled"
			if terminal != got.Terminal {
				t.Fatalf("%s: terminal=%v for lifecycle %q", row.Name, got.Terminal, row.Lifecycle)
			}
			if terminal && !strings.Contains(lines, "FROZEN HISTORICAL RESIDUE") {
				t.Fatalf("%s is terminal but the notice offers a live remedy:\n%s", row.Name, lines)
			}
			if !terminal && !strings.Contains(lines, "SELF-HEALING") {
				t.Fatalf("%s is live but the notice calls the residue frozen:\n%s", row.Name, lines)
			}
		})
	}
}

// TestBriefMirrorWarningFlipsWhenTheMIRRORIsMUTATED is the RED-ON-REVERSION arm
// criterion 2 asks for, and it changes something rather than re-running the
// builder's own query: it MUTATES each fixture row's brief block and demands
// the verdict move. Both directions, on the same real documents.
//
//   - REPAIR a loud row: overwrite purpose-copy with the canonical one-pass
//     strip of its own description, and the row must go QUIET. A comparator
//     that stayed loud is not reading the block at all.
//   - BREAK a quiet row: overwrite purpose-copy with text no description
//     produces, and the row must go LOUD. A comparator that stayed quiet is
//     answering from something other than the comparison.
//
// A test that only ever fired one of these would be the uniform verdict this
// family has already been fooled by three times, so both counts are asserted
// non-zero.
func TestBriefMirrorWarningFlipsWhenTheMIRRORIsMUTATED(t *testing.T) {
	rows := loadBriefMirrorFixture(t)
	repaired, broken := 0, 0
	for _, row := range rows {
		var env map[string]any
		if err := json.Unmarshal(row.Envelope, &env); err != nil {
			t.Fatalf("%s: decode envelope: %v", row.Name, err)
		}
		doc, _ := env["doc"].(map[string]any)
		content, _ := doc["content"].(map[string]any)
		brief, _ := content["brief"].(map[string]any)
		blocks, _ := brief["blocks"].([]any)
		description, hasDescription := content["description"].(string)
		if !hasDescription {
			continue
		}
		var purpose map[string]any
		for _, b := range blocks {
			if m, ok := b.(map[string]any); ok && m["id"] == "purpose-copy" {
				purpose = m
			}
		}
		if purpose == nil {
			continue
		}

		mutate := func(value string) (briefMirrorDivergence, bool) {
			purpose["content"] = []any{map[string]any{"type": "text", "value": value}}
			raw, err := json.Marshal(env)
			if err != nil {
				t.Fatalf("%s: marshal mutated envelope: %v", row.Name, err)
			}
			return briefMirrorDivergenceFrom(raw)
		}

		// REPAIR. Only meaningful on a row whose ONLY divergent block is
		// purpose-copy; hgw5 diverges on criteria-list too and must stay loud.
		onlyPurpose := len(row.WantBlocks) == 1 && strings.HasPrefix(row.WantBlocks[0], "purpose-copy")
		if onlyPurpose {
			if _, ok := mutate(briefPurposeStripOnePass(description)); ok {
				t.Fatalf("%s: writing the canonical mirror into purpose-copy left the warning firing — the comparator is not reading the block", row.Name)
			}
			repaired++
		}

		// BREAK. A value no strip rule can produce from this description.
		if _, ok := mutate("MUTATED — this text is in no description in the ledger"); !ok {
			t.Fatalf("%s: a purpose-copy block that mirrors nothing did not warn — the comparator is answering from something other than the comparison", row.Name)
		}
		broken++
	}
	if repaired == 0 || broken == 0 {
		t.Fatalf("mutation control did not discriminate: %d repaired-to-quiet, %d broken-to-loud", repaired, broken)
	}
}

// TestBriefMirrorStripRulesDisagreeAsRecorded is the CONTROL on the tolerance.
// It proves the two strip rules are genuinely different functions here, so the
// tolerance in briefMirrorDivergenceOf is doing work rather than being a
// second copy of the same call.
func TestBriefMirrorStripRulesDisagreeAsRecorded(t *testing.T) {
	cases := []struct {
		in         string
		onePass    string
		threePass  string
		theyDiffer bool
	}{
		{in: "foo_**_bar", onePass: "foo__bar", threePass: "foobar", theyDiffer: true},
		{in: "_**_", onePass: "__", threePass: "", theyDiffer: true},
		{in: "*__*", onePass: "**", threePass: "**"},
		{in: "**bold** and `code`", onePass: "bold and code", threePass: "bold and code"},
		{in: "  a plain description  ", onePass: "a plain description", threePass: "a plain description"},
	}
	differed, agreed := 0, 0
	for _, tc := range cases {
		if got := briefPurposeStripOnePass(tc.in); got != tc.onePass {
			t.Fatalf("one pass on %q gave %q, want %q", tc.in, got, tc.onePass)
		}
		if got := briefPurposeStripLegacyThreePass(tc.in); got != tc.threePass {
			t.Fatalf("three passes on %q gave %q, want %q", tc.in, got, tc.threePass)
		}
		if tc.theyDiffer {
			if tc.onePass == tc.threePass {
				t.Fatalf("%q was listed as divergent but both rules give %q", tc.in, tc.onePass)
			}
			differed++
			continue
		}
		if tc.onePass != tc.threePass {
			t.Fatalf("%q was listed as agreeing but the rules give %q and %q", tc.in, tc.onePass, tc.threePass)
		}
		agreed++
	}
	if differed == 0 || agreed == 0 {
		t.Fatalf("control did not discriminate: %d divergent, %d agreeing — a uniform verdict proves nothing", differed, agreed)
	}
}

// TestBriefMirrorWarningIsSilentOnAListPage is the NOISE arm. The ruling left
// 1,761 rows an operator cannot fix; a warning that fired once per row on
// `bp task ls` or `bp task ready` would be muted within a day. It is keyed on
// the single-document envelope, so a list page — even one whose rows carry the
// divergence — says nothing.
func TestBriefMirrorWarningIsSilentOnAListPage(t *testing.T) {
	rows := loadBriefMirrorFixture(t)
	var loud json.RawMessage
	for _, row := range rows {
		if row.WantWarn {
			loud = row.Envelope
			break
		}
	}
	if loud == nil {
		t.Fatal("fixture carries no divergent row — nothing to build a list page from")
	}
	// Control: the same document, alone, DOES warn.
	if _, ok := briefMirrorDivergenceFrom(loud); !ok {
		t.Fatal("control failed: the single-document envelope no longer warns, so a silent list page below would prove nothing")
	}
	var doc map[string]any
	if err := json.Unmarshal(loud, &doc); err != nil {
		t.Fatalf("decode fixture envelope: %v", err)
	}
	page, err := json.Marshal(map[string]any{"count": 2, "documents": []any{doc["doc"], doc["doc"]}})
	if err != nil {
		t.Fatalf("marshal list page: %v", err)
	}
	if d, ok := briefMirrorDivergenceFrom(page); ok {
		t.Fatalf("a list page warned about %s — this notice must stay one row at a time or it becomes noise the operator mutes", d.DocID)
	}
}

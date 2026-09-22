package cli

import (
	"bufio"
	"encoding/json"
	"net/http"
	"os"
	"strings"
	"testing"
)

// ---------------------------------------------------------------------------
// ve-bl-stamp-flatkey-bug criterion 2 — regression tests that inspect PERSISTED
// content, not the request that produced it.
//
// The sibling file (set_key_bracket_index_test.go) proves the write seam
// REFUSES a bracketed key. That is an assertion about an error value. This file
// asserts the two things a reader of the row actually cares about, off the
// stored document:
//
//	1. the updated criterion is on the ARRAY ELEMENT (met + evidence), and
//	2. no key anywhere in the document starts `acceptance_criteria[`.
//
// MUTATION PROOF (run it, do not trust it): delete both checkSetKeyIndexing
// calls in buildBody's --set loop (internal/cli/run.go ~2085, ~2112) and
// TestStampPersistsOnTheArrayElementNotABracketKey reds on
// "bracket-indexed key REACHED the store" — the guarded write marshals onto the
// wire and the stand-in store, which merges shallowly exactly as
// Barkpark.Content.Mutations.apply_one/3 does, keeps it as a literal key.
//
// The live half is TestCriteriaResidueLiveCorpus below: opt-in, pointed at a
// real `bp export --type task` NDJSON stream.
// ---------------------------------------------------------------------------

func TestScanCriteriaResidue(t *testing.T) {
	// The CONTROL comes first: a scanner that reports nothing is worthless
	// until it is shown to report something, and every "zero stray keys"
	// verdict below is worth exactly what this arm is worth.
	t.Run("CONTROL — planted residue is named, with its path", func(t *testing.T) {
		doc := map[string]any{
			"acceptance_criteria[5].evidence": "proof",
			"acceptance_criteria[5].met":      true,
			"acceptance_criteria":             storedCriteria(),
		}
		got := ScanCriteriaResidue(doc)
		if len(got) != 2 {
			t.Fatalf("ScanCriteriaResidue = %#v, want both planted keys", got)
		}
		if got[0].Path != "acceptance_criteria[5].evidence" || !got[0].IsCriteria() {
			t.Fatalf("first hit = %#v, want the evidence key named as criteria residue", got[0])
		}
		if got[1].Head != "acceptance_criteria" {
			t.Fatalf("second hit = %#v, want the head it pretends to index", got[1])
		}
	})

	t.Run("CONTROL — residue nested under another object is still found", func(t *testing.T) {
		doc := map[string]any{"content": map[string]any{
			"acceptance_criteria[0].met": true,
		}}
		got := ScanCriteriaResidue(doc)
		if len(got) != 1 || got[0].Path != "content.acceptance_criteria[0].met" {
			t.Fatalf("ScanCriteriaResidue = %#v, want the nested path", got)
		}
	})

	t.Run("CONTROL — residue inside an array element is still found", func(t *testing.T) {
		doc := map[string]any{"history": []any{
			map[string]any{"ok": true},
			map[string]any{"blocks[2].text": "x"},
		}}
		got := ScanCriteriaResidue(doc)
		if len(got) != 1 || got[0].Path != "history[1].blocks[2].text" || got[0].IsCriteria() {
			t.Fatalf("ScanCriteriaResidue = %#v, want the indexed path and NOT a criteria hit", got)
		}
	})

	// ── the quiet half: what must never be reported ─────────────────────────
	t.Run("a healthy row reports nothing", func(t *testing.T) {
		doc := map[string]any{
			"title":               "a row",
			"acceptance_criteria": storedCriteria(),
			"labels":              []any{"proj:x"},
		}
		if got := ScanCriteriaResidue(doc); len(got) != 0 {
			t.Fatalf("ScanCriteriaResidue = %#v, want nothing on a clean row", got)
		}
	})

	t.Run("brackets in a VALUE are not residue", func(t *testing.T) {
		doc := map[string]any{
			"description": "see acceptance_criteria[5] in the old row",
			"note":        "blocks[0].text was the other spelling",
		}
		if got := ScanCriteriaResidue(doc); len(got) != 0 {
			t.Fatalf("ScanCriteriaResidue = %#v, want nothing — the scanner reads KEYS", got)
		}
	})
}

// TestStampPersistsOnTheArrayElementNotABracketKey is the persisted-content
// regression: drive both spellings through buildBody into the stand-in store
// and then read the STORE, asserting the criterion moved on the element and the
// document carries no bracket key.
func TestStampPersistsOnTheArrayElementNotABracketKey(t *testing.T) {
	store := newMutateStore(map[string]any{
		"title":               "a row",
		"acceptance_criteria": storedCriteria(),
	})
	srv := store.serve(t)
	defer srv.Close()

	patch := nestingDocPatch()
	args := map[string]string{"type": "task", "id": "ve-bl-stamp-flatkey-bug"}

	send := func(t *testing.T, sets ...string) error {
		t.Helper()
		body, _, ct, err := buildBody(patch, map[string][]string{"set": sets}, args)
		if err != nil {
			return err
		}
		resp, perr := http.Post(srv.URL+"/v1/data/mutate/production", ct, strings.NewReader(string(body)))
		if perr != nil {
			t.Fatalf("POST mutate: %v", perr)
		}
		_ = resp.Body.Close()
		resp, perr = http.Post(srv.URL+"/v1/data/mutate/production", "application/json",
			strings.NewReader(`{"mutations":[{"publish":{"id":"ve-bl-stamp-flatkey-bug","type":"task"}}]}`))
		if perr != nil {
			t.Fatalf("POST publish: %v", perr)
		}
		_ = resp.Body.Close()
		return nil
	}

	// Arm 1 — the spelling that produced the residue. Pre-fix it is accepted,
	// lands on the wire and sticks in the store as a literal key.
	if err := send(t, `acceptance_criteria[5]:={"met":true,"evidence":"proof"}`); err == nil {
		t.Errorf("the bracket spelling was accepted at the seam")
	}
	if residue := ScanCriteriaResidue(store.published); len(residue) != 0 {
		t.Fatalf("a bracket-indexed key REACHED the store: %#v (published = %#v)", residue, store.published)
	}

	// Arm 2 — the spelling that DOES update the element. The persisted array is
	// what is read back: same length, and the criterion carries its evidence.
	if err := send(t, `acceptance_criteria:=[`+
		`{"criterion":"first","met":true,"evidence":"gate green: go test ./internal/cli/"},`+
		`{"criterion":"second","met":false,"evidence":""}]`); err != nil {
		t.Fatalf("the correct spelling must land: %v", err)
	}
	arr, _ := store.published["acceptance_criteria"].([]any)
	if len(arr) != 2 {
		t.Fatalf("acceptance_criteria = %#v, want the canonical 2-element array", store.published["acceptance_criteria"])
	}
	first, _ := arr[0].(map[string]any)
	if first["met"] != true || first["evidence"] != "gate green: go test ./internal/cli/" {
		t.Fatalf("criterion 0 = %#v, want met+evidence ON THE ELEMENT", arr[0])
	}
	if second, _ := arr[1].(map[string]any); second["met"] != false {
		t.Fatalf("criterion 1 = %#v, want the untouched neighbour left alone", arr[1])
	}
	if residue := ScanCriteriaResidue(store.published); len(residue) != 0 {
		t.Fatalf("the CORRECT write left residue behind: %#v", residue)
	}
}

// TestCriteriaResidueLiveCorpus is the live corpus scan, opt-in because it
// needs a real ledger export:
//
//	env -u BARKPARK_TOKEN bp export --type task > corpus.ndjson
//	BARKPARK_CORPUS_NDJSON=$PWD/corpus.ndjson \
//	  go test ./internal/cli/ -run TestCriteriaResidueLiveCorpus -v
//
// NOTE on the instrument: `bp export` refuses to ATTEST completeness when the
// stream is close-delimited, and says so on stderr while still writing every
// document it received. A zero here therefore means "zero across the documents
// this export delivered", and the test prints that count so the verdict carries
// its own denominator rather than implying a whole-corpus sweep it cannot
// prove.
func TestCriteriaResidueLiveCorpus(t *testing.T) {
	path := os.Getenv("BARKPARK_CORPUS_NDJSON")
	if path == "" {
		t.Skip("set BARKPARK_CORPUS_NDJSON to an NDJSON export to run the live scan")
	}
	f, err := os.Open(path)
	if err != nil {
		t.Fatalf("open corpus: %v", err)
	}
	defer f.Close()

	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 1<<20), 1<<26)
	docs, dirty := 0, 0
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" {
			continue
		}
		var doc map[string]any
		if err := json.Unmarshal([]byte(line), &doc); err != nil {
			t.Fatalf("document %d is not JSON: %v", docs+1, err)
		}
		docs++
		if residue := ScanCriteriaResidue(doc); len(residue) != 0 {
			dirty++
			id, _ := doc["_id"].(string)
			paths := make([]string, 0, len(residue))
			for _, r := range residue {
				paths = append(paths, r.Path)
			}
			t.Errorf("stray bracket keys on %s: %s", id, strings.Join(paths, ", "))
		}
	}
	if err := sc.Err(); err != nil {
		t.Fatalf("read corpus: %v", err)
	}
	if docs == 0 {
		t.Fatal("corpus held zero documents — the scan measured nothing")
	}
	t.Logf("scanned %d documents from %s; %d carried stray bracket keys", docs, path, dirty)
}

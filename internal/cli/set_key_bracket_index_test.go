package cli

import (
	"net/http"
	"strings"
	"testing"
)

// ---------------------------------------------------------------------------
// ve-bl-stamp-flatkey-bug — a task row once carried two TOP-LEVEL content keys
// literally named `acceptance_criteria[5].evidence` and
// `acceptance_criteria[5].met` while the canonical acceptance_criteria array
// was untouched. The stamp looked like it landed: a rev came back, the exit was
// 0, and the evidence sat where no reader looks.
//
// The write seam is `--set`. The merge is SHALLOW at every write path
// (Barkpark.Content.Mutations.apply_one/3), so a BRACKET is no more an index
// into a stored list than a dot is a path. Before the fix:
//
//	--set 'acceptance_criteria[5]:={…}'       → accepted, literal key stored
//	--set 'acceptance_criteria[5].evidence=…' → refused, but the refusal's own
//	                                            hint SPELLED the accepted form
//
// so the guard that existed handed the caller the exact spelling that produced
// the residue. checkSetKeyIndexing now runs FIRST and refuses the whole shape.
//
// MUTATION PROOF: delete either checkSetKeyIndexing call in buildBody's --set
// loop (internal/cli/run.go) and TestSetBracketIndexedKeyIsRefused and
// TestPatchBracketIndexedCriterionReproduction both red — the typed arm because
// the bracket key marshals onto the wire and into the store, the dotted arm
// because it falls back to the nesting hint that names `…[5]:={…}`.
// ---------------------------------------------------------------------------

// storedCriteria is the canonical array shape a stamp is supposed to update.
func storedCriteria() []any {
	return []any{
		map[string]any{"criterion": "first", "met": false, "evidence": ""},
		map[string]any{"criterion": "second", "met": false, "evidence": ""},
	}
}

func TestSetBracketIndexedKeyIsRefused(t *testing.T) {
	patch := nestingDocPatch()
	args := map[string]string{"type": "task", "id": "ve-bl-stamp-flatkey-bug"}

	refusalFor := func(t *testing.T, kv string) string {
		t.Helper()
		body, _, _, err := buildBody(patch, map[string][]string{"set": {kv}}, args)
		if err == nil {
			t.Fatalf("--set %q lands a literal bracket key; it must be refused. body = %s", kv, body)
		}
		if body != nil {
			t.Fatalf("--set %q was refused but still produced a body: %s", kv, body)
		}
		return err.Error()
	}

	t.Run("the typed whole-element form is refused", func(t *testing.T) {
		msg := refusalFor(t, `acceptance_criteria[5]:={"met":true,"evidence":"proof"}`)
		for _, want := range []string{"SHALLOW merge", "acceptance_criteria[5]", "bp task stamp"} {
			if !strings.Contains(msg, want) {
				t.Fatalf("refusal = %q, want it to carry %q", msg, want)
			}
		}
	})

	t.Run("the bracket-plus-dot form is refused by the INDEX guard, not the dot guard", func(t *testing.T) {
		msg := refusalFor(t, "acceptance_criteria[5].evidence=proof")
		// The pre-fix refusal for this spelling was the nesting hint, which
		// computed the head up to the first dot and advised exactly the form
		// that stored the residue. That sentence must never be printed again.
		if strings.Contains(msg, "--set 'acceptance_criteria[5]:={…}'") {
			t.Fatalf("the refusal STEERS the caller to the residue spelling: %q", msg)
		}
		if !strings.Contains(msg, "bp task stamp") {
			t.Fatalf("refusal = %q, want it to name the verb that updates the array element", msg)
		}
	})

	t.Run("a non-criteria bracket key is refused too — nothing indexes anywhere", func(t *testing.T) {
		msg := refusalFor(t, `blocks[0]:={"type":"paragraph"}`)
		if !strings.Contains(msg, `--set 'blocks:=[…]'`) {
			t.Fatalf("refusal = %q, want the whole-field spelling for a non-criteria list", msg)
		}
		if strings.Contains(msg, "bp task stamp") {
			t.Fatalf("the stamp hint is criteria-specific; it must not appear for blocks: %q", msg)
		}
	})

	t.Run("the create verb is fenced the same way", func(t *testing.T) {
		body, _, _, err := buildBody(nestingDocCreate(),
			map[string][]string{"set": {"acceptance_criteria[0].met=true"}},
			map[string]string{"type": "task"})
		if err == nil {
			t.Fatalf("a bracket key lands literally on create as well; it must be refused. body = %s", body)
		}
	})

	// ── the quiet half: what must STILL ride ────────────────────────────────
	t.Run("the whole-array spelling still rides", func(t *testing.T) {
		body, _, _, err := buildBody(patch, map[string][]string{
			"set": {`acceptance_criteria:=[{"criterion":"first","met":true,"evidence":"proof"}]`},
		}, args)
		if err != nil {
			t.Fatalf("the CORRECT spelling must still land — the refusal is not a wall: %v", err)
		}
		set, _ := decodeOnePatch(t, body)["set"].(map[string]any)
		arr, ok := set["acceptance_criteria"].([]any)
		if !ok || len(arr) != 1 {
			t.Fatalf("set = %#v, want the canonical array under its bare name", set)
		}
	})

	t.Run("an ordinary key and a value CONTAINING brackets still ride", func(t *testing.T) {
		// The guard reads the KEY only. A value that happens to contain a
		// bracket — a JSON array, or prose quoting one — is untouched.
		body, _, _, err := buildBody(patch, map[string][]string{
			"set": {"description=see acceptance_criteria[5] in the old row", `labels:=["a"]`},
		}, args)
		if err != nil {
			t.Fatalf("brackets in a VALUE are not the defect: %v", err)
		}
		set, _ := decodeOnePatch(t, body)["set"].(map[string]any)
		if set["description"] != "see acceptance_criteria[5] in the old row" {
			t.Fatalf("set = %#v, want the value preserved verbatim", set)
		}
		if arr, _ := set["labels"].([]any); len(arr) != 1 {
			t.Fatalf("set = %#v, want labels to ride", set)
		}
	})

	t.Run("naming a bracketed key to DELETE it is still allowed", func(t *testing.T) {
		// Residue an older client stored can only be removed by naming it, so
		// `key:=null` on a patch stays upstream of the guard — the same
		// exception the dotted refusal makes.
		body, _, _, err := buildBody(patch, map[string][]string{
			"set": {"acceptance_criteria[5].evidence:=null", "acceptance_criteria[5].met:=null"},
		}, args)
		if err != nil {
			t.Fatalf("removing residue must not be refused: %v", err)
		}
		unset, _ := decodeOnePatch(t, body)["unset"].([]any)
		if len(unset) != 2 || unset[0] != "acceptance_criteria[5].evidence" {
			t.Fatalf("unset = %#v, want both residue keys named for deletion", unset)
		}
	})
}

// TestPatchBracketIndexedCriterionReproduction is the transport-level
// reproduction: patch a bracket-indexed criterion key, publish, and read the
// row back from a store that merges the way the real one does. It asserts the
// canonical array is what changed — so a refactor cannot restore the
// success-shaped no-op.
func TestPatchBracketIndexedCriterionReproduction(t *testing.T) {
	store := newMutateStore(map[string]any{
		"title":               "a row",
		"acceptance_criteria": storedCriteria(),
	})
	srv := store.serve(t)
	defer srv.Close()

	patch := nestingDocPatch()
	args := map[string]string{"type": "task", "id": "ve-bl-stamp-flatkey-bug"}
	const publishBody = `{"mutations":[{"publish":{"id":"ve-bl-stamp-flatkey-bug","type":"task"}}]}`

	send := func(t *testing.T, sets []string) error {
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
		return nil
	}
	publish := func(t *testing.T) {
		t.Helper()
		resp, err := http.Post(srv.URL+"/v1/data/mutate/production", "application/json", strings.NewReader(publishBody))
		if err != nil {
			t.Fatalf("POST publish: %v", err)
		}
		_ = resp.Body.Close()
	}

	// Step 1: the reproduction verbatim. The spelling used is the bracket-ONLY
	// one — `acceptance_criteria[5]:={…}` — because that is the form the CLI
	// ACCEPTED before this fix: the dotted spellings were already stopped by
	// the nesting guard, and its hint is what pointed here. Pre-fix this POST
	// reaches the store and a literal `acceptance_criteria[5]` key lands beside
	// the untouched array, so the residue assertion below is what reds.
	err := send(t, []string{`acceptance_criteria[5]:={"met":true,"evidence":"proof"}`})
	publish(t)

	if err == nil {
		t.Fatalf("the bracket-indexed key must be refused before it reaches the wire; store = %#v", store.published)
	}
	for k := range store.published {
		if strings.HasPrefix(k, "acceptance_criteria[") {
			t.Fatalf("a literal bracket key reached the store: %q in %#v", k, store.published)
		}
	}
	arr, _ := store.published["acceptance_criteria"].([]any)
	if len(arr) != 2 {
		t.Fatalf("acceptance_criteria = %#v, want the canonical 2-element array intact", store.published["acceptance_criteria"])
	}

	// And the spelling that DOES update the array element still lands.
	if err := send(t, []string{`acceptance_criteria:=[{"criterion":"first","met":true,"evidence":"proof"},{"criterion":"second","met":false,"evidence":""}]`}); err != nil {
		t.Fatalf("the whole-array spelling must work: %v", err)
	}
	publish(t)
	arr, _ = store.published["acceptance_criteria"].([]any)
	if len(arr) != 2 {
		t.Fatalf("acceptance_criteria = %#v, want 2 elements after the correct write", store.published["acceptance_criteria"])
	}
	first, _ := arr[0].(map[string]any)
	if first["met"] != true || first["evidence"] != "proof" {
		t.Fatalf("criterion 0 = %#v, want met:true with its evidence ON THE ELEMENT", arr[0])
	}
}

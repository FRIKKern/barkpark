package cli

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// ---------------------------------------------------------------------------
// task-aea2ec281f24d026 — `bp doc patch <type> <id> --set content.description=…`
// created a key LITERALLY named "content.description" beside the real
// `description`, returned a new rev and exited 0. Every signal a caller checks
// said the write landed: the rev moved, the publish succeeded, updated_at
// advanced. Only a field-by-field read-back showed the patch went nowhere.
//
// `--set` fields are merged INTO the document's content by a SHALLOW
// Map.merge (Barkpark.Content.Mutations.apply_one/3), so a dot is never a
// path — at any write verb. The fix refuses the dotted key client-side with
// the same hint the `--set 'content:={…}'` spelling gets, and routes
// `--set key:=null` on a patch into the mutate op's `unset` list so a junk key
// is removable by the person who made it.
// ---------------------------------------------------------------------------

func nestingDocPatch() manifest.Command {
	return manifest.Command{
		ID: "doc.patch", Noun: "doc", Verb: "patch", Writes: true, MutationOp: "patch", SetKey: "set",
		HTTP: manifest.HTTP{Method: "POST", PathTemplate: "/v1/data/mutate/:dataset"},
		Args: []manifest.Arg{
			{Name: "type", Required: true, Type: "string"},
			{Name: "id", Required: true, Type: "string"},
		},
		Flags: []manifest.Flag{{Name: "set", Type: "string", Repeatable: true}},
	}
}

func nestingDocCreate() manifest.Command {
	return manifest.Command{
		ID: "doc.create", Noun: "doc", Verb: "create", Writes: true, MutationOp: "create",
		HTTP:  manifest.HTTP{Method: "POST", PathTemplate: "/v1/data/mutate/:dataset"},
		Args:  []manifest.Arg{{Name: "type", Required: true, Type: "string"}},
		Flags: []manifest.Flag{{Name: "set", Type: "string", Repeatable: true}},
	}
}

// TestSetDottedKeyIsRefusedWithTheNestingHint is criterion 0 + 2: a dotted key
// never reaches the wire, and the refusal carries the SAME hint the
// `content:={…}` spelling gets — one mistake, two spellings, one answer.
//
// MUTATION PROOF: delete the checkSetKeyNesting call in buildBody's --set loop
// and every arm here reds on "want a refusal", because the dotted key marshals
// into the body instead.
func TestSetDottedKeyIsRefusedWithTheNestingHint(t *testing.T) {
	patch := nestingDocPatch()
	args := map[string]string{"type": "task", "id": "task-aea2ec281f24d026"}

	// The shared core: what makes the two spellings read alike.
	const mechanism = "merged INTO the document's content"

	t.Run("the dotted string form names the bare inner field", func(t *testing.T) {
		_, _, _, err := buildBody(patch, map[string][]string{"set": {"content.description=NEW"}}, args)
		if err == nil {
			t.Fatalf("a dotted --set key must be refused, not stored literally")
		}
		for _, want := range []string{mechanism, "content.description", "--set 'description=…'"} {
			if !strings.Contains(err.Error(), want) {
				t.Fatalf("refusal = %q, want it to carry %q", err, want)
			}
		}
	})

	t.Run("the dotted typed form is refused the same way", func(t *testing.T) {
		_, _, _, err := buildBody(patch,
			map[string][]string{"set": {`content.acceptance_criteria:=[{"criterion":"x"}]`}}, args)
		if err == nil {
			t.Fatalf("a dotted --set key must be refused in the := form too")
		}
		if !strings.Contains(err.Error(), mechanism) ||
			!strings.Contains(err.Error(), "--set 'acceptance_criteria=…'") {
			t.Fatalf("refusal = %q, want the mechanism and the bare inner field", err)
		}
	})

	t.Run("the content:= wrapper form gets the SAME hint", func(t *testing.T) {
		_, _, _, err := buildBody(patch,
			map[string][]string{"set": {`content:={"blocks":[]}`}}, args)
		if err == nil {
			t.Fatalf("--set 'content:={…}' double-nests to content.content; it must be refused")
		}
		if !strings.Contains(err.Error(), mechanism) || !strings.Contains(err.Error(), "--set 'blocks:=[…]'") {
			t.Fatalf("refusal = %q, want the same mechanism sentence and an inner-field example", err)
		}
	})

	t.Run("a non-content dotted key is refused too — nothing nests anywhere", func(t *testing.T) {
		_, _, _, err := buildBody(nestingDocCreate(),
			map[string][]string{"set": {"brief.blocks=x"}}, map[string]string{"type": "task"})
		if err == nil {
			t.Fatalf("a dotted key lands a literal key on create as well; it must be refused")
		}
		if !strings.Contains(err.Error(), mechanism) || !strings.Contains(err.Error(), "--set 'brief:={…}'") {
			t.Fatalf("refusal = %q, want the mechanism and the whole-field spelling", err)
		}
	})

	t.Run("an undotted key and a scalar content field still ride", func(t *testing.T) {
		// The refusal must not swallow the CORRECT spelling, nor a legitimate
		// content-level field literally named `content` holding a scalar (the
		// server's own guard is map-only for exactly this reason).
		body, _, _, err := buildBody(patch,
			map[string][]string{"set": {"description=NEW", `content:="a scalar"`}}, args)
		if err != nil {
			t.Fatalf("the correct spelling must still work: %v", err)
		}
		if !strings.Contains(string(body), `"description":"NEW"`) ||
			!strings.Contains(string(body), `"content":"a scalar"`) {
			t.Fatalf("body = %s, want both fields", body)
		}
	})
}

// TestSetNullUnsetsOnPatch is criterion 1: `--set key:=null` on a patch DELETES
// the key through the mutate op's `unset` list instead of storing a present key
// holding null — and it may name a DOTTED key, because a junk key already
// stored under a dotted name can only be removed by naming it.
//
// MUTATION PROOF: make setSupportsUnset return false and the two patch arms red
// ("unset" absent, a null stored in `set` instead).
func TestSetNullUnsetsOnPatch(t *testing.T) {
	args := map[string]string{"type": "task", "id": "task-4a969b6e57d82390"}

	t.Run("null routes to unset, not into set", func(t *testing.T) {
		body, _, _, err := buildBody(nestingDocPatch(), map[string][]string{
			"set": {"content.description:=null", "content.acceptance_criteria:=null"},
		}, args)
		if err != nil {
			t.Fatalf("removing a junk key must not be refused: %v", err)
		}
		patch := decodeOnePatch(t, body)
		unset, _ := patch["unset"].([]any)
		if len(unset) != 2 || unset[0] != "content.description" || unset[1] != "content.acceptance_criteria" {
			t.Fatalf("unset = %#v, want both junk keys named for deletion", patch["unset"])
		}
		set, _ := patch["set"].(map[string]any)
		if _, present := set["content.description"]; present {
			t.Fatalf("a null must not be stored in `set` (that is the key-holding-null bug): %#v", set)
		}
	})

	t.Run("a set alongside an unset still rides", func(t *testing.T) {
		body, _, _, err := buildBody(nestingDocPatch(), map[string][]string{
			"set": {"description=NEW", "content.description:=null"},
		}, args)
		if err != nil {
			t.Fatalf("buildBody: %v", err)
		}
		patch := decodeOnePatch(t, body)
		set, _ := patch["set"].(map[string]any)
		if set["description"] != "NEW" {
			t.Fatalf("set = %#v, want description=NEW", set)
		}
		if unset, _ := patch["unset"].([]any); len(unset) != 1 {
			t.Fatalf("unset = %#v, want exactly the junk key", patch["unset"])
		}
	})

	t.Run("a create body has no unset slot, so a null stays a null", func(t *testing.T) {
		// A null field on a NEW document is a legitimate value, not a deletion,
		// and the create op carries no `unset` list to route one into.
		body, _, _, err := buildBody(nestingDocCreate(),
			map[string][]string{"set": {"parent_id:=null"}}, map[string]string{"type": "task"})
		if err != nil {
			t.Fatalf("buildBody: %v", err)
		}
		if !strings.Contains(string(body), `"parent_id":null`) || strings.Contains(string(body), "unset") {
			t.Fatalf("create body = %s, want a literal null and no unset", body)
		}
	})
}

// decodeOnePatch unwraps {mutations:[{patch:{…}}]}.
func decodeOnePatch(t *testing.T, body []byte) map[string]any {
	t.Helper()
	var env struct {
		Mutations []map[string]json.RawMessage `json:"mutations"`
	}
	if err := json.Unmarshal(body, &env); err != nil {
		t.Fatalf("decode mutation envelope %s: %v", body, err)
	}
	if len(env.Mutations) != 1 {
		t.Fatalf("mutations = %d, want 1 (%s)", len(env.Mutations), body)
	}
	raw, ok := env.Mutations[0]["patch"]
	if !ok {
		t.Fatalf("mutation is not a patch: %s", body)
	}
	var patch map[string]any
	if err := json.Unmarshal(raw, &patch); err != nil {
		t.Fatalf("decode patch: %v", err)
	}
	return patch
}

// mutateStore is a stand-in for /v1/data/mutate that applies the SAME rules
// Barkpark.Content.Mutations.apply_one/3 applies: `set` is merged into content
// with a shallow Map.merge (a dotted key therefore lands literally, exactly as
// it did in production), `unset` keys are dropped, and `publish` promotes the
// draft. Its whole job is to make the reproduction reproduce: if the CLI ships
// a dotted key, this store keeps it and `description` never changes.
type mutateStore struct {
	draft     map[string]any
	published map[string]any
	revs      int
}

func newMutateStore(content map[string]any) *mutateStore {
	pub := map[string]any{}
	for k, v := range content {
		pub[k] = v
	}
	return &mutateStore{draft: nil, published: pub}
}

func (s *mutateStore) serve(t *testing.T) *httptest.Server {
	t.Helper()
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		raw, _ := io.ReadAll(r.Body)
		var env struct {
			Mutations []map[string]json.RawMessage `json:"mutations"`
		}
		if err := json.Unmarshal(raw, &env); err != nil {
			http.Error(w, "bad body", http.StatusBadRequest)
			return
		}
		for _, m := range env.Mutations {
			if p, ok := m["patch"]; ok {
				var patch struct {
					Set   map[string]any `json:"set"`
					Unset []string       `json:"unset"`
				}
				_ = json.Unmarshal(p, &patch)
				if s.draft == nil {
					s.draft = map[string]any{}
					for k, v := range s.published {
						s.draft[k] = v
					}
				}
				for k, v := range patch.Set {
					s.draft[k] = v // shallow: a dotted key is a literal key
				}
				for _, k := range patch.Unset {
					delete(s.draft, k)
				}
			}
			if _, ok := m["publish"]; ok && s.draft != nil {
				s.published = s.draft
				s.draft = nil
			}
		}
		s.revs++
		_, _ = io.WriteString(w, `{"ok":true,"results":[{"rev":"r`+string(rune('0'+s.revs%10))+`"}]}`)
	}))
}

// TestPatchDottedKeyReproduction drives criterion 3: the EXACT reproduction
// from the row — patch a dotted key, publish, read the field back — against a
// server that merges the way the real one does. It asserts the field ACTUALLY
// CHANGED, so a future refactor cannot restore the silent no-op: on unpatched
// main the dotted patch is accepted, the store keeps a literal
// "content.description", `description` is untouched, and this test reds.
//
// MUTATION PROOF: delete the checkSetKeyNesting call in buildBody and this test
// reds with "the dotted patch was accepted and description never changed".
func TestPatchDottedKeyReproduction(t *testing.T) {
	store := newMutateStore(map[string]any{"description": "OLD", "title": "a row"})
	srv := store.serve(t)
	defer srv.Close()

	patch := nestingDocPatch()
	args := map[string]string{"type": "task", "id": "task-4a969b6e57d82390"}

	send := func(t *testing.T, sets []string) error {
		t.Helper()
		body, _, ct, err := buildBody(patch, map[string][]string{"set": sets}, args)
		if err != nil {
			return err
		}
		resp, err := http.Post(srv.URL+"/v1/data/mutate/production", ct, strings.NewReader(string(body)))
		if err != nil {
			t.Fatalf("POST mutate: %v", err)
		}
		_ = resp.Body.Close()
		return nil
	}

	// Step 1: the reproduction verbatim.
	err := send(t, []string{"content.description=NEW"})

	// Step 2 + 3: publish, then read the field back.
	publishBody := `{"mutations":[{"publish":{"id":"task-4a969b6e57d82390","type":"task"}}]}`
	resp, perr := http.Post(srv.URL+"/v1/data/mutate/production", "application/json", strings.NewReader(publishBody))
	if perr != nil {
		t.Fatalf("POST publish: %v", perr)
	}
	_ = resp.Body.Close()

	if err == nil && store.published["description"] != "NEW" {
		t.Fatalf("the dotted patch was accepted and description never changed: published = %#v", store.published)
	}
	if err == nil {
		t.Fatalf("the dotted key must be refused before it reaches the wire")
	}
	if _, junk := store.published["content.description"]; junk {
		t.Fatalf("a literal dotted key reached the store: %#v", store.published)
	}

	// And the CORRECT spelling still lands — the refusal is not a wall.
	if err := send(t, []string{"description=NEW"}); err != nil {
		t.Fatalf("the bare inner field must work: %v", err)
	}
	resp2, _ := http.Post(srv.URL+"/v1/data/mutate/production", "application/json", strings.NewReader(publishBody))
	_ = resp2.Body.Close()
	if store.published["description"] != "NEW" {
		t.Fatalf("the correct spelling did not land: %#v", store.published)
	}
}

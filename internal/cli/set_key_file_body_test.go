package cli

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// writeJSONFile drops body at a temp path and returns it.
func writeJSONFile(t *testing.T, body string) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "body.json")
	if err := os.WriteFile(p, []byte(body), 0o600); err != nil {
		t.Fatalf("write fixture: %v", err)
	}
	return p
}

// setKeyPatchCmd mirrors the served doc.patch entry (mutation_op patch,
// set_key set) PLUS the --file flag the manifest does not declare today.
// Declaring it here is the point: buildBody is the half of the file-body
// contract that lives in this repo, and it must already be correct on the day
// the manifest adds the flag. A capabilities.ex entry that adds `file` without
// this routing ships a body whose field changes sit OUTSIDE `set`.
func setKeyPatchCmd() manifest.Command {
	return manifest.Command{
		ID: "doc.patch", Noun: "doc", Verb: "patch", Writes: true,
		MutationOp: "patch", SetKey: "set",
		HTTP: manifest.HTTP{Method: "POST", PathTemplate: "/v1/data/mutate/:dataset"},
		Args: []manifest.Arg{
			{Name: "type", Required: true, Type: "string"},
			{Name: "id", Required: true, Type: "string"},
		},
		Flags: []manifest.Flag{
			{Name: "file", Type: "file"},
			{Name: "set", Type: "string", Repeatable: true},
		},
	}
}

// TestSetKeyFileBodyLandsUnderSetKey pins where a --file object goes on a
// command that nests its field changes under a SetKey.
//
// REVERT ARM: restore `obj = fileObj` at the seed site (and drop the fileObj
// branch at setTarget) and this reds with
// {"patch":{"blocks":[…],"id":"p1","set":{},"type":"post"}} — the blocks land
// as siblings of an EMPTY `set`, which is not a field change at all.
func TestSetKeyFileBodyLandsUnderSetKey(t *testing.T) {
	path := writeJSONFile(t, `{"blocks":[{"_type":"block","text":"one"}],"title":"From file"}`)

	body, _, _, err := buildBody(setKeyPatchCmd(),
		map[string][]string{"file": {path}},
		map[string]string{"type": "post", "id": "p1"})
	if err != nil {
		t.Fatalf("buildBody: %v", err)
	}
	want := `{"mutations":[{"patch":{"id":"p1","set":{"blocks":[{"_type":"block","text":"one"}],"title":"From file"},"type":"post"}}]}`
	if string(body) != want {
		t.Errorf("patch --file body =\n  %s\nwant\n  %s", body, want)
	}
}

// TestSetKeyFileBodyMergesWithSet proves --set stays usable alongside --file:
// its keys merge ON TOP of the file object, inside `set`, and the addressing
// args stay at the wrapper level.
func TestSetKeyFileBodyMergesWithSet(t *testing.T) {
	path := writeJSONFile(t, `{"title":"From file","keep":"me"}`)

	body, _, _, err := buildBody(setKeyPatchCmd(),
		map[string][]string{"file": {path}, "set": {"title=From flag"}},
		map[string]string{"type": "post", "id": "p1"})
	if err != nil {
		t.Fatalf("buildBody: %v", err)
	}
	want := `{"mutations":[{"patch":{"id":"p1","set":{"keep":"me","title":"From flag"},"type":"post"}}]}`
	if string(body) != want {
		t.Errorf("patch --file + --set body =\n  %s\nwant\n  %s", body, want)
	}
}

// TestFlatFileBodyUnaffectedBySetKeyRouting is the QUIET control: the
// create family has NO SetKey, so its --file object must keep merging FLAT
// into the mutation payload. It stays green under the revert above — that is
// what makes the revert arm's red specific to the SetKey path rather than to
// "--file handling changed".
func TestFlatFileBodyUnaffectedBySetKeyRouting(t *testing.T) {
	path := writeJSONFile(t, `{"_id":"p1","title":"From file"}`)

	cor := manifest.Command{
		ID: "doc.create-or-replace", Noun: "doc", Verb: "create-or-replace", Writes: true,
		MutationOp: "createOrReplace",
		HTTP:       manifest.HTTP{Method: "POST", PathTemplate: "/v1/data/mutate/:dataset"},
		Args:       []manifest.Arg{{Name: "type", Required: true, Type: "string"}},
		Flags: []manifest.Flag{
			{Name: "file", Type: "file"},
			{Name: "set", Type: "string", Repeatable: true},
		},
	}
	body, _, _, err := buildBody(cor,
		map[string][]string{"file": {path}},
		map[string]string{"type": "post"})
	if err != nil {
		t.Fatalf("buildBody: %v", err)
	}
	want := `{"mutations":[{"createOrReplace":{"_id":"p1","title":"From file","type":"post"}}]}`
	if string(body) != want {
		t.Errorf("create-or-replace --file body =\n  %s\nwant\n  %s", body, want)
	}
}

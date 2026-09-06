package cli

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// ---------------------------------------------------------------------------
// task-a1c40938ef1e94cc — `bp doc create <type> --set id=my-chosen-id` exited 0
// and created the document at a GENERATED address. MEASURED against
// guerrilla.barkpark.cloud on 2026-09-06 with a bp built from origin/main:
//
//	$ bp doc create task --set id=cli-w9-chosen-id --set title='PROBE …' … --yes
//	DRAFT created (drafts.task-e9e41ef2841a0f51)
//	  … "_id":"drafts.task-e9e41ef2841a0f51", "id":"cli-w9-chosen-id" …
//	$ bp doc get task cli-w9-chosen-id --perspective raw
//	{"error":{"code":"not_found", …}}
//
// The row's own reproduction said the key was "dropped entirely"; on main today
// it is not — `id` is absent from `Barkpark.Content.Writer.@reserved_in`, so
// `from_envelope/1` folds it into content as an ordinary field. Either way the
// defect is the same and worse for the storing: exit 0, a rev, a field that
// reads back, and a document at an address the caller never chose.
//
// The guard is checkSetIDKeyRouting in run.go, called from buildBody's --set
// loop in BOTH spellings (key=value and key:=json).
// ---------------------------------------------------------------------------

func idKeyCmd(id, verb, op, setKey string) manifest.Command {
	args := []manifest.Arg{{Name: "type", Required: true, Type: "string"}}
	if setKey != "" {
		args = append(args, manifest.Arg{Name: "id", Required: true, Type: "string"})
	}
	return manifest.Command{
		ID: id, Noun: "doc", Verb: verb, Writes: true, MutationOp: op, SetKey: setKey,
		HTTP:  manifest.HTTP{Method: "POST", PathTemplate: "/v1/data/mutate/:dataset"},
		Args:  args,
		Flags: []manifest.Flag{{Name: "set", Type: "string", Repeatable: true}},
	}
}

// The four --set verbs, in the wire shapes the dry-run printed against
// guerrilla on 2026-09-06 (`{"mutations":[{"create":…}]}` etc.).
func idKeyCreate() manifest.Command {
	return idKeyCmd("doc.create", "create", "create", "")
}
func idKeyCreateOrReplace() manifest.Command {
	return idKeyCmd("doc.create-or-replace", "create-or-replace", "createOrReplace", "")
}
func idKeyCreateIfNotExists() manifest.Command {
	return idKeyCmd("doc.create-if-not-exists", "create-if-not-exists", "createIfNotExists", "")
}
func idKeyPatch() manifest.Command {
	return idKeyCmd("doc.patch", "patch", "patch", "set")
}

// TestSetIDKeyIsRefusedOnEverySetVerb is criteria 1 + 2: `--set id=X` never
// reaches the wire on ANY --set verb, and the create family's refusal names
// `id` and spells `_id`.
//
// MUTATION PROOF: delete either checkSetIDKeyRouting call in buildBody's --set
// loop and the matching arms red on "want a refusal" — the key marshals into
// the body instead.
func TestSetIDKeyIsRefusedOnEverySetVerb(t *testing.T) {
	createArgs := map[string]string{"type": "task"}
	patchArgs := map[string]string{"type": "task", "id": "task-a1c40938ef1e94cc"}

	cases := []struct {
		name string
		cmd  manifest.Command
		args map[string]string
		set  string
		want []string // substrings the refusal MUST carry
	}{
		{"create, string form", idKeyCreate(), createArgs, "id=my-chosen-id",
			[]string{`"id"`, "is not the document id", "`_id`", "--set '_id=…'", "GENERATED id"}},
		{"create, typed form", idKeyCreate(), createArgs, `id:="my-chosen-id"`,
			[]string{`"id"`, "--set '_id=…'"}},
		{"create-or-replace", idKeyCreateOrReplace(), createArgs, "id=my-chosen-id",
			[]string{`"id"`, "--set '_id=…'", "doc create-or-replace"}},
		{"create-if-not-exists", idKeyCreateIfNotExists(), createArgs, "id=my-chosen-id",
			[]string{`"id"`, "--set '_id=…'", "doc create-if-not-exists"}},
		{"patch names its positional argument, not _id", idKeyPatch(), patchArgs, "id=my-chosen-id",
			[]string{`"id"`, "is not the document id", "`<id>` argument"}},
		{"patch refuses _id too — it is junk under `set`", idKeyPatch(), patchArgs, "_id=my-chosen-id",
			[]string{`"_id"`, "is not the document id"}},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			body, _, _, err := buildBody(tc.cmd, map[string][]string{"set": {tc.set}}, tc.args)
			if err == nil {
				t.Fatalf("--set %q must be refused, not shipped; body = %s", tc.set, body)
			}
			for _, want := range tc.want {
				if !strings.Contains(err.Error(), want) {
					t.Fatalf("refusal = %q, want it to carry %q", err, want)
				}
			}
		})
	}

	// The create-family hint must not leak `_id` into the patch refusal: on a
	// patch `_id` is junk too, so suggesting it would be a wrong answer.
	_, _, _, err := buildBody(idKeyPatch(), map[string][]string{"set": {"id=x"}}, patchArgs)
	if err == nil || strings.Contains(err.Error(), "--set '_id=…'") {
		t.Fatalf("the patch refusal must NOT spell `--set '_id=…'`: %v", err)
	}
}

// TestSetIDKeyRefusalIsNotAWall is criterion 3: legitimate content fields keep
// working, and they keep working IN THE SAME COMMAND as the rejected key would
// have been — the guard rejects one key, not the write.
//
// MUTATION PROOF: widen checkSetIDKeyRouting to any key and every arm reds.
func TestSetIDKeyRefusalIsNotAWall(t *testing.T) {
	t.Run("_id still chooses the address on create, beside a normal field", func(t *testing.T) {
		body, _, _, err := buildBody(idKeyCreate(), map[string][]string{
			"set": {"_id=my-chosen-id", "title=A row", "priority:=3"},
		}, map[string]string{"type": "task"})
		if err != nil {
			t.Fatalf("the documented spelling must still work: %v", err)
		}
		op := decodeOneOp(t, body, "create")
		if op["_id"] != "my-chosen-id" || op["title"] != "A row" || op["priority"] != float64(3) {
			t.Fatalf("create body = %s, want _id, title and priority all present", body)
		}
	})

	t.Run("a normal field alongside the rejected one is not what failed", func(t *testing.T) {
		// Same --set list, `id` swapped for `_id`: proof that the earlier
		// refusal was about the KEY and not about the other fields.
		sets := []string{"title=A row", "id=my-chosen-id"}
		if _, _, _, err := buildBody(idKeyCreate(), map[string][]string{"set": sets},
			map[string]string{"type": "task"}); err == nil {
			t.Fatalf("--set id=… must be refused even beside a good field")
		}
		sets[1] = "_id=my-chosen-id"
		if _, _, _, err := buildBody(idKeyCreate(), map[string][]string{"set": sets},
			map[string]string{"type": "task"}); err != nil {
			t.Fatalf("the same write with the correct key must pass: %v", err)
		}
	})

	t.Run("a patch of ordinary fields is untouched", func(t *testing.T) {
		body, _, _, err := buildBody(idKeyPatch(), map[string][]string{
			"set": {"description=NEW", "lifecycle_status=open"},
		}, map[string]string{"type": "task", "id": "task-a1c40938ef1e94cc"})
		if err != nil {
			t.Fatalf("an ordinary patch must not be refused: %v", err)
		}
		set, _ := decodeOnePatch(t, body)["set"].(map[string]any)
		if set["description"] != "NEW" || set["lifecycle_status"] != "open" {
			t.Fatalf("patch set = %#v, want both fields", set)
		}
	})

	t.Run("`--set id:=null` on a patch still DELETES a junk key an older bp stored", func(t *testing.T) {
		// The unset route runs BEFORE the guard, deliberately: a caller who
		// already has a stray content `id` from an unpatched bp must be able to
		// name it to remove it.
		body, _, _, err := buildBody(idKeyPatch(), map[string][]string{"set": {"id:=null"}},
			map[string]string{"type": "task", "id": "task-e9e41ef2841a0f51"})
		if err != nil {
			t.Fatalf("removing a junk `id` key must not be refused: %v", err)
		}
		unset, _ := decodeOnePatch(t, body)["unset"].([]any)
		if len(unset) != 1 || unset[0] != "id" {
			t.Fatalf("unset = %#v, want the junk key named for deletion", unset)
		}
	})

	t.Run("a non-mutation write with an `id` body field is untouched", func(t *testing.T) {
		plain := manifest.Command{
			ID: "webhook.create", Noun: "webhook", Verb: "create", Writes: true,
			HTTP:  manifest.HTTP{Method: "POST", PathTemplate: "/v1/webhooks"},
			Flags: []manifest.Flag{{Name: "set", Type: "string", Repeatable: true}},
		}
		body, _, _, err := buildBody(plain, map[string][]string{"set": {"id=hook-1"}}, nil)
		if err != nil {
			t.Fatalf("a command with no mutation op has no address to miss: %v", err)
		}
		if !strings.Contains(string(body), `"id":"hook-1"`) {
			t.Fatalf("body = %s, want the id field to ride", body)
		}
	})
}

// decodeOneOp unwraps {mutations:[{<op>:{…}}]} for the create family.
func decodeOneOp(t *testing.T, body []byte, op string) map[string]any {
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
	raw, ok := env.Mutations[0][op]
	if !ok {
		t.Fatalf("mutation is not a %s: %s", op, body)
	}
	var m map[string]any
	if err := json.Unmarshal(raw, &m); err != nil {
		t.Fatalf("decode %s: %v", op, err)
	}
	return m
}

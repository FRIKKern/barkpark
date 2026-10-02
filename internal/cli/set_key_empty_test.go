package cli

import (
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// Stranger walk (2026-09-30): `bp doc create post --set =x` exited 0 and stored
// a content key named "" holding "x" — a field no schema declares, no Studio
// form shows, and no later --set can name. checkSetKeyEmpty refuses a blank key
// on every --set arm: the manifest write path's plain and typed forms, and the
// task-create builtin's applyTaskSet.
//
// MUTATION PROOF: make checkSetKeyEmpty return nil unconditionally and every
// refusal case below reds.
func TestSetEmptyKeyIsRefused(t *testing.T) {
	args := map[string]string{"type": "post", "id": "p1"}
	cmds := map[string]manifest.Command{
		"create": nestingDocCreate(),
		"patch":  nestingDocPatch(),
	}

	for name, cmd := range cmds {
		for _, kv := range []string{"=x", " =x", ":=1", ` :="x"`, "=", ":=null"} {
			t.Run(name+" "+kv, func(t *testing.T) {
				body, _, _, err := buildBody(cmd, map[string][]string{"set": {kv}}, args)
				if err == nil {
					t.Fatalf("--set %q stored a blank field name; it must be refused. body = %s", kv, body)
				}
				if !strings.Contains(err.Error(), "field name before the = is empty") {
					t.Fatalf("refusal = %q, want it to say the field name is empty", err)
				}
			})
		}
	}

	t.Run("task create builtin", func(t *testing.T) {
		for _, kv := range []string{"=x", ":=1"} {
			body := map[string]any{}
			if err := applyTaskSet(body, kv); err == nil {
				t.Fatalf("applyTaskSet(%q) accepted a blank key: %v", kv, body)
			}
			if len(body) != 0 {
				t.Fatalf("applyTaskSet(%q) refused but still wrote %v", kv, body)
			}
		}
	})

	t.Run("a real key still lands", func(t *testing.T) {
		body, _, _, err := buildBody(nestingDocCreate(), map[string][]string{"set": {"title=x"}}, args)
		if err != nil || !strings.Contains(string(body), `"title":"x"`) {
			t.Fatalf("title=x: err=%v body=%s", err, body)
		}
	})
}

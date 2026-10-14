package taskboard

import (
	"encoding/json"
	"testing"
)

// A row filed with `--set parent=<goal>` carries content.parent and no
// parent_id (task-42823fba6f150b97). The wire decode must surface the key so
// `bp task lint` can list the row.
func TestToTaskReadsStrayParentKey(t *testing.T) {
	for _, tc := range []struct {
		content       string
		wantKey, want string
	}{
		{`{"parent":"goal-a"}`, "parent", "goal-a"},
		{`{"parentId":"goal-b"}`, "parentId", "goal-b"},
		{`{"parent-id":"goal-c"}`, "parent-id", "goal-c"},
		{`{"parent":{"id":"goal-d"}}`, "parent", ""},
		{`{"parent_id":"goal-e"}`, "", ""},
		{`{"parent_title":"x","parents":["y"]}`, "", ""},
		{`"not an object"`, "", ""},
	} {
		w := taskWire{DocID: "t1", Content: json.RawMessage(tc.content)}
		got := w.toTask()
		if got.StrayParentKey != tc.wantKey || got.StrayParent != tc.want {
			t.Errorf("content %s: key=%q value=%q, want %q %q", tc.content, got.StrayParentKey, got.StrayParent, tc.wantKey, tc.want)
		}
	}
}

package manifest

import (
	"reflect"
	"sort"
	"testing"
)

func TestPathPlaceholders(t *testing.T) {
	c := Command{HTTP: HTTP{PathTemplate: "/v1/data/doc/:dataset/:type/:id"}}
	got := c.PathPlaceholders()
	keys := make([]string, 0, len(got))
	for k := range got {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	if want := []string{"dataset", "id", "type"}; !reflect.DeepEqual(keys, want) {
		t.Errorf("placeholders = %v, want %v", keys, want)
	}
	// A template with no placeholders yields an empty set, not nil-deref.
	if n := len(Command{HTTP: HTTP{PathTemplate: "/v1/capabilities"}}.PathPlaceholders()); n != 0 {
		t.Errorf("no-placeholder template = %d entries, want 0", n)
	}
}

// ArgLocation decides where each CLI arg's value goes on the wire — a
// mis-classification would send a path segment as a query param (or vice versa)
// and silently break the command. Cover every branch of the inference.
func TestArgLocation(t *testing.T) {
	docGet := Command{HTTP: HTTP{Method: "GET", PathTemplate: "/v1/data/doc/:dataset/:type/:id"}}
	mutatePost := Command{HTTP: HTTP{Method: "POST", PathTemplate: "/v1/data/mutate/:dataset"}, Writes: true}

	cases := []struct {
		name string
		cmd  Command
		arg  Arg
		want string
	}{
		{"explicit In hint wins over inference", docGet, Arg{Name: "type", In: "body"}, "body"},
		{"placeholder name → path", docGet, Arg{Name: "type"}, "path"},
		{"placeholder name → path (id)", docGet, Arg{Name: "id"}, "path"},
		{"non-placeholder on a GET → query", docGet, Arg{Name: "limit"}, "query"},
		{"non-placeholder on a write POST → body", mutatePost, Arg{Name: "title"}, "body"},
		{"placeholder still wins on a write", mutatePost, Arg{Name: "dataset"}, "path"},
		{"write GET still infers query (unusual)", Command{HTTP: HTTP{Method: "GET"}, Writes: true}, Arg{Name: "q"}, "query"},
		{"no method + read → query", Command{}, Arg{Name: "q"}, "query"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := tc.cmd.ArgLocation(tc.arg); got != tc.want {
				t.Errorf("ArgLocation = %q, want %q", got, tc.want)
			}
		})
	}
}

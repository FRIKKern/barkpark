package cli

// bp paper pull names every list item the pulled BPML does not show all of
// (task-0b448ea0847a6b4f): the pull's x-bpml-carried-count, then the source
// route's format=carried, which must name the same view.

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const carriedBpml = "<paper slug=\"p1\" title=\"T\">\n  <ul id=\"nested-list\">\n    <li id=\"plan\">Plan</li>\n  </ul>\n</paper>\n"

func pullWith(t *testing.T, fake *fakePaperServer, args ...string) (code int, stdout, stderr string, dir string) {
	t.Helper()
	srv := httptest.NewServer(fake.handler())
	t.Cleanup(srv.Close)

	dir, g := paperTestEnv(t, srv.URL)
	var so, se bytes.Buffer
	out := newWriter(&so, &se)
	if len(args) > 0 && args[0] == "json" {
		out.output = "json"
	}
	code = runPaper(out, g, []string{"pull", "p1"})
	return code, so.String(), se.String(), dir
}

func TestPaperPullNamesCarriedItems(t *testing.T) {
	fake := &fakePaperServer{rev: "7", bpml: carriedBpml, view: "v1",
		carried: []map[string]string{{"block": "nested-list", "item": "plan"}}}

	code, so, se, _ := pullWith(t, fake)
	if code != exitOK {
		t.Fatalf("pull exit = %d; stderr=%s", code, se)
	}
	if !strings.Contains(so, "1 list items hold what this copy does not show; a push keeps it:") ||
		!strings.Contains(so, "  carried, not printed: block nested-list, item plan") {
		t.Fatalf("pull did not name the carried item:\n%s", so)
	}

	code, so, se, _ = pullWith(t, fake, "json")
	if code != exitOK {
		t.Fatalf("json pull exit = %d; stderr=%s", code, se)
	}
	var answer struct {
		Count   int                 `json:"carried_count"`
		Carried []map[string]string `json:"carried"`
	}
	if err := json.Unmarshal([]byte(so), &answer); err != nil {
		t.Fatalf("json pull: %v\n%s", err, so)
	}
	if answer.Count != 1 || len(answer.Carried) != 1 || answer.Carried[0]["item"] != "plan" {
		t.Fatalf("json pull carried = %+v", answer)
	}
}

func TestPaperPullNamesEveryCarriedItemPastOneHeader(t *testing.T) {
	var items []map[string]string
	header := 0
	for n := 1; n <= 400; n++ {
		id := fmt.Sprintf("an-item-whose-id-is-long-enough-%04d", n)
		items = append(items, map[string]string{"block": "many", "item": id})
		header += len("many/" + id + ",")
	}
	if header <= 16384 {
		t.Fatalf("the plant must not fit one header: %d bytes", header)
	}
	fake := &fakePaperServer{rev: "7", bpml: carriedBpml, view: "v1", carried: items}

	code, so, se, _ := pullWith(t, fake)
	if code != exitOK {
		t.Fatalf("pull exit = %d; stderr=%s", code, se)
	}
	if !strings.Contains(so, "400 list items hold what this copy does not show") {
		t.Fatalf("pull did not count 400:\n%s", so)
	}
	for _, it := range items {
		if !strings.Contains(so, "carried, not printed: block many, item "+it["item"]+"\n") {
			t.Fatalf("pull left %s unnamed", it["item"])
		}
	}
}

func TestPaperPullRefusesCarriedItemsOfAnotherView(t *testing.T) {
	fake := &fakePaperServer{rev: "7", bpml: carriedBpml, view: "v1", carriedView: "v2",
		carried: []map[string]string{{"block": "nested-list", "item": "plan"}}}

	code, _, se, dir := pullWith(t, fake)
	if code == exitOK {
		t.Fatalf("pull took carried items of another view")
	}
	if !strings.Contains(se, `not one view (pull: rev "7", view "v1"; carried read: rev "7", view "v2")`) {
		t.Fatalf("stderr = %s", se)
	}
	if _, err := os.Stat(filepath.Join(dir, "p1.bpml")); err == nil {
		t.Fatalf("pull wrote the copy although its carried items were of another view")
	}
}

func TestPaperPullRefusesCarriedItemsOfAnotherRev(t *testing.T) {
	fake := &fakePaperServer{rev: "7", bpml: carriedBpml, view: "v1", carriedRev: "8",
		carried: []map[string]string{{"block": "nested-list", "item": "plan"}}}

	code, _, se, dir := pullWith(t, fake)
	if code == exitOK {
		t.Fatalf("pull took carried items of another rev")
	}
	if !strings.Contains(se, `not one view (pull: rev "7", view "v1"; carried read: rev "8", view "v1")`) {
		t.Fatalf("stderr = %s", se)
	}
	if _, err := os.Stat(filepath.Join(dir, "p1.bpml")); err == nil {
		t.Fatalf("pull wrote the copy although its carried items were of another rev")
	}
}

func TestPaperPullFromAServerWithoutACountNamesNone(t *testing.T) {
	fake := &fakePaperServer{rev: "7", bpml: carriedBpml, view: "v1"}

	code, so, se, _ := pullWith(t, fake)
	if code != exitOK {
		t.Fatalf("pull exit = %d; stderr=%s", code, se)
	}
	if strings.Contains(so, "carried") {
		t.Fatalf("pull named carried items the server never counted:\n%s", so)
	}
}

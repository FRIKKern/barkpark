package docdiff

import (
	"strings"
	"testing"
)

func mustDecode(t *testing.T, s string) map[string]any {
	t.Helper()
	m, err := Decode([]byte(s))
	if err != nil {
		t.Fatal(err)
	}
	return m
}

func TestDiffNestedPathsAndKinds(t *testing.T) {
	before := mustDecode(t, `{"title":"Old","seo":{"title":"A","desc":"same"},"tags":["x","y"],"gone":1,"nothing":null}`)
	after := mustDecode(t, `{"title":"New","seo":{"title":"B","desc":"same"},"tags":["x","z","w"],"fresh":true}`)

	got := map[string]Kind{}
	for _, c := range Diff(before, after) {
		got[c.Path] = c.Kind
	}
	want := map[string]Kind{
		"title": Changed, "seo.title": Changed, "tags[1]": Changed,
		"tags[2]": Added, "gone": Removed, "fresh": Added,
	}
	if len(got) != len(want) {
		t.Fatalf("changes = %v, want %v", got, want)
	}
	for p, k := range want {
		if got[p] != k {
			t.Errorf("%s = %q, want %q", p, got[p], k)
		}
	}
}

// A keyed row that moved is compared to itself. The move is one change on the
// array; only the row whose text changed is reported as changed.
func TestDiffKeyedRowsFollowTheirKey(t *testing.T) {
	before := mustDecode(t, `{"blocks":[{"_key":"a","text":"one"},{"_key":"b","text":"two"},{"_key":"c","text":"three"}]}`)
	moved := mustDecode(t, `{"blocks":[{"_key":"c","text":"three"},{"_key":"a","text":"one"},{"_key":"b","text":"two"}]}`)

	changes := Diff(before, moved)
	if len(changes) != 1 || changes[0].Kind != Moved || changes[0].Path != "blocks" {
		t.Fatalf("a pure move = %+v, want one moved change on blocks", changes)
	}

	edited := mustDecode(t, `{"blocks":[{"_key":"c","text":"three"},{"_key":"a","text":"ONE"},{"_key":"d","text":"four"}]}`)
	got := map[string]Kind{}
	for _, c := range Diff(before, edited) {
		got[c.Path] = c.Kind
	}
	want := map[string]Kind{"blocks": Moved, "blocks[1].text": Changed, "blocks[1]": Removed, "blocks[2]": Added}
	// blocks[1] is both the removed row b (old place) and the parent of the
	// changed text of row a (new place); the map keeps the last one written.
	if got["blocks"] != Moved || got["blocks[1].text"] != Changed || got["blocks[2]"] != Added || len(got) != len(want) {
		t.Errorf("changes = %v", got)
	}
}

func TestSummaryAndRender(t *testing.T) {
	long := strings.Repeat("a", 300)
	changes := Diff(
		mustDecode(t, `{"body":"one\ntwo\nthree","big":"`+long+`x","t":"a"}`),
		mustDecode(t, `{"body":"one\n2\nthree","big":"`+long+`y","t":"a","n":5}`),
	)
	if s := Summary(changes); s != "2 changed, 1 added, 0 removed" {
		t.Errorf("summary = %q", s)
	}
	var lines []string
	for _, r := range Render(changes) {
		lines = append(lines, r.Format())
	}
	out := strings.Join(lines, "\n")
	for _, want := range []string{"~ body", "-     two", "+     2", "(2 line(s) the same)", "+ n  5", "ax\"", "ay\""} {
		if !strings.Contains(out, want) {
			t.Errorf("render missing %q in:\n%s", want, out)
		}
	}
	if strings.Contains(out, "one") || strings.Contains(out, strings.Repeat("a", 150)) {
		t.Errorf("render shows an unchanged line or an uncut value:\n%s", out)
	}
}

func TestFieldRowsPrintsEveryLineAndEmpty(t *testing.T) {
	rows := FieldRows("a\nb", "")
	if len(rows) != 3 || rows[0].Format() != "- a" || rows[1].Format() != "- b" || rows[2].Format() != "+ (empty)" {
		t.Errorf("rows = %+v", rows)
	}
}

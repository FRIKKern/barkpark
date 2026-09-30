package pdrender

import (
	"strings"
	"testing"

	"github.com/charmbracelet/x/ansi"
)

// An ordered list's first number (`start`), the terminal twin of walk.ex
// list_start_attr/1: absent or 1 numbers from 1; any other integer numbers
// from it; bullets and a string "5" ignore it.
func renderListStart(t *testing.T, doc string) string {
	t.Helper()
	blocks, err := Decode([]byte(doc))
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	ctx := RenderCtx{Width: 60, Theme: DarkTheme(), Profile: NoColor}
	return ansi.Strip(testRegistry().RenderDoc(blocks, ctx))
}

const listStartItems = `"items":[[{"type":"text","value":"five"}],[{"type":"text","value":"six"}]]`

func TestListStartNumbersFromStart(t *testing.T) {
	out := renderListStart(t, `[{"type":"list","ordered":true,"start":5,`+listStartItems+`}]`)
	if !strings.Contains(out, "5. five") || !strings.Contains(out, "6. six") {
		t.Fatalf("start 5 must number 5, 6:\n%s", out)
	}
	if strings.Contains(out, "1. five") {
		t.Fatalf("start 5 must not number from 1:\n%s", out)
	}
}

func TestListStartAbsentOrOneNumbersFromOne(t *testing.T) {
	absent := renderListStart(t, `[{"type":"list","ordered":true,`+listStartItems+`}]`)
	one := renderListStart(t, `[{"type":"list","ordered":true,"start":1,`+listStartItems+`}]`)
	if !strings.Contains(absent, "1. five") || !strings.Contains(absent, "2. six") {
		t.Fatalf("absent start numbers from 1:\n%s", absent)
	}
	if one != absent {
		t.Fatalf("start 1 must render byte-identical to absent start:\n%s\n---\n%s", one, absent)
	}
}

func TestListStartZeroBulletsAndStrings(t *testing.T) {
	if out := renderListStart(t, `[{"type":"list","ordered":true,"start":0,`+listStartItems+`}]`); !strings.Contains(out, "0. five") {
		t.Fatalf("start 0 numbers from 0:\n%s", out)
	}
	if out := renderListStart(t, `[{"type":"list","ordered":false,"start":5,`+listStartItems+`}]`); strings.Contains(out, "5.") {
		t.Fatalf("a bullet list ignores start:\n%s", out)
	}
	if out := renderListStart(t, `[{"type":"list","ordered":true,"start":"5",`+listStartItems+`}]`); !strings.Contains(out, "1. five") {
		t.Fatalf("a string start is not a start:\n%s", out)
	}
}

func TestListStartNested(t *testing.T) {
	out := renderListStart(t, `[{"type":"list","ordered":true,"items":[{"content":[{"type":"text","value":"outer"}],"children":[{"type":"list","ordered":true,"start":3,`+listStartItems+`}]}]}]`)
	if !strings.Contains(out, "1. outer") || !strings.Contains(out, "3. five") || !strings.Contains(out, "4. six") {
		t.Fatalf("the nested list numbers from its own start:\n%s", out)
	}
}

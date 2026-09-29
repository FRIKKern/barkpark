package pdrender

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

// task-6b5fa5205732bd0f — with the Tasks plugin off the server marks every
// query-carrying task block "unavailable": true (TaskResolver.mark_unavailable,
// #20164). These tests pin that the Go renderer paints the server's note for
// every marked type, and that a block WITHOUT the key renders byte-for-byte as
// it did before the change.

// unavailableFixtures: one resolved-shape block per type the server marks
// (task_resolver.ex @unavailable_types), plus its query-only form.
func unavailableFixtures() []Block {
	q := map[string]any{"type": "task"}
	row := map[string]any{"title": "Ship it", "status": "ready", "priority": "2", "phase": "Build"}
	return []Block{
		{Type: "tasks", Attrs: map[string]any{"type": "tasks", "query": q, "snapshot": []any{row}}},
		{Type: "task-list", Attrs: map[string]any{"type": "task-list", "query": q, "snapshot": []any{row}}},
		{Type: "task-board", Attrs: map[string]any{"type": "task-board", "query": q, "snapshot": []any{row}}},
		{Type: "roadmap", Attrs: map[string]any{"type": "roadmap", "query": q, "snapshot": []any{
			map[string]any{"title": "Ship it", "status": "ready", "start": "2026-01-01", "end": "2026-03-01"},
		}}},
		{Type: "task-detail", Attrs: map[string]any{"type": "task-detail", "query": q, "task": map[string]any{"title": "Ship it", "status": "ready"}}},
		{Type: "chart", Attrs: map[string]any{"type": "chart", "query": q, "series": []any{
			map[string]any{"label": "open", "points": []any{3.0, 4.0, 2.0, 5.0}},
		}}},
		{Type: "heatmap", Attrs: map[string]any{"type": "heatmap", "query": q,
			"cells": []any{[]any{0.0, 1.0}, []any{2.0, 3.0}}, "max": 3.0,
			"rowLabels": []any{"open", "done"}, "colLabels": []any{"Mon", "Tue"}}},
		{Type: "stat", Attrs: map[string]any{"type": "stat", "query": q, "value": 14.0, "label": "open tasks"}},
	}
}

// queryOnly strips the resolved payload, leaving the shape the server sends
// when no resolver is loaded: type + query (+ the marker, added by callers).
func queryOnly(b Block) Block {
	return Block{Type: b.Type, Attrs: map[string]any{"type": b.Type, "query": b.Attrs["query"]}}
}

func withKey(b Block, v any) Block {
	attrs := make(map[string]any, len(b.Attrs)+1)
	for k, val := range b.Attrs {
		attrs[k] = val
	}
	attrs["unavailable"] = v
	return Block{Type: b.Type, Attrs: attrs}
}

func TestTaskBlockUnavailableNote(t *testing.T) {
	reg := testRegistry()
	for _, fx := range unavailableFixtures() {
		for _, shape := range []struct {
			name string
			b    Block
		}{{"query-only", queryOnly(fx)}, {"with-payload", fx}} {
			t.Run(fx.Type+"/"+shape.name, func(t *testing.T) {
				out := renderBlock(reg, withKey(shape.b, true), 80)
				want := fx.Type + " — tasks unavailable — the Tasks plugin is not loaded"
				if !strings.Contains(out, want) {
					t.Fatalf("missing unavailable note %q, got:\n%s", want, out)
				}
				for _, bad := range []string{"unresolved", "No tasks yet.", "No roadmap items.", "Ship it"} {
					if strings.Contains(out, bad) {
						t.Errorf("unavailable block leaked %q:\n%s", bad, out)
					}
				}
			})
		}
	}
}

// A marked block nested in a container (the server marks nested ones too).
func TestTaskBlockUnavailableNested(t *testing.T) {
	raw := `{"version":1,"blocks":[{"type":"section","children":[
	  {"type":"task-board","query":{"type":"task"},"unavailable":true}]}]}`
	blocks, err := Decode([]byte(raw))
	if err != nil {
		t.Fatal(err)
	}
	out := testRegistry().RenderDoc(blocks, RenderCtx{Width: 80, Theme: DarkTheme(), Profile: NoColor})
	if !strings.Contains(out, "task-board — tasks unavailable — the Tasks plugin is not loaded") {
		t.Fatalf("nested unavailable note missing:\n%s", out)
	}
}

// Only the marker's exact shape (true) and only the marked types switch.
func TestTaskBlockUnavailableScope(t *testing.T) {
	reg := testRegistry()
	for _, b := range []Block{
		withKey(Block{Type: "paragraph", Attrs: map[string]any{"type": "paragraph", "text": "hi"}}, true),
		withKey(unavailableFixtures()[2], "true"),
		withKey(unavailableFixtures()[2], false),
	} {
		if out := renderBlock(reg, b, 80); strings.Contains(out, "tasks unavailable") {
			t.Errorf("%s (unavailable=%v) painted the note:\n%s", b.Type, b.Attrs["unavailable"], out)
		}
	}
}

// TestTaskBlockUnavailableByteControl: every fixture (resolved and query-only),
// key ABSENT and key false, renders to the exact bytes recorded from the code
// BEFORE this change (testdata/task_unavailable_control.golden.json, written
// on unmodified code with PDRENDER_WRITE_UNAVAILABLE_CONTROL=1).
func TestTaskBlockUnavailableByteControl(t *testing.T) {
	reg := testRegistry()
	got := map[string]string{}
	for _, fx := range unavailableFixtures() {
		for _, w := range []int{40, 80} {
			for name, b := range map[string]Block{"resolved": fx, "query-only": queryOnly(fx)} {
				ctx := RenderCtx{Width: w, Theme: DarkTheme(), Profile: TrueColor}
				key := fx.Type + "/" + name + "/w" + strconv.Itoa(w)
				got[key] = strings.Join(reg.Render(b, ctx), "\n")
				if f := strings.Join(reg.Render(withKey(b, false), ctx), "\n"); f != got[key] {
					t.Errorf("%s: unavailable=false differs from key absent", key)
				}
			}
		}
	}
	path := filepath.Join("testdata", "task_unavailable_control.golden.json")
	if os.Getenv("PDRENDER_WRITE_UNAVAILABLE_CONTROL") == "1" {
		buf, _ := json.MarshalIndent(got, "", "  ")
		if err := os.WriteFile(path, append(buf, '\n'), 0o644); err != nil {
			t.Fatal(err)
		}
		return
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var want map[string]string
	if err := json.Unmarshal(raw, &want); err != nil {
		t.Fatal(err)
	}
	if len(want) != len(got) {
		t.Fatalf("control size: golden %d entries, rendered %d", len(want), len(got))
	}
	for k, v := range want {
		if got[k] != v {
			t.Errorf("%s: bytes changed vs pre-change golden\nwant %q\ngot  %q", k, v, got[k])
		}
	}
}

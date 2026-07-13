package chat

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/pdrender"
)

// render_test.go — the projection proofs. The load-bearing one is D10: each
// settled assistant message renders as its OWN document (one RenderDoc call), so
// "Figure N." numbering RESETS per message. The golden-parity harness diffs
// exactly this assistant-body projection; cards/tail/user echoes are out of
// scope and only proven not to crash or scope-creep.

// figureDoc is a one-figure document (an ascii diagram, which carries a
// "Figure N." caption). Two of these rendered as separate messages must BOTH
// caption "Figure 1." — the per-message reset.
func figureBlocks(caption string) json.RawMessage {
	doc := map[string]any{
		"blocks": []any{
			map[string]any{
				"type":    "figure",
				"caption": caption,
				"child":   map[string]any{"type": "paragraph", "content": []any{map[string]any{"type": "text", "value": "body"}}},
			},
		},
	}
	raw, _ := json.Marshal(doc)
	return raw
}

// TestFigureNumberingResetsPerMessage is the D10 proof: two assistant messages
// each rendered via their own RenderDoc call both start at "Figure 1.", instead
// of the second continuing to "Figure 2." as it would in one shared document.
func TestFigureNumberingResetsPerMessage(t *testing.T) {
	reg := pdrender.DefaultRegistry(pdrender.DarkTheme())
	m1 := Message{Role: "assistant", Blocks: figureBlocks("first")}
	m2 := Message{Role: "assistant", Blocks: figureBlocks("second")}

	out1 := strings.Join(renderAssistantDoc(reg, 80, m1), "\n")
	out2 := strings.Join(renderAssistantDoc(reg, 80, m2), "\n")

	if !strings.Contains(out1, "Figure 1.") {
		t.Fatalf("first message should caption Figure 1., got:\n%s", out1)
	}
	if !strings.Contains(out2, "Figure 1.") {
		t.Fatalf("second message must RESET to Figure 1. (per-message document, D10), got:\n%s", out2)
	}
	if strings.Contains(out2, "Figure 2.") {
		t.Fatal("figure numbering must NOT continue across messages (D10 per-message reset)")
	}
}

// TestAssistantEmptyBlocksFallBackToSource proves a mid-persist assistant row
// (blocks not yet computed) renders its source_markdown instead of a blank.
func TestAssistantEmptyBlocksFallBackToSource(t *testing.T) {
	m := Message{Role: "assistant", SourceMarkdown: "raw reply text"}
	out := strings.Join(renderAssistantDoc(chatRegistry, 80, m), "\n")
	if !strings.Contains(out, "raw reply") {
		t.Fatalf("empty-blocks assistant must fall back to source markdown, got:\n%s", out)
	}
}

// TestCardRolesRenderReadOnly proves the approval/question/plan rows render as
// bespoke read-only cards carrying the honest "answer in Studio" footnote — the
// scope fence (answering is ct-bl-cards-interactive).
func TestCardRolesRenderReadOnly(t *testing.T) {
	for role, label := range cardRoles {
		m := Message{Role: role, SourceMarkdown: "please approve running rm -rf"}
		out := strings.Join(renderMessage(80, m), "\n")
		if !strings.Contains(out, label) {
			t.Fatalf("%s row must carry its card label %q, got:\n%s", role, label, out)
		}
		if !strings.Contains(out, "read-only") {
			t.Fatalf("%s card must state it is read-only (no answering scope creep), got:\n%s", role, out)
		}
	}
}

// TestQueuedLocalSendBadged proves the ⧗ queued badge on an optimistic mid-turn
// send (D12 render side).
func TestQueuedLocalSendBadged(t *testing.T) {
	out := strings.Join(renderLocalSend(40, LocalSend{Content: "later", Queued: true}), "\n")
	if !strings.Contains(out, "⧗ queued") {
		t.Fatalf("a queued local send must show the badge, got:\n%s", out)
	}
	out = strings.Join(renderLocalSend(40, LocalSend{Content: "now", Queued: false}), "\n")
	if strings.Contains(out, "queued") {
		t.Fatalf("an un-queued send must NOT show the badge, got:\n%s", out)
	}
}

// TestWindowFollowsBottom proves the manual line-slice viewport: follow mode
// (scroll<0) pins the last `height` lines; a pinned top shows from that index.
func TestWindowFollowsBottom(t *testing.T) {
	lines := []string{"0", "1", "2", "3", "4", "5"}

	// follow → the last 3 lines.
	got := window(lines, 3, -1)
	if strings.Join(got, ",") != "3,4,5" {
		t.Fatalf("follow mode must pin to the bottom, got %v", got)
	}
	// pinned top at 1 → lines 1..3.
	got = window(lines, 3, 1)
	if strings.Join(got, ",") != "1,2,3" {
		t.Fatalf("pinned scroll must window from the top index, got %v", got)
	}
	// an over-large top clamps to the bottom (follow).
	got = window(lines, 3, 99)
	if strings.Join(got, ",") != "3,4,5" {
		t.Fatalf("an over-large scroll must clamp to the bottom, got %v", got)
	}
	// fewer lines than the viewport → all of them.
	got = window([]string{"a", "b"}, 5, 0)
	if strings.Join(got, ",") != "a,b" {
		t.Fatalf("short content returns as-is, got %v", got)
	}
}

// TestTranscriptOrdering proves the transcript stacks settled messages, then
// optimistic local sends, then the live tail — the reading order a person sees.
func TestTranscriptOrdering(t *testing.T) {
	m := Model{st: State{
		Messages: []Message{{Seq: 1, Role: "user", SourceMarkdown: "hello"}},
		Local:    []LocalSend{{Content: "pending"}},
		Tail:     "streaming reply",
	}}
	out := strings.Join(m.transcriptLines(80), "\n")
	iHello := strings.Index(out, "hello")
	iPending := strings.Index(out, "pending")
	iTail := strings.Index(out, "streaming reply")
	if !(iHello < iPending && iPending < iTail) {
		t.Fatalf("order must be settled → local → tail, got hello=%d pending=%d tail=%d\n%s", iHello, iPending, iTail, out)
	}
}

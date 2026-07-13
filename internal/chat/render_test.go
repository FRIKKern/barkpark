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

// TestCardRolesRenderLabels proves the approval/question/plan rows carry their
// card label. A row with no request_id is not answerable and honestly reads
// read-only (the malformed/legacy fallback).
func TestCardRolesRenderLabels(t *testing.T) {
	for role, label := range cardRoles {
		m := Message{Role: role, SourceMarkdown: "please approve running rm -rf"}
		out := strings.Join(renderMessage(80, m, false, ""), "\n")
		if !strings.Contains(out, label) {
			t.Fatalf("%s row must carry its card label %q, got:\n%s", role, label, out)
		}
		if !strings.Contains(out, "read-only") {
			t.Fatalf("%s card with no request_id must read read-only, got:\n%s", role, out)
		}
	}
}

// pendingCard is a pending, answerable card fixture (request_id + pending status
// in metadata — the shape the Recorder persists via persist_approval_ask).
func pendingCard(role string) Message {
	return Message{
		Seq:            7,
		Role:           role,
		SourceMarkdown: "run `rm -rf build`?",
		Metadata: map[string]any{
			"request_id":      "req-1",
			"approval_status": "pending",
		},
	}
}

// TestPendingCardShowsAnswerAffordance proves a pending card advertises the
// answer keys, and a FOCUSED one is marked so the operator sees which card a
// keystroke acts on. Plan cards read approve/keep-planning; the others allow/deny.
func TestPendingCardShowsAnswerAffordance(t *testing.T) {
	for role := range cardRoles {
		out := strings.Join(renderMessage(80, pendingCard(role), false, ""), "\n")
		if !strings.Contains(out, "ctrl+a") || !strings.Contains(out, "ctrl+r") {
			t.Fatalf("%s pending card must advertise the answer keys, got:\n%s", role, out)
		}
		if strings.Contains(out, "read-only") {
			t.Fatalf("%s pending card must NOT read read-only (it is answerable), got:\n%s", role, out)
		}
		allow, deny := cardVerbs(role)
		if !strings.Contains(out, allow) || !strings.Contains(out, deny) {
			t.Fatalf("%s card must name its verbs %q/%q, got:\n%s", role, allow, deny, out)
		}
		// A focused card is visibly marked.
		fout := strings.Join(renderMessage(80, pendingCard(role), true, ""), "\n")
		if !strings.Contains(fout, "focused") {
			t.Fatalf("%s focused card must be marked focused, got:\n%s", role, fout)
		}
	}
	// Plan cards specifically read approve / keep planning (charter D27).
	plan := strings.Join(renderMessage(80, pendingCard("plan"), true, ""), "\n")
	if !strings.Contains(plan, "approve") || !strings.Contains(plan, "keep planning") {
		t.Fatalf("plan card must read approve/keep-planning, got:\n%s", plan)
	}
}

// TestResolvedCardShowsBadge proves a card whose approval_status flipped to a
// terminal state (a Studio answer, or this TUI's own answer landing on refetch)
// shows the resolution badge instead of the answer affordance — one Postgres
// truth, both surfaces (Law-2).
func TestResolvedCardShowsBadge(t *testing.T) {
	cases := map[string]string{"allowed": "allowed", "denied": "denied", "canceled": "canceled"}
	for status, want := range cases {
		m := pendingCard("approval")
		m.Metadata["approval_status"] = status
		out := strings.Join(renderMessage(80, m, false, ""), "\n")
		if !strings.Contains(out, want) {
			t.Fatalf("a %s card must show its resolution badge, got:\n%s", status, out)
		}
		if strings.Contains(out, "ctrl+a") {
			t.Fatalf("a resolved (%s) card must NOT offer the answer keys, got:\n%s", status, out)
		}
	}
}

// TestInFlightCardShowsAnsweringState proves the immediate-feedback layer: a card
// whose answer is POSTed but not yet confirmed reads "answering…" rather than the
// affordance or a premature terminal badge.
func TestInFlightCardShowsAnsweringState(t *testing.T) {
	out := strings.Join(renderMessage(80, pendingCard("approval"), true, "allow"), "\n")
	if !strings.Contains(out, "allowing") {
		t.Fatalf("an in-flight allow must read 'allowing…', got:\n%s", out)
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

// TestRailBandRendersEntries proves the agents rail band paints one row per
// decoded entry with its status label and token count, and shows nothing for an
// empty rail (honest absence, not an empty box).
func TestRailBandRendersEntries(t *testing.T) {
	if renderRail(80, nil) != nil {
		t.Fatal("an empty rail must render no band")
	}
	rail := []RailEntry{
		{TaskID: "t1", Status: "completed", Label: "survey", Tokens: 1500, HasTokens: true},
		{TaskID: "t2", Status: "running", Label: "build"},
	}
	out := strings.Join(renderRail(80, rail), "\n")
	if !strings.Contains(out, "agents") {
		t.Fatalf("rail band must be headed 'agents', got:\n%s", out)
	}
	if !strings.Contains(out, "survey") || !strings.Contains(out, "build") {
		t.Fatalf("rail band must list each entry's label, got:\n%s", out)
	}
	if !strings.Contains(out, "done") || !strings.Contains(out, "running") {
		t.Fatalf("rail band must show each entry's status, got:\n%s", out)
	}
	if !strings.Contains(out, "1.5k") {
		t.Fatalf("rail band must show token usage (1.5k), got:\n%s", out)
	}
}

// TestRailBandEatsTranscriptHeight proves the rail band is a fixed band that
// reduces the transcript viewport rather than overrunning the frame — the
// composer keeps its stable bottom seat.
func TestRailBandEatsTranscriptHeight(t *testing.T) {
	msgs := make([]Message, 0, 40)
	for i := 1; i <= 40; i++ {
		msgs = append(msgs, Message{Seq: i, Role: "user", SourceMarkdown: "line"})
	}
	withRail := Model{width: 80, height: 24, screen: screenChat, scroll: -1,
		st: State{Messages: msgs, Rail: []RailEntry{{TaskID: "t1", Status: "running", Label: "a"}}}}
	noRail := withRail
	noRail.st.Rail = nil
	if lines := strings.Count(withRail.renderChat(), "\n"); lines != strings.Count(noRail.renderChat(), "\n") {
		t.Fatalf("rail must keep the total frame height stable (with=%d without=%d)",
			strings.Count(withRail.renderChat(), "\n"), strings.Count(noRail.renderChat(), "\n"))
	}
}

// TestFooterAdvertisesPendingCard proves the answer affordance is discoverable
// from the footer even when the card scrolled out of view.
func TestFooterAdvertisesPendingCard(t *testing.T) {
	m := Model{width: 80, height: 24, screen: screenChat,
		st: State{Messages: []Message{pendingCard("approval")}}}
	foot := m.chatFooter()
	if !strings.Contains(foot, "card waiting") || !strings.Contains(foot, "ctrl+a") {
		t.Fatalf("footer must advertise a pending card's answer keys, got:\n%s", foot)
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

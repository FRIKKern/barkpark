package chathost

import (
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// The status label must never make the reply later (task-b235ae3b7f8fdc46).
// Live, with the label on, the first text came about 2 s later on a loaded Mac.
// These tests pin that the side call never holds the turn's text and that it
// runs below the turn's CPU priority.
//
// They are order-based (task-8ec73df27873e821): a label call or POST the test
// holds open, and an assertion on what was published while it was held, not a
// lag in milliseconds. On a machine loaded to about 42 the turn alone took over
// 8 s, so every time budget failed there. labelBackstop is the one wall clock:
// it frees what the test holds, so a host that waits for the label still ends
// and the test can say what it waited for.
const labelBackstop = 20 * time.Second

// maxTextLag bounds one lag only: from the helper writing its text to the host
// publishing it (task-0d2151c31ef9c2a8). It is measured at 0.2-4 ms; a host that
// waited a grace second or more for the label before the first text would pass
// the order checks but not this. It never bounds the whole turn or the helper's
// start, which a loaded machine stretches past any budget.
const maxTextLag = time.Second

// niceOf reads a process's niceness the same way on macOS and Linux.
func niceOf(pid int) int {
	out, err := exec.Command("ps", "-o", "ni=", "-p", strconv.Itoa(pid)).Output()
	if err != nil {
		return -100
	}
	n, err := strconv.Atoi(strings.TrimSpace(string(out)))
	if err != nil {
		return -100
	}
	return n
}

// heldLabel is a label call that answers only once freed: by the test, or by
// labelBackstop. The turn's end cancels it.
type heldLabel struct {
	entered   atomic.Bool
	released  atomic.Bool
	release   chan struct{}
	once      sync.Once
	cancelled chan struct{}
	cancel    sync.Once
}

func newHeldLabel(t *testing.T) *heldLabel {
	label := &heldLabel{release: make(chan struct{}), cancelled: make(chan struct{})}
	backstop := time.AfterFunc(labelBackstop, label.free)
	t.Cleanup(func() {
		backstop.Stop()
		label.free()
	})
	return label
}

// free answers the call. released is set first, so an event that sees it unset
// was published while the call was still held.
func (l *heldLabel) free() {
	l.once.Do(func() {
		l.released.Store(true)
		close(l.release)
	})
}

func (l *heldLabel) StatusLabel(ctx context.Context, _ string) (string, error) {
	l.entered.Store(true)
	select {
	case <-l.release:
		return tidesLabel, nil
	case <-ctx.Done():
		l.cancel.Do(func() { close(l.cancelled) })
		return "", ctx.Err()
	}
}

// The first text is published while the label call is still running: the side
// call is never under the lock the turn's events pass through, and the turn
// never waits for it. The turn ends with the call still held, so no label goes
// out. Nor does the host wait a while for the label before the text: the text
// is published within maxTextLag of the helper writing it.
func TestClaudeTurnTextIsNotHeldByASlowLabelCall(t *testing.T) {
	label := newHeldLabel(t)
	textAt := filepath.Join(t.TempDir(), "text-at")
	var textSeen, textWhileHeld bool
	var publishedAt time.Time
	events, _ := runLabelledTurnEnv(t, label, map[string]string{"BARKPARK_STATUS_HELPER_TEXT_AT": textAt}, "", &syncBuffer{}, func(event map[string]any) {
		if event["kind"] == "text_delta" && !textSeen {
			publishedAt = time.Now()
			textSeen = true
			textWhileHeld = !label.released.Load()
		}
	})
	if !label.entered.Load() {
		t.Fatal("the label call was never made, so this proves nothing")
	}
	if !textSeen {
		t.Fatalf("no text was published; events %v", kindsOf(events))
	}
	if !textWhileHeld {
		t.Fatalf("the first text was published only after the label call was freed (by the %v backstop): the side call held it", labelBackstop)
	}
	for _, event := range events {
		if event["kind"] == "status" {
			t.Fatal("a label that came after the turn ended was published")
		}
	}
	raw, err := os.ReadFile(textAt)
	if err != nil {
		t.Fatalf("the helper left no time for its text: %v", err)
	}
	wroteAt, err := strconv.ParseInt(strings.TrimSpace(string(raw)), 10, 64)
	if err != nil {
		t.Fatalf("the helper's text time %q: %v", raw, err)
	}
	// Both are wall-clock readings: a time read back from a file has no
	// monotonic reading, so Sub compares wall clocks.
	lag := publishedAt.Sub(time.Unix(0, wroteAt))
	t.Logf("text lag %v", lag)
	if lag > maxTextLag {
		t.Fatalf("the first text was published %v after the helper wrote it; want at most %v: the host waited for the label before the text", lag, maxTextLag)
	}
}

// The side call runs below the turn's CPU priority, so on a loaded host it only
// takes CPU the turn does not want.
func TestClaudeStatusLabelerRunsBelowTheTurnsPriority(t *testing.T) {
	if _, err := exec.LookPath("nice"); err != nil {
		t.Skip("no nice on this host")
	}
	record := filepath.Join(t.TempDir(), "record.json")
	installStatusHelper(t, map[string]string{
		"BARKPARK_STATUS_HELPER": "label", "BARKPARK_STATUS_HELPER_RECORD": record,
		"BARKPARK_STATUS_HELPER_SAY": tidesLabel,
	})
	// The timeout is a backstop: the helper answers as soon as it runs.
	if _, err := (&ClaudeStatusLabeler{Timeout: labelBackstop}).StatusLabel(context.Background(), "say hi"); err != nil {
		t.Fatal(err)
	}
	raw, err := os.ReadFile(record)
	if err != nil {
		t.Fatal(err)
	}
	var seen struct {
		Nice int `json:"nice"`
	}
	if err := json.Unmarshal(raw, &seen); err != nil {
		t.Fatal(err)
	}
	own := niceOf(os.Getpid())
	if seen.Nice != min(own+10, 19) {
		t.Fatalf("side call niceness %d; want %d (the host's %d + 10)", seen.Nice, min(own+10, 19), own)
	}
}

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
	"testing"
	"time"
)

// The status label must never make the reply later (task-b235ae3b7f8fdc46).
// Live, with the label on, the first text came about 2 s later on a loaded Mac.
// These tests pin that the side call never holds the turn's text and that it
// runs below the turn's CPU priority.

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

// runTimedTurn runs one claude send_turn against the helper turn with extra
// helper env, and returns when each event reached emit and the helper's own
// UnixNano stamp of when it wrote its "text" line.
func runTimedTurn(t *testing.T, labeler StatusLabeler, env map[string]string) (map[string]time.Time, map[string]time.Time) {
	t.Helper()
	stamps := filepath.Join(t.TempDir(), "times.json")
	env["BARKPARK_STATUS_HELPER"] = "turn"
	env["BARKPARK_STATUS_HELPER_TIMES"] = stamps
	installStatusHelper(t, env)
	handler := NewLocalHandler([]string{t.TempDir()})
	handler.StatusLabel = labeler
	handler.Log = &syncBuffer{}
	var mu sync.Mutex
	seen := map[string]time.Time{}
	err := handler.Handle(context.Background(), RemoteCommand{Command: map[string]any{
		"provider": "claude", "operation": "send_turn", "session_id": "session-timed",
		"payload": map[string]any{"cwd": handler.ApprovedRoots[0], "content": "say hi", "mode": "plan"},
	}}, func(event map[string]any) error {
		mu.Lock()
		defer mu.Unlock()
		if kind := event["kind"].(string); seen[kind].IsZero() {
			seen[kind] = time.Now()
		}
		return nil
	})
	if err != nil {
		t.Fatalf("Handle() = %v", err)
	}
	raw, err := os.ReadFile(stamps)
	if err != nil {
		t.Fatalf("the helper turn wrote no times: %v", err)
	}
	var nanos map[string]int64
	if err := json.Unmarshal(raw, &nanos); err != nil {
		t.Fatal(err)
	}
	helper := map[string]time.Time{}
	for name, n := range nanos {
		helper[name] = time.Unix(0, n)
	}
	mu.Lock()
	defer mu.Unlock()
	return seen, helper
}

// With a label call that takes 3 s, the first text is published as soon as the
// provider writes it, not after the label: the side call is never under the
// lock the turn's events pass through.
func TestClaudeTurnTextIsNotHeldByASlowLabelCall(t *testing.T) {
	labeler := StatusLabelFunc(func(ctx context.Context, _ string) (string, error) {
		select {
		case <-time.After(3 * time.Second):
			return tidesLabel, nil
		case <-ctx.Done():
			return "", ctx.Err()
		}
	})
	started := time.Now()
	seen, helper := runTimedTurn(t, labeler, map[string]string{})
	if seen["text_delta"].IsZero() {
		t.Fatal("no text was published")
	}
	if lag := seen["text_delta"].Sub(helper["text"]); lag > 100*time.Millisecond {
		t.Fatalf("the first text reached the server side %v after the provider wrote it; want within 100ms", lag)
	}
	if took := time.Since(started); took > 2500*time.Millisecond {
		t.Fatalf("the turn took %v; a 3 s label call held it", took)
	}
	if !seen["status"].IsZero() {
		t.Fatal("a label that came after the turn ended was published")
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
	if _, err := (&ClaudeStatusLabeler{Timeout: 5 * time.Second}).StatusLabel(context.Background(), "say hi"); err != nil {
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

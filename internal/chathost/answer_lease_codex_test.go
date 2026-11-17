package chathost

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// A real Codex run records the lease it serves (rev26735 on #26925): without
// it, every answer the server names for the run's own lease is refused, and
// the run waits on its ask forever.
func TestARunningCodexTurnTakesTheAnswerNamedForItsLease(t *testing.T) {
	installCodexAskHelper(t)
	handler := NewLocalHandler([]string{t.TempDir()})
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	asked := make(chan string, 1)
	answered := make(chan string, 1)
	done := make(chan error, 1)
	go func() {
		done <- handler.Handle(ctx, RemoteCommand{LeaseID: "lease-C", Command: map[string]any{
			"provider": "codex", "operation": "send_turn", "session_id": "s-codex",
			"payload": map[string]any{"cwd": handler.ApprovedRoots[0], "content": "run ls"},
		}}, func(event map[string]any) error {
			switch event["kind"] {
			case "approval_requested":
				asked <- fmt.Sprint(event["approval_id"])
			case "text_delta":
				answered <- fmt.Sprint(event["delta"])
			}
			return nil
		})
	}()

	var approvalID string
	select {
	case approvalID = <-asked:
	case err := <-done:
		t.Fatalf("the turn ended before it asked: %v", err)
	case <-time.After(10 * time.Second):
		t.Fatal("codex never asked")
	}

	var ack []map[string]any
	err := handler.Handle(context.Background(), RemoteCommand{LeaseID: "lease-answer", Command: map[string]any{
		"provider": "codex", "operation": "answer_approval", "session_id": "s-codex",
		"approval_id": approvalID, "payload": map[string]any{"decision": "allow", "asked_lease_id": "lease-C"},
	}}, func(event map[string]any) error { ack = append(ack, event); return nil })
	if err != nil || len(ack) != 1 || ack[0]["refused"] != nil {
		t.Fatalf("the run's own answer must be delivered, got %#v, %v", ack, err)
	}

	select {
	case got := <-answered:
		if got != "answered accept" {
			t.Fatalf("codex got %q, want the allow decision", got)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("codex never received the answer")
	}
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("send_turn: %v", err)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("send_turn never ended")
	}
}

// TestCodexAskHelperProcess is a go-test re-exec stub for "codex app-server":
// its turn asks one command approval under id 0 and reports the decision it
// is answered with as its text.
func TestCodexAskHelperProcess(t *testing.T) {
	if os.Getenv("BARKPARK_CODEX_ASK_HELPER") == "" {
		return
	}
	decoder := json.NewDecoder(bufio.NewReader(os.Stdin))
	encoder := json.NewEncoder(os.Stdout)
	write := func(value map[string]any) { _ = encoder.Encode(value) }
	turn := map[string]any{"threadId": "codex-thread", "turnId": "codex-turn"}
	for {
		var message map[string]any
		if err := decoder.Decode(&message); err != nil {
			os.Exit(1)
		}
		switch message["method"] {
		case "initialized":
		case "initialize":
			write(map[string]any{"id": message["id"], "result": map[string]any{}})
		case "thread/start":
			write(map[string]any{"id": message["id"], "result": map[string]any{"thread": map[string]any{"id": "codex-thread"}}})
		case "turn/start":
			write(map[string]any{"id": message["id"], "result": map[string]any{"turn": map[string]any{"id": "codex-turn"}}})
			write(map[string]any{"method": "turn/started", "params": map[string]any{"threadId": "codex-thread", "turn": map[string]any{"id": "codex-turn"}}})
			write(map[string]any{"id": 0, "method": "item/commandExecution/requestApproval", "params": turn})
		case nil:
			// The answer to the ask: {"id": 0, "result": {"decision": ...}}.
			result, _ := message["result"].(map[string]any)
			write(map[string]any{"method": "item/agentMessage/delta", "params": map[string]any{
				"threadId": "codex-thread", "turnId": "codex-turn", "delta": fmt.Sprintf("answered %v", result["decision"]),
			}})
			write(map[string]any{"method": "turn/completed", "params": map[string]any{"threadId": "codex-thread", "turn": map[string]any{"id": "codex-turn", "status": "completed"}}})
			os.Exit(0)
		default:
			write(map[string]any{"id": message["id"], "error": map[string]any{"message": "unexpected method"}})
		}
	}
}

func installCodexAskHelper(t *testing.T) {
	t.Helper()
	dir := t.TempDir()
	binary, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	script := fmt.Sprintf("#!/bin/sh\nBARKPARK_CODEX_ASK_HELPER=1 exec %q -test.run=TestCodexAskHelperProcess -- \"$@\"\n", binary)
	if err := os.WriteFile(filepath.Join(dir, "codex"), []byte(script), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
}

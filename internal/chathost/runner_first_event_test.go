package chathost

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"syscall"
	"testing"
	"time"
)

// Until the server takes a turn's first event, the provider must not get far:
// the server may still withdraw the lease and tell the person "not sent"
// (task-53bbabed87944b89). The fake claude below stands for one that has
// started its model call: it sends its init (the turn's first event), then
// runs a "tool" only when the test opens its gate. The tests assert on order:
// was the provider dead before the gate opened, did the tool run.

// A 503 on every try of the first event: the turn is closed within
// FirstEventTimeout, not after the 2 minute outage bound, and the provider is
// dead by the time its close reaches the server, so its tool never runs.
func TestRunnerStopsTheProviderWhenATurnsFirstEventIsNeverTaken(t *testing.T) {
	dir := t.TempDir()
	installFirstEventHelper(t, dir)
	root := t.TempDir()
	server := &leaseServer{
		command:            firstEventTurn(t, root),
		refuseKind:         map[string]int{"session_started": http.StatusServiceUnavailable},
		firstEventDeadline: 100 * time.Millisecond,
		closeDeadline:      2 * time.Second,
		runFor:             20 * time.Second,
	}
	ctx, stop := startRunner(t, server, NewLocalHandler([]string{root}))
	defer stop()

	// Wait while the run has a second left, so a provider left running can
	// still be let on to show what it does.
	runEnds, _ := ctx.Deadline()
	waitCtx, cancelWait := context.WithDeadline(ctx, runEnds.Add(-time.Second))
	defer cancelWait()
	if !waitCompleted(waitCtx, server) {
		_ = os.WriteFile(filepath.Join(dir, "gate"), nil, 0o600)
		ran := waitForFile(filepath.Join(dir, "tool"), 700*time.Millisecond)
		server.mu.Lock()
		posts := server.posts
		server.mu.Unlock()
		t.Fatalf("%v into a 503 on the turn's first event (bound %v) the turn was still open after %d event POSTs: the provider was left running, and let on, its tool ran=%v",
			server.runFor-time.Second, server.firstEventDeadline, posts, ran)
	}
	// The close goes out only after Handle returned, and Handle returns only
	// after the provider was killed and waited for.
	pid := readHelperPid(t, dir)
	if err := syscall.Kill(pid, 0); !errors.Is(err, syscall.ESRCH) {
		t.Fatalf("the provider (pid %d) is still alive after the turn was closed: kill -0 = %v", pid, err)
	}
	if _, kinds := server.snapshot(); fmt.Sprint(kinds) != "[terminal]" {
		t.Fatalf("events taken %v; want only the turn's close", kinds)
	}
	_ = os.WriteFile(filepath.Join(dir, "gate"), nil, 0o600)
	if _, err := os.Stat(filepath.Join(dir, "tool")); err == nil {
		t.Fatal("the provider ran its tool although the turn's first event was never taken")
	}
}

// Once the first event is taken, an outage on a later event outlasting
// FirstEventTimeout is retried as before: the turn goes on and completes. Here
// the server refuses event 2 with 503 for twice the bound, counted from its
// first refusal; a bound applied to event 2 would have ended the turn by then.
// It is also the control for the test above: the same provider, let on, runs
// its tool.
func TestRunnerRetriesALaterEventPastTheFirstEventBound(t *testing.T) {
	dir := t.TempDir()
	installFirstEventHelper(t, dir)
	root := t.TempDir()
	const bound = 500 * time.Millisecond
	var firstRefusal time.Time
	refused := 0
	server := &leaseServer{
		command:            firstEventTurn(t, root),
		firstEventDeadline: bound,
		runFor:             20 * time.Second,
		// Called with server.mu held.
		refuse: func(cursor uint64) int {
			if cursor != 2 {
				return 0
			}
			if firstRefusal.IsZero() {
				firstRefusal = time.Now()
			}
			if time.Since(firstRefusal) < 2*bound {
				refused++
				return http.StatusServiceUnavailable
			}
			return 0
		},
		onEvent: func(kind string) {
			if kind == "session_started" {
				_ = os.WriteFile(filepath.Join(dir, "gate"), nil, 0o600)
			}
		},
	}
	runUntilCompleted(t, server, NewLocalHandler([]string{root}))

	_, kinds := server.snapshot()
	if want := "[session_started turn_started turn_completed]"; fmt.Sprint(kinds) != want {
		t.Fatalf("events taken %v; want %s: an outage on event 2 longer than the first-event bound ended the turn", kinds, want)
	}
	server.mu.Lock()
	got := refused
	server.mu.Unlock()
	if got < 2 {
		t.Fatalf("event 2 was refused %d times; want it retried through the outage", got)
	}
	if _, err := os.Stat(filepath.Join(dir, "tool")); err != nil {
		t.Fatalf("the provider never ran its tool after its first event was taken: %v", err)
	}
}

// TestFirstEventHelperProcess is the fake claude (a go-test re-exec stub, as
// TestClaudeTurnHelperProcess). BARKPARK_FIRST_EVENT_HELPER names a folder: it
// writes its pid there, sends init, waits for the file "gate", writes the file
// "tool" and then ends the turn.
func TestFirstEventHelperProcess(t *testing.T) {
	dir := os.Getenv("BARKPARK_FIRST_EVENT_HELPER")
	if dir == "" {
		return
	}
	decoder := json.NewDecoder(bufio.NewReader(os.Stdin))
	var input map[string]any
	_ = decoder.Decode(&input)
	_ = os.WriteFile(filepath.Join(dir, "pid"), []byte(strconv.Itoa(os.Getpid())), 0o600)
	encoder := json.NewEncoder(os.Stdout)
	write := func(value map[string]any) { _ = encoder.Encode(value) }

	write(map[string]any{"type": "system", "subtype": "init", "session_id": "claude-thread"})
	if !waitForFile(filepath.Join(dir, "gate"), 20*time.Second) {
		os.Exit(4)
	}
	_ = os.WriteFile(filepath.Join(dir, "tool"), []byte("a tool ran"), 0o600)
	write(map[string]any{"type": "stream_event", "event": map[string]any{"type": "message_start"}})
	write(map[string]any{"type": "result", "subtype": "success", "is_error": false})
	os.Exit(0)
}

func installFirstEventHelper(t *testing.T, dir string) {
	t.Helper()
	bin := t.TempDir()
	binary, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	script := fmt.Sprintf("#!/bin/sh\nBARKPARK_FIRST_EVENT_HELPER=%q exec %q -test.run=TestFirstEventHelperProcess -- \"$@\"\n", dir, binary)
	if err := os.WriteFile(filepath.Join(bin, "claude"), []byte(script), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", bin+string(os.PathListSeparator)+os.Getenv("PATH"))
}

// firstEventTurn is the send_turn command JSON for a claude turn in root.
func firstEventTurn(t *testing.T, root string) string {
	t.Helper()
	command, err := json.Marshal(map[string]any{
		"provider": "claude", "operation": "send_turn", "session_id": "session-1",
		"payload": map[string]any{"cwd": root, "content": "run a tool", "mode": "plan"},
	})
	if err != nil {
		t.Fatal(err)
	}
	return string(command)
}

// waitCompleted reports whether the server took the lease's last event before
// ctx ended.
func waitCompleted(ctx context.Context, server *leaseServer) bool {
	for {
		if done, _ := server.snapshot(); done {
			return true
		}
		select {
		case <-ctx.Done():
			return false
		case <-time.After(time.Millisecond):
		}
	}
}

func waitForFile(path string, within time.Duration) bool {
	for deadline := time.Now().Add(within); time.Now().Before(deadline); time.Sleep(5 * time.Millisecond) {
		if _, err := os.Stat(path); err == nil {
			return true
		}
	}
	return false
}

func readHelperPid(t *testing.T, dir string) int {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join(dir, "pid"))
	if err != nil {
		t.Fatalf("the provider never wrote its pid: %v", err)
	}
	pid, err := strconv.Atoi(string(raw))
	if err != nil {
		t.Fatal(err)
	}
	return pid
}

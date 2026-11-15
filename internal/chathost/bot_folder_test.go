package chathost

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// A file of a bot folder turn lands under that folder's own
// .barkpark/attachments, and nothing lands in the root's.
func TestBotFolderTurnWritesItsFilesUnderTheBotFolder(t *testing.T) {
	data := []byte("a,b\n")
	handler, refs, _ := fileTurnHandler(t, servedFile{data, "text/plain", "notes.csv"})
	installRecordingClaude(t)
	root := handler.ApprovedRoots[0]
	if err := handler.Handle(context.Background(), botFolderTurn(t, "claude", root, "bot-1a2b", refs...),
		func(map[string]any) error { return nil }); err != nil {
		t.Fatalf("Handle() = %v", err)
	}
	bot := filepath.Join(realPath(t, root), "bot-1a2b")
	wantFile(t, filepath.Join(sessionFolder(bot), refs[0].ID+".csv"), data, 0o600)
	if _, err := os.Lstat(filepath.Join(root, ".barkpark")); !os.IsNotExist(err) {
		t.Fatalf("the root got a .barkpark folder: %v", err)
	}
}

// The 7-day sweep a bot folder turn runs removes only the old session folders
// under that bot folder's attachments: another bot's (the root's) old files
// stay, and so does an old folder of the bot's own work.
func TestBotFolderSweepTouchesOnlyItsOwnAttachmentFolders(t *testing.T) {
	data := []byte("x")
	handler, refs, _ := fileTurnHandler(t, servedFile{data, "text/plain", "a.txt"})
	installRecordingClaude(t)
	root := handler.ApprovedRoots[0]
	bot := filepath.Join(root, "bot-1a2b")
	const oldID = "11111111-1111-4111-8111-111111111111"
	oldInBot := filepath.Join(bot, ".barkpark", "attachments", oldID)
	oldInRoot := filepath.Join(root, ".barkpark", "attachments", oldID)
	work := filepath.Join(bot, "notes")
	stale := time.Now().Add(-8 * 24 * time.Hour)
	for _, dir := range []string{oldInBot, oldInRoot, work} {
		mustMkdir(t, dir)
		if err := os.Chtimes(dir, stale, stale); err != nil {
			t.Fatal(err)
		}
	}
	if err := handler.Handle(context.Background(), botFolderTurn(t, "claude", root, "bot-1a2b", refs...),
		func(map[string]any) error { return nil }); err != nil {
		t.Fatalf("Handle() = %v", err)
	}
	if _, err := os.Lstat(oldInBot); !os.IsNotExist(err) {
		t.Fatalf("the bot's old session folder is still there: %v", err)
	}
	for _, kept := range []string{oldInRoot, work} {
		if _, err := os.Lstat(kept); err != nil {
			t.Fatalf("%s was swept: %v", kept, err)
		}
	}
}

// The status label's side call runs in its own temp folder, not in the bot
// folder the turn runs in.
func TestBotFolderTurnStatusLabelRunsInItsOwnTempFolder(t *testing.T) {
	root := t.TempDir()
	dir := t.TempDir()
	turnCwd, labelCwd := filepath.Join(dir, "turn-cwd"), filepath.Join(dir, "label-cwd")
	binary, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	// The label call is the one with --no-session-persistence. The turn waits
	// (up to 5 s) for it, so the label runs before the turn ends.
	script := fmt.Sprintf(`#!/bin/sh
case "$*" in *--no-session-persistence*) pwd -P > %[1]q; echo "Reading ocean tides"; exit 0;; esac
pwd -P > %[2]q
i=0; while [ ! -s %[1]q ] && [ $i -lt 500 ]; do sleep 0.01; i=$((i+1)); done
BARKPARK_CLAUDE_RECORD_STDIN=%[3]q exec %[4]q -test.run=TestClaudeRecordingHelperProcess -- "$@"
`, labelCwd, turnCwd, filepath.Join(dir, "frame"), binary)
	if err := os.WriteFile(filepath.Join(dir, "claude"), []byte(script), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))

	handler := NewLocalHandler([]string{root})
	handler.StatusLabel = &ClaudeStatusLabeler{}
	handler.Status = statusPostFunc(func(context.Context, RemoteCommand, string) error { return nil })
	handler.Log = &syncBuffer{}
	if err := handler.Handle(context.Background(), botFolderTurn(t, "claude", root, "bot-1a2b"),
		func(map[string]any) error { return nil }); err != nil {
		t.Fatalf("Handle() = %v", err)
	}
	bot := filepath.Join(realPath(t, root), "bot-1a2b")
	if got := recordedCwd(t, turnCwd); got != bot {
		t.Fatalf("the turn ran in %q, want %q", got, bot)
	}
	label := recordedCwd(t, labelCwd)
	if !strings.Contains(filepath.Base(label), "barkpark-chat-host-label-") || strings.HasPrefix(label, realPath(t, root)) {
		t.Fatalf("the label call ran in %q, want its own temp folder outside the root", label)
	}
}

// Codex on a host has no bot folders: a codex turn that names one is refused
// before codex starts, and nothing is made.
func TestCodexTurnWithABotFolderIsRefused(t *testing.T) {
	root := t.TempDir()
	handler := NewLocalHandler([]string{root})
	started := installTripwire(t, "codex")
	emitted := 0
	err := handler.Handle(context.Background(), botFolderTurn(t, "codex", root, "bot-1a2b"),
		func(map[string]any) error { emitted++; return nil })
	var refused *BotFolderError
	if !errors.As(err, &refused) || !strings.Contains(err.Error(), "codex was not started") {
		t.Fatalf("err = %v, want a *BotFolderError that says codex was not started", err)
	}
	if started() || emitted != 0 {
		t.Fatalf("started=%v events=%d", started(), emitted)
	}
	if tree := listTree(t, root); len(tree) != 0 {
		t.Fatalf("made %v", tree)
	}
}

// Through the Runner, a refused bot folder ends the lease with one terminal at
// cursor 1: no cursor gap, the turn is not run a second time on a later poll,
// claude never starts, and the terminal says why.
func TestRunnerRefusedBotFolderEndsTheLeaseWithOneTerminal(t *testing.T) {
	root, outside := t.TempDir(), t.TempDir()
	mustSymlink(t, outside, filepath.Join(root, "bot-1a2b"))
	command, err := json.Marshal(map[string]any{
		"provider": "claude", "operation": "send_turn", "session_id": testSessionID,
		"payload": map[string]any{"cwd": root, "content": "hello", "mode": "plan", botFolderField: "bot-1a2b"},
	})
	if err != nil {
		t.Fatal(err)
	}
	started := installTripwire(t, "claude")
	server := &leaseServer{command: string(command), staleListings: 3}
	runUntilCompleted(t, server, NewLocalHandler([]string{root}))

	if _, kinds := server.snapshot(); fmt.Sprint(kinds) != "[terminal]" {
		t.Fatalf("events taken=%v want one terminal", kinds)
	}
	server.mu.Lock()
	terminal := server.taken[1]
	server.mu.Unlock()
	if !strings.Contains(terminal, "bot folder refused") || !strings.Contains(terminal, "is a link") {
		t.Fatalf("terminal %s does not say the bot folder was refused", terminal)
	}
	if started() {
		t.Fatal("claude was started")
	}
	if tree := listTree(t, outside); len(tree) != 0 {
		t.Fatalf("made %v through the link", tree)
	}
}

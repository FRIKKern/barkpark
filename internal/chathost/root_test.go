package chathost

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

func TestResolveApprovedPathAllowsRealChild(t *testing.T) {
	root := t.TempDir()
	child := filepath.Join(root, "repo")
	if err := os.Mkdir(child, 0o700); err != nil {
		t.Fatal(err)
	}

	got, err := ResolveApprovedPath([]string{root}, child)
	if err != nil {
		t.Fatal(err)
	}
	want, err := filepath.EvalSymlinks(child)
	if err != nil {
		t.Fatal(err)
	}
	if got != want {
		t.Fatalf("got %q want %q", got, want)
	}
}

func TestResolveApprovedPathRejectsSiblingPrefix(t *testing.T) {
	parent := t.TempDir()
	root := filepath.Join(parent, "repo")
	sibling := filepath.Join(parent, "repo-secret")
	for _, path := range []string{root, sibling} {
		if err := os.Mkdir(path, 0o700); err != nil {
			t.Fatal(err)
		}
	}

	_, err := ResolveApprovedPath([]string{root}, sibling)
	if !errors.Is(err, ErrRootDenied) {
		t.Fatalf("got %v want ErrRootDenied", err)
	}
}

func TestResolveApprovedPathRejectsSymlinkEscape(t *testing.T) {
	parent := t.TempDir()
	root := filepath.Join(parent, "approved")
	outside := filepath.Join(parent, "outside")
	if err := os.Mkdir(root, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(outside, 0o700); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(root, "escape")
	if err := os.Symlink(outside, link); err != nil {
		t.Fatal(err)
	}

	_, err := ResolveApprovedPath([]string{root}, link)
	if !errors.Is(err, ErrRootDenied) {
		t.Fatalf("got %v want ErrRootDenied", err)
	}
}

// noBotFolder leaves payload.bot_folder out of a botFolderTurn, as the server
// does for a session that names no folder.
type noBotFolder struct{}

// botFolderTurn is a send_turn whose payload carries bot_folder as the server
// leases it: folder is set as given, any JSON value, and noBotFolder{} leaves
// the key out.
func botFolderTurn(t *testing.T, provider, cwd string, folder any, refs ...AttachmentRef) RemoteCommand {
	t.Helper()
	command := leasedFileTurn(t, provider, cwd, "hello", refs...)
	if _, absent := folder.(noBotFolder); !absent {
		command.Command["payload"].(map[string]any)[botFolderField] = folder
	}
	return command
}

// installCwdClaude puts a claude on PATH that writes its physical working
// folder to the returned path, then ends the turn with a success result. The
// file exists only if claude was started.
func installCwdClaude(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	cwdPath := filepath.Join(dir, "cwd")
	binary, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	script := fmt.Sprintf("#!/bin/sh\npwd -P > %q\nBARKPARK_CLAUDE_RECORD_STDIN=%q exec %q -test.run=TestClaudeRecordingHelperProcess -- \"$@\"\n",
		cwdPath, filepath.Join(dir, "frame"), binary)
	if err := os.WriteFile(filepath.Join(dir, "claude"), []byte(script), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
	return cwdPath
}

func recordedCwd(t *testing.T, path string) string {
	t.Helper()
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("claude was not started: %v", err)
	}
	return strings.TrimSuffix(string(raw), "\n")
}

func realPath(t *testing.T, path string) string {
	t.Helper()
	real, err := filepath.EvalSymlinks(path)
	if err != nil {
		t.Fatal(err)
	}
	return real
}

// The criterion: a turn for <root>/bot-1a2b that does not exist makes the
// folder, a real 0700 folder directly under the root, and claude runs in it.
func TestBotFolderTurnMakesTheMissingFolderAndRunsClaudeInIt(t *testing.T) {
	root := t.TempDir()
	handler := NewLocalHandler([]string{root})
	cwdPath := installCwdClaude(t)

	var events []map[string]any
	if err := handler.Handle(context.Background(), botFolderTurn(t, "claude", root, "bot-1a2b"),
		func(event map[string]any) error { events = append(events, event); return nil }); err != nil {
		t.Fatalf("Handle() = %v", err)
	}
	if last := events[len(events)-1]; last["kind"] != "turn_completed" {
		t.Fatalf("last event = %#v", last)
	}
	want := filepath.Join(realPath(t, root), "bot-1a2b")
	info, err := os.Lstat(want)
	if err != nil || !info.IsDir() || info.Mode().Perm() != 0o700 {
		t.Fatalf("bot folder: info=%v err=%v, want a real 0700 folder", info, err)
	}
	if got := recordedCwd(t, cwdPath); got != want {
		t.Fatalf("claude ran in %q, want %q", got, want)
	}
}

// The criterion: a link at <root>/bot-1a2b (to a folder outside the root, or
// inside it), a file there, or a name that is not one strict segment is
// refused with a *BotFolderError. Claude never starts, no event goes out, and
// nothing is made outside the root or in it.
func TestBotFolderTurnRefusesALinkANestedNameOrAnythingButOneSegment(t *testing.T) {
	none := func(*testing.T, string, string) {}
	cases := []struct {
		name   string
		folder any
		plant  func(t *testing.T, root, outside string)
	}{
		{"link to a folder outside the root", "bot-1a2b", func(t *testing.T, root, outside string) {
			mustSymlink(t, outside, filepath.Join(root, "bot-1a2b"))
		}},
		{"link to a folder inside the root", "bot-1a2b", func(t *testing.T, root, _ string) {
			mustMkdir(t, filepath.Join(root, "other"))
			mustSymlink(t, filepath.Join(root, "other"), filepath.Join(root, "bot-1a2b"))
		}},
		{"dangling link", "bot-1a2b", func(t *testing.T, root, outside string) {
			mustSymlink(t, filepath.Join(outside, "missing"), filepath.Join(root, "bot-1a2b"))
		}},
		{"a file", "bot-1a2b", func(t *testing.T, root, _ string) {
			if err := os.WriteFile(filepath.Join(root, "bot-1a2b"), []byte("x"), 0o600); err != nil {
				t.Fatal(err)
			}
		}},
		{"nested a/b", "a/b", none},
		{"nested into an existing folder", "a/b", func(t *testing.T, root, _ string) { mustMkdir(t, filepath.Join(root, "a")) }},
		{"parent", "..", none},
		{"climb", "../escape", none},
		{"dot", ".", none},
		{"absolute", "/tmp/escape", none},
		{"backslash", `a\b`, none},
		{"empty string", "", none},
		{"leading dash", "-bot", none},
		{"upper case", "Bot-1a2b", none},
		{"trailing newline", "bot-1a2b\n", none},
		{"space", "bot 1a2b", none},
		{"dot inside", "bot.1a2b", none},
		{"trailing slash", "bot-1a2b/", none},
		{"NUL", "bot\x00x", none},
		{"non-ASCII", "bøt", none},
		{"41 characters", strings.Repeat("a", 41), none},
		{"null", nil, none},
		{"number", 42.0, none},
		{"list", []any{"bot-1a2b"}, none},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			root, outside := t.TempDir(), t.TempDir()
			c.plant(t, root, outside)
			before := listTree(t, root)
			handler := NewLocalHandler([]string{root})
			started := installTripwire(t, "claude")
			emitted := 0
			err := handler.Handle(context.Background(), botFolderTurn(t, "claude", root, c.folder),
				func(map[string]any) error { emitted++; return nil })
			var refused *BotFolderError
			if !errors.As(err, &refused) || !strings.Contains(err.Error(), "claude was not started") {
				t.Fatalf("err = %v, want a *BotFolderError that says claude was not started", err)
			}
			if started() || emitted != 0 {
				t.Fatalf("started=%v events=%d", started(), emitted)
			}
			if after := listTree(t, root); fmt.Sprint(after) != fmt.Sprint(before) {
				t.Fatalf("root changed: %v -> %v", before, after)
			}
			if tree := listTree(t, outside); len(tree) != 0 {
				t.Fatalf("made %v outside the root", tree)
			}
		})
	}
}

// The longest name the rule admits, 40 characters, is a folder.
func TestBotFolderNameOfFortyCharactersIsAdmitted(t *testing.T) {
	for _, name := range []string{"a", "0", "bot-1a2b", "a-", strings.Repeat("a", 40)} {
		if !validBotFolderName(name) {
			t.Errorf("%q refused, the server's rule admits it", name)
		}
	}
}

// A lease that names no bot folder runs exactly where it ran before: the cwd
// handed to claude is the resolved approved root, byte for byte, so the bot's
// claude sessions under ~/.claude/projects/<cwd> keep resuming. Nothing is
// made in the root.
func TestNoBotFolderRunsClaudeInTheApprovedRootAsBefore(t *testing.T) {
	root := t.TempDir()
	handler := NewLocalHandler([]string{root})
	cwdPath := installCwdClaude(t)
	if err := handler.Handle(context.Background(), botFolderTurn(t, "claude", root, noBotFolder{}),
		func(map[string]any) error { return nil }); err != nil {
		t.Fatalf("Handle() = %v", err)
	}
	before, err := ResolveApprovedPath([]string{root}, root)
	if err != nil {
		t.Fatal(err)
	}
	if got := recordedCwd(t, cwdPath); got != before || got != realPath(t, root) {
		t.Fatalf("claude ran in %q, want the approved root %q as before", got, before)
	}
	if tree := listTree(t, root); len(tree) != 0 {
		t.Fatalf("a turn with no bot folder made %v", tree)
	}
}

// A bot folder the person already made is used as it is: its mode is not
// narrowed and what is in it stays.
func TestBotFolderTurnUsesAnExistingFolderAndKeepsItsMode(t *testing.T) {
	root := t.TempDir()
	folder := filepath.Join(root, "bot-1a2b")
	mustMkdir(t, folder)
	if err := os.Chmod(folder, 0o755); err != nil {
		t.Fatal(err)
	}
	note := filepath.Join(folder, "CLAUDE.md")
	if err := os.WriteFile(note, []byte("my bot"), 0o600); err != nil {
		t.Fatal(err)
	}
	handler := NewLocalHandler([]string{root})
	cwdPath := installCwdClaude(t)
	if err := handler.Handle(context.Background(), botFolderTurn(t, "claude", root, "bot-1a2b"),
		func(map[string]any) error { return nil }); err != nil {
		t.Fatalf("Handle() = %v", err)
	}
	if got := recordedCwd(t, cwdPath); got != realPath(t, folder) {
		t.Fatalf("claude ran in %q, want %q", got, realPath(t, folder))
	}
	if info, _ := os.Lstat(folder); info.Mode().Perm() != 0o755 {
		t.Fatalf("the person's folder is now %v, want 0755 kept", info.Mode().Perm())
	}
	wantFile(t, note, []byte("my bot"), 0o600)
}

// Two sessions with different bot folders never share a cwd, and neither runs
// in the root itself.
func TestTwoBotFoldersNeverShareACwd(t *testing.T) {
	root := t.TempDir()
	handler := NewLocalHandler([]string{root})
	seen := map[string]string{realPath(t, root): "the root"}
	for i, folder := range []string{"bot-aaaa1111", "bot-bbbb2222"} {
		cwdPath := installCwdClaude(t)
		turn := botFolderTurn(t, "claude", root, folder)
		turn.Command["session_id"] = fmt.Sprintf("%08d-1111-4111-8111-111111111111", i)
		if err := handler.Handle(context.Background(), turn, func(map[string]any) error { return nil }); err != nil {
			t.Fatalf("%s: %v", folder, err)
		}
		got := recordedCwd(t, cwdPath)
		if want := filepath.Join(realPath(t, root), folder); got != want {
			t.Fatalf("%s ran in %q, want %q", folder, got, want)
		}
		if other, shared := seen[got]; shared {
			t.Fatalf("%s shares the cwd %q with %s", folder, got, other)
		}
		seen[got] = folder
	}
}

// Two first turns that make the same bot folder at once both get it.
func TestBotFolderPathMadeByManyTurnsAtOnceAllSucceed(t *testing.T) {
	root := t.TempDir()
	want := filepath.Join(realPath(t, root), "bot-1a2b")
	const turns = 32
	start := make(chan struct{})
	errs := make([]error, turns)
	paths := make([]string, turns)
	var wg sync.WaitGroup
	for i := 0; i < turns; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			<-start
			paths[i], errs[i] = BotFolderPath([]string{root}, root, "bot-1a2b")
		}(i)
	}
	close(start)
	wg.Wait()
	for i := range errs {
		if errs[i] != nil || paths[i] != want {
			t.Fatalf("turn %d: path=%q err=%v, want %q", i, paths[i], errs[i], want)
		}
	}
	if tree := listTree(t, root); fmt.Sprint(tree) != "[bot-1a2b]" {
		t.Fatalf("root holds %v", tree)
	}
}

// The base is an approved root itself: a cwd deeper in the root would put the
// bot folder below another folder, and is refused.
func TestBotFolderPathRefusesACwdThatIsNotAnApprovedRoot(t *testing.T) {
	root := t.TempDir()
	mustMkdir(t, filepath.Join(root, "project"))
	_, err := BotFolderPath([]string{root}, filepath.Join(root, "project"), "bot-1a2b")
	var refused *BotFolderError
	if !errors.As(err, &refused) {
		t.Fatalf("err = %v, want a *BotFolderError for a cwd below the root", err)
	}
	if tree := listTree(t, root); fmt.Sprint(tree) != "[project]" {
		t.Fatalf("root holds %v", tree)
	}
}

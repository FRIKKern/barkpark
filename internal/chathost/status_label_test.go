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
	"slices"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"
)

const tidesLabel = "Explaining ocean tides"

// TestStatusLabelHelperProcess is a go-test re-exec stub wired up as "claude" on
// PATH by installStatusHelper. BARKPARK_STATUS_HELPER picks what it plays:
//
//	turn   a stream-json claude turn: init, message_start, then (once the gate
//	       file exists, or after labelBackstop) one text delta and a success
//	       result
//	label  the label side call: records its args, stdin, cwd, niceness and
//	       whether a Barkpark token reached it, then prints
//	       BARKPARK_STATUS_HELPER_SAY
//	hang   a side call that never answers: records its pid and sleeps
func TestStatusLabelHelperProcess(t *testing.T) {
	mode := os.Getenv("BARKPARK_STATUS_HELPER")
	if mode == "" {
		return
	}
	record := os.Getenv("BARKPARK_STATUS_HELPER_RECORD")
	switch mode {
	case "turn":
		decoder := json.NewDecoder(bufio.NewReader(os.Stdin))
		var input map[string]any
		_ = decoder.Decode(&input)
		encoder := json.NewEncoder(os.Stdout)
		write := func(value map[string]any) { _ = encoder.Encode(value) }
		write(map[string]any{"type": "system", "subtype": "init", "session_id": "claude-thread"})
		write(map[string]any{"type": "stream_event", "event": map[string]any{"type": "message_start"}})
		if gate := os.Getenv("BARKPARK_STATUS_HELPER_GATE"); gate != "" {
			for deadline := time.Now().Add(labelBackstop); time.Now().Before(deadline); time.Sleep(5 * time.Millisecond) {
				if _, err := os.Stat(gate); err == nil {
					break
				}
			}
		}
		write(map[string]any{"type": "stream_event", "event": map[string]any{
			"type": "content_block_delta", "index": 0.0,
			"delta": map[string]any{"type": "text_delta", "text": "Tides come from the moon."},
		}})
		write(map[string]any{"type": "result", "subtype": "success", "is_error": false})
	case "label":
		stdin, _ := bufio.NewReader(os.Stdin).ReadString(0)
		cwd, _ := os.Getwd()
		_, token := os.LookupEnv("BARKPARK_API_TOKEN")
		encoded, _ := json.Marshal(map[string]any{
			"args": os.Args[slices.Index(os.Args, "--")+1:], "stdin": stdin, "cwd": cwd, "token": token,
			"nice": niceOf(os.Getpid()),
		})
		_ = os.WriteFile(record, encoded, 0o600)
		fmt.Print(os.Getenv("BARKPARK_STATUS_HELPER_SAY"))
	case "hang":
		_ = os.WriteFile(record, []byte(strconv.Itoa(os.Getpid())), 0o600)
		time.Sleep(60 * time.Second)
	}
	os.Exit(0)
}

// installStatusHelper puts a "claude" on PATH that runs the helper above with
// the given environment.
func installStatusHelper(t *testing.T, env map[string]string) {
	t.Helper()
	dir := t.TempDir()
	binary, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	var assignments []string
	for key, value := range env {
		assignments = append(assignments, key+"='"+strings.ReplaceAll(value, "'", `'\''`)+"'")
	}
	slices.Sort(assignments)
	script := fmt.Sprintf("#!/bin/sh\n%s exec %q -test.run=TestStatusLabelHelperProcess -- \"$@\"\n", strings.Join(assignments, " "), binary)
	if err := os.WriteFile(filepath.Join(dir, "claude"), []byte(script), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
}

// runLabelledTurn runs one claude send_turn with the given labeler and returns
// every event the host emitted, with each label the host posted written in
// where it was posted as {kind: status, label}. A posted label creates gate,
// which the helper turn waits for before its text.
func runLabelledTurn(t *testing.T, labeler StatusLabeler, gate string) ([]map[string]any, time.Duration) {
	t.Helper()
	return runLabelledTurnLogged(t, labeler, gate, &syncBuffer{})
}

// runLabelledTurnLogged is runLabelledTurn with the handler's log in log.
func runLabelledTurnLogged(t *testing.T, labeler StatusLabeler, gate string, log *syncBuffer) ([]map[string]any, time.Duration) {
	t.Helper()
	return runLabelledTurnHooked(t, labeler, gate, log, nil)
}

// runLabelledTurnHooked is runLabelledTurnLogged with onEvent called for each
// of the turn's events as it is published, on the turn's goroutine.
func runLabelledTurnHooked(t *testing.T, labeler StatusLabeler, gate string, log *syncBuffer, onEvent func(map[string]any)) ([]map[string]any, time.Duration) {
	t.Helper()
	env := map[string]string{"BARKPARK_STATUS_HELPER": "turn"}
	if gate != "" {
		env["BARKPARK_STATUS_HELPER_GATE"] = gate
	}
	installStatusHelper(t, env)
	handler := NewLocalHandler([]string{t.TempDir()})
	handler.StatusLabel = labeler
	handler.Log = log
	var mu sync.Mutex
	var events []map[string]any
	handler.Status = statusPostFunc(func(_ context.Context, _ RemoteCommand, label string) error {
		mu.Lock()
		events = append(events, map[string]any{"kind": "status", "label": label})
		mu.Unlock()
		if gate != "" {
			_ = os.WriteFile(gate, nil, 0o600)
		}
		return nil
	})
	started := time.Now()
	err := handler.Handle(context.Background(), RemoteCommand{Command: map[string]any{
		"provider": "claude", "operation": "send_turn", "session_id": "session-label",
		"payload": map[string]any{"cwd": handler.ApprovedRoots[0], "content": "how do ocean tides work?", "mode": "plan"},
	}}, func(event map[string]any) error {
		if onEvent != nil {
			onEvent(event)
		}
		mu.Lock()
		events = append(events, event)
		mu.Unlock()
		return nil
	})
	elapsed := time.Since(started)
	if err != nil {
		t.Fatalf("Handle() = %v; want the turn to complete", err)
	}
	mu.Lock()
	defer mu.Unlock()
	return append([]map[string]any(nil), events...), elapsed
}

func kindsOf(events []map[string]any) []string {
	kinds := make([]string, 0, len(events))
	for _, event := range events {
		kinds = append(kinds, fmt.Sprint(event["kind"]))
	}
	return kinds
}

// A turn posts ONE label, after turn_started and before its first text, and
// never as one of its events. The helper turn holds its text until the label is
// out (or 5 s pass), so without the label the turn still completes.
func TestClaudeTurnPublishesItsStatusLabelBeforeTheFirstText(t *testing.T) {
	labeler := StatusLabelFunc(func(context.Context, string) (string, error) { return tidesLabel, nil })
	events, _ := runLabelledTurn(t, labeler, filepath.Join(t.TempDir(), "gate"))

	kinds := kindsOf(events)
	want := []string{"session_started", "turn_started", "status", "text_delta", "turn_completed"}
	if fmt.Sprint(kinds) != fmt.Sprint(want) {
		t.Fatalf("events %v; want %v: one status label between turn_started and the first text", kinds, want)
	}
	if label := events[2]["label"]; label != tidesLabel {
		t.Fatalf("posted label %v; want %q", label, tidesLabel)
	}
}

// The side call is given the person's text.
func TestClaudeTurnGivesTheLabelCallThePersonsText(t *testing.T) {
	var got string
	var mu sync.Mutex
	labeler := StatusLabelFunc(func(_ context.Context, request string) (string, error) {
		mu.Lock()
		got = request
		mu.Unlock()
		return tidesLabel, nil
	})
	runLabelledTurn(t, labeler, filepath.Join(t.TempDir(), "gate"))
	mu.Lock()
	defer mu.Unlock()
	if got != "how do ocean tides work?" {
		t.Fatalf("label call got %q; want the turn's text", got)
	}
}

// A label call that never answers does not hold the turn: the turn ends while
// the call is still held, publishes no status, and the call's context is
// cancelled with it.
func TestClaudeTurnDoesNotWaitForASlowLabel(t *testing.T) {
	label := newHeldLabel(t)
	endedWhileHeld := false
	events, _ := runLabelledTurnHooked(t, label, "", &syncBuffer{}, func(event map[string]any) {
		if event["kind"] == "turn_completed" {
			endedWhileHeld = !label.released.Load()
		}
	})

	if want := []string{"session_started", "turn_started", "text_delta", "turn_completed"}; fmt.Sprint(kindsOf(events)) != fmt.Sprint(want) {
		t.Fatalf("events %v; want %v", kindsOf(events), want)
	}
	if !label.entered.Load() {
		t.Fatal("the label call was never made, so this proves nothing")
	}
	if !endedWhileHeld {
		t.Fatalf("the turn ended only after the label call was freed (by the %v backstop): it waited for the call", labelBackstop)
	}
	select {
	case <-label.cancelled:
	case <-time.After(labelBackstop):
		t.Fatal("the label call's context was not cancelled when the turn ended")
	}
}

// A label call that fails, or answers something that is not a 2 to 4 word
// label, publishes nothing and the turn is unchanged.
func TestClaudeTurnWithAFailingLabelIsUnchanged(t *testing.T) {
	for name, labeler := range map[string]StatusLabeler{
		"error":     StatusLabelFunc(func(context.Context, string) (string, error) { return "", errors.New("claude failed") }),
		"too long":  StatusLabelFunc(func(context.Context, string) (string, error) { return "Explaining at great length how tides work", nil }),
		"one word":  StatusLabelFunc(func(context.Context, string) (string, error) { return "Thinking", nil }),
		"blank":     StatusLabelFunc(func(context.Context, string) (string, error) { return "  \n", nil }),
		"no labels": nil,
	} {
		t.Run(name, func(t *testing.T) {
			events, _ := runLabelledTurn(t, labeler, "")
			if want := []string{"session_started", "turn_started", "text_delta", "turn_completed"}; fmt.Sprint(kindsOf(events)) != fmt.Sprint(want) {
				t.Fatalf("events %v; want %v", kindsOf(events), want)
			}
		})
	}
}

// A side call that fails or answers no usable label leaves one log line,
// without the person's text. One the turn's end cancelled leaves none.
func TestClaudeTurnLogsASkippedLabelWithoutThePersonsText(t *testing.T) {
	waitFor := func(log *syncBuffer, want string) string {
		for deadline := time.Now().Add(labelBackstop); time.Now().Before(deadline); time.Sleep(5 * time.Millisecond) {
			if strings.Contains(log.String(), want) {
				break
			}
		}
		return log.String()
	}
	failing := &syncBuffer{}
	runLabelledTurnLogged(t, StatusLabelFunc(func(context.Context, string) (string, error) {
		return "", errors.New("status label call: exit status 1")
	}), "", failing)
	got := waitFor(failing, "status label skipped")
	if strings.Count(got, "status label skipped: status label call: exit status 1") != 1 {
		t.Fatalf("log %q; want one line naming the failure", got)
	}
	if strings.Contains(got, "ocean tides") {
		t.Fatalf("log %q carries the person's text", got)
	}

	unusable := &syncBuffer{}
	runLabelledTurnLogged(t, StatusLabelFunc(func(context.Context, string) (string, error) { return "Thinking", nil }), "", unusable)
	if got := waitFor(unusable, "status label skipped"); strings.Count(got, "status label skipped") != 1 {
		t.Fatalf("log %q; want one line for an unusable label", got)
	}

	cancelled := &syncBuffer{}
	ended := make(chan struct{})
	runLabelledTurnLogged(t, StatusLabelFunc(func(ctx context.Context, _ string) (string, error) {
		<-ctx.Done()
		defer close(ended)
		return "", ctx.Err()
	}), "", cancelled)
	<-ended
	time.Sleep(50 * time.Millisecond)
	if got := cancelled.String(); got != "" {
		t.Fatalf("a label the turn's end cancelled logged %q", got)
	}
}

// A side call past its timeout says so in its error, which is what gets logged.
func TestClaudeStatusLabelerSaysItTimedOut(t *testing.T) {
	record := filepath.Join(t.TempDir(), "pid")
	installStatusHelper(t, map[string]string{"BARKPARK_STATUS_HELPER": "hang", "BARKPARK_STATUS_HELPER_RECORD": record})
	_, err := (&ClaudeStatusLabeler{Timeout: 300 * time.Millisecond}).StatusLabel(context.Background(), "say hi")
	if err == nil || !strings.Contains(err.Error(), "timed out after 300ms") {
		t.Fatalf("err = %v; want it to say the call timed out", err)
	}
}

// turnStatus orders the label against the turn's own events.
func TestTurnStatusPublishesTheLabelOnlyBetweenTurnStartedAndText(t *testing.T) {
	type step struct {
		event map[string]any // forward this event
		offer string         // or offer this label
	}
	turnStarted := map[string]any{"kind": "turn_started"}
	text := map[string]any{"kind": "text_delta", "delta": "hi"}
	textItem := map[string]any{"kind": "item_started", "item": map[string]any{"type": "text", "id": "text-1"}}
	toolItem := map[string]any{"kind": "item_started", "item": map[string]any{"type": "tool_use", "id": "tool-1"}}
	done := map[string]any{"kind": "turn_completed", "terminal_state": "completed"}
	cases := map[string]struct {
		steps []step
		want  []string
	}{
		"label before turn_started waits for it": {
			[]step{{offer: tidesLabel}, {event: turnStarted}, {event: text}},
			[]string{"turn_started", "status", "text_delta"},
		},
		"label after turn_started goes out at once": {
			[]step{{event: turnStarted}, {offer: tidesLabel}, {event: text}},
			[]string{"turn_started", "status", "text_delta"},
		},
		"label after a tool call still shows": {
			[]step{{event: turnStarted}, {event: toolItem}, {offer: tidesLabel}},
			[]string{"turn_started", "item_started", "status"},
		},
		"label after text is dropped": {
			[]step{{event: turnStarted}, {event: text}, {offer: tidesLabel}},
			[]string{"turn_started", "text_delta"},
		},
		"label after a text block started is dropped": {
			[]step{{event: turnStarted}, {event: textItem}, {offer: tidesLabel}},
			[]string{"turn_started", "item_started"},
		},
		"label after the turn ended is dropped": {
			[]step{{event: turnStarted}, {event: done}, {offer: tidesLabel}},
			[]string{"turn_started", "turn_completed"},
		},
		"label before turn_started on a turn that ends first is dropped": {
			[]step{{offer: tidesLabel}, {event: done}, {event: turnStarted}},
			[]string{"turn_completed", "turn_started"},
		},
		"only one label per turn": {
			[]step{{event: turnStarted}, {offer: tidesLabel}, {offer: "Mulling it over"}},
			[]string{"turn_started", "status"},
		},
	}
	for name, c := range cases {
		t.Run(name, func(t *testing.T) {
			var kinds []string
			posted := make(chan string, 4)
			status := &turnStatus{
				emit: func(event map[string]any) error {
					kinds = append(kinds, fmt.Sprint(event["kind"]))
					return nil
				},
				post: func(label string) { posted <- label },
			}
			// The label is posted on its own goroutine, which may run late on a
			// loaded machine; the decision to send it is made in the step
			// itself. So after each step, read that decision, and only then
			// wait for the POST it started.
			sent := false
			for _, s := range c.steps {
				if s.event != nil {
					if err := status.forward(s.event); err != nil {
						t.Fatal(err)
					}
				} else {
					status.offer(s.offer)
				}
				status.mu.Lock()
				decided := status.sent
				status.mu.Unlock()
				if decided && !sent {
					sent = true
					kinds = append(kinds, "status")
				}
			}
			if fmt.Sprint(kinds) != fmt.Sprint(c.want) {
				t.Fatalf("emitted %v; want %v", kinds, c.want)
			}
			if sent {
				select {
				case <-posted:
				case <-time.After(labelBackstop):
					t.Fatal("the label was marked sent but never posted")
				}
			}
			select {
			case label := <-posted:
				t.Fatalf("a second label %q was posted", label)
			default:
			}
		})
	}
}

// After the turn ends (close), a label that arrives is never posted.
func TestTurnStatusPostsNothingAfterClose(t *testing.T) {
	posted := make(chan string, 1)
	status := &turnStatus{
		emit: func(map[string]any) error { return nil },
		post: func(label string) { posted <- label },
	}
	_ = status.forward(map[string]any{"kind": "turn_started"})
	status.close()
	status.offer(tidesLabel)
	select {
	case label := <-posted:
		t.Fatalf("posted %q after close", label)
	case <-time.After(50 * time.Millisecond):
	}
}

// forward never holds its lock across emit: a label offered while the turn's
// event is being published is not held behind it, and the event is not held
// behind the label.
func TestTurnStatusForwardHoldsNoLockAcrossEmit(t *testing.T) {
	inEmit := make(chan struct{})
	release := make(chan struct{})
	posted := make(chan string, 1)
	status := &turnStatus{
		emit: func(event map[string]any) error {
			if event["kind"] == "item_started" {
				close(inEmit)
				<-release
			}
			return nil
		},
		post: func(label string) { posted <- label },
	}
	_ = status.forward(map[string]any{"kind": "turn_started"})
	go func() {
		_ = status.forward(map[string]any{"kind": "item_started", "item": map[string]any{"type": "tool_use"}})
	}()
	<-inEmit
	offered := make(chan struct{})
	go func() {
		status.offer(tidesLabel)
		close(offered)
	}()
	select {
	case <-offered:
	case <-time.After(labelBackstop):
		t.Fatal("offer waited for an event being published")
	}
	close(release)
	select {
	case <-posted:
	case <-time.After(labelBackstop):
		t.Fatal("the label was not posted")
	}
}

// End to end through the Runner: an old server (404 on the status endpoint)
// and a new one both get the whole turn, with no status among its events and
// one label POST, never retried.
func TestRunnerTurnWithAStatusLabelKeepsTheCursorWhetherOrNotTheServerTakesIt(t *testing.T) {
	for name, refuse := range map[string]map[string]int{
		"old server without the endpoint": {"status": http.StatusNotFound},
		"server takes status":             nil,
	} {
		t.Run(name, func(t *testing.T) {
			gate := filepath.Join(t.TempDir(), "gate")
			installStatusHelper(t, map[string]string{"BARKPARK_STATUS_HELPER": "turn", "BARKPARK_STATUS_HELPER_GATE": gate})
			root := t.TempDir()
			handler := NewLocalHandler([]string{root})
			handler.StatusLabel = StatusLabelFunc(func(context.Context, string) (string, error) { return tidesLabel, nil })
			command, _ := json.Marshal(map[string]any{
				"provider": "claude", "operation": "send_turn", "session_id": "session-1",
				"payload": map[string]any{"cwd": root, "content": "how do ocean tides work?", "mode": "plan"},
			})
			statusPosts := 0
			server := &leaseServer{refuseKind: refuse, command: string(command), onEvent: func(kind string) {
				if kind == "status" {
					statusPosts++
					_ = os.WriteFile(gate, nil, 0o600)
				}
			}}
			runUntilCompleted(t, server, handler)

			_, kinds := server.snapshot()
			want := []string{"session_started", "turn_started", "text_delta", "turn_completed"}
			if fmt.Sprint(kinds) != fmt.Sprint(want) {
				t.Fatalf("events taken %v; want %v", kinds, want)
			}
			server.mu.Lock()
			defer server.mu.Unlock()
			if statusPosts != 1 {
				t.Fatalf("status POSTs=%d; want 1 (a refused label is not retried)", statusPosts)
			}
		})
	}
}

// The real side call: claude --print with no tools, no MCP, no session, no
// hooks, in an empty directory that is not the bot's folder, without the turn's
// Barkpark token, fed the person's text on stdin. Its answer is cleaned.
func TestClaudeStatusLabelerRunsAToolFreeSideCall(t *testing.T) {
	record := filepath.Join(t.TempDir(), "record.json")
	installStatusHelper(t, map[string]string{
		"BARKPARK_STATUS_HELPER": "label", "BARKPARK_STATUS_HELPER_RECORD": record,
		"BARKPARK_STATUS_HELPER_SAY": "\"Explaining ocean tides.\"\n",
	})
	t.Setenv("BARKPARK_API_TOKEN", "bpcs_must-not-leak")
	// The timeout is a backstop: the helper answers as soon as it runs.
	labeler := &ClaudeStatusLabeler{Model: "sonnet", Timeout: labelBackstop}
	label, err := labeler.StatusLabel(context.Background(), "-p how do ocean tides work?")
	if err != nil {
		t.Fatal(err)
	}
	if label != tidesLabel {
		t.Fatalf("label %q; want %q", label, tidesLabel)
	}
	raw, err := os.ReadFile(record)
	if err != nil {
		t.Fatal(err)
	}
	var seen struct {
		Args  []string `json:"args"`
		Stdin string   `json:"stdin"`
		Cwd   string   `json:"cwd"`
		Token bool     `json:"token"`
	}
	if err := json.Unmarshal(raw, &seen); err != nil {
		t.Fatal(err)
	}
	want := []string{"--print", "--model", "sonnet", "--effort", "low", "--tools", "", "--strict-mcp-config",
		"--no-session-persistence", "--disable-slash-commands", "--safe-mode", "--output-format", "text",
		"--system-prompt", statusLabelPrompt}
	if fmt.Sprintf("%q", seen.Args) != fmt.Sprintf("%q", want) {
		t.Fatalf("args %q; want %q", seen.Args, want)
	}
	if seen.Stdin != "-p how do ocean tides work?" {
		t.Fatalf("stdin %q; want the person's text, never as an argument", seen.Stdin)
	}
	if seen.Token {
		t.Fatal("the side call was given BARKPARK_API_TOKEN")
	}
	if !strings.Contains(filepath.Base(seen.Cwd), "barkpark-chat-host-label-") {
		t.Fatalf("side call ran in %q; want its own temporary directory", seen.Cwd)
	}
	if _, err := os.Stat(seen.Cwd); !os.IsNotExist(err) {
		t.Fatalf("the side call's directory %q was left behind (%v)", seen.Cwd, err)
	}
}

// A side call that never answers is ended (by the turn, or by its own
// timeout: both are its context ending), and its child is waited for:
// kill(pid, 0) answers ESRCH only once the child is reaped (a zombie still
// answers). The call is ended once the helper is running, not on a clock that
// can run out before a loaded machine starts it. The timeout message itself is
// TestClaudeStatusLabelerSaysItTimedOut's.
func TestClaudeStatusLabelerReapsItsChildWhenTheCallEnds(t *testing.T) {
	record := filepath.Join(t.TempDir(), "pid")
	installStatusHelper(t, map[string]string{"BARKPARK_STATUS_HELPER": "hang", "BARKPARK_STATUS_HELPER_RECORD": record})
	labeler := &ClaudeStatusLabeler{Timeout: labelBackstop, WaitDelay: 200 * time.Millisecond}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go func() {
		defer cancel()
		for deadline := time.Now().Add(labelBackstop); time.Now().Before(deadline); time.Sleep(5 * time.Millisecond) {
			if raw, err := os.ReadFile(record); err == nil && len(raw) > 0 {
				return
			}
		}
	}()
	_, err := labeler.StatusLabel(ctx, "say hi")
	if err == nil {
		t.Fatal("a side call that never answered returned a label")
	}
	raw, readErr := os.ReadFile(record)
	if readErr != nil {
		t.Fatalf("the helper never started in %v: %v", labelBackstop, readErr)
	}
	if strings.Contains(err.Error(), "timed out") {
		t.Fatalf("err = %v; want the call ended by its context once the helper ran, not by the %v backstop", err, labelBackstop)
	}
	pid, _ := strconv.Atoi(string(raw))
	if err := syscall.Kill(pid, 0); !errors.Is(err, syscall.ESRCH) {
		t.Fatalf("kill(%d, 0) = %v; want ESRCH: the side call's child was not reaped", pid, err)
	}
}

func TestCleanStatusLabel(t *testing.T) {
	for raw, want := range map[string]string{
		"Explaining ocean tides":                                tidesLabel,
		"  \"Explaining ocean tides.\"  ":                       tidesLabel,
		"\n\n**Mulling it over**\nmore":                         "Mulling it over",
		"Greeting   the\tuser!":                                 "Greeting the user",
		"Thinking":                                              "",
		"Explaining how the ocean tides work":                   "",
		"Bad\x00label here":                                     "",
		strings.Repeat("a", 40) + " " + strings.Repeat("b", 40): "",
		"\xff\xfe bad utf8":                                     "",
	} {
		got, ok := cleanStatusLabel(raw)
		if ok != (want != "") || got != want {
			t.Errorf("cleanStatusLabel(%q) = %q, %v; want %q", raw, got, ok, want)
		}
	}
}

func TestStatusLabelerFromEnv(t *testing.T) {
	env := func(values map[string]string) func(string) string {
		return func(key string) string { return values[key] }
	}
	for _, off := range []string{"off", "0", "false", "NO"} {
		if labeler := StatusLabelerFromEnv(env(map[string]string{"BARKPARK_CHAT_HOST_STATUS_LABEL": off})); labeler != nil {
			t.Errorf("BARKPARK_CHAT_HOST_STATUS_LABEL=%s gave a labeler", off)
		}
	}
	labeler, ok := StatusLabelerFromEnv(env(nil)).(*ClaudeStatusLabeler)
	if !ok || labeler.Model != "sonnet" || labeler.Timeout != 8*time.Second {
		t.Fatalf("default labeler = %#v; want claude, sonnet, 8s", labeler)
	}
	labeler = StatusLabelerFromEnv(env(map[string]string{
		"BARKPARK_CHAT_HOST_STATUS_LABEL_MODEL":   "opus",
		"BARKPARK_CHAT_HOST_STATUS_LABEL_TIMEOUT": "3s",
	})).(*ClaudeStatusLabeler)
	if labeler.Model != "opus" || labeler.Timeout != 3*time.Second {
		t.Fatalf("configured labeler = %#v; want opus, 3s", labeler)
	}
}

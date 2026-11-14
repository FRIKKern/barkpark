package chathost

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"sync"
	"time"
	"unicode"
	"unicode/utf8"
)

// A turn's status label: 2 to 4 words, such as "Explaining ocean tides", that
// say what the assistant is about to do (task-a9983f9aeffb5430). A small side
// call of the owner's own claude CLI makes it, started with the turn. It rides
// the turn's own event stream as one event:
//
//	{"kind": "status", "label": "Explaining ocean tides"}
//
// after turn_started and before the first text. It is cosmetic, so it never
// blocks, delays, fails or reorders the turn: the turn does not wait for it, a
// failing or slow call publishes nothing, a label that arrives after the first
// text or after the turn ended is dropped, and a server that refuses the event
// leaves the turn running. The refused event moved no cursor (Runner.start), so
// the next event takes its cursor and leaves no gap.

// StatusLabeler says, in 2 to 4 words, what an assistant is about to do for a
// request. It must return once ctx is done.
type StatusLabeler interface {
	StatusLabel(ctx context.Context, request string) (string, error)
}

// StatusLabelFunc adapts a function to StatusLabeler.
type StatusLabelFunc func(ctx context.Context, request string) (string, error)

func (f StatusLabelFunc) StatusLabel(ctx context.Context, request string) (string, error) {
	return f(ctx, request)
}

const (
	// The prompt the side call gets as its system prompt; the person's text is
	// the only user message.
	statusLabelPrompt = "In 2 to 4 words, starting with a verb ending in -ing, say what an assistant is about to do for this request. Words only."
	// The longest label the host sends. The server cuts at the same length.
	statusLabelMaxRunes = 60
	// How much of the person's text the side call sees.
	statusLabelRequestRunes = 2000
	// How much of the side call's stdout is kept.
	statusLabelOutputBytes = 4096

	defaultStatusLabelModel   = "sonnet"
	defaultStatusLabelTimeout = 8 * time.Second
)

// ClaudeStatusLabeler runs `claude --print` once per turn: no tools, no MCP
// servers, no session written or resumed, no hooks, plugins or CLAUDE.md
// (--safe-mode), in an empty temporary directory that is removed afterwards,
// with the host's base environment only (never a turn's task_env, so no
// Barkpark token). Its context ends at Timeout or with the turn, and the child
// is always waited for.
type ClaudeStatusLabeler struct {
	Model   string
	Timeout time.Duration
}

// StatusLabelerFromEnv reads the side call's settings. It returns nil (no
// label) when BARKPARK_CHAT_HOST_STATUS_LABEL is off, 0, false or no.
// BARKPARK_CHAT_HOST_STATUS_LABEL_MODEL picks the model (default sonnet: the
// turn's own model can be slow enough to miss the first text);
// BARKPARK_CHAT_HOST_STATUS_LABEL_TIMEOUT (a Go duration, default 8s) bounds
// the call.
func StatusLabelerFromEnv(getenv func(string) string) StatusLabeler {
	switch strings.ToLower(strings.TrimSpace(getenv("BARKPARK_CHAT_HOST_STATUS_LABEL"))) {
	case "off", "0", "false", "no":
		return nil
	}
	labeler := &ClaudeStatusLabeler{Model: defaultStatusLabelModel, Timeout: defaultStatusLabelTimeout}
	if model := strings.TrimSpace(getenv("BARKPARK_CHAT_HOST_STATUS_LABEL_MODEL")); model != "" {
		labeler.Model = model
	}
	if timeout, err := time.ParseDuration(strings.TrimSpace(getenv("BARKPARK_CHAT_HOST_STATUS_LABEL_TIMEOUT"))); err == nil && timeout > 0 {
		labeler.Timeout = timeout
	}
	return labeler
}

func (l *ClaudeStatusLabeler) StatusLabel(ctx context.Context, request string) (string, error) {
	timeout := l.Timeout
	if timeout <= 0 {
		timeout = defaultStatusLabelTimeout
	}
	model := l.Model
	if model == "" {
		model = defaultStatusLabelModel
	}
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	dir, err := os.MkdirTemp("", "barkpark-chat-host-label-*")
	if err != nil {
		return "", err
	}
	defer os.RemoveAll(dir)

	cmd := exec.CommandContext(ctx, "claude",
		"--print",
		"--model", model,
		"--effort", "low",
		"--tools", "",
		"--strict-mcp-config",
		"--no-session-persistence",
		"--disable-slash-commands",
		"--safe-mode",
		"--output-format", "text",
		"--system-prompt", statusLabelPrompt,
	)
	cmd.Dir = dir
	cmd.Env = providerEnv(nil)
	cmd.Stdin = strings.NewReader(truncateRunes(request, statusLabelRequestRunes))
	out := &cappedBuffer{limit: statusLabelOutputBytes}
	cmd.Stdout = out
	// Stderr goes to the null device. WaitDelay bounds Wait when a grandchild
	// still holds stdout after claude exited or was killed (#26164).
	cmd.WaitDelay = providerWaitDelay
	// Run waits for the child on every path, so it is never left a zombie.
	if err := cmd.Run(); err != nil {
		return "", fmt.Errorf("status label call: %w", err)
	}
	label, ok := cleanStatusLabel(out.String())
	if !ok {
		return "", fmt.Errorf("status label call answered no 2 to 4 word label")
	}
	return label, nil
}

// cleanStatusLabel takes the first non-empty line, drops wrapping quotes and
// marks and trailing punctuation, and keeps it only when it is 2 to 4 words of
// at most statusLabelMaxRunes with no control characters.
func cleanStatusLabel(raw string) (string, bool) {
	if !utf8.ValidString(raw) {
		return "", false
	}
	var line string
	for _, candidate := range strings.Split(raw, "\n") {
		if candidate = strings.TrimSpace(candidate); candidate != "" {
			line = candidate
			break
		}
	}
	line = strings.Trim(line, " \t\"'`*_“”‘’")
	line = strings.TrimRight(line, " .!?…:;,")
	for _, r := range line {
		if unicode.IsControl(r) && !unicode.IsSpace(r) {
			return "", false
		}
	}
	words := strings.Fields(line)
	if len(words) < 2 || len(words) > 4 {
		return "", false
	}
	label := strings.Join(words, " ")
	if utf8.RuneCountInString(label) > statusLabelMaxRunes {
		return "", false
	}
	return label, true
}

func truncateRunes(text string, limit int) string {
	if utf8.RuneCountInString(text) <= limit {
		return text
	}
	return string([]rune(text)[:limit])
}

// cappedBuffer keeps the first limit bytes written to it and drops the rest,
// so a runaway child cannot grow the host's memory.
type cappedBuffer struct {
	mu    sync.Mutex
	limit int
	buf   []byte
}

func (b *cappedBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if room := b.limit - len(b.buf); room > 0 {
		b.buf = append(b.buf, p[:min(room, len(p))]...)
	}
	return len(p), nil
}

func (b *cappedBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return string(b.buf)
}

// turnStatus puts at most one status label on a turn's event stream. Every
// event of the turn passes through forward, and the label is published under
// the same lock, so the Runner's cursor is never moved by two goroutines and
// the label lands between turn_started and the first text.
type turnStatus struct {
	mu   sync.Mutex
	emit func(map[string]any) error
	// started: turn_started was taken. A label that comes sooner waits for it.
	started bool
	// closed: text began or the turn ended; no label is published after it.
	closed  bool
	sent    bool
	pending string
}

// startStatusLabel starts the side call for one turn and returns the emit the
// turn uses from now on, and the func that ends the label when the turn ends.
// The end does not wait for the side call: it cancels it, and the side call
// reaps its own child.
func (h *LocalHandler) startStatusLabel(ctx context.Context, request string, emit func(map[string]any) error) (func(map[string]any) error, func()) {
	if h.StatusLabel == nil || strings.TrimSpace(request) == "" {
		return emit, func() {}
	}
	status := &turnStatus{emit: emit}
	labelCtx, cancel := context.WithCancel(ctx)
	labeler := h.StatusLabel
	go func() {
		label, err := labeler.StatusLabel(labelCtx, request)
		if err != nil {
			return
		}
		if label, ok := cleanStatusLabel(label); ok {
			status.offer(label)
		}
	}()
	return status.forward, func() {
		cancel()
		status.close()
	}
}

func (s *turnStatus) forward(event map[string]any) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	switch event["kind"] {
	case "text_delta", "turn_completed", "error", "terminal":
		s.closed = true
	case "item_started":
		if item, _ := event["item"].(map[string]any); item["type"] == "text" {
			s.closed = true
		}
	}
	if err := s.emit(event); err != nil {
		return err
	}
	if event["kind"] == "turn_started" {
		s.started = true
		s.flush()
	}
	return nil
}

func (s *turnStatus) offer(label string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed || s.sent {
		return
	}
	s.pending = label
	s.flush()
}

func (s *turnStatus) close() {
	s.mu.Lock()
	s.closed = true
	s.pending = ""
	s.mu.Unlock()
}

// flush publishes the pending label once the turn has started. Called with
// s.mu held. A refused label is dropped: the Runner kept its cursor, so the
// turn's next event takes that cursor and the turn goes on.
func (s *turnStatus) flush() {
	if s.pending == "" || !s.started || s.closed || s.sent {
		return
	}
	label := s.pending
	s.pending = ""
	s.sent = true
	_ = s.emit(map[string]any{"kind": "status", "label": label})
}

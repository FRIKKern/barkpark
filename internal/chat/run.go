package chat

import (
	"context"
	"sync"

	tea "github.com/charmbracelet/bubbletea"
)

// run.go — the composition root. Config is the resolved connection the CLI hands
// in (mirrors taskboard.Config so `bp chat` and every other bp command can never
// drift on "which server am I talking to"); Run wires the real HTTP Transport,
// the per-session SSE streamer, and the Bubble Tea program, then blocks until
// the user quits.

// Config is the resolved server + scope `bp chat` runs against. The /v1/chat
// routes are FLAT and admin-token gated (charter D3) — Token is the data-plane
// bearer (cfg.Token, NEVER the control-plane CloudToken) — so Workspace/Project/
// Dataset are carried only for chrome + parity with the other surfaces' Config.
type Config struct {
	BaseURL   string
	Token     string
	Workspace string
	Project   string
	Dataset   string
}

// streamer owns the live SSE subscription's lifecycle. The chat stream is
// PER-SESSION (unlike the taskboard's single wireLive stream): resuming or
// switching sessions cancels the running stream and starts a fresh one from the
// new session's seq cursor. It holds the *tea.Program so the goroutine can
// p.Send frames into the update loop — the same pattern wireLive uses — with a
// mutex so a rapid switch can't race two goroutines onto one program.
type streamer struct {
	tr      Transport
	program *tea.Program
	mu      sync.Mutex
	cancel  context.CancelFunc
}

// start (re)subscribes the live stream to sessionID from lastSeq. Any prior
// stream is cancelled first, so a session switch never leaves a zombie goroutine
// pushing another session's frames. Frames arrive as streamFrameMsg; a terminal
// failure (the transport has already exhausted its own retry/backoff) arrives as
// streamErrMsg. A nil program (unit tests that never call Run) makes this a
// no-op — the reducer is driven directly.
func (s *streamer) start(sessionID string, lastSeq int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.cancel != nil {
		s.cancel()
	}
	if s.program == nil {
		return
	}
	ctx, cancel := context.WithCancel(context.Background())
	s.cancel = cancel
	p, tr := s.program, s.tr
	go func() {
		err := tr.Events(ctx, sessionID, lastSeq, func(event string, data []byte) {
			// Copy the frame payload: readSSE reuses its scanner buffer, so the
			// []byte handed here must not escape into another goroutine unowned.
			cp := append([]byte(nil), data...)
			p.Send(streamFrameMsg{name: event, data: cp})
		})
		if err != nil && ctx.Err() == nil {
			p.Send(streamErrMsg{err: err})
		}
	}()
}

// stop cancels the running stream (on quit or session switch).
func (s *streamer) stop() {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.cancel != nil {
		s.cancel()
		s.cancel = nil
	}
}

// Run opens the `bp chat` TUI against cfg and blocks until the user quits. It
// never blocks on the network before first paint (Init fires the sessions load
// as a command), so a dead server lands an honest error state on the picker
// instead of freezing the prompt.
func Run(cfg Config) error {
	tr := NewHTTPTransport(cfg.BaseURL, cfg.Token)
	stream := &streamer{tr: tr}
	m := newModel(tr, stream, cfg)

	// Mouse-all-motion so the wheel scrolls the transcript; it degrades honestly
	// (a terminal without mouse reporting simply never sends events and the
	// keyboard flow is untouched). Alt-screen so the conversation owns the frame.
	p := tea.NewProgram(m, tea.WithAltScreen(), tea.WithMouseAllMotion())
	stream.program = p // the goroutine's p.Send seam, set before Run starts the loop

	_, err := p.Run()
	stream.stop()
	return err
}

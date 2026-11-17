package chathost

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// The status label is out of the turn's cursor sequence (task-768e7dc4449cc7b9):
// it goes to POST /v1/chat-host/leases/:lease_id/status from its own goroutine,
// one try, and the turn's events never wait for it. Before, it rode
// /v1/chat-host/events under the turn's lock, so a text the provider wrote while
// the label's POST was in flight waited for that POST, and a 5xx/429 on it was
// retried for up to two minutes with the turn's next event behind it.

// statusPostFunc adapts a function to StatusPoster.
type statusPostFunc func(ctx context.Context, command RemoteCommand, label string) error

func (f statusPostFunc) PostStatus(ctx context.Context, command RemoteCommand, label string) error {
	return f(ctx, command, label)
}

// labelPathServer is the leaseServer with a status endpoint in front of it. A
// status label, on either path, creates gate (so the helper turn writes its
// text while the label is in flight) and is answered per mode: "hang" never
// answers until the host gives up on it (or labelBackstop passes), "503"
// answers 503 at once. textWhileHeld: the first text arrived while a hanging
// label POST was still open.
type labelPathServer struct {
	lease *leaseServer
	gate  string
	mode  string

	mu            sync.Mutex
	statusPosts   int
	statusBody    map[string]any
	statusPath    string
	held          bool
	textSeen      bool
	textWhileHeld bool
}

func (s *labelPathServer) handler(t *testing.T) http.Handler {
	inner := s.lease.handler(t)
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		label := false
		var body map[string]any
		if r.Method == http.MethodPost {
			raw, _ := io.ReadAll(r.Body)
			r.Body = io.NopCloser(bytes.NewReader(raw))
			_ = json.Unmarshal(raw, &body)
		}
		switch {
		case strings.HasPrefix(r.URL.Path, "/v1/chat-host/leases/") && strings.HasSuffix(r.URL.Path, "/status"):
			label = true
		case r.URL.Path == "/v1/chat-host/events":
			event, _ := body["event"].(map[string]any)
			switch event["kind"] {
			case "status":
				label = true
			case "text_delta":
				s.mu.Lock()
				if !s.textSeen {
					s.textSeen = true
					s.textWhileHeld = s.held
				}
				s.mu.Unlock()
			}
		}
		if !label {
			inner.ServeHTTP(w, r)
			return
		}
		s.mu.Lock()
		s.statusPosts++
		s.statusBody = body
		s.statusPath = r.URL.Path
		s.held = s.mode == "hang"
		s.mu.Unlock()
		_ = os.WriteFile(s.gate, nil, 0o600)
		w.Header().Set("Content-Type", "application/json")
		if s.mode == "503" {
			w.WriteHeader(http.StatusServiceUnavailable)
			_, _ = w.Write([]byte(`{"error":{"code":"unavailable"}}`))
			return
		}
		select {
		case <-time.After(labelBackstop):
		case <-r.Context().Done():
		}
		s.mu.Lock()
		s.held = false
		s.mu.Unlock()
		if r.Context().Err() != nil {
			return
		}
		if r.URL.Path == "/v1/chat-host/events" {
			// The old path: the label takes its cursor once it is answered.
			inner.ServeHTTP(w, r)
			return
		}
		w.WriteHeader(http.StatusAccepted)
		_, _ = w.Write([]byte(`{"streamed":true}`))
	})
}

func TestStatusLabelPostThatHangsOrFailsDoesNotHoldTheFirstText(t *testing.T) {
	for _, mode := range []string{"hang", "503"} {
		t.Run(mode, func(t *testing.T) {
			gate := filepath.Join(t.TempDir(), "gate")
			installStatusHelper(t, map[string]string{"BARKPARK_STATUS_HELPER": "turn", "BARKPARK_STATUS_HELPER_GATE": gate})
			root := t.TempDir()
			command, _ := json.Marshal(map[string]any{
				"provider": "claude", "operation": "send_turn", "session_id": "session-1",
				"payload": map[string]any{"cwd": root, "content": "how do ocean tides work?", "mode": "plan"},
			})
			server := &labelPathServer{lease: &leaseServer{command: string(command)}, gate: gate, mode: mode}
			ts := httptest.NewServer(server.handler(t))
			defer ts.Close()
			client := &Client{BaseURL: ts.URL, Credential: "host-secret", HTTPClient: ts.Client(), AllowInsecureLoopback: true}

			handler := NewLocalHandler([]string{root})
			handler.StatusLabel = StatusLabelFunc(func(context.Context, string) (string, error) { return tidesLabel, nil })
			handler.Status = client
			// Longer than the server holds a hanging POST: the host must not end
			// it on its own clock first, or a text that comes later than the
			// default on a loaded machine would look held.
			handler.StatusPostTimeout = 2 * labelBackstop
			log := &syncBuffer{}
			handler.Log = log
			runner := Runner{Client: client, Handler: handler, PollInterval: time.Millisecond, Log: &syncBuffer{}}
			ctx, cancel := context.WithTimeout(context.Background(), 3*labelBackstop)
			defer cancel()
			result := make(chan error, 1)
			go func() { result <- runner.Run(ctx) }()

			for {
				if done, _ := server.lease.snapshot(); done {
					break
				}
				if ctx.Err() != nil {
					_, kinds := server.lease.snapshot()
					t.Fatalf("the turn never completed behind a label POST that is %s; events taken: %v", mode, kinds)
				}
				time.Sleep(time.Millisecond)
			}
			_, kinds := server.lease.snapshot()
			server.mu.Lock()
			textSeen, textWhileHeld := server.textSeen, server.textWhileHeld
			server.mu.Unlock()
			if !textSeen {
				t.Fatalf("no text reached the server behind a label POST that is %s; events taken: %v", mode, kinds)
			}
			if mode == "hang" && !textWhileHeld {
				t.Fatalf("the first text reached the server only after the hanging label POST ended: the POST held it")
			}
			if want := []string{"session_started", "turn_started", "text_delta", "turn_completed"}; fmt.Sprint(kinds) != fmt.Sprint(want) {
				t.Fatalf("events taken %v; want %v: the label is not a turn event", kinds, want)
			}

			// One try: a refused label is not retried, after the turn either.
			time.Sleep(100 * time.Millisecond)
			cancel()
			<-result
			server.mu.Lock()
			defer server.mu.Unlock()
			if server.statusPosts != 1 {
				t.Fatalf("status POSTs=%d; want exactly 1", server.statusPosts)
			}
			if server.statusPath != "/v1/chat-host/leases/lease-1/status" {
				t.Fatalf("the label went to %s; want /v1/chat-host/leases/lease-1/status", server.statusPath)
			}
			if server.statusBody["label"] != tidesLabel || server.statusBody["epoch"] != 1.0 || len(server.statusBody) != 2 {
				t.Fatalf("status body %#v; want exactly {epoch: 1, label: %q}", server.statusBody, tidesLabel)
			}
			// A refused POST leaves one line without the person's text; one the
			// turn's end cut off (the hang) leaves none.
			got := log.String()
			if want := map[string]int{"503": 1, "hang": 0}[mode]; strings.Count(got, "status label not taken") != want {
				t.Fatalf("log %q; want %d line(s) saying the label was not taken", got, want)
			}
			if strings.Contains(got, "ocean tides") {
				t.Fatalf("log %q carries the person's text", got)
			}
		})
	}
}

// The label POST has its own timer, LocalHandler.StatusPostTimeout
// (task-0d2151c31ef9c2a8). A status endpoint that never answers is given up on
// when that timer runs out, while the turn is still going: the turn's text
// waits for the host's "not taken" line, which the host writes only while the
// turn runs, so the timer, not the turn's end, must end the POST. The label is
// dropped after one try with one log line, and the turn is the same as with no
// label.
//
// The gate opens on the host's line, not on the server seeing the POST end:
// under load the 100 ms timer can run out before the POST reaches the server
// at all (13 of 4000 runs beside 4 package loops, task-c1762a533c619bda), and a
// gate the server opened then waited out the helper's 20 s backstop. A POST
// the server did get must still have been ended by the host.
func TestStatusLabelPostIsDroppedWhenItsOwnTimerRunsOut(t *testing.T) {
	gate := filepath.Join(t.TempDir(), "gate")
	installStatusHelper(t, map[string]string{"BARKPARK_STATUS_HELPER": "turn", "BARKPARK_STATUS_HELPER_GATE": gate})

	var mu sync.Mutex
	var posts int
	served := make(chan bool, 1) // whether the host ended the POST the server got
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !strings.HasSuffix(r.URL.Path, "/status") {
			http.NotFound(w, r)
			return
		}
		mu.Lock()
		posts++
		mu.Unlock()
		// The server sees the host close the request only once the body is read.
		_, _ = io.Copy(io.Discard, r.Body)
		// Hang: never answer. The host ending the request is the only way out
		// short of the backstop.
		select {
		case <-r.Context().Done():
		case <-time.After(labelBackstop):
		}
		select {
		case served <- r.Context().Err() != nil:
		default: // a second POST; the count below reports it
		}
		if r.Context().Err() == nil {
			w.WriteHeader(http.StatusAccepted)
		}
	}))
	defer ts.Close()
	// A kept-alive connection, so the POST does not wait on a dial and the
	// server normally gets it before the timer runs out.
	warm, err := ts.Client().Get(ts.URL + "/warm")
	if err != nil {
		t.Fatal(err)
	}
	_, _ = io.Copy(io.Discard, warm.Body)
	warm.Body.Close()

	handler := NewLocalHandler([]string{t.TempDir()})
	handler.StatusLabel = StatusLabelFunc(func(context.Context, string) (string, error) { return tidesLabel, nil })
	handler.Status = &Client{BaseURL: ts.URL, Credential: "host-secret", HTTPClient: ts.Client(), AllowInsecureLoopback: true}
	handler.StatusPostTimeout = 100 * time.Millisecond
	log := &lineSignal{want: "status label not taken", seen: make(chan struct{})}
	handler.Log = log
	finished := make(chan struct{})
	defer close(finished)
	go func() {
		select {
		case <-log.seen:
			_ = os.WriteFile(gate, nil, 0o600)
		case <-finished:
		}
	}()

	var events []map[string]any
	droppedWhileTurnRan := false
	err = handler.Handle(context.Background(), RemoteCommand{LeaseID: "lease-1", Epoch: 1, Command: map[string]any{
		"provider": "claude", "operation": "send_turn", "session_id": "session-label",
		"payload": map[string]any{"cwd": handler.ApprovedRoots[0], "content": "how do ocean tides work?", "mode": "plan"},
	}}, func(event map[string]any) error {
		if event["kind"] == "turn_completed" {
			select {
			case <-log.seen:
				droppedWhileTurnRan = true
			default:
			}
		}
		events = append(events, event)
		return nil
	})
	if err != nil {
		t.Fatalf("Handle() = %v; want the turn to complete", err)
	}
	if want := []string{"session_started", "turn_started", "text_delta", "turn_completed"}; fmt.Sprint(kindsOf(events)) != fmt.Sprint(want) {
		t.Fatalf("events %v; want %v: a dropped label leaves the turn as it was", kindsOf(events), want)
	}
	if !droppedWhileTurnRan {
		t.Fatalf("the turn ended before the host gave up on the hanging label POST: its own timer never ran out (log %q)", log.String())
	}
	mu.Lock()
	got := posts
	mu.Unlock()
	if got == 1 && !<-served {
		t.Fatalf("the hanging label POST ran to the server's %v backstop: the host never gave up on it", labelBackstop)
	}

	// One try: a dropped label is not retried, after the turn either.
	time.Sleep(100 * time.Millisecond)
	out := log.String()
	if strings.Count(out, "status label not taken") != 1 || !strings.Contains(out, "deadline exceeded") {
		t.Fatalf("log %q; want one line saying the label was not taken because its time ran out", out)
	}
	if strings.Contains(out, "ocean tides") {
		t.Fatalf("log %q carries the person's text", out)
	}
	mu.Lock()
	defer mu.Unlock()
	// 0 when the timer ran out before the POST reached the server.
	if posts > 1 {
		t.Fatalf("status POSTs=%d; want at most 1", posts)
	}
}

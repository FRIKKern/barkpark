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
// text while the label is in flight) and is answered per mode: "hang" holds the
// answer for 3 s, "503" answers 503 at once.
type labelPathServer struct {
	lease *leaseServer
	gate  string
	mode  string

	mu          sync.Mutex
	statusPosts int
	statusBody  map[string]any
	statusPath  string
	textAt      time.Time
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
				if s.textAt.IsZero() {
					s.textAt = time.Now()
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
		s.mu.Unlock()
		_ = os.WriteFile(s.gate, nil, 0o600)
		w.Header().Set("Content-Type", "application/json")
		if s.mode == "503" {
			w.WriteHeader(http.StatusServiceUnavailable)
			_, _ = w.Write([]byte(`{"error":{"code":"unavailable"}}`))
			return
		}
		select {
		case <-time.After(3 * time.Second):
		case <-r.Context().Done():
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
			dir := t.TempDir()
			gate := filepath.Join(dir, "gate")
			stamps := filepath.Join(dir, "times.json")
			installStatusHelper(t, map[string]string{
				"BARKPARK_STATUS_HELPER": "turn", "BARKPARK_STATUS_HELPER_GATE": gate,
				"BARKPARK_STATUS_HELPER_TIMES": stamps,
			})
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
			log := &syncBuffer{}
			handler.Log = log
			runner := Runner{Client: client, Handler: handler, PollInterval: time.Millisecond, Log: &syncBuffer{}}
			ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
			defer cancel()
			result := make(chan error, 1)
			go func() { result <- runner.Run(ctx) }()

			started := time.Now()
			for {
				if done, _ := server.lease.snapshot(); done {
					break
				}
				if ctx.Err() != nil {
					_, kinds := server.lease.snapshot()
					t.Fatalf("the turn never completed; events taken: %v", kinds)
				}
				time.Sleep(time.Millisecond)
			}
			took := time.Since(started)
			_, kinds := server.lease.snapshot()

			raw, err := os.ReadFile(stamps)
			if err != nil {
				t.Fatalf("the helper turn wrote no times: %v", err)
			}
			var nanos map[string]int64
			if err := json.Unmarshal(raw, &nanos); err != nil {
				t.Fatal(err)
			}
			server.mu.Lock()
			textAt := server.textAt
			server.mu.Unlock()
			if textAt.IsZero() {
				t.Fatalf("no text reached the server in %v behind a label POST that is %s; events taken: %v", took, mode, kinds)
			}
			if lag := textAt.Sub(time.Unix(0, nanos["text"])); lag > 100*time.Millisecond {
				t.Fatalf("the first text reached the server %v after the provider wrote it, behind a label POST that is %s; want within 100ms", lag, mode)
			}
			if took > 2500*time.Millisecond {
				t.Fatalf("the turn took %v behind a label POST that is %s", took, mode)
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

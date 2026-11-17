package chathost

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

// Whose event holds the cursor a close was refused at (review of #26688,
// round 2). After the first-event bound cut event 1, a cursor_conflict on the
// close at cursor 1 says only that SOME event holds cursor 1: the turn's own
// event 1, taken late, or the server's close, when it withdrew the lease
// meanwhile. Only the first may move the close to cursor 2. A close sent after
// the server's own would mark the session exited and can end the NEW turn the
// person started after "send it again".

// plantFront fronts a leaseServer. On the first POST of kind plantOn it plants
// plantKind at cursor plantAt in the lease server (completes: as the server's
// own close, which completes the lease). refuse answers a kind with a status;
// with refuseUntilClose, only until the host's first close arrives.
type plantFront struct {
	inner            *leaseServer
	plantOn          string
	plantAt          uint64
	plantKind        string
	completes        bool
	refuse           map[string]int
	refuseUntilClose bool

	planted   chan struct{}
	plantOnce sync.Once

	mu     sync.Mutex
	closed bool
	posts  []string // kind@cursor=status, in order
	polls  int
}

func (p *plantFront) handler(t *testing.T) http.Handler {
	inner := p.inner.handler(t)
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/v1/chat-host/commands" {
			p.mu.Lock()
			p.polls++
			p.mu.Unlock()
		}
		if r.URL.Path != "/v1/chat-host/events" {
			inner.ServeHTTP(w, r)
			return
		}
		body, _ := io.ReadAll(r.Body)
		var payload struct {
			Cursor uint64         `json:"cursor"`
			Event  map[string]any `json:"event"`
		}
		_ = json.Unmarshal(body, &payload)
		r.Body = io.NopCloser(bytes.NewReader(body))
		kind, _ := payload.Event["kind"].(string)

		if kind == p.plantOn {
			p.plantOnce.Do(func() {
				p.inner.mu.Lock()
				if p.inner.taken == nil {
					p.inner.taken = map[uint64]string{}
				}
				p.inner.taken[p.plantAt] = "planted|" + p.plantKind
				p.inner.lastCursor = p.plantAt
				p.inner.kinds = append(p.inner.kinds, p.plantKind)
				if p.completes {
					p.inner.completed = true
				}
				p.inner.mu.Unlock()
				close(p.planted)
			})
		}
		p.mu.Lock()
		if kind == "terminal" {
			p.closed = true
		}
		status := p.refuse[kind]
		if p.refuseUntilClose && p.closed && kind != "terminal" {
			status = 0
		}
		p.mu.Unlock()
		if status == 0 {
			answer := httptest.NewRecorder()
			inner.ServeHTTP(answer, r)
			status = answer.Code
			w.WriteHeader(answer.Code)
			_, _ = w.Write(answer.Body.Bytes())
		} else {
			w.WriteHeader(status)
			_, _ = w.Write([]byte(`{"error":{"code":"refused"}}`))
		}
		p.mu.Lock()
		p.posts = append(p.posts, fmt.Sprintf("%s@%d=%d", kind, payload.Cursor, status))
		p.mu.Unlock()
	})
}

// runPlanted runs one turn against front until the lease goroutine gave up on
// its close (its "terminal was not taken" line), then lets 20 more polls go by,
// so anything the host would still send has been sent. It returns the events
// the lease server took, every event POST, and the Runner's log.
func runPlanted(t *testing.T, front *plantFront) ([]string, []string, string) {
	t.Helper()
	front.planted = make(chan struct{})
	if front.plantOn == "" {
		close(front.planted) // nothing to plant, nothing to wait for
	}
	log := &lineSignal{want: "terminal was not taken", seen: make(chan struct{})}
	front.inner.log = log
	front.inner.transport = func(base http.RoundTripper) http.RoundTripper {
		return deliverTransport{base: base, taken: front.planted}
	}
	ctx, stop := startRunnerOn(t, front.handler(t), front.inner, &turnHandler{})
	defer stop()

	select {
	case <-log.seen:
	case <-ctx.Done():
		front.mu.Lock()
		defer front.mu.Unlock()
		t.Fatalf("the host never gave up on its close; posts %v\nlog:\n%s", front.posts, log.String())
	}
	front.mu.Lock()
	until := front.polls + 20
	front.mu.Unlock()
	for ctx.Err() == nil {
		front.mu.Lock()
		polls := front.polls
		front.mu.Unlock()
		if polls >= until {
			break
		}
		time.Sleep(time.Millisecond)
	}
	_, kinds := front.inner.snapshot()
	front.mu.Lock()
	defer front.mu.Unlock()
	return kinds, append([]string(nil), front.posts...), log.String()
}

// after returns the posts that follow the first one starting with prefix.
func after(posts []string, prefix string) []string {
	for i, post := range posts {
		if strings.HasPrefix(post, prefix) {
			return posts[i+1:]
		}
	}
	return nil
}

func hostCloses(kinds []string) int {
	n := 0
	for _, kind := range kinds {
		if kind == "terminal" {
			n++
		}
	}
	return n
}

// The task's own scenario: event 1 meets 503s until the bound while the server
// withdraws the lease (its close at cursor 1). The host's close at cursor 1 is
// refused as cursor_conflict; event 1 sent again is refused too, so cursor 1 is
// not the host's and nothing more is sent. While the server is still failing,
// the host does not guess: the lease is left to the next poll, which no longer
// lists it.
func TestRunnerSendsNoCloseAfterTheServerWithdrewTheLease(t *testing.T) {
	for name, front := range map[string]*plantFront{
		"server answers again": {refuseUntilClose: true},
		"server still failing": {},
	} {
		t.Run(name, func(t *testing.T) {
			front.inner = &leaseServer{firstEventDeadline: 100 * time.Millisecond, closeDeadline: 300 * time.Millisecond}
			front.plantOn, front.plantAt, front.plantKind, front.completes = "session_started", 1, "server-close", true
			front.refuse = map[string]int{"session_started": http.StatusServiceUnavailable}
			kinds, posts, log := runPlanted(t, front)

			if n := hostCloses(kinds); n != 0 {
				t.Fatalf("events taken %v: the host's close went in after the server's own close\nposts %v\nlog:\n%s", kinds, posts, log)
			}
			rest := after(posts, "terminal@1=")
			for _, post := range rest {
				if strings.HasPrefix(post, "terminal@") {
					t.Fatalf("posts after the refused close %v: the host sent another close\nlog:\n%s", rest, log)
				}
			}
			if front.refuseUntilClose {
				if fmt.Sprint(rest) != "[session_started@1=422]" {
					t.Fatalf("posts after the refused close %v; want event 1 sent once more and refused (cursor 1 is the server's)\nlog:\n%s", rest, log)
				}
				if !strings.Contains(log, "is not what the server holds") {
					t.Fatalf("log does not say cursor 1 is the server's:\n%s", log)
				}
			}
		})
	}
}

// A real conflict, with no first-event cut: event 2's cursor holds an event
// that is not the host's. The close sent there is refused too; it must not be
// moved to cursor 3.
func TestRunnerDoesNotMoveACloseAfterAConflictTheBoundDidNotCause(t *testing.T) {
	front := &plantFront{
		inner:   &leaseServer{closeDeadline: time.Second},
		plantOn: "turn_started", plantAt: 2, plantKind: "foreign",
	}
	kinds, posts, log := runPlanted(t, front)
	if fmt.Sprint(kinds) != "[session_started foreign]" {
		t.Fatalf("events taken %v; want [session_started foreign]: a close was moved past a conflict\nposts %v\nlog:\n%s", kinds, posts, log)
	}
	var closes []string
	for _, post := range posts {
		if strings.HasPrefix(post, "terminal@") {
			closes = append(closes, post)
		}
	}
	if fmt.Sprint(closes) != "[terminal@2=422]" {
		t.Fatalf("close POSTs %v; want one, refused at cursor 2\nlog:\n%s", closes, log)
	}
}

// After a cut, a close refused for any other reason (409: the lease expired)
// is not a question about cursor 1: it is sent once and nothing follows it.
func TestRunnerSendsNothingMoreAfterACutWhenTheCloseIsRefusedForAnotherReason(t *testing.T) {
	front := &plantFront{
		inner:  &leaseServer{firstEventDeadline: 100 * time.Millisecond, closeDeadline: 300 * time.Millisecond},
		refuse: map[string]int{"session_started": http.StatusServiceUnavailable, "terminal": http.StatusConflict},
	}
	// Nothing is planted (no plantOn): event 1 never reaches the lease server.
	kinds, posts, log := runPlanted(t, front)
	if rest := after(posts, "terminal@1="); len(rest) != 0 {
		t.Fatalf("posts after the close refused with 409: %v; want none\nlog:\n%s", rest, log)
	}
	if n := hostCloses(kinds); n != 0 {
		t.Fatalf("events taken %v; want none", kinds)
	}
}

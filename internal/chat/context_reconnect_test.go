package chat

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	tea "github.com/charmbracelet/bubbletea"
)

// context_reconnect_test.go — the band must describe the connection as it is
// NOW, not as it was at launch. Every test here moves the context (both the
// connection the transport reports and the local probes) BETWEEN the launch
// read and the event under test, then asserts each of the six fields carries
// the post-move value. A band that kept its pre-drop values fails naming the
// field that went stale.

// movingTransport reports whatever connection *conn currently holds, so a test
// can move the connection under a running model.
type movingTransport struct {
	Transport
	conn *Connection
}

func (t movingTransport) Connection() Connection { return *t.conn }

// contextSnapshot is one full set of the six band values.
type contextSnapshot struct {
	host, repo, server, workspace, project, dataset string
}

func (s contextSnapshot) connection() Connection {
	return Connection{Endpoint: s.server, Workspace: s.workspace, Project: s.project, Dataset: s.dataset}
}

func (s contextSnapshot) fields() []struct{ field, value string } {
	return []struct{ field, value string }{
		{"host", s.host},
		{"server", s.server},
		{"workspace", s.workspace},
		{"project", s.project},
		{"dataset", s.dataset},
		{"repo", s.repo},
	}
}

var (
	preDrop = contextSnapshot{
		host: "pre-host", repo: "/pre/repo", server: "https://pre.example",
		workspace: "pre-ws", project: "pre-proj", dataset: "pre-ds",
	}
	postDrop = contextSnapshot{
		host: "post-host", repo: "/post/repo", server: "https://post.example",
		workspace: "post-ws", project: "post-proj", dataset: "post-ds",
	}
)

// movingContext wires a model whose connection AND local probes both read
// through mutable state, starting at preDrop. move() flips every value to
// postDrop. The config stays at preDrop, so after the move the connection
// fields disagree with it; the band displays the CONNECTION's value (law 1)
// with a "configured …" note, which is why a correct re-read shows postDrop
// and a skipped one keeps preDrop. Reconciliation itself is context_test.go's.
func movingContext(t *testing.T) (Model, func()) {
	t.Helper()
	cur := preDrop
	conn := cur.connection()
	withProbe(t, LocalProbe{
		Hostname: func() (string, error) { return cur.host, nil },
		RepoRoot: func() (string, error) { return cur.repo, nil },
	})
	tr := movingTransport{conn: &conn}
	m := newModel(tr, &streamer{tr: tr}, Config{
		BaseURL: preDrop.server, Workspace: preDrop.workspace,
		Project: preDrop.project, Dataset: preDrop.dataset,
	})
	m.width, m.height = 160, 40
	move := func() {
		cur = postDrop
		conn = cur.connection()
	}
	return m, move
}

// assertBandShows checks both the resolved identity and the painted frame for
// every field of want, and names the stale field (with the value it still
// carries) when one is left behind.
func assertBandShows(t *testing.T, m Model, want contextSnapshot, stale contextSnapshot, when string) {
	t.Helper()
	frame := m.renderPicker()
	staleFields := stale.fields()
	for i, tc := range want.fields() {
		f, ok := m.ctxid.Field(tc.field)
		if !ok {
			t.Fatalf("%s: the identity carries no %q field", when, tc.field)
		}
		if f.Status != FieldSet || f.Value != tc.value {
			t.Errorf("%s: STALE FIELD %q — the band holds %q, the live context is %q "+
				"(pre-drop value %q). The band did not re-read after %s.",
				when, tc.field, f.Value, tc.value, staleFields[i].value, when)
		}
		if seg := tc.field + " " + tc.value; !strings.Contains(frame, seg) {
			t.Errorf("%s: the painted band lacks %q", when, seg)
		}
	}
}

// driveOnce runs Update for msg and then executes the single command it returns
// (the re-read), feeding its message back in — exactly one round trip of the
// update loop.
func driveOnce(t *testing.T, m Model, msg tea.Msg) Model {
	t.Helper()
	next, cmd := m.Update(msg)
	m = next.(Model)
	if cmd == nil {
		return m
	}
	next, _ = m.Update(cmd())
	return next.(Model)
}

func TestContextBandReReadsAfterStreamReconnect(t *testing.T) {
	m, move := movingContext(t)
	assertBandShows(t, m, preDrop, preDrop, "launch")

	move()
	// CONTROL: moving the context alone changes nothing — the band is held,
	// not re-probed per paint. The green below is therefore the reconnect's.
	assertBandShows(t, m, preDrop, preDrop, "the move, before any reconnect")

	m = driveOnce(t, m, streamReconnectedMsg{})
	assertBandShows(t, m, postDrop, preDrop, "a stream reconnect")
}

func TestContextBandReReadsAfterSessionResume(t *testing.T) {
	m, move := movingContext(t)
	assertBandShows(t, m, preDrop, preDrop, "launch")

	move()
	assertBandShows(t, m, preDrop, preDrop, "the move, before the resume")

	// The resume path: resumeSessionCmd's GET lands as sessionOpenedMsg.
	m = driveOnce(t, m, sessionOpenedMsg{session: Session{ID: "s-resumed"}})
	if m.screen != screenChat || m.st.SessionID != "s-resumed" {
		t.Fatalf("precondition: the resume must open the session (screen=%v id=%q)", m.screen, m.st.SessionID)
	}
	assertBandShows(t, m, postDrop, preDrop, "a session resume")
}

// A FAILED resume re-reads nothing: no session opened, so there is no new
// connection moment to describe.
func TestContextBandHeldOnFailedResume(t *testing.T) {
	m, move := movingContext(t)
	move()
	m = driveOnce(t, m, sessionOpenedMsg{err: errors.New("boom")})
	assertBandShows(t, m, preDrop, preDrop, "a failed resume")
}

// reconnectingTransport's Events calls onReconnect once, then returns.
type reconnectingTransport struct{ Transport }

func (reconnectingTransport) Events(ctx context.Context, id string, lastSeq int, onFrame func(string, []byte), onReconnect func()) error {
	onFrame("chat", []byte(`{}`))
	onReconnect()
	return nil
}

// TestStreamDeliversReconnectToTheShell closes the stream-goroutine link: a
// transport reconnect becomes a streamReconnectedMsg in the update loop, and a
// reconnect from a CANCELLED (replaced) stream does not.
func TestStreamDeliversReconnectToTheShell(t *testing.T) {
	var got []tea.Msg
	runStream(context.Background(), reconnectingTransport{}, "s1", 0, func(msg tea.Msg) { got = append(got, msg) })
	var reconnects int
	for _, msg := range got {
		if _, ok := msg.(streamReconnectedMsg); ok {
			reconnects++
		}
	}
	if reconnects != 1 {
		t.Fatalf("a transport reconnect must reach the shell as exactly one streamReconnectedMsg, got %d in %#v", reconnects, got)
	}

	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	got = nil
	runStream(ctx, reconnectingTransport{}, "s1", 0, func(msg tea.Msg) { got = append(got, msg) })
	for _, msg := range got {
		if _, ok := msg.(streamReconnectedMsg); ok {
			t.Fatalf("a cancelled stream must not report a reconnect: %#v", got)
		}
	}
}

// TestHTTPTransportForwardsReconnect proves the REAL transport hands
// apiclient's onReconnect through: a server that drops the stream once must
// produce a reconnect callback. (apiclient's backoff floor is 1s and is not
// settable from this package, so this test takes ~1s.)
func TestHTTPTransportForwardsReconnect(t *testing.T) {
	var hits int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&hits, 1)
		w.Header().Set("Content-Type", "text/event-stream")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("event: chat\ndata: {}\n\n"))
		// Return: the body ends, which the client reads as a drop.
	}))
	defer srv.Close()

	tr := NewHTTPTransport(Config{BaseURL: srv.URL, Token: "tok"})
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	reconnected := make(chan struct{}, 1)
	go func() {
		_ = tr.Events(ctx, "s1", 0, func(string, []byte) {}, func() {
			select {
			case reconnected <- struct{}{}:
			default:
			}
		})
	}()
	select {
	case <-reconnected:
		cancel()
	case <-ctx.Done():
		t.Fatalf("the real transport never reported a reconnect after the server dropped the stream (%d connects)", atomic.LoadInt32(&hits))
	}
}

// TestRepoRootProbeReReadsTheWorkingDirectory proves the PRODUCTION repo
// probe answers each re-read afresh. The band tests above inject the probe, so
// they would stay green over a probe that memoised its first answer — which
// would make every post-reconnect "re-read" of the repo root the launch value.
func TestRepoRootProbeReReadsTheWorkingDirectory(t *testing.T) {
	wd, err := os.Getwd()
	if err != nil {
		t.Fatalf("getwd: %v", err)
	}
	t.Chdir(wd)
	root, err := gitRepoRoot()
	if err != nil || root == "" {
		t.Fatalf("precondition: inside this repo the probe must find a root, got %q, %v", root, err)
	}

	t.Chdir(t.TempDir())
	if again, err := gitRepoRoot(); !errors.Is(err, ErrNotARepo) {
		t.Errorf("STALE FIELD \"repo\": after the working directory left the work tree the "+
			"probe still answered %q (err %v) — it is replaying its first answer instead of re-reading", again, err)
	}
}

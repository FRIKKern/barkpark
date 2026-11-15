package cli

import (
	"context"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"reflect"
	"sort"
	"strings"
	"sync"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// docFakeServer answers the routes `bp doc diff` and `bp doc duplicate` use:
// the document read, the revision read, the schema read and the mutate write.
// Bodies are keyed by the path after the workspace and project prefix.
type docFakeServer struct {
	srv *httptest.Server

	mu     sync.Mutex
	gets   map[string]string
	posts  []string
	answer string // the mutate response body
	// publicRead makes the fake answer like the real server answers a
	// credential that may only read published documents: 404 on every
	// drafts. id, and a refusal on a perspective=raw read.
	publicRead bool
	// noToken makes it answer like the real server answers a caller with no
	// token: 404 on every drafts. id, the published row on any other read,
	// and 401 on the history read.
	noToken bool
}

func newDocFakeServer(t *testing.T, gets map[string]string) *docFakeServer {
	t.Helper()
	s := &docFakeServer{gets: gets, answer: `{"transactionId":"t1","results":[{"id":"drafts.post-9","operation":"create"}]}`}
	s.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		s.mu.Lock()
		defer s.mu.Unlock()
		path := strings.TrimPrefix(r.URL.Path, "/w/ws/p/proj")
		w.Header().Set("Content-Type", "application/json")
		if r.Method == http.MethodPost && path == "/v1/data/mutate/production" {
			b, _ := io.ReadAll(r.Body)
			s.posts = append(s.posts, string(b))
			_, _ = w.Write([]byte(s.answer))
			return
		}
		if s.publicRead && r.URL.Query().Get("perspective") == "raw" {
			w.WriteHeader(http.StatusForbidden)
			_, _ = w.Write([]byte(`{"error":{"code":"forbidden","message":"public-read tokens may only read published public documents"}}`))
			return
		}
		if strings.HasPrefix(path, "/v1/data/history/") {
			switch {
			case s.publicRead:
				w.WriteHeader(http.StatusForbidden)
				_, _ = w.Write([]byte(`{"error":{"code":"forbidden","message":"read seat needed"}}`))
			case s.noToken:
				w.WriteHeader(http.StatusUnauthorized)
				_, _ = w.Write([]byte(`{"error":{"code":"unauthorized","message":"missing token"}}`))
			default:
				_, _ = w.Write([]byte(`{"revisions":[],"count":0}`))
			}
			return
		}
		if (s.publicRead || s.noToken) && strings.Contains(path, "/drafts.") {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		if body, ok := s.gets[path]; ok && r.Method == http.MethodGet {
			_, _ = w.Write([]byte(body))
			return
		}
		w.WriteHeader(http.StatusNotFound)
		_, _ = w.Write([]byte(`{"error":{"code":"not_found","message":"not found"}}`))
	}))
	t.Cleanup(s.srv.Close)
	return s
}

func (s *docFakeServer) ctx() manifest.Context {
	return manifest.Context{Server: s.srv.URL, Workspace: "ws", Project: "proj", Dataset: "production"}
}

func (s *docFakeServer) postCount() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return len(s.posts)
}

func runDocVerb(run func(*writer, globals, manifest.Context, []string) int, ctx manifest.Context, g globals, tail ...string) (int, string, string) {
	var so, se strings.Builder
	out := newWriter(&so, &se)
	out.output = g.output
	return run(out, g, ctx, tail), so.String(), se.String()
}

const docDiffPublished = `{"result":{"_id":"p1","_type":"post","_rev":"r1","_draft":false,"_publishedId":"p1",
	"_createdAt":"2026-01-01T00:00:00Z","_updatedAt":"2026-01-02T00:00:00Z",
	"title":"Old","subtitle":"gone","seo":{"title":"same"},
	"blocks":[{"_key":"a","text":"one"},{"_key":"b","text":"two"},{"_key":"c","text":"three"}]}}`

const docDiffDraft = `{"result":{"_id":"drafts.p1","_type":"post","_rev":"r2","_draft":true,"_publishedId":"p1",
	"_createdAt":"2026-01-03T00:00:00Z","_updatedAt":"2026-01-04T00:00:00Z",
	"title":"New","extra":"added","seo":{"title":"same"},
	"blocks":[{"_key":"c","text":"three"},{"_key":"a","text":"one"},{"_key":"b","text":"two"}]}}`

const (
	docDiffPubPath   = "/v1/data/doc/production/post/p1"
	docDiffDraftPath = "/v1/data/doc/production/post/drafts.p1"
)

// One changed, one added and one removed field are reported; the server's own
// keys are not; three keyed rows that moved are one reordered array. The exit
// code is 1, and -o json carries path, kind, before and after.
func TestDocDiffDraftAgainstPublished(t *testing.T) {
	s := newDocFakeServer(t, map[string]string{docDiffPubPath: docDiffPublished, docDiffDraftPath: docDiffDraft})

	code, stdout, stderr := runDocVerb(runDocDiff, s.ctx(), globals{output: "json"}, "post", "p1")
	if code != exitDocDiff {
		t.Fatalf("exit = %d, want %d; stdout=%s stderr=%s", code, exitDocDiff, stdout, stderr)
	}
	var got struct {
		Differences bool           `json:"differences"`
		Summary     map[string]int `json:"summary"`
		Changes     []struct {
			Path   string `json:"path"`
			Kind   string `json:"kind"`
			Before any    `json:"before"`
			After  any    `json:"after"`
		} `json:"changes"`
	}
	if err := json.Unmarshal([]byte(stdout), &got); err != nil {
		t.Fatalf("-o json did not parse: %v\n%s", err, stdout)
	}
	kinds := map[string]string{}
	for _, c := range got.Changes {
		kinds[c.Path] = c.Kind
		if c.Path == "title" && (c.Before != "Old" || c.After != "New") {
			t.Errorf("title before/after = %v/%v", c.Before, c.After)
		}
	}
	want := map[string]string{"title": "changed", "extra": "added", "subtitle": "removed", "blocks": "moved"}
	if !reflect.DeepEqual(kinds, want) || !got.Differences {
		t.Errorf("changes = %v (differences=%v), want %v", kinds, got.Differences, want)
	}
	if !reflect.DeepEqual(got.Summary, map[string]int{"changed": 1, "added": 1, "removed": 1, "moved": 1}) {
		t.Errorf("summary = %v", got.Summary)
	}

	code, stdout, _ = runDocVerb(runDocDiff, s.ctx(), globals{}, "post", "p1")
	if code != exitDocDiff {
		t.Fatalf("table exit = %d, want %d", code, exitDocDiff)
	}
	for _, wantLine := range []string{"post p1: draft compared to published", "~ title", `-     "Old"`, `+     "New"`, `+ extra  "added"`, `- subtitle  "gone"`, "1 changed, 1 added, 1 removed, 1 reordered"} {
		if !strings.Contains(stdout, wantLine) {
			t.Errorf("output is missing %q:\n%s", wantLine, stdout)
		}
	}
	if strings.Contains(stdout, "\x1b[") || strings.Contains(stdout, "_rev") || strings.Contains(stdout, "blocks[") {
		t.Errorf("output has colour off a terminal, a server key, or a moved row shown as changed:\n%s", stdout)
	}
}

// The same on both sides exits 0; no draft says so and exits 0; a draft that
// was never published shows every field as added; no document at all is 4.
func TestDocDiffExitCodes(t *testing.T) {
	same := strings.Replace(strings.Replace(docDiffPublished, `"_id":"p1"`, `"_id":"drafts.p1"`, 1), `"_rev":"r1"`, `"_rev":"r9"`, 1)
	s := newDocFakeServer(t, map[string]string{docDiffPubPath: docDiffPublished, docDiffDraftPath: same})
	if code, stdout, _ := runDocVerb(runDocDiff, s.ctx(), globals{}, "post", "p1"); code != exitOK || !strings.Contains(stdout, "0 changed, 0 added, 0 removed") {
		t.Errorf("identical: exit = %d, stdout=%s", code, stdout)
	}

	s = newDocFakeServer(t, map[string]string{docDiffPubPath: docDiffPublished})
	if code, stdout, _ := runDocVerb(runDocDiff, s.ctx(), globals{}, "post", "drafts.p1"); code != exitOK || strings.TrimSpace(stdout) != "no draft; nothing to publish" {
		t.Errorf("no draft: exit = %d, stdout=%q", code, stdout)
	}

	s = newDocFakeServer(t, map[string]string{docDiffDraftPath: docDiffDraft})
	code, stdout, _ := runDocVerb(runDocDiff, s.ctx(), globals{}, "post", "p1")
	if code != exitDocDiff || !strings.Contains(stdout, "0 changed, 4 added, 0 removed") {
		t.Errorf("never published: exit = %d, stdout=%s", code, stdout)
	}

	s = newDocFakeServer(t, nil)
	if code, _, stderr := runDocVerb(runDocDiff, s.ctx(), globals{}, "post", "p1"); code != exitNotFound || !strings.Contains(stderr, "no post document p1") {
		t.Errorf("no document: exit = %d, stderr=%s", code, stderr)
	}
	if code, _, _ := runDocVerb(runDocDiff, s.ctx(), globals{}, "post", "p1", "--from", "a"); code != exitUsage {
		t.Errorf("--from without --to: exit = %d, want %d", code, exitUsage)
	}
}

// A credential that cannot read drafts gets 404 on drafts.p1 although the
// draft is there. That must never read as "no draft; nothing to publish",
// exit 0: a CI job would pass while the draft differs. It is refused, with a
// code that is neither 0 nor the "differs" code.
func TestDocDiffRefusesACredentialThatCannotSeeDrafts(t *testing.T) {
	s := newDocFakeServer(t, map[string]string{docDiffPubPath: docDiffPublished, docDiffDraftPath: docDiffDraft})
	for _, kind := range []string{"public-read", "no token"} {
		s.publicRead, s.noToken = kind == "public-read", kind == "no token"
		for _, g := range []globals{{}, {output: "json"}} {
			code, stdout, stderr := runDocVerb(runDocDiff, s.ctx(), g, "post", "p1")
			if code != exitAuth || strings.Contains(stdout+stderr, "nothing to publish") || strings.Contains(stdout, `"differences":false`) {
				t.Errorf("%s, output %q: exit = %d, want %d and no claim that there is no draft; stdout=%s stderr=%s", kind, g.output, code, exitAuth, stdout, stderr)
			}
		}
	}
}

// --rev compares a revision to the current document, and a revision of
// another document is refused.
func TestDocDiffRevision(t *testing.T) {
	s := newDocFakeServer(t, map[string]string{
		docDiffPubPath:                   docDiffPublished,
		"/v1/data/revision/production/r": `{"revision":{"id":"r","doc_id":"drafts.p1","type":"post","title":"Older","content":{"subtitle":"gone","seo":{"title":"same"},"blocks":[{"_key":"a","text":"one"},{"_key":"b","text":"two"},{"_key":"c","text":"three"}]}}}`,
		"/v1/data/revision/production/x": `{"revision":{"id":"x","doc_id":"other","type":"post","content":{}}}`,
	})
	code, stdout, _ := runDocVerb(runDocDiff, s.ctx(), globals{}, "post", "p1", "--rev", "r")
	if code != exitDocDiff || !strings.Contains(stdout, "published compared to revision r") || !strings.Contains(stdout, "1 changed, 0 added, 0 removed") || !strings.Contains(stdout, `"Older"`) {
		t.Errorf("--rev: exit = %d, stdout=%s", code, stdout)
	}
	if code, _, stderr := runDocVerb(runDocDiff, s.ctx(), globals{}, "post", "p1", "--rev", "x"); code != exitValidation || !strings.Contains(stderr, "belongs to post other") {
		t.Errorf("foreign revision: exit = %d, stderr=%s", code, stderr)
	}
	if code, stdout, _ := runDocVerb(runDocDiff, s.ctx(), globals{}, "post", "p1", "--from", "r", "--to", "r"); code != exitOK {
		t.Errorf("--from r --to r: exit = %d, stdout=%s", code, stdout)
	}

	// -o json has the same keys in every mode.
	want := []string{"after", "before", "changes", "differences", "draft", "id", "published", "summary", "type"}
	noDraft := newDocFakeServer(t, map[string]string{docDiffPubPath: docDiffPublished})
	both := newDocFakeServer(t, map[string]string{docDiffPubPath: docDiffPublished, docDiffDraftPath: docDiffDraft})
	for name, run := range map[string]func() string{
		"--rev": func() string {
			_, o, _ := runDocVerb(runDocDiff, s.ctx(), globals{output: "json"}, "post", "p1", "--rev", "r")
			return o
		},
		"--from --to": func() string {
			_, o, _ := runDocVerb(runDocDiff, s.ctx(), globals{output: "json"}, "post", "p1", "--from", "r", "--to", "r")
			return o
		},
		"no draft": func() string {
			_, o, _ := runDocVerb(runDocDiff, noDraft.ctx(), globals{output: "json"}, "post", "p1")
			return o
		},
		"draft": func() string {
			_, o, _ := runDocVerb(runDocDiff, both.ctx(), globals{output: "json"}, "post", "p1")
			return o
		},
	} {
		var got map[string]any
		if err := json.Unmarshal([]byte(run()), &got); err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		keys := make([]string, 0, len(got))
		for k := range got {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		if !reflect.DeepEqual(keys, want) {
			t.Errorf("%s: keys = %v, want %v", name, keys, want)
		}
	}
}

// dialAllTo makes every request of the test reach the fake server whatever
// host its URL names, so a test can use a host that is not loopback and so
// counts as production.
func dialAllTo(t *testing.T, s *docFakeServer) {
	t.Helper()
	old := http.DefaultTransport
	addr := s.srv.Listener.Addr().String()
	http.DefaultTransport = &http.Transport{
		DialContext: func(ctx context.Context, network, _ string) (net.Conn, error) {
			return (&net.Dialer{}).DialContext(ctx, network, addr)
		},
	}
	t.Cleanup(func() { http.DefaultTransport = old })
}

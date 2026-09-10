package cli

// tasks_landed_merge_commit_test.go — the sha `bp task landed` records must be the one
// that is ON MAIN.
//
// THE DEFECT, measured on PR #17098 (branch cli/close-time-children) 2026-09-10:
//
//	compare/022dc4c44...main -> diverged   (branch tip)
//	compare/29b6c3e66...main -> ahead      (mergeCommit.oid)
//
// This repo squash-merges, so the branch's own head is on no branch that
// survives and is not an ancestor of main — ever. The sha an operator has on
// screen when they repair a missed landing is that tip, and before this wrapper
// `--commit <tip>` was recorded verbatim: a machine-readable merge record that
// no later reader can ancestor-check, which is the hand-reconstruction cost the
// structured field exists to end.
//
// RED-WITHOUT/GREEN-WITH: revert cli.go's `task landed` dispatch (or
// tasks_landed_cmd.go itself) and TestTaskLandedResolvesPRToMergeCommitOID fails
// — the request goes out with no commit at all.

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const mergeCommitLandedManifest = `{
  "manifest_version": "test",
  "server": {"name": "test", "version": "0", "base_url": "http://example.invalid"},
  "auth_tier": "read",
  "nouns": [{"name": "task", "summary": "tasks"}],
  "commands": [
    {
      "id": "task.landed", "noun": "task", "verb": "landed", "summary": "landed",
      "http": {"method": "POST", "path_template": "/v1/tasks/:doc_id/landed"},
      "auth_tier": "read",
      "args": [{"name": "doc_id", "required": true, "type": "string", "summary": "id"}],
      "flags": [
        {"name": "commit", "type": "string", "summary": "sha"},
        {"name": "pr", "type": "string", "summary": "pr"},
        {"name": "note", "type": "string", "summary": "note"},
        {"name": "criterion", "type": "int", "summary": "idx"}
      ],
      "writes": true, "batch": false, "paginated": false, "dry_run": false,
      "default_output": "minimal"
    }
  ]
}`

// mergeCommitLandedServer records what the POST actually carried — the only thing that
// settles which sha was recorded.
type mergeCommitLandedServer struct {
	query string
	body  string
}

func (s *mergeCommitLandedServer) start(t *testing.T) {
	t.Helper()
	be := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodPost && strings.HasSuffix(r.URL.Path, "/landed") {
			s.query = r.URL.RawQuery
			buf := make([]byte, 8192)
			n, _ := r.Body.Read(buf)
			s.body = string(buf[:n])
			_, _ = w.Write([]byte(`{"ok":true,"doc":{"doc_id":"bp-task-l"}}`))
			return
		}
		http.NotFound(w, r)
	}))
	t.Cleanup(be.Close)

	mf := filepath.Join(t.TempDir(), "manifest.json")
	if err := os.WriteFile(mf, []byte(mergeCommitLandedManifest), 0o600); err != nil {
		t.Fatalf("write manifest: %v", err)
	}
	t.Setenv("BARKPARK_MANIFEST", mf)
	t.Setenv("BARKPARK_API_URL", be.URL)
	t.Setenv("BARKPARK_API_TOKEN", "landed-stub")
}

// sent reports whether the request (query string OR body — the transport moves
// between them and this test is not about which) carried this text.
func (s *mergeCommitLandedServer) sent(text string) bool {
	return strings.Contains(s.query, text) || strings.Contains(s.body, text)
}

// stubGH pins `gh pr view` to a canned payload for the duration of one test.
func stubGH(t *testing.T, payload map[string]any) {
	t.Helper()
	raw, err := json.Marshal(payload)
	if err != nil {
		t.Fatalf("marshal stub: %v", err)
	}
	prev := ghPRView
	ghPRView = func(string) ([]byte, error) { return raw, nil }
	t.Cleanup(func() { ghPRView = prev })
}

// The real numbers off PR #17098. `tip` is `diverged` from main; `merge` is
// `ahead`. Only one of them may ever be written.
const (
	pr17098Tip   = "022dc4c440f22072e023ae5b394cb5ff636a8ccf"
	pr17098Merge = "29b6c3e66c40d67bdf201324d825e470cdabb60d"
)

// THE DETECTOR. `--pr` with no `--commit` records mergeCommit.oid, and NEVER
// headRefOid — which is present in the very same response, one field away.
func TestTaskLandedResolvesPRToMergeCommitOID(t *testing.T) {
	s := &mergeCommitLandedServer{}
	s.start(t)
	stubGH(t, map[string]any{
		"number":      17098,
		"state":       "MERGED",
		"mergedAt":    "2026-09-09T18:33:18Z",
		"headRefName": "cli/close-time-children",
		"headRefOid":  pr17098Tip,
		"mergeCommit": map[string]any{"oid": pr17098Merge},
	})

	so, se := captureStreams(t, []string{"task", "landed", "bp-task-l", "--pr", "17098", "--yes"})

	if !s.sent(pr17098Merge) {
		t.Fatalf("the landing did not record mergeCommit.oid %s — query=%q body=%q\nstdout:\n%s\nstderr:\n%s",
			pr17098Merge, s.query, s.body, so, se)
	}
	if s.sent(pr17098Tip) {
		t.Fatalf("the landing recorded the BRANCH TIP %s, which a squash leaves diverged from main forever — query=%q body=%q",
			pr17098Tip, s.query, s.body)
	}
	if !strings.Contains(se, "NOT the branch tip") {
		t.Errorf("the resolution was silent — an operator cannot tell which sha was recorded; stderr:\n%s", se)
	}
}

// THE CONTROL FOR THE DETECTOR. Same wrapper, same PR, one fact different: an
// explicit --commit is passed through UNTOUCHED and `gh` is never consulted.
// Without this, the test above proves only that some sha arrived.
func TestTaskLandedNeverOverridesAnExplicitCommit(t *testing.T) {
	s := &mergeCommitLandedServer{}
	s.start(t)
	prev := ghPRView
	ghPRView = func(string) ([]byte, error) {
		t.Fatalf("`gh` was consulted even though --commit was given explicitly")
		return nil, nil
	}
	t.Cleanup(func() { ghPRView = prev })

	_, _ = captureStreams(t, []string{
		"task", "landed", "bp-task-l", "--pr", "17098", "--commit", "deadbeef1234", "--yes",
	})

	if !s.sent("deadbeef1234") {
		t.Fatalf("an explicit --commit was not sent — query=%q body=%q", s.query, s.body)
	}
}

// AN UNMERGED PR IS A REFUSAL, NOT A FALLBACK. headRefOid is right there in the
// response and using it is the whole defect: it would write a sha silently that
// no reader can ancestor-check.
func TestTaskLandedRefusesAnUnmergedPRAndNeverFallsBackToTheTip(t *testing.T) {
	s := &mergeCommitLandedServer{}
	s.start(t)
	stubGH(t, map[string]any{
		"number":      17098,
		"state":       "OPEN",
		"headRefName": "cli/close-time-children",
		"headRefOid":  pr17098Tip,
	})

	so, se := captureStreams(t, []string{"task", "landed", "bp-task-l", "--pr", "17098", "--yes"})
	// The refusal rides whichever channel the caller's output shape puts it on
	// (an error envelope on stdout under the default render, prose on stderr);
	// this test is about WHAT IT SAYS, not which pipe carried it.
	said := so + se

	if s.query != "" || s.body != "" {
		t.Fatalf("an unmerged PR still POSTed a landing — query=%q body=%q", s.query, s.body)
	}
	if !strings.Contains(said, "no mergeCommit") {
		t.Errorf("the refusal does not say WHY; stdout:\n%s\nstderr:\n%s", so, se)
	}
	if !strings.Contains(said, pr17098Tip[:10]) {
		t.Errorf("the refusal does not NAME the tip it is refusing, so an operator will paste it into --commit by hand; output:\n%s", said)
	}
}

// A `gh` that cannot answer is also a refusal — "we could not ask" is not "here
// is the sha".
func TestTaskLandedRefusesWhenGHCannotAnswer(t *testing.T) {
	s := &mergeCommitLandedServer{}
	s.start(t)
	prev := ghPRView
	ghPRView = func(string) ([]byte, error) { return nil, errGHUnavailable }
	t.Cleanup(func() { ghPRView = prev })

	so, se := captureStreams(t, []string{"task", "landed", "bp-task-l", "--pr", "17098", "--yes"})
	said := so + se

	if s.query != "" || s.body != "" {
		t.Fatalf("a landing was POSTed with an unresolved sha — query=%q body=%q", s.query, s.body)
	}
	if !strings.Contains(said, "never guessed") {
		t.Errorf("the refusal does not state the rule it is enforcing; output:\n%s", said)
	}
}

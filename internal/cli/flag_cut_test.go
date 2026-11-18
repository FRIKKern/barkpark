package cli

// task-9ef60a4a9bac92fe: a cut whose budget falls between the two regional
// indicators of a flag ends on a grapheme boundary, never on a lone 🇳.

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestDecodePaperCheckErrCutsOnAGraphemeBoundary(t *testing.T) {
	pad := strings.Repeat("a", 196)
	if got := decodePaperCheckErr(502, []byte(pad+"🇳🇴")).Message; got != pad+"…" {
		t.Errorf("message ends %q, want the padding and an ellipsis", got[190:])
	}
}

func TestSupportTrimCutsOnAGraphemeBoundary(t *testing.T) {
	pad := strings.Repeat("a", 296)
	if got := supportTrim([]byte(pad + "🇳🇴")); got != pad+"…" {
		t.Errorf("supportTrim ends %q, want the padding and an ellipsis", got[290:])
	}
}

func TestTaskEventsErrorSnippetCutsOnAGraphemeBoundary(t *testing.T) {
	pad := strings.Repeat("a", 508)
	ts := httptest.NewServer(http.HandlerFunc(func(rw http.ResponseWriter, _ *http.Request) {
		rw.WriteHeader(http.StatusBadRequest)
		_, _ = rw.Write([]byte(pad + "🇳🇴"))
	}))
	defer ts.Close()
	_, _, err := httpTaskEventSource{server: ts.URL}.fetchOne("task-1", 0)
	if err == nil || !strings.HasSuffix(err.Error(), ": "+pad) {
		t.Errorf("task events error does not end on the padding: %v", err)
	}
}

func TestCapBodyCutsOnAGraphemeBoundary(t *testing.T) {
	pad := strings.Repeat("a", maxOpaqueRunes-1)
	if got := capBody([]byte(pad + "🇳🇴")); got != pad+"…" {
		t.Errorf("capBody ends %q, want the padding and an ellipsis", got[len(got)-12:])
	}
}

func TestCapDetailLineCutsOnAGraphemeBoundary(t *testing.T) {
	pad := strings.Repeat("a", maxOpaqueRunes-1)
	want := pad + "… (+8 more bytes; -o json for the full details)"
	if got := capDetailLine(pad + "🇳🇴"); got != want {
		t.Errorf("capDetailLine = …%q, want …%q", got[190:], want[190:])
	}
}

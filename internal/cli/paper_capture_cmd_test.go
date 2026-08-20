package cli

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"testing"
	"unicode/utf8"

	"github.com/charmbracelet/x/ansi"
)

func TestPaperCaptureFetchesOnceAndEmitsRealPinnedReaders(t *testing.T) {
	requests := 0
	const evidenceHref = "https://evidence.example/papers/candidate"
	const evidenceLabel = "Open candidate evidence"
	body := fmt.Sprintf(`{"release_gate_id":%q,"wave_revision":%q,"candidate_id":%q,"role":"campaign","document_id":%q,"doc_id":"campaign-paper","title":"Campaign proof","content_digest":%q,"source":{"kind":"blocks","blocks":[{"type":"heading","level":1,"content":[{"type":"text","value":"Immutable campaign"}]},{"type":"paragraph","content":[{"type":"text","value":"candidate proof"},{"type":"text","value":" — "},{"type":"link","href":%q,"children":[{"type":"text","value":%q}]}]}]}}`,
		cliReleaseGate, cliWaveRev, cliCandidate, cliDocument, strings.Repeat("b", 64),
		evidenceHref, evidenceLabel)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests++
		if got := r.URL.Query(); got.Get("wave_revision") != cliWaveRev || got.Get("candidate_id") != cliCandidate || len(got) != 2 {
			t.Errorf("query = %q", r.URL.RawQuery)
		}
		w.Header().Set("ETag", `"sha256:`+strings.Repeat("b", 64)+`"`)
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("X-Barkpark-Release-Gate", cliReleaseGate)
		w.Header().Set("X-Barkpark-Wave-Revision", cliWaveRev)
		w.Header().Set("X-Barkpark-Paper-Candidate", cliCandidate)
		w.Header().Set("X-Barkpark-Paper-Role", "campaign")
		_, _ = w.Write([]byte(body))
	}))
	defer srv.Close()

	sourceURL := srv.URL + "/w/acme/p/rocket/v1/cycles/epic/wave/release-gates/" + cliReleaseGate +
		"/papers/campaign/source?wave_revision=" + cliWaveRev + "&candidate_id=" + cliCandidate
	deployment := strings.Repeat("d", 64)
	args := []string{sourceURL, "--release-gate", cliReleaseGate, "--wave-revision", cliWaveRev,
		"--candidate-id", cliCandidate, "--role", "campaign", "--deployment-digest", deployment, "--width", "120"}
	run := func() paperCaptureEnvelope {
		var stdout, stderr bytes.Buffer
		out := newWriter(&stdout, &stderr)
		g := globals{server: srv.URL, workspace: "acme", project: "rocket", dataset: "production", output: "json", outputSet: true}
		out.applyGlobals(g)
		if code := runPaperCapture(out, g, args); code != exitOK {
			t.Fatalf("runPaperCapture code=%d stderr=%s stdout=%s", code, stderr.String(), stdout.String())
		}
		var envelope paperCaptureEnvelope
		if err := json.Unmarshal(stdout.Bytes(), &envelope); err != nil {
			t.Fatalf("decode: %v\n%s", err, stdout.String())
		}
		return envelope
	}
	first := run()
	second := run()
	if requests != 2 {
		t.Fatalf("requests = %d, want exactly one per capture", requests)
	}
	if first.Format != paperCaptureFormat || first.SourceURL != sourceURL || first.ReleaseGateID != cliReleaseGate ||
		first.WaveRevision != cliWaveRev || first.CandidateID != cliCandidate || first.Role != "campaign" {
		t.Fatalf("envelope pins drifted: %+v", first)
	}
	if len(first.Readers) != 3 {
		t.Fatalf("readers = %v", first.Readers)
	}
	sourceSum := sha256.Sum256([]byte(body))
	for _, name := range []string{"cli", "task_board", "tui"} {
		got := first.Readers[name]
		visible := ansi.Strip(got.RawUTF8)
		if got.RawUTF8 == "" || !utf8.ValidString(got.RawUTF8) || !strings.Contains(got.RawUTF8, "candidate proof") ||
			!strings.Contains(got.RawUTF8, "Campaign proof") || !strings.Contains(visible, evidenceLabel) ||
			!strings.Contains(got.RawUTF8, evidenceHref) {
			t.Errorf("%s raw output is not the real candidate render: %q", name, got.RawUTF8)
		}
		p := got.Provenance
		if p.Status != 0 || p.DeploymentDigest != deployment || p.SourceDigest != hex.EncodeToString(sourceSum[:]) ||
			len(p.BinaryDigest) != 64 || len(p.ParserDigest) != 64 || len(p.Argv) == 0 || p.Geometry == "" || p.Theme == "" || p.Profile == "" {
			t.Errorf("%s provenance incomplete: %+v", name, p)
		}
		if !reflect.DeepEqual(got, second.Readers[name]) {
			t.Errorf("%s capture is not deterministic", name)
		}
	}
	if first.Readers["cli"].RawUTF8 == first.Readers["task_board"].RawUTF8 || first.Readers["cli"].RawUTF8 == first.Readers["tui"].RawUTF8 {
		t.Fatal("reader outputs collapsed to one synthesized representation")
	}
}

func TestPaperCaptureRejectsPinDriftBeforeNetwork(t *testing.T) {
	sourceURL := "https://api.example/w/acme/p/rocket/v1/cycles/epic/wave/release-gates/" + cliReleaseGate +
		"/papers/campaign/source?wave_revision=" + cliWaveRev + "&candidate_id=" + cliCandidate
	var stdout, stderr bytes.Buffer
	out := newWriter(&stdout, &stderr)
	g := globals{output: "json", outputSet: true}
	out.applyGlobals(g)
	code := runPaperCapture(out, g, []string{sourceURL, "--release-gate", cliReleaseGate,
		"--wave-revision", cliWaveRev, "--candidate-id", "55555555-5555-4555-8555-555555555555",
		"--role", "campaign", "--deployment-digest", strings.Repeat("d", 64)})
	if code != exitUsage || !strings.Contains(stderr.String(), "pins do not match") {
		t.Fatalf("code=%d stderr=%q stdout=%q", code, stderr.String(), stdout.String())
	}
}

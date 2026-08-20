package cli

import (
	"bytes"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/FRIKKern/barkpark/internal/apiclient"
	"github.com/FRIKKern/barkpark/internal/taskboard"
)

func samplePicks() []taskboard.Pick {
	return []taskboard.Pick{
		{
			Task:            taskboard.Task{DocID: "drafts.ag-seam", Title: "User-principal seam", Priority: "0"},
			Score:           270,
			Reason:          "continues airdrop",
			NeighborhoodKey: "proj:airdrop",
			Areas:           []string{"~api"},
			Risk:            taskboard.RiskNeighborhood,
		},
		{
			Task:            taskboard.Task{DocID: "au-w1-2", Title: "per-surface token emitters", Priority: "1"},
			Score:           160,
			Reason:          "well-formed",
			NeighborhoodKey: "proj:design-system",
			Areas:           []string{"~cli", "~pdrender", "~studio", "~web"},
			Risk:            taskboard.RiskSharedSurface,
			Solo:            true,
			Displaced: []taskboard.Displaced{
				{DocID: "drafts.cloud-console", Title: "Members panel", Reason: "shared surface area:studio"},
			},
		},
		{
			Task:            taskboard.Task{DocID: "cc-members", Title: "Members + Usage GUI", Priority: "1"},
			Score:           160,
			Reason:          "",
			NeighborhoodKey: "proj:cloud-console",
			Areas:           []string{"studio"},
			Risk:            taskboard.RiskIsolated,
		},
	}
}

func TestParseFrontierFlags(t *testing.T) {
	cases := []struct {
		args       []string
		wantMax    int
		wantProven bool
		wantErr    bool
	}{
		{nil, 0, false, false},
		{[]string{"--proven-only"}, 0, true, false},
		{[]string{"--max", "5"}, 5, false, false},
		{[]string{"--max=3"}, 3, false, false},
		{[]string{"--max", "5", "--proven-only"}, 5, true, false},
		{[]string{"--max"}, 0, false, true},        // missing value
		{[]string{"--max", "-1"}, 0, false, true},  // negative
		{[]string{"--max", "abc"}, 0, false, true}, // non-int
		{[]string{"--bogus"}, 0, false, true},      // unknown flag
	}
	for _, c := range cases {
		opts, err := parseFrontierFlags(c.args)
		if c.wantErr {
			if err == nil {
				t.Errorf("%v: want error, got nil", c.args)
			}
			continue
		}
		if err != nil {
			t.Errorf("%v: unexpected error %v", c.args, err)
			continue
		}
		if opts.Max != c.wantMax || opts.ProvenOnly != c.wantProven {
			t.Errorf("%v: got {Max:%d Proven:%v}, want {Max:%d Proven:%v}",
				c.args, opts.Max, opts.ProvenOnly, c.wantMax, c.wantProven)
		}
	}
}

func TestRenderFrontierTable(t *testing.T) {
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	w.color = false
	picks := samplePicks()
	renderFrontierTable(w, picks, 15, 1, 14, taskboard.FrontierOpts{})
	got := stdout.String()

	for _, want := range []string{
		"FRONTIER · 15 independent · 1 proven · 14 unproven",
		"--proven-only for the safe set",
		"ag-seam", // bareID-stripped
		"User-principal seam",
		"[nbhd",
		"[SOLO",
		"⚑solo",
		"[isolated",
		"~cli,~pdrender,~studio,~web",
		"studio",
		"↳ displaces cloud-console", // bareID-stripped displaced id
		"shared surface area:studio",
	} {
		if !strings.Contains(got, want) {
			t.Errorf("table missing %q\n---\n%s", want, got)
		}
	}
}

func TestRenderFrontierTableEmpty(t *testing.T) {
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	renderFrontierTable(w, nil, 0, 0, 0, taskboard.FrontierOpts{})
	if !strings.Contains(stdout.String(), "nothing to dispatch") {
		t.Errorf("empty frontier should say nothing to dispatch, got:\n%s", stdout.String())
	}
}

func TestEmitFrontierJSON(t *testing.T) {
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	w.output = "json"
	picks := samplePicks()
	emitFrontierJSON(w, picks, 15, 1, 14, nil)

	var payload struct {
		OK          bool `json:"ok"`
		Independent int  `json:"independent"`
		Proven      int  `json:"proven"`
		Unproven    int  `json:"unproven"`
		Picks       []struct {
			ID            string   `json:"id"`
			Score         int      `json:"score"`
			Risk          string   `json:"risk"`
			Solo          bool     `json:"solo"`
			Proven        bool     `json:"proven"`
			Areas         []string `json:"areas"`
			ConflictsWith []struct {
				ID     string `json:"id"`
				Reason string `json:"reason"`
			} `json:"conflicts_with"`
		} `json:"picks"`
	}
	if err := json.Unmarshal(stdout.Bytes(), &payload); err != nil {
		t.Fatalf("json unmarshal: %v\n%s", err, stdout.String())
	}
	if !payload.OK || payload.Independent != 15 || payload.Proven != 1 || payload.Unproven != 14 {
		t.Errorf("summary = %+v", payload)
	}
	if len(payload.Picks) != 3 {
		t.Fatalf("picks = %d, want 3", len(payload.Picks))
	}
	if payload.Picks[0].ID != "ag-seam" {
		t.Errorf("pick[0].id = %q, want ag-seam (bareID)", payload.Picks[0].ID)
	}
	if !payload.Picks[1].Solo || payload.Picks[1].Risk != "shared-surface" {
		t.Errorf("pick[1] = %+v, want solo shared-surface", payload.Picks[1])
	}
	if len(payload.Picks[1].ConflictsWith) != 1 || payload.Picks[1].ConflictsWith[0].ID != "cloud-console" {
		t.Errorf("pick[1].conflicts_with = %+v", payload.Picks[1].ConflictsWith)
	}
	if !payload.Picks[2].Proven || payload.Picks[2].Risk != "isolated" {
		t.Errorf("pick[2] = %+v, want proven isolated", payload.Picks[2])
	}
}

// fakeGraphShower counts GraphShow calls and returns canned results keyed by
// root, so fetchCrossEdges' zero-fetch guard is testable without a network.
// The call counter is atomic because fetchCrossEdges fans out on a worker pool.
type fakeGraphShower struct {
	calls   atomic.Int32
	results map[string]*apiclient.GraphResult
}

func (f *fakeGraphShower) GraphShow(id string) (*apiclient.GraphResult, error) {
	f.calls.Add(1)
	if r, ok := f.results[id]; ok {
		return r, nil
	}
	return &apiclient.GraphResult{OK: true, Root: id}, nil
}

// TestFetchCrossEdgesZeroCallGuard — the CRITICAL guard: a single-root ready set
// can carry no cross-ROOT dependency, so fetchCrossEdges makes ZERO GraphShow
// calls and returns nil (slice-1 behavior).
func TestFetchCrossEdgesZeroCallGuard(t *testing.T) {
	snap := taskboard.Snapshot{Tasks: []taskboard.Task{
		{DocID: "r1", Lifecycle: "open"},
		{DocID: "a", ParentID: "r1", Lifecycle: "ready", Priority: "1"},
		{DocID: "b", ParentID: "r1", Lifecycle: "ready", Priority: "2"},
	}}
	gs := &fakeGraphShower{}
	edges := fetchCrossEdges(gs, snap)
	if got := gs.calls.Load(); got != 0 {
		t.Errorf("GraphShow calls = %d, want 0 (single-root ready set → no fetch)", got)
	}
	if edges != nil {
		t.Errorf("edges = %v, want nil", edges)
	}
}

// TestFetchCrossEdgesFetchesAndFolds — a multi-root ready set DOES fetch (once
// per candidate root) and folds a returned cross-root `blocks` edge into the
// CrossEdges shape. Non-`blocks` edges are ignored.
func TestFetchCrossEdgesFetchesAndFolds(t *testing.T) {
	snap := taskboard.Snapshot{Tasks: []taskboard.Task{
		{DocID: "r1", Lifecycle: "open"},
		{DocID: "r2", Lifecycle: "open"},
		{DocID: "a", ParentID: "r1", Lifecycle: "ready", Priority: "1"},
		{DocID: "b", ParentID: "r2", Lifecycle: "ready", Priority: "1"},
	}}
	// r1's graph carries the real cross-root block edge a→b (drafts path: node
	// id == doc_id) plus a noise ref edge that must be ignored.
	gs := &fakeGraphShower{results: map[string]*apiclient.GraphResult{
		"r1": {
			OK:   true,
			Root: "r1",
			Nodes: []apiclient.GraphNode{
				{ID: "a", DocID: "a"}, {ID: "b", DocID: "b"},
			},
			Edges: []apiclient.GraphEdgeWire{
				{FromID: "a", ToID: "b", Kind: "blocks"},
				{FromID: "a", ToID: "b", Kind: "references"}, // ignored
			},
		},
	}}
	edges := fetchCrossEdges(gs, snap)
	if got := gs.calls.Load(); got != 2 {
		t.Errorf("GraphShow calls = %d, want 2 (one per candidate root)", got)
	}
	if edges == nil || len(edges["a"]) != 1 || edges["a"][0] != "b" {
		t.Fatalf("folded edges = %+v, want a→[b]", edges)
	}
}

// slowGraphShower answers fast roots from the canned map and BLOCKS every other
// root until release is closed — the D12 pathology (a ~10s-per-call graph
// endpoint) made absolute.
type slowGraphShower struct {
	fast    map[string]*apiclient.GraphResult
	release chan struct{}
}

func (s *slowGraphShower) GraphShow(id string) (*apiclient.GraphResult, error) {
	if r, ok := s.fast[id]; ok {
		return r, nil
	}
	<-s.release
	return nil, errors.New("blocked root released")
}

// crossEdgeSnapTwoRoots is the minimal multi-root snapshot (ready set spans two
// epic roots) that arms the cross-edge fan-out.
func crossEdgeSnapTwoRoots() taskboard.Snapshot {
	return taskboard.Snapshot{Tasks: []taskboard.Task{
		{DocID: "r1", Lifecycle: "open"},
		{DocID: "r2", Lifecycle: "open"},
		{DocID: "a", ParentID: "r1", Lifecycle: "ready", Priority: "1"},
		{DocID: "b", ParentID: "r2", Lifecycle: "ready", Priority: "1"},
	}}
}

// TestFetchCrossEdgesDeadlineNeverHangs — D12/D4 deny-path: a graph endpoint
// that NEVER answers must not hang fetchCrossEdges. The bounded fan-out returns
// (empty-handed, no error) once the TOTAL wall-clock deadline fires, orders of
// magnitude before the blocked calls would ever finish.
func TestFetchCrossEdgesDeadlineNeverHangs(t *testing.T) {
	gs := &slowGraphShower{release: make(chan struct{})}
	t.Cleanup(func() { close(gs.release) }) // unblock abandoned workers

	start := time.Now()
	edges := fetchCrossEdgesBounded(gs, crossEdgeSnapTwoRoots(), 2, 100*time.Millisecond)
	elapsed := time.Since(start)

	if elapsed > 2*time.Second {
		t.Fatalf("fetchCrossEdgesBounded took %v — the total deadline must bound the fan-out", elapsed)
	}
	if edges != nil {
		t.Errorf("edges = %+v, want nil (nothing arrived before the deadline)", edges)
	}
}

// TestFetchCrossEdgesDeadlineKeepsCollected — best-effort on deadline: the root
// that answered in time contributes its cross-root block edge; the root still
// blocked when the deadline fires is dropped WITHOUT erroring the whole fetch.
func TestFetchCrossEdgesDeadlineKeepsCollected(t *testing.T) {
	gs := &slowGraphShower{
		fast: map[string]*apiclient.GraphResult{
			"r1": {
				OK:   true,
				Root: "r1",
				Nodes: []apiclient.GraphNode{
					{ID: "a", DocID: "a"}, {ID: "b", DocID: "b"},
				},
				Edges: []apiclient.GraphEdgeWire{
					{FromID: "a", ToID: "b", Kind: "blocks"},
				},
			},
			// r2 is absent from fast → its fetch blocks past the deadline.
		},
		release: make(chan struct{}),
	}
	t.Cleanup(func() { close(gs.release) })

	edges := fetchCrossEdgesBounded(gs, crossEdgeSnapTwoRoots(), 2, 150*time.Millisecond)
	if edges == nil || len(edges["a"]) != 1 || edges["a"][0] != "b" {
		t.Fatalf("collected edges = %+v, want a→[b] kept from the fast root", edges)
	}
}

// TestRenderOverlaps — the OVERLAP section prints each claimed collision with
// both workers and the shared surface, and prints NOTHING when the claim set is
// clean.
func TestRenderOverlaps(t *testing.T) {
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	w.color = false
	overlaps := []taskboard.OverlapPair{
		{AID: "a", BID: "b", AWorker: "w1", BWorker: "w2", Kind: "files", Shared: "internal/cli/onramp_cmd.go"},
	}
	renderOverlaps(w, overlaps)
	got := stdout.String()
	for _, want := range []string{"OVERLAP", "1 claimed pair", "internal/cli/onramp_cmd.go", "w1", "w2", "files"} {
		if !strings.Contains(got, want) {
			t.Errorf("overlap output missing %q\n---\n%s", want, got)
		}
	}
	// silent when none
	stdout.Reset()
	renderOverlaps(w, nil)
	if stdout.String() != "" {
		t.Errorf("no overlaps should render nothing, got %q", stdout.String())
	}
}

// TestEmitFrontierJSONOverlaps — the JSON payload carries the overlaps array.
func TestEmitFrontierJSONOverlaps(t *testing.T) {
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	w.output = "json"
	overlaps := []taskboard.OverlapPair{
		{AID: "a", BID: "b", AWorker: "w1", BWorker: "w2", Kind: "files", Shared: "internal/cli/onramp_cmd.go"},
	}
	emitFrontierJSON(w, nil, 0, 0, 0, overlaps)

	var payload struct {
		Overlaps []struct {
			A       string `json:"a"`
			B       string `json:"b"`
			AWorker string `json:"a_worker"`
			BWorker string `json:"b_worker"`
			Kind    string `json:"kind"`
			Shared  string `json:"shared"`
		} `json:"overlaps"`
	}
	if err := json.Unmarshal(stdout.Bytes(), &payload); err != nil {
		t.Fatalf("json unmarshal: %v\n%s", err, stdout.String())
	}
	if len(payload.Overlaps) != 1 {
		t.Fatalf("overlaps = %d, want 1", len(payload.Overlaps))
	}
	o := payload.Overlaps[0]
	if o.A != "a" || o.B != "b" || o.Kind != "files" || o.Shared != "internal/cli/onramp_cmd.go" || o.AWorker != "w1" || o.BWorker != "w2" {
		t.Errorf("overlap = %+v", o)
	}
}

// TestFrontierFetchFailureEmitsJSONEnvelope pins the fetchSnapshotErr fix
// (wbqs-go-board-fetch-error-envelope): before the fix, a failed
// taskboard.FetchSnapshotFull hit `out.userErr(...); return exitGeneric` with
// no machineOut() check, so `bp task frontier -o json | jq` on a broken board
// fetch got EMPTY stdout. It must now emit a parseable
// {"ok":false,"error":{"code":...,"message":...}} envelope on stdout.
func TestFrontierFetchFailureEmitsJSONEnvelope(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
	}))
	t.Cleanup(srv.Close)

	var so, se bytes.Buffer
	w := &writer{stdout: &so, stderr: &se, output: "json"}
	code := runTaskFrontier(w, globals{}, dispatchCtx(srv.URL), nil)
	if code != exitGeneric {
		t.Fatalf("exit = %d, want exitGeneric (%d)", code, exitGeneric)
	}
	if se.Len() != 0 {
		t.Errorf("json mode must not also leak the human stderr line:\n%s", se.String())
	}
	var env struct {
		OK    bool `json:"ok"`
		Error struct {
			Code    string `json:"code"`
			Message string `json:"message"`
		} `json:"error"`
	}
	if err := json.Unmarshal(so.Bytes(), &env); err != nil {
		t.Fatalf("json stdout not parseable (empty stdout is exactly the pre-fix bug): %v\n%s", err, so.String())
	}
	if env.OK || env.Error.Code == "" || env.Error.Message == "" {
		t.Errorf("bad fetch-failure envelope:\n%s", so.String())
	}
}

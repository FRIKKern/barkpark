package cli

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"

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
	emitFrontierJSON(w, picks, 15, 1, 14)

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

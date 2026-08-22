package cli

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/cloudclient"
)

// The 2026-08-06 guerrilla incident as a fleet row: the box the API was flapping
// on, carrying the runaway the beat now names. Every number is the incident's.
func incidentBox() cloudclient.Barkpark {
	cores, load1, load15 := 2.0, 6.32, 6.63
	at := "2026-08-06T01:30:00Z"
	return cloudclient.Barkpark{
		ID:           "bp-guerrilla",
		Name:         "guerrilla",
		Slug:         "guerrilla",
		Host:         "157.180.90.121",
		URL:          "https://guerrilla.barkpark.cloud",
		HealthStatus: "up",
		AgentStatus:  "online",
		LastSeenAt:   at,
		Pressure: &cloudclient.Pressure{
			CPUCores:   &cores,
			Load1:      &load1,
			Load15:     &load15,
			ReportedAt: &at,
			RunawayProcs: []cloudclient.RunawayProc{{
				PID:        3369344,
				ElapsedS:   10001,
				CPUPercent: 66.3,
				Command:    "journalctl -u bp-site-build-* --since -14d --no-pager",
			}},
		},
	}
}

// quietBox is the SAME box after the lead's `kill` — measured (a non-nil,
// empty list), and with nothing to say.
func quietBox() cloudclient.Barkpark {
	b := incidentBox()
	b.Pressure.RunawayProcs = []cloudclient.RunawayProc{}
	return b
}

// ARM ONE — the runaway REACHES THE SCREEN, with its elapsed time, its CPU
// share and the command an operator would kill.
func TestCloudStatusRendersTheRunaway(t *testing.T) {
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	renderStatusRows(w, rankBarkparks([]cloudclient.Barkpark{incidentBox()}))
	got := stdout.String()

	for _, want := range []string{
		"DETAIL",
		"runaway: pid 3369344",
		"orphaned 2h46m",
		"66.3% CPU",
		"journalctl -u bp-site-build-*",
	} {
		if !strings.Contains(got, want) {
			t.Fatalf("rendering is missing %q:\n%s", want, got)
		}
	}
}

// ARM TWO — the arm that makes arm one an instrument rather than a decoration.
// The SAME row with the runaway killed says NOTHING about a runaway, and a box
// whose agent never measured (nil list) says nothing either: neither may invent
// a sentence.
func TestCloudStatusIsSilentWithoutARunaway(t *testing.T) {
	for _, tc := range []struct {
		name string
		bp   cloudclient.Barkpark
	}{
		{"measured and quiet", quietBox()},
		{"never measured", func() cloudclient.Barkpark {
			b := incidentBox()
			b.Pressure.RunawayProcs = nil
			return b
		}()},
		{"no pressure block at all", func() cloudclient.Barkpark {
			b := incidentBox()
			b.Pressure = nil
			return b
		}()},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var stdout, stderr bytes.Buffer
			w := newWriter(&stdout, &stderr)
			renderStatusRows(w, rankBarkparks([]cloudclient.Barkpark{tc.bp}))
			if got := stdout.String(); strings.Contains(strings.ToLower(got), "runaway") {
				t.Fatalf("a box with no runaway rendered one:\n%s", got)
			}
		})
	}
}

// The marker rides on ANY row, including one the ladder calls `ok`. That is the
// whole point: for the first two hours the incident box WAS ok by every fence on
// this screen — the load average only caught up later, and by then the API was
// already returning 500s.
func TestRunawayMarkerRidesAnOkRow(t *testing.T) {
	b := incidentBox()
	// Idle by every aggregate: no fence on this screen can fire.
	load1, load15 := 0.10, 0.08
	b.Pressure.Load1, b.Pressure.Load15 = &load1, &load15

	ranked := rankBarkparks([]cloudclient.Barkpark{b})
	if ranked[0].Status != "ok" {
		t.Fatalf("status = %q, want ok (the aggregates are all idle)", ranked[0].Status)
	}
	if !strings.Contains(ranked[0].Detail, "runaway: pid 3369344") {
		t.Fatalf("an ok row hid its runaway; detail = %q", ranked[0].Detail)
	}
	// And the vocabulary is UNTOUCHED — no twelfth rung, no rebucketing.
	if ranked[0].Bucket != "healthy" || ranked[0].Rank != attentionRank("ok") {
		t.Fatalf("the marker moved the row: bucket=%q rank=%d", ranked[0].Bucket, ranked[0].Rank)
	}
}

// The marker COMPOSES with the reason a status already had, rather than
// replacing it. On the real incident the box was strained AND carrying the
// runaway, and an operator needs both halves: the strain is the symptom, the
// runaway is the cause.
func TestRunawayMarkerComposesWithStrainedReason(t *testing.T) {
	ranked := rankBarkparks([]cloudclient.Barkpark{incidentBox()})
	if ranked[0].Status != "strained" {
		t.Fatalf("status = %q, want strained (load15 6.63 on 2 cores)", ranked[0].Status)
	}
	d := ranked[0].Detail
	if !strings.Contains(d, "load 6.6 on 2 cores") {
		t.Fatalf("the strained reason was lost: %q", d)
	}
	if !strings.Contains(d, "runaway: pid 3369344") {
		t.Fatalf("the runaway was lost: %q", d)
	}
	if !strings.Contains(d, " · ") {
		t.Fatalf("the two clauses did not join: %q", d)
	}
}

// A second and third runaway are COUNTED even though only the worst is named.
func TestRunawayMarkerCountsTheRest(t *testing.T) {
	b := incidentBox()
	b.Pressure.RunawayProcs = append(b.Pressure.RunawayProcs,
		cloudclient.RunawayProc{PID: 2, ElapsedS: 4000, CPUPercent: 51, Command: "du -sh /"},
		cloudclient.RunawayProc{PID: 3, ElapsedS: 3000, CPUPercent: 55, Command: "grep -r x /"},
	)
	if got := runawayMarker(b); !strings.Contains(got, "(+2 more)") {
		t.Fatalf("marker = %q, want a (+2 more) count", got)
	}
}

// `-o json` carries EVERY row and the FULL command, and it keeps the three-state
// honesty the table cannot: absent key = never measured, [] = measured and quiet.
func TestRunawayJSONIsTriState(t *testing.T) {
	measured := rankedBarkparkRow(rankBarkparks([]cloudclient.Barkpark{incidentBox()})[0])
	raw, ok := measured["runaway_procs"]
	if !ok {
		t.Fatal("a measured box emitted no runaway_procs key")
	}
	blob, _ := json.Marshal(raw)
	for _, want := range []string{`"pid":3369344`, `"elapsed_s":10001`, `"cpu_percent":66.3`, "--no-pager"} {
		if !strings.Contains(string(blob), want) {
			t.Fatalf("json missing %s: %s", want, string(blob))
		}
	}

	quiet := rankedBarkparkRow(rankBarkparks([]cloudclient.Barkpark{quietBox()})[0])
	q, ok := quiet["runaway_procs"]
	if !ok {
		t.Fatal("a measured-quiet box emitted no runaway_procs key; [] is a real answer")
	}
	if n := len(q.([]any)); n != 0 {
		t.Fatalf("quiet box emitted %d rows, want 0", n)
	}

	unmeasured := incidentBox()
	unmeasured.Pressure.RunawayProcs = nil
	row := rankedBarkparkRow(rankBarkparks([]cloudclient.Barkpark{unmeasured})[0])
	if _, ok := row["runaway_procs"]; ok {
		t.Fatal("an UNMEASURED box emitted a runaway_procs key; absent is the only honest answer")
	}
}

// The elapsed rendering is the incident's own reading, and it never flattens a
// short age to 0.
func TestHumanElapsed(t *testing.T) {
	for _, tc := range []struct {
		in   float64
		want string
	}{
		{10001, "2h46m"}, // ELAPSED 02:46:41
		{3600, "1h00m"},
		{1800, "30m"},
		{45, "45s"},
		{-1, "?"},
	} {
		if got := humanElapsed(tc.in); got != tc.want {
			t.Errorf("humanElapsed(%v) = %q, want %q", tc.in, got, tc.want)
		}
	}
}

// The wire decodes: `null`, `[]` and a populated list arrive as three
// distinguishable states off the control plane's own key names.
func TestPressureDecodesRunawayProcs(t *testing.T) {
	var nilCase, emptyCase, fullCase cloudclient.Pressure
	if err := json.Unmarshal([]byte(`{"runaway_procs":null}`), &nilCase); err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal([]byte(`{"runaway_procs":[]}`), &emptyCase); err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal([]byte(
		`{"runaway_procs":[{"pid":3369344,"elapsed_s":10001,"cpu_percent":66.3,"command":"journalctl -u bp-site-build-*"}]}`,
	), &fullCase); err != nil {
		t.Fatal(err)
	}
	if nilCase.RunawayProcs != nil {
		t.Error("null decoded to a non-nil slice — unmeasured became measured")
	}
	if emptyCase.RunawayProcs == nil {
		t.Error("[] decoded to nil — measured-and-quiet became unmeasured")
	}
	if len(fullCase.RunawayProcs) != 1 || fullCase.RunawayProcs[0].PID != 3369344 {
		t.Errorf("populated list decoded wrong: %+v", fullCase.RunawayProcs)
	}
}

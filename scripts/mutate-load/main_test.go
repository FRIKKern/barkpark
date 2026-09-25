package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	mrand "math/rand"
	"net/http"
	"net/http/httptest"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
)

var roundRe = regexp.MustCompile(`round (\d+)`)

// fakeMutate answers by ROUND NUMBER (read out of the title), never by arrival
// order, so the expected counts are exact under any concurrency:
//
//	create, round%5==0           -> 500 {"error":{"code":"dedup_unavailable"}}
//	create, round%5==1           -> 409 {"error":{"code":"duplicate_task"}}
//	create, round%5==2           -> 500 text/html (no envelope)          -> http_500:-
//	create, round%5==3, round<10 -> 200 {"results":[]} (no id)           -> no_id
//	create, otherwise            -> 200 {"results":[{"id":"drafts.task-<round>"}]}
//	publish, round%10==4         -> connection hijacked and closed       -> transport:eof
//	publish, otherwise           -> 200
func fakeMutate(t *testing.T, seen *sync.Map, tagLegs *atomic.Int64) *httptest.Server {
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !strings.HasSuffix(r.URL.Path, "/w/default/p/default/v1/data/mutate/production") {
			t.Errorf("unexpected path %s", r.URL.Path)
		}
		if r.Header.Get("Authorization") != "Bearer tok" {
			t.Errorf("missing bearer: %q", r.Header.Get("Authorization"))
		}
		// A key may repeat ONLY as the transport's own resend of a publish this
		// server hung up on; every other reuse is a harness bug.
		key := r.Header.Get("Idempotency-Key")
		if prev, dup := seen.LoadOrStore(key, "sent"); key == "" || (dup && prev != "hungup") {
			t.Errorf("idempotency key reused or empty: %q", key)
		}
		var body struct {
			Mutations []map[string]map[string]any `json:"mutations"`
		}
		raw, _ := io.ReadAll(r.Body)
		if err := json.Unmarshal(raw, &body); err != nil || len(body.Mutations) != 1 {
			t.Errorf("bad body %s", raw)
			return
		}
		m := body.Mutations[0]
		if c, ok := m["create"]; ok && c["_type"] == "tag" {
			tagLegs.Add(1)
			w.WriteHeader(409)
			w.Write([]byte(`{"error":{"code":"conflict"}}`))
			return
		}
		if p, ok := m["publish"]; ok && p["type"] == "tag" {
			tagLegs.Add(1)
			w.Write([]byte(`{"results":[{"id":"loadtest"}]}`))
			return
		}
		if c, ok := m["create"]; ok {
			if b, _ := c["brief"].(map[string]any); b == nil || b["version"] != float64(1) {
				t.Errorf("create carries no v1 brief: %v", c["brief"])
			}
			if tags, _ := c["tags"].([]any); len(tags) != 1 {
				t.Errorf("create carries no weighted tag: %v", c["tags"])
			}
			if !strings.HasSuffix(key, "-create") || c["_type"] != "task" || c["kind"] != "task" || c["lifecycle_status"] != "open" {
				t.Errorf("create leg shape wrong: key=%s body=%v", key, c)
			}
			n, _ := strconv.Atoi(roundRe.FindStringSubmatch(c["title"].(string))[1])
			switch {
			case n%5 == 0:
				w.WriteHeader(500)
				w.Write([]byte(`{"error":{"code":"dedup_unavailable","message":"x"}}`))
			case n%5 == 1:
				w.WriteHeader(409)
				w.Write([]byte(`{"error":{"code":"duplicate_task","message":"x","details":{"similar":[]}}}`))
			case n%5 == 2:
				w.Header().Set("Content-Type", "text/html")
				w.WriteHeader(500)
				w.Write([]byte(`<html>Internal Server Error</html>`))
			case n%5 == 3 && n < 10:
				w.Write([]byte(`{"results":[]}`))
			default:
				w.Write([]byte(`{"results":[{"id":"drafts.task-` + strconv.Itoa(n) + `"}]}`))
			}
			return
		}
		p, ok := m["publish"]
		if !ok {
			t.Errorf("neither create nor publish: %v", m)
			return
		}
		if !strings.HasSuffix(key, "-publish") || p["type"] != "task" || strings.HasPrefix(p["id"].(string), "drafts.") {
			t.Errorf("publish leg shape wrong: key=%s body=%v", key, p)
		}
		n, _ := strconv.Atoi(strings.TrimPrefix(p["id"].(string), "task-"))
		if n%10 == 4 {
			seen.Store(key, "hungup")
			conn, _, _ := w.(http.Hijacker).Hijack()
			conn.Close()
			return
		}
		w.Write([]byte(`{"results":[{"id":"task-` + strconv.Itoa(n) + `"}]}`))
	}))
}

func runJSON(t *testing.T, args []string, rt http.RoundTripper) (int, report, string) {
	t.Helper()
	var out, errb bytes.Buffer
	code := run(append(args, "--json"), &out, &errb, rt)
	var rep report
	if code != 2 {
		if err := json.Unmarshal(out.Bytes(), &rep); err != nil {
			t.Fatalf("report not JSON: %v\n%s", err, out.String())
		}
	}
	return code, rep, errb.String()
}

// The core property: a 500 is a 500, not a success. 40 rounds, 8 in flight.
func TestFailuresAreCountedByClassNotAsSuccesses(t *testing.T) {
	var seen sync.Map
	var tagLegs atomic.Int64
	srv := fakeMutate(t, &seen, &tagLegs)
	defer srv.Close()

	code, rep, stderr := runJSON(t, []string{"--server", srv.URL, "--token", "tok", "--rounds", "40", "--concurrency", "8"}, http.DefaultTransport)
	if code != 1 {
		t.Fatalf("exit=%d want 1 (failures present); stderr=%s", code, stderr)
	}
	// rounds 0..39: %5==0 -> 8, %5==1 -> 8, %5==2 -> 8, %5==3 & <10 -> {3,8} = 2,
	// creates OK = 40-26 = 14; of those, publish eof on n%10==4 -> {4,14,24,34} = 4.
	c := rep.Legs["create"]
	wantCreate := map[string]int{"http_500:dedup_unavailable": 8, "http_409:duplicate_task": 8, "http_500:-": 8, "no_id": 2, "ok": 14}
	if c.Count != 40 || c.OK != 14 || !equalMap(c.Classes, wantCreate) {
		t.Fatalf("create stats = n=%d ok=%d %v, want n=40 ok=14 %v", c.Count, c.OK, c.Classes, wantCreate)
	}
	p := rep.Legs["publish"]
	wantPub := map[string]int{"ok": 10, "transport:eof": 4}
	if p.Count != 14 || p.OK != 10 || !equalMap(p.Classes, wantPub) {
		t.Fatalf("publish stats = n=%d ok=%d %v, want n=14 ok=10 %v", p.Count, p.OK, p.Classes, wantPub)
	}
	if tagLegs.Load() != 2 {
		t.Fatalf("ensure-tag sent %d legs, want 2 (create+publish)", tagLegs.Load())
	}
	if _, counted := rep.Legs["tag"]; counted {
		t.Fatal("ensure-tag legs leaked into the measured report")
	}
	if c.Resends != 0 {
		t.Fatalf("create legs never hung up on, yet resends=%d", c.Resends)
	}
	if rep.RoundsOK != 10 {
		t.Fatalf("rounds_ok=%d want 10", rep.RoundsOK)
	}
	if c.MaxMs < c.P95ms || c.P95ms < c.P50ms {
		t.Fatalf("percentiles out of order: %+v", c)
	}
}

func TestAllGreenExitsZeroAndTextReportCarriesSummary(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte(`{"results":[{"id":"drafts.task-1"}]}`))
	}))
	defer srv.Close()
	var out, errb bytes.Buffer
	code := run([]string{"--server", srv.URL, "--rounds", "5", "--concurrency", "2", "--desc-bytes", "3400"}, &out, &errb, http.DefaultTransport)
	if code != 0 {
		t.Fatalf("exit=%d stderr=%s out=%s", code, errb.String(), out.String())
	}
	if !strings.Contains(out.String(), "SUMMARY rounds_ok=5/5 failed=0") || !strings.Contains(out.String(), "desc_bytes: 3400") {
		t.Fatalf("report missing summary:\n%s", out.String())
	}
}

type countingRT struct{ n atomic.Int64 }

func (c *countingRT) RoundTrip(*http.Request) (*http.Response, error) {
	c.n.Add(1)
	return nil, errors.New("counting transport: no network in tests")
}

// The safety property: a non-loopback target is refused with exit 2 and ZERO
// requests, unless --i-own-this-target is passed.
func TestNonLoopbackTargetIsRefusedBeforeAnyRequest(t *testing.T) {
	for _, target := range []string{
		"https://guerrilla.barkpark.cloud",
		"https://api.barkpark.cloud",
		"http://89.167.28.206",
		"http://localhost.barkpark.cloud:4000",
		"http://10.0.0.5:4000",
		"http://[2001:db8::1]:4000",
		"ftp://localhost",
		"localhost:4000",
	} {
		rt := &countingRT{}
		code, _, stderr := runJSON(t, []string{"--server", target, "--rounds", "3"}, rt)
		if code != 2 || rt.n.Load() != 0 {
			t.Errorf("%s: exit=%d requests=%d, want exit 2 and 0 requests", target, code, rt.n.Load())
		}
		if !strings.Contains(stderr, "REFUSED") {
			t.Errorf("%s: stderr lacks REFUSED: %q", target, stderr)
		}
	}
}

func TestOwnTargetFlagPermitsNonLoopback(t *testing.T) {
	rt := &countingRT{}
	code, rep, _ := runJSON(t, []string{"--server", "https://box.example.com", "--i-own-this-target", "--ensure-tag=false", "--rounds", "3", "--concurrency", "1"}, rt)
	if code != 1 || rt.n.Load() != 3 || rep.Legs["create"].Classes["transport:other"] != 3 {
		t.Fatalf("exit=%d requests=%d classes=%v; want 1, 3 requests, 3 transport:other", code, rt.n.Load(), rep.Legs["create"].Classes)
	}
}

func TestLoopbackForms(t *testing.T) {
	for _, h := range []string{"http://localhost:4000", "http://LOCALHOST", "http://127.0.0.1:4001", "http://127.9.9.9", "http://[::1]:4000"} {
		if err := checkTarget(h, false); err != nil {
			t.Errorf("%s refused: %v", h, err)
		}
	}
}

func TestDescriptionIsExactSize(t *testing.T) {
	rnd := mrand.New(mrand.NewSource(1))
	for _, n := range []int{0, 1, 200, 3400} {
		if got := len(makeDescription(rnd, n)); got != n {
			t.Errorf("makeDescription(%d) len=%d", n, got)
		}
	}
}

func equalMap(a, b map[string]int) bool {
	if len(a) != len(b) {
		return false
	}
	for k, v := range a {
		if b[k] != v {
			return false
		}
	}
	return true
}

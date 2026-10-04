package cli

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/cloudclient"
)

// A box's last FAILED self-update reaches `bp cloud status`: the phase it failed
// in (build vs migrate) and the end of its redacted log, so an operator no
// longer needs SSH to the box's .deploy-status.json to learn why Gyldendal's
// update died before the swap.

func failedBox(name, phase string, code int, tail []string) cloudclient.Barkpark {
	return cloudclient.Barkpark{
		ID: name, Name: name, Slug: name, Host: "h",
		HealthStatus: "up", AgentStatus: "online", UpdateState: "behind",
		UpdateLastFailure: &cloudclient.UpdateFailure{
			Phase: phase, Source: "deploy_status", ExitCode: &code, Mode: "self_update",
			FinishedAt: "2026-10-04T20:00:00Z", Tail: tail,
		},
	}
}

func TestUpdateFailuresRenderPhaseAndTail(t *testing.T) {
	ranked := rankBarkparks([]cloudclient.Barkpark{
		failedBox("gyldendal", "build", 1, []string{"[deploy-rebuild] building aside", "** (CompileError) lib/x.ex:1"}),
		failedBox("dnd", "migrate", 13, []string{"ERROR 42P07 (duplicate_table)"}),
		{ID: "ok", Name: "fine", Slug: "fine", HealthStatus: "up", AgentStatus: "online"},
	})
	var sout, serr bytes.Buffer
	w := newWriter(&sout, &serr)
	w.color = false
	renderUpdateFailures(w, ranked)
	got := sout.String()

	for _, want := range []string{
		"LAST FAILED UPDATE (2)",
		"gyldendal: update failed in phase build · exit 1 · per the box's deploy-status record · at 2026-10-04T20:00:00Z",
		"    ** (CompileError) lib/x.ex:1",
		"dnd: update failed in phase migrate · exit 13",
		"    ERROR 42P07 (duplicate_table)",
	} {
		if !strings.Contains(got, want) {
			t.Fatalf("missing %q in:\n%s", want, got)
		}
	}
	if strings.Contains(got, "fine:") {
		t.Fatalf("a box with no failed run must not be listed:\n%s", got)
	}
}

func TestUpdateFailuresSilentWithNone(t *testing.T) {
	ranked := rankBarkparks([]cloudclient.Barkpark{{ID: "ok", Name: "fine", Slug: "fine"}})
	var sout, serr bytes.Buffer
	w := newWriter(&sout, &serr)
	renderUpdateFailures(w, ranked)
	if sout.Len() != 0 {
		t.Fatalf("no failed run must print nothing, got:\n%s", sout.String())
	}
}

func TestUpdateFailuresTableTailIsCapped(t *testing.T) {
	tail := make([]string, 40)
	for i := range tail {
		tail[i] = "line " + string(rune('A'+i%26))
	}
	tail[39] = "the last line"
	ranked := rankBarkparks([]cloudclient.Barkpark{failedBox("gyl", "build", 1, tail)})
	var sout, serr bytes.Buffer
	w := newWriter(&sout, &serr)
	w.color = false
	renderUpdateFailures(w, ranked)
	got := sout.String()
	if !strings.Contains(got, "25 earlier line(s) — full tail: bp cloud status -o json") {
		t.Fatalf("the table must say how much it left out:\n%s", got)
	}
	if !strings.Contains(got, "the last line") {
		t.Fatalf("the newest line must be printed:\n%s", got)
	}
}

// The machine reader gets the whole failure, keyed exactly as the plane sent it.
func TestRunCloudStatusJSONCarriesUpdateLastFailure(t *testing.T) {
	withTempConfigHome(t)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/v1/deploy-ledger/census":
			_, _ = io.WriteString(w, `{"volume":0,"failed":0,"failure_rate":{"sample":0,"pct":null,"numerator":0,"min_sample":200,"refused":true,"reason":"sample 0 below min_sample 200"},"classes":[],"not_attempted":[],"sites":[],"min_sample":200}`)
			return
		case "/v1/sites":
			_, _ = io.WriteString(w, `{"sites":[]}`)
			return
		}
		_, _ = io.WriteString(w, `{"barkparks":[
			{"id":"g","name":"gyldendal","host":"h","health_status":"up","agent_status":"online","update_state":"behind","queued_deploy_age_seconds":null,
			 "update_last_failure":{"phase":"migrate","source":"deploy_status","exit_code":13,"mode":"self_update","finished_at":"2026-10-04T20:00:00Z","tail":["ERROR 42P07"]}},
			{"id":"o","name":"fine","host":"h","health_status":"up","agent_status":"online","update_state":"current","queued_deploy_age_seconds":null,"update_last_failure":null}
		]}`)
	}))
	defer srv.Close()
	seedCloudLogin(t, srv.URL)

	stdout, _, code := runCloudCapture(t, true, func(out *writer) int {
		return runCloudStatus(out, globals{}, nil)
	})
	if code != exitOK {
		t.Fatalf("exit = %d\n%s", code, stdout)
	}
	var env struct {
		Barkparks []map[string]any `json:"barkparks"`
	}
	if err := json.Unmarshal([]byte(stdout), &env); err != nil {
		t.Fatalf("not json: %v\n%s", err, stdout)
	}
	byName := map[string]map[string]any{}
	for _, row := range env.Barkparks {
		byName[row["name"].(string)] = row
	}
	f, ok := byName["gyldendal"]["update_last_failure"].(map[string]any)
	if !ok {
		t.Fatalf("gyldendal row lacks update_last_failure: %v", byName["gyldendal"])
	}
	if f["phase"] != "migrate" || f["exit_code"] != float64(13) {
		t.Fatalf("wrong failure: %v", f)
	}
	if _, present := byName["fine"]["update_last_failure"]; present {
		t.Fatalf("a box with no failed run must carry no key: %v", byName["fine"])
	}
}

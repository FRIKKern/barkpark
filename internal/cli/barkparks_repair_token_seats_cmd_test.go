package cli

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

const repairBoxID = "b1ed9b5d-247f-4122-98ea-f4af7f317576"

const repairDryRunBody = `{"ok":true,"barkpark_id":"` + repairBoxID + `","restore":{"token_id":"tok-new","predecessors":["tok-old"],
"restore":[{"workspace":"gyldendal-no","role":"admin","from_token":"tok-old"},{"workspace":"gyldendal-agency-twin","role":"admin","from_token":"tok-old"}],
"already":["default"],"refused":[],"applied":false}}`

type repairPlane struct {
	hits int
	path string
	body map[string]any
}

func newRepairPlane(t *testing.T, status int, resp string) (*httptest.Server, *repairPlane) {
	t.Helper()
	p := &repairPlane{}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		p.hits++
		p.path = r.URL.Path
		if r.Method != http.MethodPost {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		raw, _ := io.ReadAll(r.Body)
		_ = json.Unmarshal(raw, &p.body)
		w.WriteHeader(status)
		_, _ = io.WriteString(w, resp)
	}))
	t.Cleanup(srv.Close)
	return srv, p
}

func TestRepairTokenSeatsDryRunIsTheDefault(t *testing.T) {
	withTempConfigHome(t)
	srv, plane := newRepairPlane(t, http.StatusOK, repairDryRunBody)
	seedCloudLogin(t, srv.URL)

	stdout, stderr, code := runCloudCapture(t, false, func(out *writer) int {
		out.output = "table"
		return runBarkparks(out, []string{"repair-token-seats", repairBoxID, "--seat", "gyldendal-no", "--seat=gyldendal-agency-twin"})
	})
	if code != exitOK {
		t.Fatalf("exit = %d\n%s\n%s", code, stdout, stderr)
	}
	if plane.path != "/v1/operator/barkparks/"+repairBoxID+"/token-seats/restore" {
		t.Fatalf("path = %s", plane.path)
	}
	if plane.body["apply"] != false {
		t.Fatalf("apply must default to false; body = %v", plane.body)
	}
	if _, ok := plane.body["token"]; ok {
		t.Fatalf("no --token-id means no token in the body; body = %v", plane.body)
	}
	ws, _ := plane.body["workspaces"].([]any)
	if len(ws) != 2 || ws[0] != "gyldendal-no" || ws[1] != "gyldendal-agency-twin" {
		t.Fatalf("workspaces = %v", plane.body["workspaces"])
	}
	for _, want := range []string{"Dry run for token tok-new", "pass --apply", "revoked predecessors: tok-old", "would restore: gyldendal-no as admin, held by tok-old", "already seated: default"} {
		if !strings.Contains(stdout, want) {
			t.Fatalf("stdout missing %q:\n%s", want, stdout)
		}
	}
}

func TestRepairTokenSeatsApplySendsTokenAndCommaList(t *testing.T) {
	withTempConfigHome(t)
	applied := strings.Replace(repairDryRunBody, `"applied":false`, `"applied":true`, 1)
	srv, plane := newRepairPlane(t, http.StatusOK, applied)
	seedCloudLogin(t, srv.URL)

	stdout, _, code := runCloudCapture(t, false, func(out *writer) int {
		out.output = "table"
		return runBarkparks(out, []string{"repair-token-seats", repairBoxID, "--token-id", "tok-new", "--seat", "a,b", "--apply"})
	})
	if code != exitOK {
		t.Fatalf("exit = %d\n%s", code, stdout)
	}
	if plane.body["apply"] != true || plane.body["token"] != "tok-new" {
		t.Fatalf("body = %v", plane.body)
	}
	if ws, _ := plane.body["workspaces"].([]any); len(ws) != 2 {
		t.Fatalf("workspaces = %v", plane.body["workspaces"])
	}
	if !strings.Contains(stdout, "Restored seats for token tok-new") || !strings.Contains(stdout, "restored: gyldendal-no") {
		t.Fatalf("stdout:\n%s", stdout)
	}
}

func TestRepairTokenSeatsRefusedSeatExitsNonZero(t *testing.T) {
	withTempConfigHome(t)
	body := `{"ok":true,"barkpark_id":"` + repairBoxID + `","restore":{"token_id":"tok-new","predecessors":[],"restore":[],"already":[],"refused":[{"workspace":"x","reason":"not_held_before"}],"applied":false}}`
	srv, _ := newRepairPlane(t, http.StatusOK, body)
	seedCloudLogin(t, srv.URL)

	stdout, _, code := runCloudCapture(t, false, func(out *writer) int {
		out.output = "table"
		return runBarkparks(out, []string{"repair-token-seats", repairBoxID, "--seat", "x"})
	})
	if code != exitGeneric {
		t.Fatalf("exit = %d, want %d\n%s", code, exitGeneric, stdout)
	}
	if !strings.Contains(stdout, "refused: x (not_held_before)") || !strings.Contains(stdout, "none found") {
		t.Fatalf("stdout:\n%s", stdout)
	}
}

func TestRepairTokenSeatsCloudRefusalSurfaces(t *testing.T) {
	withTempConfigHome(t)
	srv, _ := newRepairPlane(t, http.StatusConflict, `{"error":"seat_not_held_before","detail":"No revoked predecessor of the token held a seat in x. Nothing changed."}`)
	seedCloudLogin(t, srv.URL)

	stdout, stderr, code := runCloudCapture(t, false, func(out *writer) int {
		out.output = "table"
		return runBarkparks(out, []string{"repair-token-seats", repairBoxID, "--seat", "x", "--apply"})
	})
	if code == exitOK {
		t.Fatalf("a refusal must not exit 0\n%s", stdout)
	}
	if !strings.Contains(stdout+stderr, "seat_not_held_before") {
		t.Fatalf("output must name the code:\n%s\n%s", stdout, stderr)
	}
}

func TestRepairTokenSeatsJSONReemitsTheEnvelope(t *testing.T) {
	withTempConfigHome(t)
	srv, _ := newRepairPlane(t, http.StatusOK, repairDryRunBody)
	seedCloudLogin(t, srv.URL)

	stdout, _, code := runCloudCapture(t, false, func(out *writer) int {
		out.output = "json"
		return runBarkparks(out, []string{"repair-token-seats", repairBoxID})
	})
	if code != exitOK {
		t.Fatalf("exit = %d\n%s", code, stdout)
	}
	var got map[string]any
	if err := json.Unmarshal([]byte(stdout), &got); err != nil {
		t.Fatalf("stdout is not one JSON object: %v\n%s", err, stdout)
	}
	if r, _ := got["restore"].(map[string]any); r["token_id"] != "tok-new" {
		t.Fatalf("envelope = %v", got)
	}
}

func TestRepairTokenSeatsUsageRefusesBeforeAnyRequest(t *testing.T) {
	for _, args := range [][]string{
		{"repair-token-seats"},
		{"repair-token-seats", repairBoxID, "--seat"},
		{"repair-token-seats", repairBoxID, "--bogus", "x"},
		{"repair-token-seats", repairBoxID, "extra"},
		{"repair-token-seats", repairBoxID, "--apply=false"},
	} {
		withTempConfigHome(t)
		srv, plane := newRepairPlane(t, http.StatusOK, repairDryRunBody)
		seedCloudLogin(t, srv.URL)
		_, _, code := runCloudCapture(t, false, func(out *writer) int {
			out.output = "table"
			return runBarkparks(out, args)
		})
		if code != exitUsage {
			t.Fatalf("%v: exit = %d, want %d", args, code, exitUsage)
		}
		if plane.hits != 0 {
			t.Fatalf("%v: a usage error must not reach the plane", args)
		}
	}
}

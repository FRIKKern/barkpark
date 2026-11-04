package cli

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"
)

const sha1BoxID = "b1ed9b5d-247f-4122-98ea-f4af7f317576"

const sha1DryRunBody = `{"ok":true,"barkpark_id":"` + sha1BoxID + `","backfill":{"applied":false,"unhashed":1299,
"datasets":[{"workspace":"gyldendal-no","dataset":"production","unhashed":1299}]}}`

type sha1Plane struct {
	bodies  []map[string]any
	path    string
	replies []string
	status  int
}

func newSha1Plane(t *testing.T, status int, replies ...string) (*httptest.Server, *sha1Plane) {
	t.Helper()
	p := &sha1Plane{replies: replies, status: status}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		p.path = r.URL.Path
		raw, _ := io.ReadAll(r.Body)
		var body map[string]any
		_ = json.Unmarshal(raw, &body)
		p.bodies = append(p.bodies, body)
		i := len(p.bodies) - 1
		if i >= len(p.replies) {
			i = len(p.replies) - 1
		}
		w.WriteHeader(p.status)
		_, _ = io.WriteString(w, p.replies[i])
	}))
	t.Cleanup(srv.Close)
	return srv, p
}

func sha1Page(hashed int, failed string, next string, unhashed int) string {
	nextJSON := "null"
	if next != "" {
		nextJSON = `"` + next + `"`
	}
	return `{"ok":true,"barkpark_id":"` + sha1BoxID + `","backfill":{"applied":true,"hashed":` +
		strconv.Itoa(hashed) + `,"failed":[` + failed + `],"next_after":` + nextJSON + `,"unhashed":` + strconv.Itoa(unhashed) + `}}`
}

func TestBackfillMediaSha1DryRunIsTheDefault(t *testing.T) {
	withTempConfigHome(t)
	srv, plane := newSha1Plane(t, http.StatusOK, sha1DryRunBody)
	seedCloudLogin(t, srv.URL)

	stdout, stderr, code := runCloudCapture(t, false, func(out *writer) int {
		out.output = "table"
		return runBarkparks(out, []string{"backfill-media-sha1", sha1BoxID})
	})
	if code != exitOK {
		t.Fatalf("exit = %d\n%s\n%s", code, stdout, stderr)
	}
	if plane.path != "/v1/operator/barkparks/"+sha1BoxID+"/media-sha1-backfill" {
		t.Fatalf("path = %s", plane.path)
	}
	if len(plane.bodies) != 1 || plane.bodies[0]["apply"] != false {
		t.Fatalf("one request with apply false; bodies = %v", plane.bodies)
	}
	if _, ok := plane.bodies[0]["after"]; ok {
		t.Fatalf("a dry run sends no cursor; body = %v", plane.bodies[0])
	}
	for _, want := range []string{"Dry run on", "pass --apply", "media files with no SHA-1: 1299", "gyldendal-no/production: 1299"} {
		if !strings.Contains(stdout, want) {
			t.Fatalf("stdout missing %q:\n%s", want, stdout)
		}
	}
}

func TestBackfillMediaSha1ApplyFollowsTheCursor(t *testing.T) {
	withTempConfigHome(t)
	srv, plane := newSha1Plane(t, http.StatusOK,
		sha1Page(200, "", "id-200", 1099),
		sha1Page(199, `{"id":"id-399","workspace":"gyldendal-no","dataset":"production","reason":"blob_not_found"}`, "", 1))
	seedCloudLogin(t, srv.URL)

	stdout, stderr, code := runCloudCapture(t, false, func(out *writer) int {
		out.output = "table"
		return runBarkparks(out, []string{"backfill-media-sha1", sha1BoxID, "--apply", "--page-size", "200"})
	})
	if code != exitGeneric {
		t.Fatalf("a failed file exits 1; exit = %d\n%s\n%s", code, stdout, stderr)
	}
	if len(plane.bodies) != 2 {
		t.Fatalf("want 2 pages, got %d: %v", len(plane.bodies), plane.bodies)
	}
	if plane.bodies[0]["apply"] != true || plane.bodies[0]["limit"] != float64(200) {
		t.Fatalf("first body = %v", plane.bodies[0])
	}
	if _, ok := plane.bodies[0]["after"]; ok {
		t.Fatalf("the first page sends no cursor; body = %v", plane.bodies[0])
	}
	if plane.bodies[1]["after"] != "id-200" {
		t.Fatalf("second page must send the cursor; body = %v", plane.bodies[1])
	}
	for _, want := range []string{"Hashed 399 media file(s)", "in 2 page(s)", "could not hash: 1", "id-399 gyldendal-no/production: blob_not_found", "still with no SHA-1: 1"} {
		if !strings.Contains(stdout, want) {
			t.Fatalf("stdout missing %q:\n%s", want, stdout)
		}
	}
	if !strings.Contains(stderr, "page 2: 199 hashed, 1 failed") {
		t.Fatalf("stderr missing progress:\n%s", stderr)
	}
}

func TestBackfillMediaSha1ApplyJSON(t *testing.T) {
	withTempConfigHome(t)
	srv, _ := newSha1Plane(t, http.StatusOK, sha1Page(8, "", "", 0))
	seedCloudLogin(t, srv.URL)

	stdout, _, code := runCloudCapture(t, false, func(out *writer) int {
		out.output = "json"
		return runBarkparks(out, []string{"backfill-media-sha1", sha1BoxID, "--apply"})
	})
	if code != exitOK {
		t.Fatalf("exit = %d\n%s", code, stdout)
	}
	var got map[string]any
	if err := json.Unmarshal([]byte(stdout), &got); err != nil {
		t.Fatalf("stdout is not JSON: %v\n%s", err, stdout)
	}
	if got["hashed"] != float64(8) || got["pages"] != float64(1) || got["applied"] != true {
		t.Fatalf("json = %v", got)
	}
	if f, _ := got["failed"].([]any); f == nil || len(f) != 0 {
		t.Fatalf("failed must be an empty list; json = %v", got)
	}
}

func TestBackfillMediaSha1CloudRefusal(t *testing.T) {
	withTempConfigHome(t)
	srv, _ := newSha1Plane(t, http.StatusConflict, `{"error":"box_too_old","missing":"POST /v1/admin/media/sha1-backfill","detail":"Update the box first."}`)
	seedCloudLogin(t, srv.URL)

	_, stderr, code := runCloudCapture(t, false, func(out *writer) int {
		out.output = "table"
		return runBarkparks(out, []string{"backfill-media-sha1", sha1BoxID, "--apply"})
	})
	if code == exitOK {
		t.Fatalf("a refusal must not exit 0")
	}
	if !strings.Contains(stderr, "box_too_old") {
		t.Fatalf("stderr missing the refusal:\n%s", stderr)
	}
}

func TestBackfillMediaSha1UsageErrorsMakeNoRequest(t *testing.T) {
	withTempConfigHome(t)
	srv, plane := newSha1Plane(t, http.StatusOK, sha1DryRunBody)
	seedCloudLogin(t, srv.URL)

	for _, args := range [][]string{
		{"backfill-media-sha1"},
		{"backfill-media-sha1", sha1BoxID, "--page-size", "0"},
		{"backfill-media-sha1", sha1BoxID, "--page-size", "501"},
		{"backfill-media-sha1", sha1BoxID, "--apply=no"},
		{"backfill-media-sha1", sha1BoxID, "--bogus"},
		{"backfill-media-sha1", sha1BoxID, "extra"},
	} {
		_, _, code := runCloudCapture(t, false, func(out *writer) int {
			out.output = "table"
			return runBarkparks(out, args)
		})
		if code != exitUsage {
			t.Fatalf("%v: exit = %d, want usage", args, code)
		}
	}
	if len(plane.bodies) != 0 {
		t.Fatalf("usage errors made %d request(s)", len(plane.bodies))
	}
}

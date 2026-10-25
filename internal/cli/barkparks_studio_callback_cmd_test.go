package cli

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

const studioCallbackID = "b1ed9b5d-247f-4122-98ea-f4af7f317576"

func TestBarkparksStudioCallbackAddByNameSendsTheURL(t *testing.T) {
	withTempConfigHome(t)
	var method, path string
	var body map[string]any
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/v1/barkparks" {
			_, _ = io.WriteString(w, `{"barkparks":[{"id":"`+studioCallbackID+`","name":"gyl","slug":"gyl"}]}`)
			return
		}
		method, path = r.Method, r.URL.Path
		raw, _ := io.ReadAll(r.Body)
		_ = json.Unmarshal(raw, &body)
		_, _ = io.WriteString(w, `{"studio_callbacks":["https://pensum-studio.vercel.app/auth/cloud/callback"]}`)
	}))
	t.Cleanup(srv.Close)
	seedCloudLogin(t, srv.URL)

	stdout, stderr, code := runCloudCapture(t, false, func(out *writer) int {
		out.output = "table"
		return runBarkparks(out, []string{"studio-origin", "add", "gyl", "https://pensum-studio.vercel.app/auth/cloud/callback"})
	})
	if code != exitOK {
		t.Fatalf("exit = %d\n%s\n%s", code, stdout, stderr)
	}
	if method != http.MethodPost || path != "/v1/barkparks/"+studioCallbackID+"/studio-callbacks" {
		t.Fatalf("request = %s %s", method, path)
	}
	if body["url"] != "https://pensum-studio.vercel.app/auth/cloud/callback" {
		t.Fatalf("body = %v", body)
	}
	if !strings.Contains(stdout, "https://pensum-studio.vercel.app/auth/cloud/callback") {
		t.Fatalf("stdout = %s", stdout)
	}
}

func TestBarkparksStudioCallbackRefusalIsAnError(t *testing.T) {
	withTempConfigHome(t)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusUnprocessableEntity)
		_, _ = io.WriteString(w, `{"error":"invalid_url","detail":"The Studio callback must use https://."}`)
	}))
	t.Cleanup(srv.Close)
	seedCloudLogin(t, srv.URL)

	_, stderr, code := runCloudCapture(t, false, func(out *writer) int {
		out.output = "table"
		return runBarkparks(out, []string{"studio-callback", "add", studioCallbackID, "http://studio.example.com/cb"})
	})
	if code == exitOK || !strings.Contains(stderr, "invalid_url") {
		t.Fatalf("exit = %d, stderr = %s", code, stderr)
	}
}

func TestBarkparksStudioCallbackUsage(t *testing.T) {
	withTempConfigHome(t)
	_, _, code := runCloudCapture(t, false, func(out *writer) int {
		return runBarkparks(out, []string{"studio-callback", "add", "gyl"})
	})
	if code != exitUsage {
		t.Fatalf("exit = %d, want usage", code)
	}
}

package cli

import (
	"bytes"
	"encoding/json"
	"net/http"
	"testing"
)

// task-2b8d011b6c573467: with -o json a rate-limited call printed the code
// rate_limited but neither 429 nor how long to wait, so a script looking for
// the status gave up instead of waiting. The envelope now carries both.
func TestJSONErrorCarriesStatusAndRetryAfter(t *testing.T) {
	body := []byte(`{"error":{"code":"rate_limited","message":"too many requests","details":{"retry_after":7}}}`)
	got := renderedError(t, classifyErrorWithHeader(429, body, http.Header{}))
	if got["status"] != float64(429) || got["retry_after"] != float64(7) || got["code"] != "rate_limited" {
		t.Fatalf("want status 429, retry_after 7, code rate_limited; got %v", got)
	}

	// No retry_after in details: the Retry-After header answers.
	hdr := http.Header{}
	hdr.Set("Retry-After", "12")
	got = renderedError(t, classifyErrorWithHeader(429, []byte(`{"error":{"code":"rate_limited","message":"x"}}`), hdr))
	if got["retry_after"] != float64(12) {
		t.Fatalf("want retry_after 12 from the header; got %v", got)
	}

	// A refusal with no wait carries its status and no retry_after.
	got = renderedError(t, classifyErrorWithHeader(404, []byte(`{"error":{"code":"not_found","message":"x"}}`), http.Header{}))
	if got["status"] != float64(404) {
		t.Fatalf("want status 404; got %v", got)
	}
	if _, ok := got["retry_after"]; ok {
		t.Fatalf("want no retry_after; got %v", got)
	}
}

func renderedError(t *testing.T, ae apiError) map[string]any {
	t.Helper()
	var so, se bytes.Buffer
	renderError(&writer{stdout: &so, stderr: &se, output: "json"}, ae)
	var env struct {
		OK    bool           `json:"ok"`
		Error map[string]any `json:"error"`
	}
	if err := json.Unmarshal(so.Bytes(), &env); err != nil {
		t.Fatalf("not JSON: %v: %s", err, so.String())
	}
	if env.OK {
		t.Fatalf("want ok:false: %s", so.String())
	}
	return env.Error
}

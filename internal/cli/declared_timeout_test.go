// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

package cli

import (
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// task-597c98acab512fbf: a 50-file `bp media delete-many` ran 172.7 s on the
// server while bp stopped waiting at 30 s and printed no result. A command
// whose manifest declares timeout_seconds now carries that budget on its
// request, and the send uses it.
func deleteManyCommand(timeoutSeconds int) manifest.Command {
	return manifest.Command{
		ID:             "media.delete-many",
		Noun:           "media",
		Verb:           "delete-many",
		HTTP:           manifest.HTTP{Method: "POST", PathTemplate: "/v1/media/:dataset/delete-many"},
		AuthTier:       "write",
		Flags:          []manifest.Flag{{Name: "ids", Type: "string"}, {Name: "force", Type: "bool"}},
		Writes:         true,
		WritesDeclared: true,
		DefaultOutput:  "json",
		TimeoutSeconds: timeoutSeconds,
	}
}

func TestDeclaredTimeoutRidesTheRequest(t *testing.T) {
	ctx := manifest.Context{Server: "https://example.invalid", Dataset: "production", Token: "bppat_test"}
	m := &manifest.Manifest{Commands: []manifest.Command{deleteManyCommand(300)}}

	cases := []struct {
		declared int
		want     time.Duration
	}{
		{300, 300 * time.Second},
		// Zero, or no longer than the default, keeps the default client.
		{0, 0},
		{10, 0},
		{30, 0},
	}
	for _, tc := range cases {
		req, derr := buildManifestRequest(globals{}, ctx, m, deleteManyCommand(tc.declared), []string{"--ids", "a,b"}, false)
		if derr != nil {
			t.Fatalf("buildManifestRequest(timeout_seconds=%d): %v", tc.declared, derr)
		}
		if req.timeout != tc.want {
			t.Errorf("timeout_seconds=%d: request timeout = %v, want %v", tc.declared, req.timeout, tc.want)
		}
	}
}

// The send for a declared timeout reaches the server and returns its answer
// through the longer-budget client.
func TestDeclaredTimeoutSendUsesItsClient(t *testing.T) {
	if got := dispatchClientWithTimeout(300 * time.Second).Timeout; got != 300*time.Second {
		t.Fatalf("dispatchClientWithTimeout(300s).Timeout = %v, want 300s", got)
	}

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"result":{"deleted":["a"],"gone":[],"refused":[]}}`))
	}))
	defer srv.Close()

	status, body, _, err := sendManifestRequest(&manifestRequest{
		method:  "POST",
		url:     srv.URL + "/v1/media/production/delete-many",
		headers: map[string]string{"Content-Type": "application/json"},
		body:    []byte(`{"ids":"a"}`),
		timeout: 300 * time.Second,
	})
	if err != nil || status != 200 {
		t.Fatalf("send = %d, %v; want 200, nil", status, err)
	}
	if string(body) != `{"result":{"deleted":["a"],"gone":[],"refused":[]}}` {
		t.Errorf("body = %s", body)
	}
}

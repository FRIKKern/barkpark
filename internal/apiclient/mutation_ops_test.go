package apiclient

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// mutateCaptureServer records the body POSTed to /v1/data/mutate and answers
// with a minimal results envelope. Any other path is an unexpected call.
func mutateCaptureServer(t *testing.T, body *[]byte) *httptest.Server {
	t.Helper()
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.Contains(r.URL.Path, "/v1/data/mutate/") {
			*body, _ = io.ReadAll(r.Body)
			_, _ = w.Write([]byte(`{"transactionId":"t1","results":[{"id":"drafts.post-9","operation":"create"}]}`))
			return
		}
		t.Errorf("unexpected request: %s %s", r.Method, r.URL.Path)
		w.WriteHeader(http.StatusNotFound)
	}))
}

// parseSingleMutation unmarshals the captured body and returns the sole
// mutation's op key + its inner field map. Each mutation is a one-key map
// ({"publish": {...}}), so this asserts exactly-one and returns {key, fields}.
func parseSingleMutation(t *testing.T, body []byte) (string, map[string]any) {
	t.Helper()
	var env struct {
		Mutations []map[string]map[string]any `json:"mutations"`
	}
	if err := json.Unmarshal(body, &env); err != nil {
		t.Fatalf("parse mutate body %q: %v", body, err)
	}
	if len(env.Mutations) != 1 {
		t.Fatalf("want exactly 1 mutation, got %d (%q)", len(env.Mutations), body)
	}
	for k, fields := range env.Mutations[0] {
		return k, fields
	}
	t.Fatalf("mutation had no op key: %q", body)
	return "", nil
}

// The id/type-shaped write ops (publish/unpublish/discardDraft/delete) must each
// emit their own op key carrying {id, type} — a wrong key or swapped field is a
// silent data-mutation regression these guard against.
func TestIdTypeMutationOpsWireShape(t *testing.T) {
	cases := []struct {
		name    string
		call    func(c *Client)
		wantKey string
	}{
		{"Publish", func(c *Client) { _ = c.Publish("post", "p1") }, "publish"},
		{"Unpublish", func(c *Client) { _ = c.Unpublish("post", "p1") }, "unpublish"},
		{"DiscardDraft", func(c *Client) { _ = c.DiscardDraft("post", "p1") }, "discardDraft"},
		{"Delete", func(c *Client) { _ = c.Delete("post", "p1") }, "delete"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var body []byte
			srv := mutateCaptureServer(t, &body)
			defer srv.Close()
			c := New(Config{BaseURL: srv.URL, Token: "t", Dataset: "production"})

			tc.call(c)

			key, fields := parseSingleMutation(t, body)
			if key != tc.wantKey {
				t.Errorf("op key = %q, want %q", key, tc.wantKey)
			}
			if fields["id"] != "p1" {
				t.Errorf("id = %v, want p1", fields["id"])
			}
			if fields["type"] != "post" {
				t.Errorf("type = %v, want post", fields["type"])
			}
		})
	}
}

// Create emits a `create` op with {_type, title} and NO _id (server assigns it),
// and returns the server-assigned draft id from the results envelope.
func TestCreateMutationWireShapeAndReturnedID(t *testing.T) {
	var body []byte
	srv := mutateCaptureServer(t, &body)
	defer srv.Close()
	c := New(Config{BaseURL: srv.URL, Token: "t", Dataset: "production"})

	id, err := c.Create("post", "Hello")
	if err != nil {
		t.Fatalf("Create: %v", err)
	}
	if id != "drafts.post-9" {
		t.Errorf("returned id = %q, want the server-assigned drafts.post-9", id)
	}

	key, fields := parseSingleMutation(t, body)
	if key != "create" {
		t.Errorf("op key = %q, want create", key)
	}
	if fields["_type"] != "post" {
		t.Errorf("_type = %v, want post", fields["_type"])
	}
	if fields["title"] != "Hello" {
		t.Errorf("title = %v, want Hello", fields["title"])
	}
	if _, ok := fields["_id"]; ok {
		t.Errorf("create must not carry _id (server assigns it); got %v", fields["_id"])
	}
}

// Delete returns nil on a successful mutate, and on failure surfaces the server's
// status + body verbatim (via humanAPIError) rather than swallowing it into a bare
// bool — the destructive delete must show WHY a 403/409 failed. Mirrors how the
// sibling id/type mutations return their error.
func TestDeleteReturnsMutateError(t *testing.T) {
	t.Run("success returns nil", func(t *testing.T) {
		var body []byte
		srv := mutateCaptureServer(t, &body)
		defer srv.Close()
		c := New(Config{BaseURL: srv.URL, Token: "t", Dataset: "production"})

		if err := c.Delete("post", "p1"); err != nil {
			t.Errorf("Delete on 200: err = %v, want nil", err)
		}
	})

	t.Run("failure surfaces server status and body", func(t *testing.T) {
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			w.WriteHeader(http.StatusConflict)
			_, _ = w.Write([]byte(`{"error":{"code":"conflict","message":"doc is referenced"}}`))
		}))
		defer srv.Close()
		c := New(Config{BaseURL: srv.URL, Token: "t", Dataset: "production"})

		err := c.Delete("post", "p1")
		if err == nil {
			t.Fatalf("Delete on 409: err = nil, want the server error")
		}
		if !strings.Contains(err.Error(), "doc is referenced") {
			t.Errorf("Delete error = %q, want it to carry the server message", err.Error())
		}
	})
}
